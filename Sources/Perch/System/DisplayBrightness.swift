import CoreGraphics
import Foundation
import Observation

/// Brightness of the built-in display through the private DisplayServices framework, the same calls
/// the brightness keys end in. Symbols are looked up at runtime, so a missing one only turns this off.
@Observable
final class DisplayBrightness {
    private(set) var level: Double = 0

    /// DisplayServices reported a change: from the keys, Control Center or auto-brightness alike.
    @ObservationIgnored var onChange: (() -> Void)?

    private typealias GetFunction = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFunction = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private typealias CanChangeFunction = @convention(c) (CGDirectDisplayID) -> Bool
    private typealias RegisterFunction = @convention(c) (CGDirectDisplayID, UnsafeRawPointer?, CFNotificationCallback) -> Int32

    @ObservationIgnored private let getBrightness: GetFunction?
    @ObservationIgnored private let setBrightness: SetFunction?
    @ObservationIgnored private let canChange: CanChangeFunction?
    @ObservationIgnored private let register: RegisterFunction?
    @ObservationIgnored private var display: CGDirectDisplayID?
    @ObservationIgnored private var registered: Set<CGDirectDisplayID> = []

    fileprivate static weak var current: DisplayBrightness?

    init() {
        let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
        func load<T>(_ name: String, as type: T.Type) -> T? {
            dlsym(handle, name).map { unsafeBitCast($0, to: type) }
        }
        getBrightness = load("DisplayServicesGetBrightness", as: GetFunction.self)
        setBrightness = load("DisplayServicesSetBrightness", as: SetFunction.self)
        canChange = load("DisplayServicesCanChangeBrightness", as: CanChangeFunction.self)
        register = load("DisplayServicesRegisterForBrightnessChangeNotifications", as: RegisterFunction.self)
        Self.current = self
        updateDisplay()
    }

    var isAvailable: Bool { display != nil && getBrightness != nil && setBrightness != nil }

    /// Picks the display the brightness keys control: the built-in one while it's on, otherwise the
    /// main display if DisplayServices can drive it (an Apple display, say).
    func updateDisplay() {
        let candidates = [Self.activeBuiltInDisplay(), CGMainDisplayID()].compactMap { $0 }
        display = candidates.first { canChange?($0) ?? true }
        if let display, let register, !registered.contains(display) {
            if register(display, UnsafeRawPointer(bitPattern: UInt(display)), brightnessDidChange) == 0 {
                registered.insert(display)
            }
        }
        refresh()
    }

    func step(up: Bool, fine: Bool) {
        refresh()
        setLevel(LevelStep.next(from: level, up: up, fine: fine))
    }

    func setLevel(_ value: Double) {
        guard let display, let setBrightness else { return }
        let clamped = min(max(value, 0), 1)
        _ = setBrightness(display, Float(clamped))
        level = clamped
    }

    func refresh() {
        guard let display, let getBrightness else { return }
        var value: Float = 0
        if getBrightness(display, &value) == 0 { level = Double(value) }
    }

    fileprivate func notificationArrived() {
        refresh()
        onChange?()
    }

    private static func activeBuiltInDisplay() -> CGDirectDisplayID? {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return nil }
        return displays.first { CGDisplayIsBuiltin($0) != 0 }
    }
}

nonisolated private func brightnessDidChange(
    _: CFNotificationCenter?, _: UnsafeMutableRawPointer?, _: CFNotificationName?, _: UnsafeRawPointer?, _: CFDictionary?
) {
    Task { @MainActor in DisplayBrightness.current?.notificationArrived() }
}
