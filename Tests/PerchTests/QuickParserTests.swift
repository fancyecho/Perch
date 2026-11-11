import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Perch

private func calendar(_ zone: String) -> Calendar {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: zone)!
    return cal
}

private func moment(_ cal: Calendar, _ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
    cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
}

private func wallClock(_ schedule: Schedule?, _ cal: Calendar) -> DateComponents? {
    schedule?.time.map { cal.dateComponents([.year, .month, .day, .hour, .minute], from: $0) }
}

struct QuickParserTests {
    private let cal = calendar("Asia/Shanghai")
    /// Friday 2026-10-23 10:00 in Shanghai
    private var now: Date { moment(cal, 2026, 10, 23, 10) }

    private func parse(_ text: String, defaultDay: Day? = nil) -> ParsedInput {
        QuickParser.parse(text, now: now, defaultDay: defaultDay, calendar: cal)
    }

    @Test func chineseDateTimePriorityAndTag() {
        let parsed = parse("明天下午3点 写周报 !! #工作")
        #expect(parsed.title == "写周报")
        #expect(parsed.priority == .medium)
        #expect(parsed.tags == ["工作"])
        #expect(wallClock(parsed.schedule, cal) == DateComponents(year: 2026, month: 10, day: 24, hour: 15, minute: 0))
    }

    @Test func halfHourAndEvening() {
        let parsed = parse("晚上8点半 看电影")
        #expect(parsed.title == "看电影")
        #expect(wallClock(parsed.schedule, cal) == DateComponents(year: 2026, month: 10, day: 23, hour: 20, minute: 30))
    }

    @Test func clockRangeSetsStartAndLength() {
        let parsed = parse("明天 9:00-10:30 设计评审")
        #expect(parsed.title == "设计评审")
        #expect(wallClock(parsed.schedule, cal) == DateComponents(year: 2026, month: 10, day: 24, hour: 9, minute: 0))
        #expect(parsed.duration == 90)
    }

    @Test func chineseRangeSharesItsPeriod() {
        let parsed = parse("下午3点到5点半 写方案")
        #expect(parsed.title == "写方案")
        #expect(wallClock(parsed.schedule, cal) == DateComponents(year: 2026, month: 10, day: 23, hour: 15, minute: 0))
        #expect(parsed.duration == 150)
        #expect(parse("明天两点到四点 开会").duration == 120)
    }

    @Test func englishRange() {
        let parsed = parse("Workshop tomorrow 3-5pm")
        #expect(parsed.title == "Workshop")
        #expect(wallClock(parsed.schedule, cal) == DateComponents(year: 2026, month: 10, day: 24, hour: 15, minute: 0))
        #expect(parsed.duration == 120)
        let morning = parse("Gym tomorrow 11-1pm")
        #expect(wallClock(morning.schedule, cal)?.hour == 11)
        #expect(morning.duration == 120)
    }

    @Test func lengthsOnTheirOwn() {
        #expect(parse("明天下午3点 健身 1小时").duration == 60)
        #expect(parse("读书 半小时").duration == 30)
        #expect(parse("一个半小时 写代码").duration == 90)
        #expect(parse("Run tomorrow 7am for 45 min").duration == 45)
        #expect(parse("Deep work 1h30m").duration == 90)
        #expect(parse("Deep work 1h30m").title == "Deep work")
        // Relative times are not lengths.
        #expect(parse("2小时后 喝水").duration == nil)
        #expect(parse("call mom in 30 min").duration == nil)
    }

    @Test func nextWeekdayIsAFloatingDay() {
        let parsed = parse("下周三 交报告")
        #expect(parsed.title == "交报告")
        #expect(parsed.schedule == .day(Day(year: 2026, month: 10, day: 28)))
    }

    @Test func plainWeekdayMeansUpcoming() {
        #expect(parse("周一 例会").schedule == .day(Day(year: 2026, month: 10, day: 26)))
    }

    @Test func colonTimeWithoutDateRollsToTomorrowWhenPassed() {
        let parsed = parse("9:30 standup")
        #expect(parsed.title == "standup")
        #expect(wallClock(parsed.schedule, cal) == DateComponents(year: 2026, month: 10, day: 24, hour: 9, minute: 30))
    }

    @Test func bareSmallHourMeansAfternoon() {
        let parsed = parse("3点开会")
        #expect(parsed.title == "开会")
        #expect(wallClock(parsed.schedule, cal)?.hour == 15)
    }

    @Test func relativeHours() {
        let parsed = parse("2小时后 回电话")
        #expect(parsed.title == "回电话")
        #expect(parsed.schedule == .time(now.addingTimeInterval(7200)))
    }

    @Test func englishPhrases() {
        let parsed = parse("call mom tomorrow 5pm p1")
        #expect(parsed.title == "call mom")
        #expect(parsed.priority == .high)
        #expect(wallClock(parsed.schedule, cal) == DateComponents(year: 2026, month: 10, day: 24, hour: 17, minute: 0))
    }

    @Test func monthDay() {
        let parsed = parse("11月3日 体检")
        #expect(parsed.title == "体检")
        #expect(parsed.schedule == .day(Day(year: 2026, month: 11, day: 3)))
    }

