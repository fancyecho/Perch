import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Perch

struct LevelStepTests {
    @Test func coarseStepsAreSixteenths() {
        #expect(LevelStep.next(from: 0.5, up: true, fine: false) == 0.5625)
        #expect(LevelStep.next(from: 0.5, up: false, fine: false) == 0.4375)
    }

    @Test func fineStepsAreSixtyFourths() {
        #expect(LevelStep.next(from: 0.5, up: true, fine: true) == 0.515625)
    }

    @Test func snapsToTheGridAndStaysInRange() {
        #expect(LevelStep.next(from: 0.53, up: true, fine: false) == 0.5625)
        #expect(LevelStep.next(from: 1, up: true, fine: false) == 1)
        #expect(LevelStep.next(from: 0, up: false, fine: false) == 0)
    }
}

struct PowerEventTests {
    private func battery(_ level: Int, pluggedIn: Bool = false, charged: Bool = false) -> BatteryState {
        BatteryState(level: level, isPluggedIn: pluggedIn, isCharging: pluggedIn && !charged, isCharged: charged, minutesToFull: nil, minutesToEmpty: nil)
    }

    @Test func plugAndUnplug() {
        #expect(PowerEvent.between(battery(50), battery(50, pluggedIn: true)) == .pluggedIn)
        #expect(PowerEvent.between(battery(50, pluggedIn: true), battery(50)) == .unplugged)
    }

    @Test func lowBatteryOnlyWhenCrossingAThreshold() {
        #expect(PowerEvent.between(battery(21), battery(20)) == .low)
        #expect(PowerEvent.between(battery(20), battery(19)) == nil)
        #expect(PowerEvent.between(battery(11), battery(10)) == .low)
        #expect(PowerEvent.between(battery(25, pluggedIn: true), battery(20, pluggedIn: true)) == nil)
    }

    @Test func fullyCharged() {
        #expect(PowerEvent.between(battery(99, pluggedIn: true), battery(100, pluggedIn: true, charged: true)) == .charged)
        #expect(PowerEvent.between(battery(100, pluggedIn: true, charged: true), battery(100, pluggedIn: true, charged: true)) == nil)
    }
}

struct NowPlayingReportTests {
    @Test func decodesATrack() throws {
        let line = #"{"album":"Album","artist":"Artist","bundle":"com.apple.Music","duration":180,"elapsed":12.5,"pid":42,"playing":true,"rate":1,"timestamp":1793339697,"title":"Song"}"#
        let report = try #require(NowPlayingReport(line: line))
        #expect(report.track == MediaTrack(title: "Song", artist: "Artist", album: "Album", duration: 180))
        #expect(report.isPlaying)
        #expect(report.elapsed == 12.5)
        #expect(report.bundleID == "com.apple.Music")
        #expect(report.timestamp == Date(timeIntervalSince1970: 1793339697))
        guard case .unchanged = report.artwork else {
            Issue.record("a report without an artwork field keeps the old artwork")
            return
        }
    }

    @Test func emptyReportMeansNothingIsPlaying() throws {
        let report = try #require(NowPlayingReport(line: #"{"empty":true,"playing":false}"#))
        #expect(report.track == nil)
        #expect(!report.isPlaying)
    }

    @Test func emptyArtworkRemovesIt() throws {
        let report = try #require(NowPlayingReport(line: #"{"artwork":"","artist":"A","playing":true,"title":"T"}"#))
        guard case .removed = report.artwork else {
            Issue.record("expected the artwork to be removed")
            return
        }
    }

    @Test func artworkCarriesItsAccent() throws {
        let png = try #require(Self.solidPNG(red: 0.9, green: 0.1, blue: 0.1))
        let line = #"{"artwork":"\#(png.base64EncodedString())","artist":"A","playing":true,"title":"T"}"#
        let report = try #require(NowPlayingReport(line: line))
        guard case .replaced(let data, let accent?) = report.artwork else {
            Issue.record("expected new artwork with an accent color")
            return
        }
        #expect(data == png)
        #expect(accent.red > 0.8 && accent.green < 0.4 && accent.blue < 0.4)
        #expect(accent.hsb.brightness >= 0.86)
    }

    @Test func rejectsGarbage() {
        #expect(NowPlayingReport(line: "not json") == nil)
    }

    private static func solidPNG(red: Double, green: Double, blue: Double) -> Data? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        guard let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}

struct IslandModelTests {
    @Test func bluetoothBatteryReportsTheLowerEarbud() {
        #expect(BluetoothBattery(left: 80, right: 65).main == 65)
        #expect(BluetoothBattery(single: 40).main == 40)
        #expect(BluetoothBattery(caseLevel: 90).main == nil)
        #expect(!BluetoothBattery(caseLevel: 90).isEmpty)
    }

    @Test func colorsSurviveTheRoundTrip() {
        let color = RGB(hue: 0.6, saturation: 0.5, brightness: 0.8)
        let hsb = color.hsb
        #expect(abs(hsb.hue - 0.6) < 0.001)
        #expect(abs(hsb.saturation - 0.5) < 0.001)
        #expect(abs(hsb.brightness - 0.8) < 0.001)
    }

