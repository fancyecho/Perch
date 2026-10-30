import Foundation
import UserNotifications

/// Mirrors timed, open tasks into local notifications.
final class ReminderScheduler: NSObject, UNUserNotificationCenterDelegate {
    var onOpen: (() -> Void)?
    /// While the notch island announces reminders, notifications only go to Notification Center,
    /// without a banner or sound of their own.
    var deliversQuietly = false
    private var syncTask: Task<Void, Never>?
    private var isAuthorized: Bool?

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

    func sync(_ tasks: [TaskItem]) {
        guard let center else { return }
        syncTask?.cancel()
        let now = Date.now
        let upcoming = tasks
            .compactMap { task -> (TaskItem, Date)? in
                guard !task.isDone, let time = task.schedule?.time, time > now else { return nil }
                return (task, time)
            }
            .sorted { $0.1 < $1.1 }
            .prefix(50)

        syncTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            center.removeAllPendingNotificationRequests()
            guard !upcoming.isEmpty else { return }
            if isAuthorized == nil {
                isAuthorized = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            }
            guard isAuthorized == true else { return }
            for (task, time) in upcoming {
                let content = UNMutableNotificationContent()
                content.title = task.title
                content.body = tr("到时间了 · \(DateText.time(time))", "Due now · \(DateText.time(time))")
                content.sound = deliversQuietly ? nil : .default
                content.interruptionLevel = deliversQuietly ? .passive : .active
                var components = Self.utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: time)
                components.calendar = Self.utc
                components.timeZone = Self.utc.timeZone
                let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
                let request = UNNotificationRequest(identifier: task.id.uuidString, content: content, trigger: trigger)
                try? await center.add(request)
            }
        }
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
        await MainActor.run { onOpen?() }
    }
}