    @Test func impossibleDateIsIgnored() {
        #expect(parse("2月30日 什么").schedule == nil)
    }

    @Test func noDateUsesDefaultDayButIsNotExplicit() {
        let today = Day(now, in: cal)
        let parsed = parse("买牛奶", defaultDay: today)
        #expect(parsed.title == "买牛奶")
        #expect(parsed.schedule == .day(today))
        #expect(!parsed.hasExplicitDate)
    }

    @Test func chineseNumeralNeedsPeriodWord() {
        let parsed = parse("多喝一点水")
        #expect(parsed.title == "多喝一点水")
        #expect(parsed.schedule == nil)
    }
}

/// New York: DST starts 2026-03-08 02:00 (clocks jump to 03:00) and ends 2026-11-01 02:00 (back to 01:00).
struct DaylightSavingTests {
    private let ny = calendar("America/New_York")

    @Test func tomorrowMorningAcrossSpringForwardKeepsWallClock() {
        let now = moment(ny, 2026, 3, 7, 10)
        let parsed = QuickParser.parse("明天上午9点 跑步", now: now, calendar: ny)
        #expect(wallClock(parsed.schedule, ny) == DateComponents(year: 2026, month: 3, day: 8, hour: 9, minute: 0))
        // Only 22 real hours pass, because the night is an hour shorter.
        #expect(parsed.schedule?.time?.timeIntervalSince(now) == TimeInterval(22 * 3600))
    }

    @Test func timeSkippedBySpringForwardMovesForward() {
        let date = Day(year: 2026, month: 3, day: 8).date(hour: 2, minute: 30, in: ny)
        let c = ny.dateComponents([.hour, .minute], from: date)
        #expect(c.hour == 3 && c.minute == 30)
    }

    @Test func repeatedFallBackTimeUsesFirstOccurrence() {
        let date = Day(year: 2026, month: 11, day: 1).date(hour: 1, minute: 30, in: ny)
        #expect(ny.timeZone.secondsFromGMT(for: date) == -4 * 3600)
    }

    @Test func dayArithmeticIgnoresDST() {
        let saturday = Day(year: 2026, month: 3, day: 7)
        #expect(saturday.adding(days: 1) == Day(year: 2026, month: 3, day: 8))
        #expect(saturday.days(until: Day(year: 2026, month: 3, day: 9)) == 2)
        #expect(Day(year: 2026, month: 10, day: 23).mondayIndex == 4)
        #expect(Day(year: 2026, month: 3, day: 8).start(in: ny) == moment(ny, 2026, 3, 8, 0))
    }

    @Test func floatingDayDoesNotShiftWithTimeZone() {
        let task = TaskItem(title: "体检", schedule: .day(Day(year: 2026, month: 11, day: 3)))
        #expect(task.day(in: ny) == task.day(in: calendar("Asia/Tokyo")))
    }

    @Test func timedTaskShowsLocalDayOfItsZone() {
        // 2026-10-24 01:00 in Shanghai is still the 23rd in New York.
        let task = TaskItem(title: "call", schedule: .time(moment(calendar("Asia/Shanghai"), 2026, 10, 24, 1)))
        #expect(task.day(in: ny) == Day(year: 2026, month: 10, day: 23))
    }
}

struct TaskStoreTests {
    private func makeStore() -> TaskStore {
        let url = FileManager.default.temporaryDirectory.appending(path: "perch-tests-\(UUID().uuidString).json")
        try? JSONEncoder.perch.encode(["tasks": [TaskItem]()]).write(to: url)
        return TaskStore(fileURL: url)
    }

    @Test func submittingParsedInputCreatesTask() {
        let store = makeStore()
        let today = Day(.now, in: AppSettings.shared.calendar)
        let parsed = QuickParser.parse("测试 !", defaultDay: today)
        let task = store.add(parsed)
        #expect(task?.title == "测试")
        #expect(task?.priority == .low)
        #expect(store.dueToday(now: .now).map(\.title) == ["测试"])
    }

    @Test func emptyTitleIsRejected() {
        let store = makeStore()
        #expect(store.add(QuickParser.parse("明天下午3点")) == nil)
        #expect(store.tasks.isEmpty)
    }

    @Test func postponeKeepsWallClockAcrossDST() {
        let settings = AppSettings.shared
        let previous = settings.timeZoneID
        settings.timeZoneID = "America/New_York"
        defer { settings.timeZoneID = previous }
        let ny = settings.calendar

        let store = makeStore()
        let task = store.add(ParsedInput(title: "run", schedule: .time(moment(ny, 2026, 3, 7, 9))))!
        store.postponeToTomorrow(task.id, now: moment(ny, 2026, 3, 7, 12))
        let moved = store.task(task.id)?.schedule?.time
        #expect(moved.map { ny.dateComponents([.day, .hour], from: $0) } == DateComponents(day: 8, hour: 9))
    }

