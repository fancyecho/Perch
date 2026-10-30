import Foundation
import Observation

/// The parts of CoreBrightness's private KeyboardBrightnessClient that Perch calls.
@objc private protocol KeyboardBrightnessClientMethods {
    func copyKeyboardBacklightIDs() -> NSArray?
    func brightnessForKeyboard(_ keyboard: UInt64) -> Float
    func setBrightness(_ brightness: Float, forKeyboard keyboard: UInt64) -> Bool
}

/// The built-in keyboard's backlight, for Macs whose keyboards still have backlight keys.
@Observable
final class KeyboardBacklight {
    private(set) var level: Double = 0

    @ObservationIgnored private let client: KeyboardBrightnessClientMethods?
    @ObservationIgnored private let keyboard: UInt64?

    init() {
        dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW)
        let selectors = [
            #selector(KeyboardBrightnessClientMethods.copyKeyboardBacklightIDs),
            #selector(KeyboardBrightnessClientMethods.brightnessForKeyboard(_:)),
            #selector(KeyboardBrightnessClientMethods.setBrightness(_:forKeyboard:)),
        ]
        guard let type = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type,
              selectors.allSatisfy({ type.instancesRespond(to: $0) }) else {
            client = nil
            keyboard = nil
            return
        }
        let client = unsafeBitCast(type.init(), to: KeyboardBrightnessClientMethods.self)
        self.client = client
        keyboard = (client.copyKeyboardBacklightIDs() as? [NSNumber])?.first?.uint64Value
        refresh()
    }

    var isAvailable: Bool { client != nil && keyboard != nil }

    func step(up: Bool, fine: Bool) {
        refresh()
        setLevel(LevelStep.next(from: level, up: up, fine: fine))
    }

    func setLevel(_ value: Double) {
        guard let client, let keyboard else { return }
        let clamped = min(max(value, 0), 1)
        _ = client.setBrightness(Float(clamped), forKeyboard: keyboard)
        level = clamped
    }

    func refresh() {
        guard let client, let keyboard else { return }
        level = Double(client.brightnessForKeyboard(keyboard))
    }
}
