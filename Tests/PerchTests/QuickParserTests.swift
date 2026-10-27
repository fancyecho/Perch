import AppKit
import Foundation
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

    private func task(_ title: String, minutesFromNow: Double?) -> TaskItem {
        TaskItem(title: title, schedule: minutesFromNow.map { .time(now.addingTimeInterval($0 * 60)) } ?? .day(Day(now, in: .current)))
    }

    private func describe(_ entries: [TodayTimeline.Entry]) -> [String] {
        entries.map { entry in
            switch entry.kind {
            case .task(let task, let node): "\(task.title):\(node.above)/\(node.below)\(node.hint == nil ? "" : "*")"
            case .now(let node): "now:\(node.above)/\(node.below)"
            case .anytime(let node): "anytime:\(node.above)/\(node.below)"
            }
        }
    }

    @Test func ordersPastNowAheadThenAnytime() {
        let entries = TodayTimeline.entries(for: [
            task("later", minutesFromNow: 90),
            task("whenever", minutesFromNow: nil),
            task("earlier", minutesFromNow: -30),
            task("soon", minutesFromNow: 20),
        ], now: now)
        #expect(describe(entries) == [
            "earlier:none/elapsed",
            "now:elapsed/ahead",
            "soon:ahead/ahead*",
            "later:ahead/anytime",
            "anytime:anytime/anytime",
            "whenever:anytime/none",
        ])
    }

    @Test func untimedOnlyStartsAtNow() {
        let entries = TodayTimeline.entries(for: [task("a", minutesFromNow: nil), task("b", minutesFromNow: nil)], now: now)
        #expect(describe(entries) == ["now:none/anytime", "a:anytime/anytime", "b:anytime/none"])
    }

    @Test func allPastEndsAtNow() {
        let entries = TodayTimeline.entries(for: [task("a", minutesFromNow: -60), task("b", minutesFromNow: -5)], now: now)
        #expect(describe(entries) == ["a:none/elapsed", "b:elapsed/elapsed", "now:elapsed/none"])
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