    @Test func rescheduleSetsAndClearsDateAndTime() {
        let store = makeStore()
        let cal = AppSettings.shared.calendar
        let task = store.add(ParsedInput(title: "写周报"))!
        #expect(store.task(task.id)?.schedule == nil)

        let friday = Day(year: 2026, month: 10, day: 30)
        store.reschedule(task.id, to: .day(friday))
        #expect(store.task(task.id)?.schedule == .day(friday))

        let afternoon = friday.date(hour: 15, minute: 30, in: cal)
        store.reschedule(task.id, to: .time(afternoon))
        #expect(store.task(task.id)?.schedule?.time == afternoon)
        #expect(store.task(task.id)?.day(in: cal) == friday)

        store.reschedule(task.id, to: nil)
        #expect(store.task(task.id)?.schedule == nil)
        #expect(store.inbox().map(\.id) == [task.id])
    }

    @Test func extendingAddsTimeFromTheLaterOfTheEndAndNow() {
        let store = makeStore()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let task = store.add(ParsedInput(title: "read", schedule: .time(start), duration: 30))!
        // Answered on time: 30 + 15.
        store.extend(task.id, by: 15, now: start.addingTimeInterval(30 * 60))
        #expect(store.task(task.id)?.minutes == 45)
        // Answered ten minutes after it ran out: still a full 15 from now.
        store.extend(task.id, by: 15, now: start.addingTimeInterval(55 * 60))
        #expect(store.task(task.id)?.minutes == 70)
    }

    @Test func legacyFormatStillDecodes() throws {
        let json = """
        {"id":"FBD242D1-579F-4F84-AB20-A3E438164D9B","title":"old","due":"2026-10-23T04:00:00Z","hasTime":true,"priority":2,"tags":[],"createdAt":"2026-10-23T03:00:00Z"}
        """
        let task = try JSONDecoder.perch.decode(TaskItem.self, from: Data(json.utf8))
        #expect(task.schedule == .time(ISO8601DateFormatter().date(from: "2026-10-23T04:00:00Z")!))
        let encoded = try JSONEncoder.perch.encode(task)
        #expect(try JSONDecoder.perch.decode(TaskItem.self, from: encoded) == task)
    }
}

struct UpdaterTests {
    /// A 504 page from GitHub's download servers must be an error, not an "update" whose
    /// signature then fails.
    @Test func errorPagesAreNotUpdates() throws {
        let url = URL(string: "https://github.com/fancyecho/Perch/releases/download/v1/Perch-1.zip")!
        let ok = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        let timeout = try #require(HTTPURLResponse(url: url, statusCode: 504, httpVersion: nil, headerFields: nil))
        #expect(throws: Never.self) { try Updater.requireSuccess(ok) }
        #expect(throws: UpdateError.self) { try Updater.requireSuccess(timeout) }
        // A local test feed has no status to check.
        #expect(throws: Never.self) { try Updater.requireSuccess(URLResponse(url: URL(fileURLWithPath: "/tmp/a.zip"), mimeType: nil, expectedContentLength: 0, textEncodingName: nil)) }
    }

    @Test func versionComparison() {
        #expect(Updater.isVersion("0.2.0", newerThan: "0.1.9"))
        #expect(Updater.isVersion("1.0", newerThan: "0.9.9"))
        #expect(Updater.isVersion("0.1.10", newerThan: "0.1.9"))
        #expect(!Updater.isVersion("0.1.0", newerThan: "0.1"))
        #expect(!Updater.isVersion("0.1.0", newerThan: "0.2.0"))
    }
}

