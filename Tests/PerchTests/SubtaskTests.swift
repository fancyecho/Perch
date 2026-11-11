import Foundation
import Testing
@testable import Perch

struct TaskDetailsModelTests {
    @Test func oldFilesDecodeWithoutDetailsAndStayTheSame() throws {
        let json = #"{"createdAt":"2026-11-01T08:00:00Z","id":"6F1C7E1A-6C55-4B8E-9C43-4C7A0A1F0B11","priority":0,"tags":[],"title":"写周报"}"#
        let task = try JSONDecoder.perch.decode(TaskItem.self, from: Data(json.utf8))
        #expect(task.subtasks.isEmpty)
        #expect(task.notes == nil)
        #expect(!task.hasDetails)
        let encoded = String(decoding: try JSONEncoder.perch.encode(task), as: UTF8.self)
        #expect(!encoded.contains("notes"))
        #expect(!encoded.contains("subtasks"))
    }

    @Test func detailsRoundTrip() throws {
        var task = TaskItem(title: "搬家")
        task.notes = "钥匙在门卫\n记得拍照"
        task.subtasks = [Subtask(title: "打包", isDone: true), Subtask(title: "叫车")]
        let data = try JSONEncoder.perch.encode(task)
        let text = String(decoding: data, as: UTF8.self)
        // Only checked steps write "done".
        #expect(text.components(separatedBy: "\"done\"").count == 2)
        let decoded = try JSONDecoder.perch.decode(TaskItem.self, from: data)
        // (createdAt is written to the second, so compare the details themselves.)
        #expect(decoded.notes == task.notes)
        #expect(decoded.subtasks == task.subtasks)
        #expect(decoded.checklist == (1, 2))
    }

    @Test func blankStepsAndNotesAreDroppedOnLoad() throws {
        let json = #"{"id":"6F1C7E1A-6C55-4B8E-9C43-4C7A0A1F0B11","title":"x","notes":"","subtasks":[{"id":"7F1C7E1A-6C55-4B8E-9C43-4C7A0A1F0B11","title":""},{"title":"a","done":true}]}"#
        let task = try JSONDecoder.perch.decode(TaskItem.self, from: Data(json.utf8))
        #expect(task.notes == nil)
        #expect(task.subtasks.map(\.title) == ["a"])
        #expect(task.subtasks.first?.isDone == true)
    }

    @Test func checklistCountsOnlyNamedSteps() {
        var task = TaskItem(title: "x")
        task.subtasks = [Subtask(title: "a", isDone: true), Subtask(title: ""), Subtask(title: "b")]
        #expect(task.checklist == (1, 2))
        #expect(task.hasDetails)
    }
}

struct TaskDetailsStoreTests {
    private func makeStore() -> TaskStore {
        let url = FileManager.default.temporaryDirectory.appending(path: "perch-tests-\(UUID().uuidString).json")
        try? JSONEncoder.perch.encode(["tasks": [TaskItem]()]).write(to: url)
        return TaskStore(fileURL: url)
    }

    private func titles(_ store: TaskStore, _ id: UUID) -> [String] {
        store.task(id)?.subtasks.map(\.title) ?? []
    }

    @Test func addRenameToggleAndReorder() throws {
        let store = makeStore()
        let task = try #require(store.add(ParsedInput(title: "旅行")))
        let a = try #require(store.addSubtask(task.id, title: "  订机票 "))
        let c = try #require(store.addSubtask(task.id, title: "收拾行李"))
        let b = try #require(store.addSubtask(task.id, title: "订酒店", after: a.id))
        #expect(titles(store, task.id) == ["订机票", "订酒店", "收拾行李"])

        store.renameSubtask(task.id, b.id, to: "订民宿")
        store.toggleSubtask(task.id, a.id)
        #expect(store.task(task.id).map { $0.checklist == (1, 3) } == true)

        store.moveSubtask(task.id, c.id, by: -1)
        #expect(titles(store, task.id) == ["订机票", "收拾行李", "订民宿"])
        store.moveSubtask(task.id, a.id, by: 1)
        #expect(titles(store, task.id) == ["收拾行李", "订机票", "订民宿"])
        // Already at the top: nothing moves.
        store.moveSubtask(task.id, c.id, by: -1)
        #expect(titles(store, task.id) == ["收拾行李", "订机票", "订民宿"])
    }

