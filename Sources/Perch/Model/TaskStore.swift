import Foundation
import Observation

nonisolated private struct StoreFile: Codable, Sendable {
    var tasks: [TaskItem]
    var focus: FocusSession?
}

struct Notice: Identifiable, Equatable {
    struct Snapshot: Equatable {
        let tasks: [TaskItem]
        let focus: FocusSession?
    }

    let id = UUID()
    let message: String
    let undo: Snapshot?
}

@Observable
final class TaskStore {
    private(set) var tasks: [TaskItem] = []
    private(set) var focus: FocusSession?
    var notice: Notice?

    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private let fileURL: URL

    init(fileURL: URL = TaskStore.defaultFileURL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let file = try? JSONDecoder.perch.decode(StoreFile.self, from: data) {
            tasks = file.tasks
            focus = file.focus
        } else {
            tasks = Self.welcomeTasks()
        }
    }

    static var defaultFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "Perch", directoryHint: .isDirectory).appending(path: "tasks.json")
    }

    private var calendar: Calendar { AppSettings.shared.calendar }

    func task(_ id: UUID) -> TaskItem? { tasks.first { $0.id == id } }

    // MARK: - Mutations

    @discardableResult
    func add(_ input: ParsedInput) -> TaskItem? {
        let title = input.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        let item = TaskItem(title: title, schedule: input.schedule, priority: input.priority, tags: input.tags)
        tasks.append(item)
        changed()
        return item
    }

    func complete(_ id: UUID) {
        guard let task = task(id), !task.isDone else { return }
        let snapshot = currentSnapshot
        update(id) { $0.completedAt = .now }
        if focus?.taskID == id { focus = nil }
        announce(tr("已完成「\(task.title)」", "Completed “\(task.title)”"), undo: snapshot)
        changed()
    }

    func reopen(_ id: UUID) {
        update(id) { $0.completedAt = nil }
        changed()
    }

    func delete(_ id: UUID) {
        guard let task = task(id) else { return }
        let snapshot = currentSnapshot
        tasks.removeAll { $0.id == id }
        if focus?.taskID == id { focus = nil }
        announce(tr("已删除「\(task.title)」", "Deleted “\(task.title)”"), undo: snapshot)
        changed()
    }

    func rename(_ id: UUID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        update(id) { $0.title = trimmed }
        changed()
    }

    /// Moves a task to another day. Timed tasks keep their wall-clock time in the selected
    /// time zone, so a 09:00 task is still at 09:00 after crossing a DST change.
    func schedule(_ id: UUID, day: Day?) {
        let cal = calendar
        update(id) { task in
            guard let day else {
                task.schedule = nil
                return
            }
            if let time = task.schedule?.time {
                let c = cal.dateComponents([.hour, .minute], from: time)
                task.schedule = .time(day.date(hour: c.hour ?? 9, minute: c.minute ?? 0, in: cal))
            } else {
                task.schedule = .day(day)
            }
        }
        changed()
    }

    func postponeToTomorrow(_ id: UUID, now: Date = .now) {
        guard let task = task(id) else { return }
        let snapshot = currentSnapshot
        schedule(id, day: Day(now, in: calendar).adding(days: 1))
        announce(tr("「\(task.title)」推迟到明天", "Moved “\(task.title)” to tomorrow"), undo: snapshot)
    }

    func setPriority(_ id: UUID, _ priority: Priority) {
        update(id) { $0.priority = priority }
        changed()
    }

    func startFocus(_ id: UUID) {
        guard let task = task(id) else { return }
        focus = FocusSession(taskID: id, startedAt: .now)
        announce(tr("开始专注「\(task.title)」", "Focusing on “\(task.title)”"), undo: nil)
        changed()
    }

    func stopFocus() {
        focus = nil
        changed()
    }

    func clearCompleted() {
        let snapshot = currentSnapshot
        let count = tasks.filter(\.isDone).count
        guard count > 0 else { return }
        tasks.removeAll(where: \.isDone)
        announce(tr("已清空 \(count) 项", "Cleared \(count) items"), undo: snapshot)
        changed()
    }

    func undo() {
        guard let snapshot = notice?.undo else { return }
        tasks = snapshot.tasks
        focus = snapshot.focus
        notice = nil
        changed()
    }

    func announce(_ message: String, undo: Notice.Snapshot?) {
        notice = Notice(message: message, undo: undo)
    }

    private var currentSnapshot: Notice.Snapshot { .init(tasks: tasks, focus: focus) }

    private func update(_ id: UUID, _ body: (inout TaskItem) -> Void) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        body(&tasks[index])
    }

    // MARK: - Persistence

    private func changed() {
        scheduleSave()
        onChange?()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let file = StoreFile(tasks: tasks, focus: focus)
        let url = fileURL
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            Self.write(file, to: url)
        }
    }

    func saveNow() {
        saveTask?.cancel()
        Self.write(StoreFile(tasks: tasks, focus: focus), to: fileURL)
    }

    nonisolated private static func write(_ file: StoreFile, to url: URL) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder.perch.encode(file)
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("Perch: failed to save tasks: \(error)")
        }
    }

    private static func welcomeTasks() -> [TaskItem] {
        let today = Day(.now, in: AppSettings.shared.calendar)
        return [
            TaskItem(title: tr("欢迎来到 Perch，双击文字可以编辑", "Welcome to Perch. Double-click text to edit"), schedule: .day(today), priority: .high),
            TaskItem(title: tr("在任务上用触控板向右扫 → 完成", "Swipe right on a task to complete it →"), schedule: .day(today), priority: .medium),
            TaskItem(title: tr("向左扫 ← 推迟到明天", "← Swipe left to move it to tomorrow"), schedule: .day(today), priority: .low),
            TaskItem(title: tr("用全局快捷键随时唤出，可在设置里修改", "Summon Perch with the global shortcut (change it in Settings)"), schedule: .day(today)),
            TaskItem(
                title: tr("试试输入「明天下午3点 写周报 !! #工作」", "Try typing “Report tomorrow 3pm !! #work”"),
                schedule: .day(today.adding(days: 1)),
                tags: [tr("入门", "intro")]
            ),
        ]
    }
}