struct TimelineTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func task(_ title: String, minutesFromNow: Double?, lasting: Int? = nil, done: Bool = false) -> TaskItem {
        var item = TaskItem(title: title, schedule: minutesFromNow.map { .time(now.addingTimeInterval($0 * 60)) } ?? .day(Day(now, in: .current)))
        item.duration = lasting
        if done { item.completedAt = now }
        return item
    }

    private func describe(_ entries: [TodayTimeline.Entry]) -> [String] {
        entries.map { entry in
            switch entry.kind {
            case .task(let task, let node): "\(task.title):\(node.above.style)/\(node.below.style)\(node.hint == nil ? "" : "*")"
            case .now(let node): "now:\(node.above.style)/\(node.below.style)"
            case .gap(let from, let to, _): "gap\(Int(to.timeIntervalSince(from) / 60))"
            case .overlap(let overlap, _): "overlap\(overlap.minutes)"
            case .anytime(let node): "anytime:\(node.above.style)/\(node.below.style)"
            case .edge(let edge, _, _): "\(edge)"
            case .details(let task, _): "details:\(task.title)"
            }
        }
    }

    private func node(_ title: String, in entries: [TodayTimeline.Entry]) -> TimelineNode? {
        for entry in entries {
            if case .task(let task, let node) = entry.kind, task.title == title { return node }
        }
        return nil
    }

    @Test func ordersPastNowAheadThenAnytime() {
        let entries = TodayTimeline.entries(for: [
            task("later", minutesFromNow: 90),
            task("whenever", minutesFromNow: nil),
            task("earlier", minutesFromNow: -60),
            task("soon", minutesFromNow: 20),
        ], now: now)
        #expect(describe(entries) == [
            "earlier:none/elapsed",
            "now:elapsed/ahead",
            "soon:ahead/ahead*",
            "gap40",
            "later:ahead/anytime",
            "anytime:anytime/anytime",
            "whenever:anytime/none",
        ])
    }

    /// A task under way shows "now" by filling its capsule, so there is no separate marker.
    @Test func runningTaskReplacesNowMarker() {
        let entries = TodayTimeline.entries(for: [
            task("meeting", minutesFromNow: -15, lasting: 60),
            task("lunch", minutesFromNow: 60),
        ], now: now)
        #expect(describe(entries) == ["meeting:none/ahead*", "lunch:ahead/none"])
        let meeting = node("meeting", in: entries)
        #expect(meeting?.progress == 0.25)
        #expect(meeting?.hint?.contains("45") == true)
        #expect(node("lunch", in: entries)?.progress == 0)
    }

    @Test func doneTasksStayFilledAndLateOnesAreMarked() {
        let entries = TodayTimeline.entries(for: [
            task("done early", minutesFromNow: 30, done: true),
            task("missed", minutesFromNow: -120),
        ], now: now)
        #expect(node("done early", in: entries)?.progress == 1)
        // Finished tasks fold down to a dot and a single line.
        #expect(node("done early", in: entries)?.isCollapsed == true)
        #expect(node("done early", in: entries)?.height == TimelineMetrics.collapsedSize)
        #expect(node("missed", in: entries)?.isCollapsed == false)
        #expect(node("missed", in: entries)?.isLate == true)
        #expect(node("missed", in: entries)?.progress == 1)
    }

    /// 08:00–12:00 and 10:00–14:00: flagged between them, with the fix pointing at 12:00.
    @Test func overlappingTasksAreFlagged() {
        let entries = TodayTimeline.entries(for: [
            task("course", minutesFromNow: 60, lasting: 240),
            task("words", minutesFromNow: 180, lasting: 240),
            task("done", minutesFromNow: 200, lasting: 30, done: true),
        ], now: now)
        #expect(describe(entries) == ["now:none/ahead", "course:ahead/conflict*", "overlap120", "words:conflict/ahead", "done:ahead/none"])
        if case .overlap(let overlap, _) = entries[2].kind {
            #expect(overlap.freeAt == now.addingTimeInterval(300 * 60))
            #expect(overlap.otherTitle == "course")
        }
    }

    @Test func clearingAnOverlapKeepsTheLength() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "perch-overlap-\(UUID()).json")
        let store = TaskStore(fileURL: file)
        let item = try #require(store.add(ParsedInput(title: "words", schedule: .time(now), duration: 240)))
        store.startAfter(item.id, at: now.addingTimeInterval(7200))
        #expect(store.task(item.id)?.schedule?.time == now.addingTimeInterval(7200))
        #expect(store.task(item.id)?.minutes == 240)
        store.undo()
        #expect(store.task(item.id)?.schedule?.time == now)
    }

    @Test func capsulesGrowWithLength() {
        #expect(TimelineMetrics.capsuleHeight(minutes: 15) == TimelineMetrics.capsuleWidth)
        #expect(TimelineMetrics.capsuleHeight(minutes: 60) > TimelineMetrics.capsuleHeight(minutes: 30))
        #expect(TimelineMetrics.capsuleHeight(minutes: 600) == TimelineMetrics.capsuleHeight(minutes: 900))
    }

    @Test func untimedOnlyStartsAtNow() {
        let entries = TodayTimeline.entries(for: [task("a", minutesFromNow: nil), task("b", minutesFromNow: nil)], now: now)
        #expect(describe(entries) == ["now:none/anytime", "a:anytime/anytime", "b:anytime/none"])
    }

    @Test func allPastEndsAtNow() {
        let entries = TodayTimeline.entries(for: [task("a", minutesFromNow: -90), task("b", minutesFromNow: -45)], now: now)
        #expect(describe(entries) == ["a:none/elapsed", "b:elapsed/elapsed", "now:elapsed/none"])
    }
}

struct TaskAppearanceTests {
    private func symbol(_ title: String) -> String? { TaskTopic.match(title)?.symbol }

    @Test func topicsComeFromTitleWords() {
        #expect(symbol("明天下午跑步") == "figure.run")
        #expect(symbol("吃药") == "pills.fill")
        #expect(symbol("Team lunch") == "fork.knife")
        #expect(symbol("Weekly meeting") == "video.fill")
        #expect(symbol("Get ready") == nil)
    }

    @Test func studyTasksAreRecognized() {
        #expect(symbol("背单词") == "character.book.closed.fill")
        #expect(symbol("背 GRE 单词 200 个") == "character.book.closed.fill")
        #expect(symbol("880做完线代") == "pencil.and.list.clipboard")
        #expect(symbol("做两套数学真题") == "pencil.and.list.clipboard")
        #expect(symbol("刷 LeetCode") == "pencil.and.list.clipboard")
        #expect(symbol("听张宇的课") == "play.rectangle.fill")
        #expect(symbol("看操作系统网课") == "play.rectangle.fill")
        #expect(symbol("复习线代") == "function")
        #expect(symbol("学习英语") == "textformat.abc")
        #expect(symbol("学 Swift") == "graduationcap.fill")
        #expect(symbol("练听力") == "headphones")
        #expect(symbol("整理笔记") == "note.text")
        #expect(symbol("背景调研") == nil)
    }