    @Test func deletingAStepCanBeUndone() throws {
        let store = makeStore()
        let task = try #require(store.add(ParsedInput(title: "旅行")))
        let step = try #require(store.addSubtask(task.id, title: "订机票"))
        store.notice = nil
        store.deleteSubtask(task.id, step.id)
        #expect(titles(store, task.id).isEmpty)
        #expect(store.notice?.undo != nil)
        store.undo()
        #expect(titles(store, task.id) == ["订机票"])
    }

    @Test func blankRowsComeAndGoQuietly() throws {
        let store = makeStore()
        let task = try #require(store.add(ParsedInput(title: "旅行")))
        let a = try #require(store.addSubtask(task.id, title: "订机票"))
        let blank = try #require(store.addSubtask(task.id, after: a.id))
        #expect(titles(store, task.id) == ["订机票", ""])
        store.notice = nil
        store.deleteSubtask(task.id, blank.id)
        #expect(store.notice == nil)
        store.addSubtask(task.id)
        store.removeBlankSubtasks(task.id)
        #expect(titles(store, task.id) == ["订机票"])
    }

    @Test func notesAreTrimmedAndClearingCanBeUndone() throws {
        let store = makeStore()
        let task = try #require(store.add(ParsedInput(title: "面试")))
        store.setNotes(task.id, "  带简历\n")
        #expect(store.task(task.id)?.notes == "带简历")
        store.notice = nil
        store.setNotes(task.id, "   ")
        #expect(store.task(task.id)?.notes == nil)
        #expect(store.notice?.undo != nil)
        store.undo()
        #expect(store.task(task.id)?.notes == "带简历")
    }

    @Test func detailsAreSavedToDisk() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "perch-tests-\(UUID().uuidString).json")
        try JSONEncoder.perch.encode(["tasks": [TaskItem]()]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let store = TaskStore(fileURL: url)
        let task = try #require(store.add(ParsedInput(title: "面试")))
        store.addSubtask(task.id, title: "打印简历")
        store.setNotes(task.id, "三楼")
        store.saveNow()
        let reloaded = TaskStore(fileURL: url)
        #expect(reloaded.task(task.id)?.subtasks.map(\.title) == ["打印简历"])
        #expect(reloaded.task(task.id)?.notes == "三楼")
    }

    @Test func aRepeatingTaskComesBackWithItsStepsUnchecked() throws {
        let store = makeStore()
        let cal = AppSettings.shared.calendar
        let today = Day(.now, in: cal)
        let task = try #require(store.add(ParsedInput(title: "晨间", schedule: .day(today), recurrence: .daily)))
        let stretch = try #require(store.addSubtask(task.id, title: "拉伸"))
        store.addSubtask(task.id, title: "喝水")
        store.setNotes(task.id, "十分钟")
        store.toggleSubtask(task.id, stretch.id)

        store.complete(task.id)
        let next = try #require(store.tasks.first { !$0.isDone })
        #expect(next.subtasks.map(\.title) == ["拉伸", "喝水"])
        #expect(next.subtasks.allSatisfy { !$0.isDone })
        #expect(next.notes == "十分钟")
        // Fresh steps, so checking one never checks the other's.
        #expect(Set(next.subtasks.map(\.id)).isDisjoint(with: Set(store.task(task.id)!.subtasks.map(\.id))))
        // The finished one keeps what was checked.
        #expect(store.task(task.id).map { $0.checklist == (1, 2) } == true)

        // Skipping a time starts the next one fresh too.
        store.toggleSubtask(next.id, next.subtasks[0].id)
        store.skip(next.id)
        #expect(store.task(next.id).map { $0.checklist == (0, 2) } == true)
    }
}

struct TimelineDetailsTests {
    private let cal = AppSettings.shared.calendar

    private func at(_ hour: Int, _ minute: Int = 0) -> Date {
        Day(.now, in: cal).date(hour: hour, minute: minute, in: cal)
    }

    private func ids(_ entries: [TodayTimeline.Entry]) -> [String] { entries.map(\.id) }

    @Test func anOpenedTaskGetsItsDetailsRowRightUnderIt() {
        let a = TaskItem(title: "a", schedule: .time(at(9)), duration: 60)
        let b = TaskItem(title: "b", schedule: .time(at(13)), duration: 30)
        let c = TaskItem(title: "c", schedule: .day(Day(.now, in: cal)))
        let now = at(8)

        let closed = TodayTimeline.entries(for: [a, b, c], now: now)
        #expect(!ids(closed).contains { $0.hasPrefix("details-") })

        let openA = ids(TodayTimeline.entries(for: [a, b, c], now: now, expanded: a.id))
        let index = openA.firstIndex(of: a.id.uuidString)!
        #expect(openA[index + 1] == "details-\(a.id)")
        // Free time is still noted after it.
        #expect(openA[index + 2].hasPrefix("gap-"))
        #expect(openA.count == ids(closed).count + 1)

        let openC = ids(TodayTimeline.entries(for: [a, b, c], now: now, expanded: c.id))
        #expect(openC.last == "details-\(c.id)")
    }

