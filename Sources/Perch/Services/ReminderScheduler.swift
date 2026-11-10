import Foundation
import UserNotifications

/// Which edge of a task's time block a reminder marks.
nonisolated enum ReminderMoment: String, Equatable, Sendable {
    case start, end
}

/// What a reminder offers: done, ten more minutes before starting, or fifteen more to finish.
enum ReminderAction: String {
    case complete, snooze, extend
}

/// Which reminders are on (Settings › Tasks). With the timeline every timed task is a block, so
/// by default Perch speaks up when a block runs out rather than when it begins.
nonisolated struct ReminderTiming: Equatable, Sendable {
    var atStart: Bool
    var atEnd: Bool

    @MainActor static var current: ReminderTiming {
        let defaults = UserDefaults.standard
        return ReminderTiming(atStart: defaults.bool(forKey: Pref.remindAtStart), atEnd: defaults.bool(forKey: Pref.remindAtEnd))
    }

    var isOff: Bool { !atStart && !atEnd }
}

/// One moment worth a word: a task starting or its time running out.
nonisolated struct Reminder: Equatable, Sendable {
    let task: TaskItem
    let moment: ReminderMoment
    let time: Date
}

/// When the next reminders fall, and which ones fall together.
nonisolated enum ReminderClock {
    /// Every reminder still ahead, soonest first; at one moment a task ending comes before one starting.
    static func upcoming(after now: Date, in tasks: [TaskItem], timing: ReminderTiming) -> [Reminder] {
        tasks.flatMap { task -> [Reminder] in
            guard !task.isDone, let start = task.schedule?.time, let end = task.end else { return [] }
            var reminders: [Reminder] = []
            if timing.atStart, start > now { reminders.append(Reminder(task: task, moment: .start, time: start)) }
            if timing.atEnd, end > now { reminders.append(Reminder(task: task, moment: .end, time: end)) }
            return reminders
        }
        .sorted { a, b in
            if a.time != b.time { return a.time < b.time }
            return a.moment == .end && b.moment == .start
        }
    }

    static func next(after now: Date, in tasks: [TaskItem], timing: ReminderTiming) -> (time: Date, reminders: [Reminder])? {
        let upcoming = upcoming(after: now, in: tasks, timing: timing)
        guard let first = upcoming.first?.time else { return nil }
        return (first, upcoming.filter { $0.time == first })
    }

    /// The open task that picks up right where an ending one stops (starting within ten minutes),
    /// so the end of one block can point at the next.
    static func following(_ reminder: Reminder, in tasks: [TaskItem]) -> TaskItem? {
        guard reminder.moment == .end else { return nil }
        return tasks
            .filter { task in
                guard task.id != reminder.task.id, !task.isDone, let start = task.schedule?.time else { return false }
                let gap = start.timeIntervalSince(reminder.time)
                return gap >= -60 && gap <= 10 * 60
            }
            .min { ($0.schedule?.time ?? .distantFuture) < ($1.schedule?.time ?? .distantFuture) }
    }
}

/// Mirrors the reminders ahead into local notifications, with buttons to answer them in place.
final class ReminderScheduler: NSObject, UNUserNotificationCenterDelegate {
    var onOpen: (() -> Void)?
    var onAction: ((UUID, ReminderAction) -> Void)?
    /// While the notch island announces reminders, notifications only go to Notification Center,
    /// without a banner or sound of their own.
    var deliversQuietly = false
    private(set) var timing = ReminderTiming.current
    private var syncTask: Task<Void, Never>?
    private var isAuthorized: Bool?

    private nonisolated static let taskKey = "task"

    /// UNUserNotificationCenter raises if the process is not running from an app bundle.
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : .current()
    }

    /// Triggers are expressed in UTC: an absolute moment that no DST change can shift or double.
    private static let utc: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()

    func activate() {
        center?.delegate = self
    }

    /// Re-reads which reminders are on; true when that changed and the schedule needs rebuilding.
    func refreshTiming() -> Bool {
        let current = ReminderTiming.current
        guard current != timing else { return false }
        timing = current
        return true
    }

    func sync(_ tasks: [TaskItem]) {
        guard let center else { return }
        syncTask?.cancel()
        let upcoming = ReminderClock.upcoming(after: .now, in: tasks, timing: timing).prefix(50)

        syncTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            center.removeAllPendingNotificationRequests()
            guard !upcoming.isEmpty else { return }
            if isAuthorized == nil {
                isAuthorized = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            }
            guard isAuthorized == true else { return }
            center.setNotificationCategories(Self.categories)
            for reminder in upcoming {
                let content = UNMutableNotificationContent()
                content.title = reminder.task.title
                content.body = Self.body(for: reminder, next: ReminderClock.following(reminder, in: tasks))
                content.categoryIdentifier = reminder.moment.rawValue
                content.userInfo = [Self.taskKey: reminder.task.id.uuidString]
                content.sound = deliversQuietly ? nil : .default
                content.interruptionLevel = deliversQuietly ? .passive : .active
                var components = Self.utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: reminder.time)
                components.calendar = Self.utc
                components.timeZone = Self.utc.timeZone
                let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
                let id = "\(reminder.task.id.uuidString)-\(reminder.moment.rawValue)"
                try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
            }
        }
    }

    /// "Starting · 10:00 – 10:30" or "Time's up · 10:00 – 10:30 · Next: Read".
    static func body(for reminder: Reminder, next: TaskItem?) -> String {
        let range = DateText.timeRange(reminder.task) ?? DateText.time(reminder.time)
        switch reminder.moment {
        case .start:
            return tr("开始了 · \(range)", "Starting · \(range)")
        case .end:
            let body = tr("时间到了 · \(range)", "Time's up · \(range)")
            guard let next else { return body }
            return body + tr(" · 接下来「\(next.title)」", " · Next: \(next.title)")
        }
    }

    private static var categories: Set<UNNotificationCategory> {
        let done = UNNotificationAction(identifier: ReminderAction.complete.rawValue, title: tr("完成", "Done"))
        let later = UNNotificationAction(identifier: ReminderAction.snooze.rawValue, title: tr("10 分钟后开始", "Start in 10 min"))
        let more = UNNotificationAction(identifier: ReminderAction.extend.rawValue, title: tr("再给 15 分钟", "15 more minutes"))
        return [
            UNNotificationCategory(identifier: ReminderMoment.start.rawValue, actions: [done, later], intentIdentifiers: []),
            UNNotificationCategory(identifier: ReminderMoment.end.rawValue, actions: [done, more], intentIdentifiers: []),
        ]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        await MainActor.run { deliversQuietly } ? [.list] : [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let action = ReminderAction(rawValue: response.actionIdentifier)
        let id = (response.notification.request.content.userInfo[Self.taskKey] as? String).flatMap(UUID.init(uuidString:))
        await MainActor.run {
            if let action, let id {
                onAction?(id, action)
            } else {
                onOpen?()
            }
        }
    }
}