    @Test func untitledTopicsFallBackToTheFirstLetter() {
        #expect(TaskItem(title: "整理思路").glyph == .symbol("sparkles"))
        #expect(TaskItem(title: "quarterly OKRs").glyph == .text("Q"))
        #expect(TaskItem(title: "3号线换乘").glyph == .text("号"))
    }

    @Test func everyTopicSymbolExists() {
        for topic in TaskTopic.all {
            #expect(NSImage(systemSymbolName: topic.symbol, accessibilityDescription: nil) != nil, "\(topic.symbol)")
        }
    }

    @Test func tagColorIsStable() {
        let a = TaskItem(title: "x", tags: ["工作"]), b = TaskItem(title: "y", tags: ["工作"])
        #expect(a.tint == b.tint)
    }
}

struct FeedbackSoundTests {
    @Test func synthesizedSoundsArePlayable() throws {
        for style in ChimeStyle.allCases {
            let sound = try #require(NSSound(data: SoundBank.chime(style)))
            #expect(sound.duration > 0.02 && sound.duration < 2)
            let fanfare = try #require(NSSound(data: SoundBank.fanfare(style)))
            #expect(fanfare.duration > 0.3 && fanfare.duration < 3)
        }
    }

    /// Decoding alone passes for pure silence, so check the samples actually carry sound.
    @Test func synthesizedSoundsAreAudible() {
        let sounds = ChimeStyle.allCases.flatMap { [SoundBank.chime($0), SoundBank.fanfare($0)] }
        for wav in sounds {
            let samples = wav.dropFirst(44).withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
            let peak = samples.map { abs(Int($0)) }.max() ?? 0
            let loud = samples.filter { abs(Int($0)) > 1000 }.count
            #expect(peak > 20_000)
            // At least ~10 ms of clearly audible signal (Tink is a very short tap).
            #expect(loud > Int(0.01 * ToneSynth.sampleRate))
        }
    }

    /// The chime must start the instant it plays: no leading silence.
    @Test func recordingsStartImmediately() throws {
        for style in ChimeStyle.allCases where style.systemSound != nil {
            let clip = try #require(Clip(contentsOf: style.systemSound!)).trimmingLeadingSilence()
            let peak = clip.samples.map(abs).max() ?? 0
            let onset = clip.samples.firstIndex { abs($0) > peak * 0.03 } ?? 0
            #expect(Double(onset) / clip.sampleRate < 0.003)
        }
    }

    @Test func pitchingUpShortensProportionally() {
        let clip = Clip(samples: (0..<48_000).map { Float(sin(Double($0) * 0.05)) }, sampleRate: 48_000)
        let up = clip.pitched(by: 12)
        #expect(abs(up.samples.count - 24_000) <= 1)
    }
}

struct RecurrenceTests {
    private let cal = calendar("Asia/Shanghai")
    /// Friday 2026-10-23 10:00 in Shanghai
    private var now: Date { moment(cal, 2026, 10, 23, 10) }
    private var today: Day { Day(year: 2026, month: 10, day: 23) }

    private func parse(_ text: String) -> ParsedInput {
        QuickParser.parse(text, now: now, defaultDay: today, calendar: cal)
    }

    @Test func dailyAtATimeThatHasPassedStartsTomorrow() {
        let parsed = parse("每天早上8点 背单词")
        #expect(parsed.title == "背单词")
        #expect(parsed.recurrence == .daily)
        #expect(wallClock(parsed.schedule, cal) == DateComponents(year: 2026, month: 10, day: 24, hour: 8, minute: 0))
    }

    @Test func namedWeekdaysLandOnTheFirstOne() {
        let parsed = parse("每周一三五 晚上7点 跑步")
        #expect(parsed.title == "跑步")
        #expect(parsed.recurrence == .weekly([0, 2, 4]))
        // Friday at 19:00 hasn't happened yet: today.
        #expect(wallClock(parsed.schedule, cal) == DateComponents(year: 2026, month: 10, day: 23, hour: 19, minute: 0))
        let english = parse("Gym every mon and thu 7pm")
        #expect(english.title == "Gym")
        #expect(english.recurrence == .weekly([0, 3]))
        #expect(wallClock(english.schedule, cal)?.day == 26)
    }

    @Test func otherRules() {
        #expect(parse("工作日 站会").recurrence == .weekdays)
        #expect(parse("weekdays standup").title == "standup")
        #expect(parse("每周 周报").recurrence == .weekly([4]))
        let monthly = parse("每月15号 交房租")
        #expect(monthly.recurrence == .monthly)
        #expect(monthly.schedule == .day(Day(year: 2026, month: 11, day: 15)))
        #expect(monthly.title == "交房租")
        #expect(parse("每周日 大扫除").schedule == .day(Day(year: 2026, month: 10, day: 25)))
    }

