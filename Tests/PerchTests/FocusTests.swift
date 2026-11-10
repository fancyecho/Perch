import AppKit
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

@MainActor
struct BreakTests {
    @Test func aBreakGetsPastStrictSchedulesTooAndTheyAreCounted() {
        let store = ScheduleStore.shared
        let saved = store.rules
        defer { store.rules = saved }
        var strict = rule(0, 0, strict: true)
        strict.apps = [BlockedApp(bundleID: "com.example.chat", name: "Chat")]
        store.rules = [strict]

        let now = Date.now.addingTimeInterval(30 * 86400) // a fresh day for the count
        #expect(store.blockingOccurrence(for: "com.example.chat", at: now) != nil)
        let left = store.passesLeft(at: now)
        store.grantPass(for: "com.example.chat", minutes: 15, at: now)
        #expect(store.blockingOccurrence(for: "com.example.chat", at: now.addingTimeInterval(60)) == nil)
        #expect(store.blockingOccurrence(for: "com.example.chat", at: now.addingTimeInterval(16 * 60)) != nil)
        #expect(store.passesLeft(at: now) == left - 1)
        store.revokePass(for: "com.example.chat")
    }

    @Test func aBreakIsNeverLongerThanHalfAnHour() {
        let store = ScheduleStore.shared
        let now = Date.now.addingTimeInterval(40 * 86400)
        store.grantPass(for: "com.example.video", minutes: 90, at: now)
        #expect(store.passLengths["com.example.video"] == TimeInterval(30 * 60))
        store.revokePass(for: "com.example.video")
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

struct AppleAudioModelTests {
    @Test func airPodsGenerationsGetTheirOwnSymbols() {
        #expect(AppleAudioModel.symbol(for: 0x2013) == "airpods.gen3")
        #expect(AppleAudioModel.symbol(for: 0x2014) == "airpods.pro")
        #expect(AppleAudioModel.symbol(for: 0x1234) == nil)
    }

    @Test func namesGiveAwayWiredAndOtherOutputs() {
        #expect(DeviceSymbol.look(forName: "EarPods")?.symbol == "earpods")
        #expect(DeviceSymbol.look(forName: "Rick's AirPods Pro")?.symbol == "airpods.pro")
        #expect(DeviceSymbol.look(forName: "AirPods 4")?.symbol == "airpods.gen4")
        #expect(DeviceSymbol.look(forName: "Living Room HomePod mini")?.isPersonal == false)
        #expect(DeviceSymbol.look(forName: "USB Audio Device") == nil)
    }

    @Test func everydayDevicesGetTheirOwnSymbols() {
        #expect(DeviceSymbol.look(forName: "WH-1000XM6") == DeviceLook("headphones.over.ear", personal: true))
        #expect(DeviceSymbol.look(forName: "WF-1000XM5")?.symbol == "earbuds")
        #expect(DeviceSymbol.look(forName: "Galaxy Buds3 Pro")?.symbol == "earbuds")
        #expect(DeviceSymbol.look(forName: "Beats Studio Buds +")?.symbol == "beats.studiobudsplus")
        #expect(DeviceSymbol.look(forName: "Powerbeats Pro")?.symbol == "beats.powerbeats.pro")
        #expect(DeviceSymbol.look(forName: "Beats Pill")?.isPersonal == false)
        // The Mac's own speakers aren't a hi-fi speaker, in either language.
        #expect(DeviceSymbol.look(forName: "MacBook Air Speakers")?.symbol == "macbook")
        #expect(DeviceSymbol.look(forName: "MacBook Pro扬声器")?.symbol == "macbook")
        #expect(DeviceSymbol.look(forName: "Studio Display Speakers")?.symbol == "display")
        #expect(DeviceSymbol.look(forName: "Magic Trackpad")?.symbol == "rectangle.and.hand.point.up.left.fill")
        #expect(DeviceSymbol.look(forName: "Magic Keyboard with Touch ID")?.symbol == "keyboard.fill")
        #expect(DeviceSymbol.look(forName: "MX Master 3S")?.symbol == "computermouse.fill")
        #expect(DeviceSymbol.look(forName: "DualSense Wireless Controller")?.symbol == "gamecontroller.fill")
        #expect(DeviceSymbol.look(forName: "Xbox Wireless Controller")?.symbol == "gamecontroller.fill")
        #expect(DeviceSymbol.look(forName: "Rick’s iPhone")?.symbol == "iphone")
        #expect(DeviceSymbol.look(forName: "Living Room TV")?.symbol == "tv.fill")
        #expect(DeviceSymbol.look(forName: "Stevens")?.symbol == nil)
    }

    @Test func coreAudioModelIDsNameAppleHeadphones() {
        #expect(DeviceSymbol.look(forModelUID: "2014 4c")?.symbol == "airpods.pro")
        #expect(DeviceSymbol.look(forModelUID: "200a 4c")?.symbol == "airpods.max")
        // Sony's WH-1000XM6: not Apple's, so the name decides.
        #expect(DeviceSymbol.look(forModelUID: "f8a 54c") == nil)
        #expect(DeviceSymbol.look(forModelUID: "Speaker") == nil)
    }

    @Test func bluetoothClassesSayWhatADeviceIs() {
        #expect(DeviceSymbol.symbol(forMajorClass: 0x04, minor: 0x06) == "headphones")
        #expect(DeviceSymbol.symbol(forMajorClass: 0x04, minor: 0x05) == "hifispeaker.fill")
        #expect(DeviceSymbol.symbol(forMajorClass: 0x04, minor: 0x08) == "car.fill")
        #expect(DeviceSymbol.symbol(forMajorClass: 0x05, minor: 0x02) == "gamecontroller.fill")
        #expect(DeviceSymbol.symbol(forMajorClass: 0x05, minor: 0x20) == "computermouse.fill")
        #expect(DeviceSymbol.symbol(forMajorClass: 0x05, minor: 0x10) == "keyboard.fill")
    }

    @Test func wingsShowTheModelNotTheOwner() {
        #expect(DeviceSymbol.shortName("Rick's AirPods Pro") == "AirPods Pro")
        #expect(DeviceSymbol.shortName("Rick’s AirPods Pro") == "AirPods Pro")
        #expect(DeviceSymbol.shortName("小白的AirPods Max") == "AirPods Max")
        #expect(DeviceSymbol.shortName("WH-1000XM6") == "WH-1000XM6")
        // Not a model after the apostrophe, so the name stays whole.
        #expect(DeviceSymbol.shortName("Rick's Thing") == "Rick's Thing")
    }

    @Test func allTheSymbolsExist() {
        let names = ["WH-1000XM6", "WF-1000XM5", "Beats Studio Buds +", "Powerbeats Pro", "Beats Pill", "Beats Flex",
                     "MacBook Air Speakers", "iMac Speakers", "Mac mini Speakers", "Mac Studio Speakers", "Mac Pro Speakers",
                     "HomePod", "HomePod mini", "Apple TV", "iPad", "Apple Watch", "Vision Pro", "Apple Pencil",
                     "Magic Trackpad", "Magic Mouse", "Magic Keyboard", "MX Master", "DualSense", "Studio Display", "TV", "Sonos"]
        var symbols = names.compactMap { DeviceSymbol.look(forName: $0)?.symbol }
        symbols += [0x2002, 0x2013, 0x2019, 0x2014, 0x200A, 0x2003, 0x200D, 0x200B, 0x2005, 0x2006, 0x2011, 0x2016, 0x2012]
            .compactMap(AppleAudioModel.symbol(for:))
        symbols += symbols.map(AppleAudioModel.caseSymbol(for:))
        symbols += [(1, 1), (1, 3), (2, 3), (4, 15), (5, 3), (6, 0), (7, 1), (9, 0)].map { DeviceSymbol.symbol(forMajorClass: $0.0, minor: $0.1) }
        #expect(symbols.count > names.count)
        for symbol in symbols {
            #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil, "\(symbol)")
        }
    }

    @Test func theCaseMatchesTheEarbuds() {
        #expect(AppleAudioModel.caseSymbol(for: "airpods.gen3") == "airpods.gen3.chargingcase.wireless")
        #expect(AppleAudioModel.caseSymbol(for: "airpods") == "airpods.chargingcase")
    }
}

struct CapsuleClockTests {
    private let taipei = TimeZone(identifier: "Asia/Taipei")!
    private var saturday: Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = taipei
        return calendar.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 8, minute: 39))!
    }

    @Test func readsLikeDayline() {
        let english = ClockLineStyle(english: true).parts(at: saturday, in: taipei)
        #expect(english.leading == "SAT OCT 31")
        #expect(english.time == "08:39")
        let chinese = ClockLineStyle(wideTracking: false).parts(at: saturday, in: taipei)
        #expect(chinese.leading == "10月31日 周六")
        let bare = ClockLineStyle(showsDate: false, showsWeekday: false, uses24Hour: false, english: true).parts(at: saturday, in: taipei)
        #expect(bare.leading == nil)
        #expect(bare.time == "8:39 AM")
    }

    @Test func theTimeComesAsTheMinuteTurns() {
        let calendar = Calendar.current
        let base = calendar.date(bySettingHour: 10, minute: 0, second: 0, of: .now)!
        #expect(CapsuleClockMode.onTheMinute.showsClock(at: base.addingTimeInterval(-2)))
        #expect(CapsuleClockMode.onTheMinute.showsClock(at: base.addingTimeInterval(3)))
        #expect(!CapsuleClockMode.onTheMinute.showsClock(at: base.addingTimeInterval(20)))
        #expect(!CapsuleClockMode.off.showsClock(at: base))
    }

    @Test func theCapsuleRedrawsOnlyWhenTheClockChanges() {
        let calendar = Calendar.current
        let base = calendar.date(bySettingHour: 10, minute: 0, second: 30, of: .now)!
        var entries = CapsuleClockSchedule(mode: .onTheMinute).entries(from: base, mode: .normal)
        let seconds = (0..<4).compactMap { _ in entries.next() }.map { calendar.component(.second, from: $0) }
        // Now, then the time coming in, the minute turning, and the task coming back.
        #expect(seconds == [30, 57, 0, 5])
    }

    @Test func aLateTaskDoesntHoldBackTheTime() {
        let calendar = Calendar.current
        let base = calendar.date(bySettingHour: 10, minute: 0, second: 0, of: .now)!
        #expect(CapsuleClockMode.onTheMinute.showsClock(at: base.addingTimeInterval(1), urgentTask: true))
        // Always the clock, but a late task gets its turns.
        let turns = (0..<15).map { CapsuleClockMode.always.showsClock(at: base.addingTimeInterval(Double($0)), urgentTask: true) }
        #expect(turns.contains(true) && turns.contains(false))
        #expect(CapsuleClockMode.always.showsClock(at: base, urgentTask: false))
    }
}