    @Test func statesGrowOutOfTheNotch() {
        let model = IslandModel(geometry: NotchGeometry(screen: nil))
        let notch = model.geometry.notchSize
        let idle = model.layout(for: .idle, hovering: false)
        let live = model.layout(for: .live(LiveActivity(leading: .artwork, trailing: .equalizer)), hovering: false)
        let drop = model.layout(for: .banner(.track), hovering: false)
        let expanded = model.layout(for: .expanded, hovering: false)
        let tasks = model.layout(for: .tasks, hovering: false)
        #expect(idle.width == notch.width && idle.height == notch.height)
        // Without a notch there is nothing to blend into, so the idle island hides.
        #expect(idle.isHidden)
        #expect(live.height == notch.height && live.width > notch.width)
        #expect(drop.height > live.height)
        #expect(expanded.height > drop.height)
        #expect(tasks.height > expanded.height)
        #expect(model.windowSize.width > tasks.width && model.windowSize.height > tasks.height)
    }
}

struct ReminderClockTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func picksTheNextTimedOpenTask() throws {
        let later = TaskItem(title: "later", schedule: .time(now.addingTimeInterval(3600)))
        let sooner = TaskItem(title: "sooner", schedule: .time(now.addingTimeInterval(600)))
        let past = TaskItem(title: "past", schedule: .time(now.addingTimeInterval(-60)))
        let done = TaskItem(title: "done", schedule: .time(now.addingTimeInterval(300)), completedAt: now)
        let dayOnly = TaskItem(title: "day", schedule: .day(Day(year: 2027, month: 1, day: 15)))
        let next = try #require(ReminderClock.next(after: now, in: [later, past, done, dayOnly, sooner]))
        #expect(next.time == now.addingTimeInterval(600))
        #expect(next.tasks.map(\.title) == ["sooner"])
    }

    @Test func tasksDueTogetherComeTogether() throws {
        let time = now.addingTimeInterval(900)
        let first = TaskItem(title: "a", schedule: .time(time))
        let second = TaskItem(title: "b", schedule: .time(time))
        let next = try #require(ReminderClock.next(after: now, in: [first, second]))
        #expect(next.tasks.map(\.title) == ["a", "b"])
    }

    @Test func nothingLeftToRemind() {
        #expect(ReminderClock.next(after: now, in: [TaskItem(title: "inbox")]) == nil)
    }
}

struct IslandSizeTests {
    private let model = IslandModel(geometry: NotchGeometry(screen: nil))

    @Test func openIslandIsAboutAlcovesSize() {
        let notch = model.geometry.notchSize
        let player = model.layout(for: .expanded, hovering: false)
        #expect(player.width - player.shoulder * 2 == max(notch.width + IslandModel.expandedExtraWidth, 340))
        #expect(player.height == notch.height + IslandModel.playerDrop)
        // With today's tasks inside it (merged style) it is taller, not wider.
        model.taskStyle = .merged
        let merged = model.layout(for: .expanded, hovering: false)
        #expect(merged.width == player.width)
        #expect(merged.height == notch.height + IslandModel.expandedDrop)
    }

    @Test func statusStaysAtTheNotchHeightWhileContentDropsDown() {
        let notch = model.geometry.notchSize
        let hud = model.layout(for: .banner(.level(LevelHUD(kind: .volume, value: 0.5))), hovering: false)
        #expect(hud.height == notch.height)
        #expect(hud.width - hud.shoulder * 2 == notch.width + IslandModel.bannerWing * 2)
        let task = TaskItem(title: "t", schedule: .time(.now))
        let reminder = model.layout(for: .banner(.reminder(task, alsoDue: 0)), hovering: false)
        #expect(reminder.height == notch.height + IslandModel.bannerDrop)
    }

    @Test func wingsMakeRoomForATime() {
        #expect(LiveActivity(leading: .progress, trailing: .due).wing > LiveActivity(leading: .artwork, trailing: .equalizer).wing)
        #expect(LiveActivity(leading: nil, trailing: .focus).wing == LiveActivity(leading: .progress, trailing: .due).wing)
    }
}

struct TaskCapsuleTests {
    private let model = IslandModel(geometry: NotchGeometry(screen: nil))

    @Test func capsuleIsAsWideAsTheIslandAtRest() {
        #expect(model.cardSize == CGSize(width: IslandModel.capsuleMinWidth, height: IslandModel.capsuleHeight))
        model.live = LiveActivity(leading: .artwork, trailing: .equalizer)
        let live = model.layout(for: model.restState, hovering: false)
        #expect(model.cardSize.width == max(live.width - live.shoulder * 2, IslandModel.capsuleMinWidth))
    }

    @Test func capsuleSwellsUnderThePointer() {
        let resting = model.cardSize
        model.isCardHovering = true
        #expect(model.cardSize.width > resting.width && model.cardSize.height > resting.height)
    }

    @Test func capsuleRidesBelowWhateverTheIslandShows() {
        model.banner = .track
        #expect(model.cardTop == model.layout(for: .banner(.track), hovering: false).height + IslandModel.capsuleGap)
        model.banner = nil
        model.isExpanded = true
        // Still in sight below the open island rather than hidden under it.
        #expect(model.cardTop == model.layout(for: .expanded, hovering: false).height + IslandModel.capsuleGap)
    }

    @Test func openPanelStaysWhereItOpened() {
        model.pinnedCardTop = 40
        model.cardMode = .panel
        model.banner = .track
        #expect(model.cardTop == 40)
        #expect(model.cardSize == IslandModel.panelSize)
    }
}