    @Test func nextDays() {
        #expect(Recurrence.weekdays.next(after: today) == Day(year: 2026, month: 10, day: 26))
        #expect(Recurrence.weekly([2]).next(after: today) == Day(year: 2026, month: 10, day: 28))
        let jan31 = Day(year: 2027, month: 1, day: 31)
        let feb = Recurrence.monthly.next(after: jan31)
        #expect(feb == Day(year: 2027, month: 2, day: 28))
        #expect(Recurrence.monthly.next(after: feb, anchor: jan31) == Day(year: 2027, month: 3, day: 31))
        #expect(Recurrence(storageValue: Recurrence.weekly([4, 0]).storageValue) == .weekly([0, 4]))
    }

    @Test func completingBringsTheNextOneAndReopeningTakesItBack() {
        let url = FileManager.default.temporaryDirectory.appending(path: "perch-tests-\(UUID().uuidString).json")
        try? JSONEncoder.perch.encode(["tasks": [TaskItem]()]).write(to: url)
        let store = TaskStore(fileURL: url)
        let settingsCal = AppSettings.shared.calendar
        let today = Day(.now, in: settingsCal)
        let task = store.add(ParsedInput(title: "背单词", schedule: .time(today.date(hour: 8, minute: 0, in: settingsCal)), duration: 20, recurrence: .daily))!
        store.complete(task.id)
        let next = store.tasks.first { !$0.isDone }
        #expect(next?.title == "背单词")
        #expect(next?.recurrence == .daily)
        #expect(next?.minutes == 20)
        #expect(next.flatMap { $0.day(in: settingsCal) } == today.adding(days: 1))
        #expect(next.flatMap { settingsCal.dateComponents([.hour], from: $0.schedule!.time!).hour } == 8)

        store.reopen(task.id)
        #expect(store.tasks.count == 1)
        #expect(store.task(task.id)?.isDone == false)

        store.skip(task.id)
        #expect(store.task(task.id)?.day(in: settingsCal) == today.adding(days: 1))
        let encoded = try! JSONEncoder.perch.encode(store.task(task.id)!)
        #expect(try! JSONDecoder.perch.decode(TaskItem.self, from: encoded).recurrence == .daily)
    }
}

struct TimelineDragTests {
    private let cal = calendar("Asia/Shanghai")

    @Test func movingSnapsToFiveMinutesAndStaysInTheDay() {
        let start = moment(cal, 2026, 10, 23, 10)
        let moved = TimelineDrag(mode: .move, translation: 47).result(start: start, minutes: 30, calendar: cal)
        #expect(moved == .init(start: moment(cal, 2026, 10, 23, 10, 45), minutes: 30))
        let late = TimelineDrag(mode: .move, translation: 900).result(start: moment(cal, 2026, 10, 23, 22), minutes: 60, calendar: cal)
        #expect(late.start == moment(cal, 2026, 10, 23, 23))
        let early = TimelineDrag(mode: .move, translation: -900).result(start: start, minutes: 30, calendar: cal)
        #expect(early.start == moment(cal, 2026, 10, 23, 0))
    }

    @Test func resizingFollowsTheCapsuleAndNeverVanishes() {
        let start = moment(cal, 2026, 10, 23, 10)
        // 9pt at 0.6pt a minute is 15 minutes.
        #expect(TimelineDrag(mode: .resize, translation: 9).result(start: start, minutes: 30, calendar: cal).minutes == 45)
        #expect(TimelineDrag(mode: .resize, translation: -200).result(start: start, minutes: 30, calendar: cal).minutes == 5)
        #expect(TimelineDrag(mode: .resize, translation: 5000).result(start: start, minutes: 30, calendar: cal).minutes == 14 * 60)
    }

    /// Two tasks an hour apart: 10:00–10:30 with its capsule at 100…139, then 11:30–12:00 at 200…239.
    private func ruler() -> TimelineRuler {
        TimelineRuler([
            .init(y: 200, time: moment(cal, 2026, 10, 23, 11, 30)), .init(y: 239, time: moment(cal, 2026, 10, 23, 12)),
            .init(y: 100, time: moment(cal, 2026, 10, 23, 10)), .init(y: 139, time: moment(cal, 2026, 10, 23, 10, 30)),
        ])
    }

    @Test func aRulerReadsTimeOffTheRows() {
        let ruler = ruler()
        #expect(ruler.time(at: 100) == moment(cal, 2026, 10, 23, 10))
        // Halfway down the squeezed hour of free time is half an hour in.
        #expect(ruler.time(at: 169.5) == moment(cal, 2026, 10, 23, 11))
        // Off either end, a point is a minute.
        #expect(ruler.time(at: 70) == moment(cal, 2026, 10, 23, 9, 30))
        #expect(ruler.time(at: 249) == moment(cal, 2026, 10, 23, 12, 10))
        #expect(ruler.y(of: moment(cal, 2026, 10, 23, 11)) == 169.5)
        #expect(ruler.y(of: moment(cal, 2026, 10, 23, 12, 10)) == 249)
    }