    @Test func theLineRunsOnThroughTheDetails() {
        let a = TaskItem(title: "a", schedule: .time(at(9)), duration: 60)
        let b = TaskItem(title: "b", schedule: .time(at(10)), duration: 30)
        let c = TaskItem(title: "c", schedule: .day(Day(.now, in: cal)))

        // Under way: what's still ahead of it stays quiet.
        let during = TodayTimeline.entries(for: [a, b, c], now: at(9, 30), expanded: a.id)
        let details = during.first { $0.id == "details-\(a.id)" }!
        #expect(details.node.height == 0)
        #expect(details.node.above.style == .ahead)
        #expect(details.node.below.style == .ahead)

        // Once it's over, the stretch under it is colored in.
        let after = TodayTimeline.entries(for: [a, b, c], now: at(12), expanded: a.id)
        let past = after.first { $0.id == "details-\(a.id)" }!
        #expect(past.node.above.style == .elapsed)

        // An untimed task's details sit on the dashed stretch.
        let anytime = TodayTimeline.entries(for: [a, b, c], now: at(12), expanded: c.id)
        let untimed = anytime.first { $0.id == "details-\(c.id)" }!
        #expect(untimed.node.above.style == .anytime)
    }
}

struct UndoHistoryTests {
    private func makeStore() -> TaskStore {
        let url = FileManager.default.temporaryDirectory.appending(path: "perch-tests-\(UUID().uuidString).json")
        try? JSONEncoder.perch.encode(["tasks": [TaskItem]()]).write(to: url)
        return TaskStore(fileURL: url)
    }

    @Test func stepsBackThroughQuietChangesAndForwardAgain() throws {
        let store = makeStore()
        let task = try #require(store.add(ParsedInput(title: "写周报")))
        store.closeUndoGroup()
        store.rename(task.id, to: "写月报")
        store.closeUndoGroup()
        store.setColor(task.id, .sage)
        store.closeUndoGroup()

        store.undo()
        #expect(store.task(task.id)?.color == nil)
        #expect(store.task(task.id)?.title == "写月报")
        store.undo()
        #expect(store.task(task.id)?.title == "写周报")
        store.undo()
        #expect(store.tasks.isEmpty)
        #expect(!store.canUndo)

        store.redo()
        store.redo()
        #expect(store.task(task.id)?.title == "写月报")
        // A new change drops what could have been redone.
        store.setPriority(task.id, .high)
        #expect(!store.canRedo)
    }

    @Test func oneTurnOfTheRunLoopIsOneStep() async throws {
        let store = makeStore()
        let task = try #require(store.add(ParsedInput(title: "旅行")))
        await Task.yield()
        store.closeUndoGroup()
        // Return in a step: renamed and a blank row opened under it, together.
        let step = try #require(store.addSubtask(task.id, title: "订机票"))
        store.closeUndoGroup()
        store.renameSubtask(task.id, step.id, to: "订高铁")
        store.addSubtask(task.id, after: step.id)
        store.closeUndoGroup()
        // Tidying the blank row away isn't a step of its own.
        store.removeBlankSubtasks(task.id)
        store.closeUndoGroup()

        store.undo()
        #expect(store.task(task.id)?.subtasks.map(\.title) == ["订机票"])
        store.undo()
        #expect(store.task(task.id)?.subtasks.isEmpty == true)
    }

    @Test func withANoticeShowingUndoIsThatNoticesUndo() throws {
        let store = makeStore()
        let task = try #require(store.add(ParsedInput(title: "写周报")))
        store.closeUndoGroup()
        store.rename(task.id, to: "写月报")
        store.closeUndoGroup()
        store.delete(task.id)
        #expect(store.notice?.undo != nil)
        store.undo(announcing: true)
        #expect(store.task(task.id)?.title == "写月报")
        #expect(store.notice?.undo == nil)
        // The rename before it is the next step back.
        store.undo()
        #expect(store.task(task.id)?.title == "写周报")
    }
}
