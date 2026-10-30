import Foundation
import Testing
@testable import Perch

/// Runs `body` with the app's time zone (and so every schedule's) set to `identifier`.
@MainActor
private func inZone(_ identifier: String, _ body: (Calendar) -> Void) {
    let settings = AppSettings.shared
    let previous = settings.timeZoneID
    settings.timeZoneID = identifier
    defer { settings.timeZoneID = previous }
    body(ScheduleClock.calendar)
}

private func moment(_ calendar: Calendar, _ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
}

private func rule(_ start: Int, _ end: Int, weekdays: Set<Int> = Set(1...7), strict: Bool = false) -> BlockRule {
    BlockRule(name: "Test", tint: 0, weekdays: weekdays, windows: [TimeWindow(start: start, end: end)], apps: [], isStrict: strict)
}

struct ScheduleTests {
    @Test func runsInsideItsWindowOnly() {
        inZone("America/New_York") { ny in
            let evening = rule(19 * 60, 22 * 60)
            #expect(evening.activeOccurrence(at: moment(ny, 2026, 10, 30, 20)) != nil)
            #expect(evening.activeOccurrence(at: moment(ny, 2026, 10, 30, 22, 30)) == nil)
            #expect(evening.nextOccurrence(after: moment(ny, 2026, 10, 30, 22, 30))?.start == moment(ny, 2026, 10, 31, 19))
        }
    }

    @Test func aWindowAcrossMidnightBelongsToTheDayItStarts() {
        inZone("America/New_York") { ny in
            let night = rule(23 * 60, 7 * 60, weekdays: [6]) // starts Fridays
            let occurrence = night.activeOccurrence(at: moment(ny, 2026, 10, 31, 2))
            #expect(occurrence?.start == moment(ny, 2026, 10, 30, 23))
            #expect(occurrence?.end == moment(ny, 2026, 10, 31, 7))
            #expect(night.activeOccurrence(at: moment(ny, 2026, 11, 1, 2)) == nil)
        }
    }

    @Test func onlyOnItsWeekdays() {
        inZone("America/New_York") { ny in
            let weekdays = rule(9 * 60, 17 * 60, weekdays: [2, 3, 4, 5, 6])
            #expect(weekdays.activeOccurrence(at: moment(ny, 2026, 10, 30, 10)) != nil) // Friday
            #expect(weekdays.activeOccurrence(at: moment(ny, 2026, 10, 31, 10)) == nil) // Saturday
        }
    }

    @Test func fallingBackCoversTheRepeatedHour() {
        inZone("America/New_York") { ny in
            // 1:00–2:00 on the night clocks go back is two real hours.
            let day = ny.startOfDay(for: moment(ny, 2026, 11, 1, 12))
            let occurrence = rule(60, 120).occurrence(of: TimeWindow(start: 60, end: 120), onDayOf: day)
            let duration = occurrence.map { $0.end.timeIntervalSince($0.start) }
            #expect(duration == TimeInterval(2 * 3600))
        }
    }

    @Test func followsTheAppTimeZoneNotTheMacs() {
        inZone("Asia/Taipei") { taipei in
            let study = rule(19 * 60, 22 * 60)
            let start = study.activeOccurrence(at: moment(taipei, 2026, 10, 30, 20))?.start
            #expect(start == moment(taipei, 2026, 10, 30, 19))
        }
    }

    @Test func windowsThatCrossMidnightAndTheirLength() {
        #expect(TimeWindow(start: 23 * 60, end: 7 * 60).crossesMidnight)
        #expect(TimeWindow(start: 23 * 60, end: 7 * 60).durationMinutes == 8 * 60)
        #expect(TimeWindow(start: 9 * 60, end: 9 * 60).durationMinutes == 24 * 60)
    }

    @Test func weekdaySummaries() {
        let settings = AppSettings.shared
        let previous = settings.language
        settings.language = .english
        defer { settings.language = previous }
        #expect(ScheduleText.weekdays(Set(1...7)) == "Every day")
        #expect(ScheduleText.weekdays([2, 3, 4, 5, 6]) == "Weekdays")
        #expect(ScheduleText.weekdays([2, 4]) == "Mon, Wed")
    }
}

struct BlockedSiteTests {
    @Test func normalizesWhatWasTyped() {
        #expect(BlockedSite.normalize("https://www.Bilibili.com/video/?spm=1") == "bilibili.com/video")
        #expect(BlockedSite.normalize("youtube.com/shorts/") == "youtube.com/shorts")
        #expect(BlockedSite.normalize("not a site") == nil)
        #expect(BlockedSite.normalize("localhost") == nil)
    }

    @Test func aDomainTakesItsSubdomains() {
        let site = BlockedSite(pattern: "bilibili.com", name: nil)
        #expect(site.matches(URL(string: "https://m.bilibili.com/video/1")!))
        #expect(site.matches(URL(string: "https://www.bilibili.com")!))
        #expect(!site.matches(URL(string: "https://notbilibili.com")!))
    }

    @Test func aPathOnlyTakesThatPath() {
        let shorts = BlockedSite(pattern: "youtube.com/shorts", name: nil)
        #expect(shorts.matches(URL(string: "https://www.youtube.com/shorts/abc")!))
        #expect(!shorts.matches(URL(string: "https://www.youtube.com/watch?v=1")!))
    }

    @Test func passKeysNeverCollideWithBundleIDs() {
        let pass = ActivePass(key: BlockedSite(pattern: "x.com", name: nil).passKey, end: .now)
        #expect(pass.site?.pattern == "x.com")
        #expect(ActivePass(key: "com.apple.Safari", end: .now).site == nil)
    }
}

struct UnlockPhraseTests {
    @Test func spacesPunctuationAndCaseDontCount() {
        let settings = AppSettings.shared
        let previous = settings.language
        defer { settings.language = previous }

        settings.language = .chinese
        let chinese = OverlayModel()
        chinese.typed = "我现在 要用电脑，做正事。"
        #expect(chinese.isComplete)

        settings.language = .english
        let english = OverlayModel()
        english.typed = "i NEED the computer"
        #expect(english.matchedCount == "ineedthecomputer".count)
        #expect(!english.isComplete)
        english.typed = "I need the computer for real work!"
        #expect(english.isComplete)
    }

    @Test func aTypoStopsTheMatch() {
        let settings = AppSettings.shared
        let previous = settings.language
        settings.language = .english
        defer { settings.language = previous }
        let model = OverlayModel()
        model.typed = "I nead"
        #expect(model.matchedCount == 3)
    }
}

struct StatusFormatTests {
    @Test func compactRatesForTheMenuBar() {
        #expect(Fmt.compactRate(950) == "950B")
        #expect(Fmt.compactRate(1_234) == "1.2K")
        #expect(Fmt.compactRate(12_345_678) == "12M")
    }

    @Test func bytesInDecimalLikeFinder() {
        #expect(Fmt.bytesParts(1_500_000) == ("1.50", "MB"))
        #expect(Fmt.bytesParts(265_000_000_000) == ("265", "GB"))
    }
}