    @Test func timeNeverRunsBackwardsWhereTasksOverlap() {
        let ruler = TimelineRuler([
            .init(y: 0, time: moment(cal, 2026, 10, 23, 10)), .init(y: 60, time: moment(cal, 2026, 10, 23, 12)),
            .init(y: 80, time: moment(cal, 2026, 10, 23, 11)), .init(y: 120, time: moment(cal, 2026, 10, 23, 13)),
        ])
        #expect(ruler.time(at: 70) == moment(cal, 2026, 10, 23, 12))
        #expect(ruler.time(at: 100) == moment(cal, 2026, 10, 23, 12, 30))
    }

    @Test func aCarriedTaskTakesTheTimeWhereItIsSetDown() {
        let start = moment(cal, 2026, 10, 23, 10)
        // The first task, carried down past the second: its top at 249 is ten minutes after that one ends.
        var drag = TimelineDrag(mode: .move, translation: 149, origin: 100, ruler: ruler())
        #expect(drag.result(start: start, minutes: 30, calendar: cal).start == moment(cal, 2026, 10, 23, 12, 10))
        // Barely moved, it hasn't gone anywhere.
        drag.translation = 1
        #expect(drag.result(start: start, minutes: 30, calendar: cal).start == start)
    }

    @Test func aCarriedTaskClicksAgainstItsNeighbours() {
        // The second task ends at 12:07 now, which no five-minute step lands on.
        let ruler = TimelineRuler([
            .init(y: 100, time: moment(cal, 2026, 10, 23, 10)), .init(y: 139, time: moment(cal, 2026, 10, 23, 10, 30)),
            .init(y: 200, time: moment(cal, 2026, 10, 23, 11, 30)), .init(y: 239, time: moment(cal, 2026, 10, 23, 12, 7)),
        ])
        let end = moment(cal, 2026, 10, 23, 12, 7)
        var drag = TimelineDrag(mode: .move, translation: 142, origin: 100, ruler: ruler, magnets: [end])
        #expect(drag.result(start: moment(cal, 2026, 10, 23, 10), minutes: 30, calendar: cal).start == end)
        drag.translation = 150
        #expect(drag.result(start: moment(cal, 2026, 10, 23, 10), minutes: 30, calendar: cal).start == moment(cal, 2026, 10, 23, 12, 20))
    }

    @Test func aCarriedTaskIsDrawnUnderThePointerOrFlushWithANeighbour() {
        let ruler = TimelineRuler([
            .init(y: 100, time: moment(cal, 2026, 10, 23, 10)), .init(y: 239, time: moment(cal, 2026, 10, 23, 12, 7)),
        ])
        var drag = TimelineDrag(mode: .move, translation: 60, origin: 100, ruler: ruler, magnets: [moment(cal, 2026, 10, 23, 12, 7)])
        #expect(drag.shownTranslation == 60)
        // Within reach of the neighbour's edge, it sits right on it.
        drag.translation = 136
        #expect(drag.shownTranslation == 139)
    }

    @Test func theLayoutBuildsARulerFromItsRows() {
        let now = moment(cal, 2026, 10, 23, 9)
        let first = TaskItem(title: "a", schedule: .time(moment(cal, 2026, 10, 23, 10)), duration: 30)
        let second = TaskItem(title: "b", schedule: .time(moment(cal, 2026, 10, 23, 11, 30)), duration: 30)
        let layout = TimelineLayout()
        layout.update(TodayTimeline.entries(for: [first, second], now: now), now: now)
        let height = TimelineMetrics.capsuleHeight(minutes: 30)
        layout.frames[first.id.uuidString] = CGRect(x: 0, y: 100, width: 300, height: height + 14)
        layout.frames[second.id.uuidString] = CGRect(x: 0, y: 200, width: 300, height: height + 14)
        #expect(layout.capsuleTop(of: first.id.uuidString) == 107)
        #expect(layout.ruler().time(at: 207) == moment(cal, 2026, 10, 23, 11, 30))
        // The first could start when the second ends, end when it starts, or start now.
        #expect(Set(layout.magnets(for: first.id.uuidString, minutes: 30)) == [moment(cal, 2026, 10, 23, 12), moment(cal, 2026, 10, 23, 11), now])
    }

    @Test func freeSlotPrefillParsesAsToday() {
        let now = moment(cal, 2026, 10, 23, 16)
        let parsed = QuickParser.parse("今天 9:00-10:00 读书", now: now, defaultDay: Day(year: 2026, month: 10, day: 23), calendar: cal)
        #expect(wallClock(parsed.schedule, cal) == DateComponents(year: 2026, month: 10, day: 23, hour: 9, minute: 0))
        #expect(parsed.duration == 60)
        #expect(parsed.title == "读书")
    }
}

struct LeftoverTests {
    private func makeStore() -> TaskStore {
        let url = FileManager.default.temporaryDirectory.appending(path: "perch-tests-\(UUID().uuidString).json")
        try? JSONEncoder.perch.encode(["tasks": [TaskItem]()]).write(to: url)
        return TaskStore(fileURL: url)
    }

