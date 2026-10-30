import AppKit
import AVFoundation
import IOKit.ps
import IOKit.pwr_mgt

/// Whether another app is keeping the display awake. Browsers and players do while video plays, as
/// do video calls; then the user is probably watching a lecture or in a meeting, and the screen
/// shouldn't blur on its own.
enum MediaActivity {
    private static let displayAssertionTypes: Set<String> = [
        kIOPMAssertPreventUserIdleDisplaySleep as String,
        "NoDisplaySleepAssertion",
    ]

    /// The name of the app keeping the display awake, if any.
    static func appKeepingDisplayAwake() -> String? {
        var raw: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&raw) == kIOReturnSuccess,
              let byProcess = raw?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return nil }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        for (pid, assertions) in byProcess where pid.int32Value != ownPID {
            let keepsDisplayAwake = assertions.contains { assertion in
                guard let type = assertion[kIOPMAssertionTypeKey as String] as? String else { return false }
                return displayAssertionTypes.contains(type)
            }
            guard keepsDisplayAwake else { continue }
            // Only apps with windows count, not background daemons.
            if let app = NSRunningApplication(processIdentifier: pid.int32Value), app.activationPolicy == .regular {
                return app.localizedName ?? tr("其他 App", "Another app")
            }
        }
        return nil
    }
}

enum BatteryCheck {
    /// On battery and below 20%.
    static var isLow: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return false }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let max = description[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            if Double(current) / Double(max) < 0.2 { return true }
        }
        return false
    }
}

enum Displays {
    /// The main display is dark: asleep, lid closed, or one of the dark wakes after closing it.
    static var areAsleep: Bool { CGDisplayIsAsleep(CGMainDisplayID()) != 0 }
}

/// Plays Focus's sounds (Resources/Sounds). The same sound can overlap itself.
final class SoundPlayer {
    static let shared = SoundPlayer()

    enum Sound: String {
        case enter, unlock, wrong, hold
    }

    private var pool: [String: [AVAudioPlayer]] = [:]
    private let volume: Float = 0.8

    private init() {
        // Loaded up front so the first one doesn't stutter.
        for name in ["enter", "unlock", "wrong", "hold"] + (0..<10).map({ "note\($0)" }) {
            _ = player(for: name)
        }
    }

    func play(_ sound: Sound) { play(name: sound.rawValue) }

    /// The note for the index-th correct character (from 0), a pentatonic step each.
    func playNote(_ index: Int, delay: TimeInterval = 0) {
        let name = "note\(min(max(index, 0), 9))"
        guard delay > 0 else { return play(name: name) }
        Task {
            try? await Task.sleep(for: .seconds(delay))
            play(name: name)
        }
    }

    func stop(_ sound: Sound, fade: TimeInterval) {
        for player in pool[sound.rawValue] ?? [] where player.isPlaying {
            player.setVolume(0, fadeDuration: fade)
            Task {
                try? await Task.sleep(for: .seconds(fade))
                player.stop()
            }
        }
    }

    private func play(name: String) {
        guard FocusStore.shared.soundEnabled, let player = player(for: name) else { return }
        player.currentTime = 0
        player.volume = volume
        player.play()
    }

    private func player(for name: String) -> AVAudioPlayer? {
        if let idle = pool[name]?.first(where: { !$0.isPlaying }) { return idle }
        guard let url = Bundle.main.url(forResource: name, withExtension: "m4a", subdirectory: "Sounds"),
              let player = try? AVAudioPlayer(contentsOf: url) else { return nil }
        player.prepareToPlay()
        pool[name, default: []].append(player)
        return player
    }
}

struct Quote: Equatable {
    let text: String
    let author: String
}

enum Quotes {
    static let all: [Quote] = [
        Quote(text: "不积跬步，无以至千里；不积小流，无以成江海。", author: "荀子"),
        Quote(text: "锲而舍之，朽木不折；锲而不舍，金石可镂。", author: "荀子"),
        Quote(text: "业精于勤，荒于嬉；行成于思，毁于随。", author: "韩愈"),
        Quote(text: "黑发不知勤学早，白首方悔读书迟。", author: "颜真卿"),
        Quote(text: "宝剑锋从磨砺出，梅花香自苦寒来。", author: "《警世贤文》"),
        Quote(text: "千里之行，始于足下。", author: "老子"),
        Quote(text: "合抱之木，生于毫末；九层之台，起于累土。", author: "老子"),
        Quote(text: "天下难事，必作于易；天下大事，必作于细。", author: "老子"),
        Quote(text: "学而不思则罔，思而不学则殆。", author: "孔子"),
        Quote(text: "博学之，审问之，慎思之，明辨之，笃行之。", author: "《中庸》"),
        Quote(text: "路漫漫其修远兮，吾将上下而求索。", author: "屈原"),
        Quote(text: "纸上得来终觉浅，绝知此事要躬行。", author: "陆游"),
        Quote(text: "盛年不重来，一日难再晨。及时当勉励，岁月不待人。", author: "陶渊明"),
        Quote(text: "屏幕里没有你要的答案，答案在草稿纸上。", author: "Perch"),
        Quote(text: "现在多做一道题，考场上就少慌一分。", author: "Perch"),
        Quote(text: "放下鼠标，拿起笔。这道题做完再说。", author: "Perch"),

        Quote(text: "It does not matter how slowly you go as long as you do not stop.", author: "Confucius"),
        Quote(text: "Well begun is half done.", author: "Aristotle"),
        Quote(text: "We are what we repeatedly do. Excellence, then, is not an act, but a habit.", author: "Will Durant"),
        Quote(text: "Success is the sum of small efforts, repeated day in and day out.", author: "Robert Collier"),
        Quote(text: "Concentrate all your thoughts upon the work at hand. The sun's rays do not burn until brought to a focus.", author: "Alexander Graham Bell"),
        Quote(text: "Don't watch the clock; do what it does. Keep going.", author: "Sam Levenson"),
        Quote(text: "The expert in anything was once a beginner.", author: "Helen Hayes"),
        Quote(text: "Learning never exhausts the mind.", author: "Leonardo da Vinci"),
        Quote(text: "You don't have to see the whole staircase, just take the first step.", author: "Martin Luther King Jr."),
        Quote(text: "The screen can wait. Your future can't.", author: "Perch"),
        Quote(text: "Focus on the problem in front of you, not the tab behind you.", author: "Perch"),
    ]

    static func random(excluding current: Quote? = nil) -> Quote {
        let pool = all.filter { $0.text != current?.text }
        return pool.randomElement() ?? all[0]
    }
}
