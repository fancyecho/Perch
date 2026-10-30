import AppKit
import ApplicationServices

/// A hardware key the island can take over from the system HUD.
nonisolated enum MediaKey: Hashable, Sendable {
    case volumeUp, volumeDown, mute, brightnessUp, brightnessDown, illuminationUp, illuminationDown

    /// NX_KEYTYPE_* values from IOKit's ev_keymap.h.
    init?(keyType: Int) {
        switch keyType {
        case 0: self = .volumeUp
        case 1: self = .volumeDown
        case 2: self = .brightnessUp
        case 3: self = .brightnessDown
        case 7: self = .mute
        case 21: self = .illuminationUp
        case 22: self = .illuminationDown
        default: return nil
        }
    }
}

nonisolated struct MediaKeyPress: Sendable {
    let key: MediaKey
    let isDown: Bool
    let isRepeat: Bool
    let modifiers: NSEvent.ModifierFlags

    /// The keys arrive as system-defined events (subtype 8) whose data1 packs the key type,
    /// the up/down state and a repeat bit.
    init?(_ event: NSEvent) {
        guard event.type == .systemDefined, event.subtype.rawValue == 8 else { return nil }
        let data = event.data1
        guard let key = MediaKey(keyType: (data & 0xFFFF_0000) >> 16) else { return nil }
        let flags = data & 0xFFFF
        self.key = key
        isDown = (flags & 0xFF00) >> 8 == 0x0A
        isRepeat = flags & 0x1 != 0
        modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    }
}

/// Catches the volume, brightness and keyboard-light keys before the system does, so the island can
/// show its own HUD instead of the system's. Needs Accessibility permission; without it nothing is
/// installed and the keys behave as usual.
final class MediaKeyTap {
    /// Returns true when Perch handled the press, which hides it from the system.
    var handler: ((MediaKeyPress) -> Bool)?

    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    /// Keys whose press Perch took; their release is taken too.
    private var heldKeys: Set<MediaKey> = []

    var isActive: Bool { port != nil }

    @discardableResult
    func start() -> Bool {
        guard port == nil else { return true }
        guard Accessibility.isTrusted else { return false }
        let systemDefined = CGEventMask(1) << CGEventMask(NSEvent.EventType.systemDefined.rawValue)
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: systemDefined,
            callback: mediaKeyTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        let source = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        self.port = port
        self.source = source
        return true
    }

    func stop() {
        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        port = nil
        source = nil
        heldKeys = []
    }

    fileprivate func reenable() {
        if let port { CGEvent.tapEnable(tap: port, enable: true) }
    }

    fileprivate func handle(_ press: MediaKeyPress) -> Bool {
        if press.isDown {
            let handled = handler?(press) ?? false
            if handled { heldKeys.insert(press.key) } else { heldKeys.remove(press.key) }
            return handled
        }
        guard heldKeys.remove(press.key) != nil else { return false }
        _ = handler?(press)
        return true
    }
}

nonisolated private func mediaKeyTapCallback(
    _: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return .passUnretained(event) }
    let tap = Unmanaged<MediaKeyTap>.fromOpaque(refcon).takeUnretainedValue()
    // The system switches a tap off if it ever answers too slowly; switch it straight back on.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MainActor.assumeIsolated { tap.reenable() }
        return .passUnretained(event)
    }
    guard let nsEvent = NSEvent(cgEvent: event), let press = MediaKeyPress(nsEvent) else {
        return .passUnretained(event)
    }
    let handled = MainActor.assumeIsolated { tap.handle(press) }
    return handled ? nil : .passUnretained(event)
}

enum Accessibility {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that leads to Privacy & Security › Accessibility.
    static func requestAccess() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    static func openSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }
}