    @Test func tonightAsksAboutWhatIsOverOrUntimed() {
        let store = makeStore()
        let cal = AppSettings.shared.calendar
        let now = Date.now
        let today = Day(now, in: cal)
        let over = store.add(ParsedInput(title: "over", schedule: .time(now.addingTimeInterval(-3600)), duration: 30))!
        let later = store.add(ParsedInput(title: "later", schedule: .time(now.addingTimeInterval(3600))))!
        let untimed = store.add(ParsedInput(title: "untimed", schedule: .day(today)))!
        _ = store.add(ParsedInput(title: "tomorrow", schedule: .day(today.adding(days: 1))))
        let ids = Set(store.leftoversTonight(now: now).map(\.id))
        // A task an hour ago may have started yesterday near midnight; only count it if it's today's.
        let expected: Set<UUID> = Set([untimed.id] + (over.day(in: cal) == today ? [over.id] : []))
        #expect(ids == expected)
        #expect(!ids.contains(later.id))
    }

    @Test func carryingAllSkipsRepeatingOnesAhead() {
        let store = makeStore()
        let cal = AppSettings.shared.calendar
        let today = Day(.now, in: cal)
        let plain = store.add(ParsedInput(title: "plain", schedule: .day(today.adding(days: -2))))!
        let daily = store.add(ParsedInput(title: "daily", schedule: .day(today.adding(days: -2)), recurrence: .daily))!
        store.carryAll([plain.id, daily.id], to: today)
        #expect(store.task(plain.id)?.day(in: cal) == today)
        #expect(store.task(daily.id)?.day(in: cal) == today)
        #expect(store.overdue(now: .now).isEmpty)
        store.undo()
        #expect(store.overdue(now: .now).count == 2)
    }
}

@MainActor
struct TimelineDayTests {
    private let cal = AppSettings.shared.calendar
    private let day = TimelineDay(start: 7 * 60, end: 23 * 60)

    private func at(_ hour: Int, _ minute: Int = 0) -> Date { moment(cal, 2026, 11, 10, hour, minute) }

    private func task(_ title: String, _ hour: Int, _ minute: Int = 0, lasting: Int = 60) -> TaskItem {
        TaskItem(title: title, schedule: .time(at(hour, minute)), duration: lasting)
    }

    private func kinds(_ entries: [TodayTimeline.Entry]) -> [String] {
        entries.map { entry in
            switch entry.kind {
            case .task(let task, _): task.title
            case .now: "now"
            case .gap: "gap"
            case .overlap: "overlap"
            case .anytime: "anytime"
            case .edge(let edge, _, _): "\(edge)"
            case .details: "details"
            }
        }
    }

    @Test func theLineRunsAcrossTheDay() {
        let entries = TodayTimeline.entries(for: [task("read", 8), task("gym", 18, 30)], now: at(9, 20), day: day)
        // No headings in between: noon and six are drawn behind the rows, not as rows.
        #expect(kinds(entries) == ["open", "gap", "read", "now", "gym", "gap", "close"])
    }

    @Test func aLongTaskIsOneRowWhateverItCrosses() {
        let entries = TodayTimeline.entries(for: [task("course", 11, 45, lasting: 390)], now: at(8), day: day)
        #expect(kinds(entries) == ["open", "now", "course", "gap", "close"])
    }

    @Test func tasksOutsideTheDayStretchTheLine() {
        let span = TodayTimeline.span(for: [task("early", 5, 30), task("late", 23, 15)], day: day, now: at(12))
        #expect(span?.open == at(5))
        #expect(span?.close == moment(cal, 2026, 11, 11, 0))
    }

    @Test func noTimedTasksNoSpan() {
        #expect(TodayTimeline.span(for: [], day: day, now: at(9)) == nil)
        #expect(TodayTimeline.span(for: [task("a", 9)], day: nil, now: at(9)) == nil)
    }

    @Test func aPartOfTheDayIsNamedInTheFirstClearSpot() {
        // Afternoon starts 4pt into a long capsule whose start time is written at 108.
        #expect(DayParts.labelY(start: 104, end: 300, clearOf: [108, 292]) == 121)
        #expect(DayParts.labelY(start: 0, end: 20, clearOf: [10]) == nil)
    }

    @Test func theListScrollsFasterNearerTheEdge() {
        #expect(TimelineScroller.speed(depth: 1) < TimelineScroller.speed(depth: 30))
        #expect(TimelineScroller.speed(depth: 200) == TimelineScroller.topSpeed)
    }

    @Test func theEndsAreOnTheDragRuler() {
        let morning = task("read", 8)
        let entries = TodayTimeline.entries(for: [morning], now: at(7, 30), day: day)
        let layout = TimelineLayout()
        layout.update(entries, now: at(7, 30))
        for (index, entry) in entries.enumerated() {
            layout.frames[entry.id] = CGRect(x: 0, y: CGFloat(index) * 40, width: 300, height: 30)
        }
        // The line opens at seven: above the first task there is still time to read off.
        #expect(layout.ruler().marks.first?.time == at(7))
    }
}
