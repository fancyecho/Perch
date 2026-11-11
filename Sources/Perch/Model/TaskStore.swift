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
    /// Called after a completion; `clearedToday` is true when nothing is left for today.
    @ObservationIgnored var onComplete: ((_ clearedToday: Bool, _ playsSound: Bool) -> Void)?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private let fileURL: URL

    /// Every change can be stepped back with ⌘Z (and forward again with ⇧⌘Z). Each entry is the
    /// state before one action; changes made in the same turn of the run loop (a drag let go, a
    /// step renamed and the next one opened) count as one.
    @ObservationIgnored private var undoStack: [Notice.Snapshot] = []
    @ObservationIgnored private var redoStack: [Notice.Snapshot] = []
    /// The state as of the last change, which becomes the undo entry for the next one.
    @ObservationIgnored private var committed = Notice.Snapshot(tasks: [], focus: nil)
    @ObservationIgnored private var groupOpen = false
    static let historyLimit = 50

    init(fileURL: URL = TaskStore.defaultFileURL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let file = try? JSONDecoder.perch.decode(StoreFile.self, from: data) {
            tasks = file.tasks
            focus = file.focus
        } else {
            tasks = Self.welcomeTasks()
        }
        committed = Self.meaningful(currentSnapshot)
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
        let item = TaskItem(title: title, schedule: input.schedule, priority: input.priority, tags: input.tags,
                            duration: input.duration, recurrence: input.recurrence)
        tasks.append(item)
        changed()
        return item
    }

    /// `playsSound` is false when the caller already gave feedback (the checkbox does, at click time).
    func complete(_ id: UUID, playsSound: Bool = true) {
        guard let task = task(id), !task.isDone else { return }
        let snapshot = currentSnapshot
        let wasForToday = task.day(in: calendar).map { $0 <= Day(.now, in: calendar) } ?? false
        update(id) { $0.completedAt = .now }
        if focus?.taskID == id { focus = nil }
        if let next = nextOccurrence(of: task) {
            tasks.append(next)
            let when = DateText.dueLabel(next, now: .now) ?? ""
            announce(tr("已完成「\(task.title)」· 下次 \(when)", "Completed “\(task.title)” · next \(when)"), undo: snapshot)
        } else {
            announce(tr("已完成「\(task.title)」", "Completed “\(task.title)”"), undo: snapshot)
        }
        changed()
        let progress = progress(now: .now)
        onComplete?(wasForToday && progress.done == progress.total, playsSound)
    }

    func reopen(_ id: UUID) {
        guard let task = task(id), task.isDone else { return }
        update(id) { $0.completedAt = nil }
        // A repeating task brought back takes the place of the one its completion added.
        if let next = nextOccurrence(of: task) {
            tasks.removeAll { other in
                !other.isDone && other.id != id && other.title == task.title && other.recurrence == task.recurrence
                    && other.schedule == next.schedule
            }
        }
        changed()
    }

    /// Skips this time of a repeating task: it moves on to its next day.
    func skip(_ id: UUID) {
        guard let task = task(id), let next = nextOccurrence(of: task) else { return }
        let snapshot = currentSnapshot
        update(id) { item in
            item.schedule = next.schedule
            item.subtasks = item.subtasks.map { Subtask(id: $0.id, title: $0.title) }
        }
        let when = DateText.dueLabel(next, now: .now) ?? ""
        announce(tr("跳过这次，下次 \(when)", "Skipped · next \(when)"), undo: snapshot)
        changed()
    }

    /// Makes a task repeat, or stop. A task without a date starts today; one on a day the rule
    /// skips moves to the first day it allows.
    func setRecurrence(_ id: UUID, _ recurrence: Recurrence?) {
        guard let task = task(id), task.recurrence != recurrence else { return }
        let cal = calendar
        update(id) { item in
            item.recurrence = recurrence
            guard let recurrence else { return }
            let current = item.day(in: cal) ?? Day(.now, in: cal)
            let day = recurrence.first(onOrAfter: current)
            item.schedule = Self.moving(item.schedule, to: day, in: cal) ?? .day(day)
        }
        changed()
    }

    /// The copy of a repeating task that comes after this one: on the next matching day after
    /// its own, but never before today, at the same time of day.
    func nextOccurrence(of task: TaskItem, now: Date = .now) -> TaskItem? {
        guard let recurrence = task.recurrence, let day = task.day(in: calendar) else { return nil }
        let today = Day(now, in: calendar)
        var next = recurrence.next(after: day, anchor: day)
        while next < today { next = recurrence.next(after: next, anchor: day) }
        var copy = TaskItem(title: task.title, schedule: Self.moving(task.schedule, to: next, in: calendar), priority: task.priority,
                            tags: task.tags, duration: task.duration, color: task.color, recurrence: recurrence)
        copy.createdAt = now
        // The same notes and steps come back, all unchecked, for the next time round.
        copy.notes = task.notes
        copy.subtasks = task.subtasks.filter { !$0.title.isEmpty }.map { Subtask(title: $0.title) }
        return copy
    }

    /// The same schedule on another day, keeping the wall-clock time.
    private static func moving(_ schedule: Schedule?, to day: Day, in cal: Calendar) -> Schedule? {
        guard let schedule else { return nil }
        guard let time = schedule.time else { return .day(day) }
        let c = cal.dateComponents([.hour, .minute], from: time)
        return .time(day.date(hour: c.hour ?? 9, minute: c.minute ?? 0, in: cal))
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

    /// Sets a task's date and time outright (nil moves it to the Inbox).
    func reschedule(_ id: UUID, to schedule: Schedule?) {
        guard task(id)?.schedule != schedule else { return }
        update(id) { $0.schedule = schedule }
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

    /// Moves a leftover task to another day (keeping its time of day), with undo.
    func carry(_ id: UUID, to day: Day) {
        guard let task = task(id) else { return }
        let snapshot = currentSnapshot
        schedule(id, day: day)
        let label = DateText.relativeDay(day, now: .now)
        announce(tr("「\(task.title)」移到\(label)", "Moved “\(task.title)” to \(label.lowercased())"), undo: snapshot)
    }

    /// Moves every leftover on at once: repeating ones skip ahead, the rest go to `day`.
    func carryAll(_ ids: [UUID], to day: Day) {
        guard !ids.isEmpty else { return }
        let snapshot = currentSnapshot
        for id in ids {
            guard let task = task(id) else { continue }
            if let next = nextOccurrence(of: task) {
                update(id) { item in
                    item.schedule = next.schedule
                    item.subtasks = item.subtasks.map { Subtask(id: $0.id, title: $0.title) }
                }
            } else {
                schedule(id, day: day)
            }
        }
        let label = DateText.relativeDay(day, now: .now)
        announce(tr("已把 \(ids.count) 项移到\(label)", "Moved \(ids.count) to \(label.lowercased())"), undo: snapshot)
        changed()
    }

    /// Moves a timed task to start at `start`, keeping its length (used to clear an overlap).
    func startAfter(_ id: UUID, at start: Date) {
        guard let task = task(id), task.hasTime else { return }
        let snapshot = currentSnapshot
        update(id) { $0.schedule = .time(start) }
        announce(tr("「\(task.title)」顺延到 \(DateText.time(start))", "Moved “\(task.title)” to \(DateText.time(start))"), undo: snapshot)
        changed()
    }

    /// Moves a timed task and sets its length in one go, as dragging it on the timeline does.
    func retime(_ id: UUID, start: Date, minutes: Int) {
        guard let task = task(id), task.hasTime else { return }
        let length = min(max(minutes, TaskItem.durationRange.lowerBound), TaskItem.durationRange.upperBound)
        guard task.schedule?.time != start || task.minutes != length else { return }
        let snapshot = currentSnapshot
        update(id) { item in
            item.schedule = .time(start)
            if length != item.minutes { item.duration = length }
        }
        let end = start.addingTimeInterval(Double(length) * 60)
        announce(tr("「\(task.title)」\(DateText.time(start)) – \(DateText.time(end))", "“\(task.title)” \(DateText.time(start)) – \(DateText.time(end))"), undo: snapshot)
        changed()
    }

    /// Sets how long a task lasts (nil goes back to the default length).
    func setDuration(_ id: UUID, minutes: Int?) {
        let value = minutes.map { min(max($0, TaskItem.durationRange.lowerBound), TaskItem.durationRange.upperBound) }
        guard let task = task(id), task.duration != value else { return }
        update(id) { $0.duration = value }
        changed()
    }

    /// Gives a timed task more time: its block ends `minutes` later than now or its end, whichever
    /// is later (answering a reminder late still buys the full extra time).
    func extend(_ id: UUID, by minutes: Int, now: Date = .now) {
        guard let task = task(id), let start = task.schedule?.time, let end = task.end else { return }
        let snapshot = currentSnapshot
        let newEnd = max(end, now).addingTimeInterval(Double(minutes) * 60)
        let length = Int((newEnd.timeIntervalSince(start) / 60).rounded(.up))
        update(id) { $0.duration = min(length, TaskItem.durationRange.upperBound) }
        announce(tr("「\(task.title)」延长到 \(DateText.time(newEnd))", "Extended “\(task.title)” to \(DateText.time(newEnd))"), undo: snapshot)
        changed()
    }

    /// What a reminder's buttons do, on the island or in a notification.
    func answer(_ action: ReminderAction, for id: UUID, now: Date = .now) {
        switch action {
        case .complete: complete(id)
        case .snooze: reschedule(id, to: .time(now.addingTimeInterval(10 * 60)))
        case .extend: extend(id, by: 15, now: now)
        }
    }

    func setColor(_ id: UUID, _ color: TaskColor?) {
        update(id) { $0.color = color }
        changed()
    }

    func setPriority(_ id: UUID, _ priority: Priority) {
        update(id) { $0.priority = priority }
        changed()
    }

    // MARK: Details

    /// Adds a step to a task's checklist, after `after` or at the end. A blank title makes an
    /// empty row to type into, as Return in the checklist does; `removeBlankSubtasks` tidies
    /// it away if nothing gets written.
    @discardableResult
    func addSubtask(_ id: UUID, title: String = "", after: UUID? = nil) -> Subtask? {
        guard task(id) != nil else { return nil }
        let subtask = Subtask(title: title.trimmingCharacters(in: .whitespacesAndNewlines))
        update(id) { item in
            if let after, let index = item.subtasks.firstIndex(where: { $0.id == after }) {
                item.subtasks.insert(subtask, at: index + 1)
            } else {
                item.subtasks.append(subtask)
            }
        }
        changed()
        return subtask
    }

    /// Renames a step. A blank title is kept only while the row is being written.
    func renameSubtask(_ id: UUID, _ subtaskID: UUID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let current = task(id)?.subtasks.first(where: { $0.id == subtaskID }), current.title != trimmed else { return }
        updateSubtask(id, subtaskID) { $0.title = trimmed }
        changed()
    }

    func toggleSubtask(_ id: UUID, _ subtaskID: UUID) {
        updateSubtask(id, subtaskID) { $0.isDone.toggle() }
        changed()
    }

    /// Removes a step. One with a title can be brought back from the notice.
    func deleteSubtask(_ id: UUID, _ subtaskID: UUID) {
        guard let subtask = task(id)?.subtasks.first(where: { $0.id == subtaskID }) else { return }
        let snapshot = currentSnapshot
        update(id) { $0.subtasks.removeAll { $0.id == subtaskID } }
        if !subtask.title.isEmpty {
            announce(tr("已删除子任务「\(subtask.title)」", "Deleted step “\(subtask.title)”"), undo: snapshot)
        }
        changed()
    }

    /// Moves a step up (negative) or down the checklist.
    func moveSubtask(_ id: UUID, _ subtaskID: UUID, by step: Int) {
        guard let item = task(id), let index = item.subtasks.firstIndex(where: { $0.id == subtaskID }) else { return }
        let target = min(max(index + step, 0), item.subtasks.count - 1)
        guard target != index else { return }
        update(id) { $0.subtasks.move(fromOffsets: [index], toOffset: target > index ? target + 1 : target) }
        changed()
    }

    /// Drops steps left blank (a row added with Return and never written in).
    func removeBlankSubtasks(_ id: UUID) {
        guard task(id)?.subtasks.contains(where: { $0.title.isEmpty }) == true else { return }
        update(id) { $0.subtasks.removeAll { $0.title.isEmpty } }
        changed()
    }

    /// Sets a task's notes. Blank notes are none; clearing written notes can be undone.
    func setNotes(_ id: UUID, _ notes: String?) {
        let trimmed = notes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let value = trimmed.isEmpty ? nil : trimmed
        guard let task = task(id), task.notes != value else { return }
        let snapshot = currentSnapshot
        update(id) { $0.notes = value }
        if value == nil {
            announce(tr("已清除「\(task.title)」的备注", "Cleared the notes of “\(task.title)”"), undo: snapshot)
        }
        changed()
    }

    private func updateSubtask(_ id: UUID, _ subtaskID: UUID, _ body: (inout Subtask) -> Void) {
        update(id) { item in
            guard let index = item.subtasks.firstIndex(where: { $0.id == subtaskID }) else { return }
            body(&item.subtasks[index])
        }
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

    var canUndo: Bool { notice?.undo != nil || !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// While a notice offers Undo, this is that Undo: back to just before what it reports.
    /// Otherwise it steps back one action. `announcing` confirms it in a notice (for ⌘Z,
    /// where nothing else on screen may show what changed).
    func undo(announcing: Bool = false) {
        let current = Self.meaningful(currentSnapshot)
        if let snapshot = notice?.undo {
            let target = Self.meaningful(snapshot)
            if let index = undoStack.lastIndex(of: target) { undoStack.removeSubrange(index...) }
            restore(snapshot, redo: current)
        } else if let previous = undoStack.popLast() {
            restore(previous, redo: current)
        } else {
            return
        }
        notice = announcing ? Notice(message: tr("已撤销", "Undone"), undo: nil) : nil
    }

    /// Takes back the last undo.
    func redo(announcing: Bool = false) {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(Self.meaningful(currentSnapshot))
        tasks = next.tasks
        focus = next.focus
        settle()
        notice = announcing ? Notice(message: tr("已重做", "Redone"), undo: nil) : nil
    }

    /// Ends the current group of changes, so the next one gets an undo step of its own (the
    /// next turn of the run loop does this anyway).
    func closeUndoGroup() {
        groupOpen = false
    }

    private func restore(_ snapshot: Notice.Snapshot, redo current: Notice.Snapshot) {
        redoStack.append(current)
        tasks = snapshot.tasks
        focus = snapshot.focus
        settle()
    }

    /// Saves a state put back by undo or redo without making it a step of its own.
    private func settle() {
        committed = Self.meaningful(currentSnapshot)
        groupOpen = false
        scheduleSave()
        onChange?()
    }

    /// Notes the state before this change as an undo step, unless it belongs to the step
    /// already taken in this turn of the run loop.
    private func recordHistory() {
        let now = Self.meaningful(currentSnapshot)
        let before = committed
        committed = now
        guard now != before else { return }
        redoStack = []
        guard !groupOpen else { return }
        undoStack.append(before)
        if undoStack.count > Self.historyLimit { undoStack.removeFirst(undoStack.count - Self.historyLimit) }
        groupOpen = true
        Task { [weak self] in self?.groupOpen = false }
    }

    /// A state as worth stepping back to: a blank checklist row (one opened with Return and
    /// not yet written in) isn't a change of its own.
    private static func meaningful(_ snapshot: Notice.Snapshot) -> Notice.Snapshot {
        guard snapshot.tasks.contains(where: { $0.subtasks.contains { $0.title.isEmpty } }) else { return snapshot }
        let tasks = snapshot.tasks.map { task in
            var task = task
            task.subtasks.removeAll { $0.title.isEmpty }
            return task
        }
        return Notice.Snapshot(tasks: tasks, focus: snapshot.focus)
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
        recordHistory()
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

    /// What the evening review asks about: today's open tasks that have no time or whose time is over.
    func leftoversTonight(now: Date) -> [TaskItem] {
        let today = today(now)
        return sorted(tasks.filter { task in
            guard !task.isDone, task.day(in: calendar) == today else { return false }
            return task.end.map { $0 <= now } ?? true
        })
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
        case .focus: 0
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