// MARK: - Queries

extension TaskStore {
    private func today(_ now: Date) -> Day { Day(now, in: calendar) }

    func overdue(now: Date) -> [TaskItem] {
        let today = today(now)
        return sorted(tasks.filter { !$0.isDone && ($0.day(in: calendar).map { $0 < today } ?? false) })
    }

    func dueToday(now: Date) -> [TaskItem] {
        let today = today(now)
        return sorted(tasks.filter { !$0.isDone && $0.day(in: calendar) == today })
    }

    func doneToday(now: Date) -> [TaskItem] {
        let today = today(now)
        return tasks.filter { $0.completedAt.map { Day($0, in: calendar) == today } ?? false }
            .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
    }

    func upcoming(now: Date) -> [(day: Day, tasks: [TaskItem])] {
        let today = today(now)
        var groups: [Day: [TaskItem]] = [:]
        for task in tasks where !task.isDone {
            guard let day = task.day(in: calendar), day > today else { continue }
            groups[day, default: []].append(task)
        }
        return groups.keys.sorted().map { ($0, sorted(groups[$0, default: []])) }
    }

    func inbox() -> [TaskItem] {
        tasks.filter { !$0.isDone && $0.schedule == nil }
            .sorted { $0.priority != $1.priority ? $0.priority > $1.priority : $0.createdAt < $1.createdAt }
    }

    func completed() -> [TaskItem] {
        tasks.filter(\.isDone).sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
    }

    /// Open tasks for today (including overdue) plus what was completed today.
    func progress(now: Date) -> (done: Int, total: Int) {
        let open = overdue(now: now).count + dueToday(now: now).count
        let done = doneToday(now: now).count
        return (done, open + done)
    }

    func count(for tab: TaskTab, now: Date) -> Int {
        switch tab {
        case .today: overdue(now: now).count + dueToday(now: now).count
        case .upcoming: upcoming(now: now).reduce(0) { $0 + $1.tasks.count }
        case .inbox: inbox().count
        case .done: completed().count
        }
    }

    /// What the pill shows: the focused task, otherwise the next thing to do today.
    func headline(now: Date) -> TaskItem? {
        if let focus, let task = task(focus.taskID), !task.isDone { return task }
        return (overdue(now: now) + dueToday(now: now)).first
    }

    /// What the hover peek lists under the pill: the next few, without repeating the headline.
    func peekTasks(now: Date) -> [TaskItem] {
        let headlineID = headline(now: now)?.id
        let today = overdue(now: now) + dueToday(now: now)
        return (today.isEmpty ? inbox() : today).filter { $0.id != headlineID }
    }

    /// Day first (undated last), then timed tasks by time, then priority, then creation order.
    private func sorted(_ items: [TaskItem]) -> [TaskItem] {
        let cal = calendar
        return items.sorted { a, b in
            switch (a.day(in: cal), b.day(in: cal)) {
            case let (dayA?, dayB?) where dayA != dayB: return dayA < dayB
            case (nil, _?): return false
            case (_?, nil): return true
            default: break
            }
            if a.hasTime != b.hasTime { return a.hasTime }
            if let ta = a.schedule?.time, let tb = b.schedule?.time, ta != tb { return ta < tb }
            if a.priority != b.priority { return a.priority > b.priority }
            return a.createdAt < b.createdAt
        }
    }
}

extension JSONEncoder {
    nonisolated static var perch: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    nonisolated static var perch: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
