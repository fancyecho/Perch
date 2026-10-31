import AppKit
import Carbon.HIToolbox
import SwiftUI

/// System-wide shortcut via Carbon, which needs no Accessibility permission.
/// Registration fails when another app already owns the same combination.
final class GlobalHotKey {
    /// "PRCH", telling Perch's shortcuts from anyone else's in the app.
    nonisolated static let signature = OSType(0x5052_4348)

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    /// Each shortcut sees every hot key event of the app, so it answers only to its own id.
    private let id: UInt32
    private let action: () -> Void
    private let release: (() -> Void)?

    /// `release` hears the keys come back up too, for shortcuts that are held down.
    init(id: UInt32 = 1, action: @escaping () -> Void, release: (() -> Void)? = nil) {
        self.id = id
        self.action = action
        self.release = release
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), hotKeyCallback, eventTypes.count, &eventTypes, context, &handlerRef)
    }

    func register(_ combo: HotKeyCombo?) -> HotKeyStatus {
        unregister()
        guard let combo else { return .disabled }
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr { hotKeyRef = nil }
        return status == noErr ? .registered : .unavailable
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
    }

    /// Passes events for another shortcut on down the handler chain.
    fileprivate func handle(id: UInt32, pressed: Bool) -> OSStatus {
        guard id == self.id else { return OSStatus(eventNotHandledErr) }
        if pressed {
            action()
        } else {
            release?()
        }
        return noErr
    }

    isolated deinit {
        unregister()
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}

nonisolated private func hotKeyCallback(_: EventHandlerCallRef?, _ event: EventRef?, context: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event, let context else { return noErr }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                   nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
    // The screenshot line registers shortcuts of its own, numbered from 1 too.
    guard status == noErr, hotKeyID.signature == GlobalHotKey.signature else { return OSStatus(eventNotHandledErr) }
    let id = hotKeyID.id
    let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
    let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(context).takeUnretainedValue()
    return MainActor.assumeIsolated { hotKey.handle(id: id, pressed: pressed) }
}

// MARK: - Display & conversion

extension HotKeyCombo {
    init(keyCode: UInt16, flags: NSEvent.ModifierFlags) {
        var modifiers = 0
        if flags.contains(.command) { modifiers |= cmdKey }
        if flags.contains(.option) { modifiers |= optionKey }
        if flags.contains(.control) { modifiers |= controlKey }
        if flags.contains(.shift) { modifiers |= shiftKey }
        self.init(keyCode: UInt32(keyCode), modifiers: UInt32(modifiers))
    }

    var displayString: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + " " + Self.keyName(Int(keyCode))
    }

    /// Function keys are fine as shortcuts on their own; anything else needs ⌘, ⌥ or ⌃.
    static func isAcceptable(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        let functionKeys: Set<Int> = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                                      kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
        return functionKeys.contains(Int(keyCode)) || !flags.intersection([.command, .option, .control]).isEmpty
    }

    private static let specialKeys: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_Escape: "⎋", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7",
        kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13",
        kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
    ]

    /// Names a key using the ASCII layout, so a Chinese input method still shows "K" rather than nothing.
    static func keyName(_ keyCode: Int) -> String {
        if let special = specialKeys[keyCode] { return special }
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "#\(keyCode)" }
        let layoutData = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = layoutData.withUnsafeBytes { buffer -> OSStatus in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return -1 }
            return UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return "#\(keyCode)" }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }

    /// Mirror of the combo for menu display; only for keys SwiftUI can express.
    var keyboardShortcut: KeyboardShortcut? {
        var modifiers: SwiftUI.EventModifiers = []
        if self.modifiers & UInt32(cmdKey) != 0 { modifiers.insert(.command) }
        if self.modifiers & UInt32(optionKey) != 0 { modifiers.insert(.option) }
        if self.modifiers & UInt32(controlKey) != 0 { modifiers.insert(.control) }
        if self.modifiers & UInt32(shiftKey) != 0 { modifiers.insert(.shift) }
        let key: KeyEquivalent
        switch Int(keyCode) {
        case kVK_Space: key = .space
        case kVK_Return: key = .return
        case kVK_Tab: key = .tab
        case kVK_LeftArrow: key = .leftArrow
        case kVK_RightArrow: key = .rightArrow
        case kVK_UpArrow: key = .upArrow
        case kVK_DownArrow: key = .downArrow
        default:
            let name = Self.keyName(Int(keyCode))
            guard name.count == 1, let character = name.lowercased().first else { return nil }
            key = KeyEquivalent(character)
        }
        return KeyboardShortcut(key, modifiers: modifiers)
    }
}

// MARK: - Recorder

/// Click, then press the new combination. Esc cancels, Delete clears.
struct HotKeyRecorder: View {
    var slot = HotKeySlot.tasks
    @Environment(AppSettings.self) private var settings
    @State private var monitor: Any?
    @State private var rejected = 0

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 8) {
                Button(action: toggleRecording) {
                    Text(settings.isRecording(slot) ? tr("请按下新的快捷键…", "Press a new shortcut…") : (settings.hotKey(slot)?.displayString ?? tr("未设置", "Not set")))
                        .font(.system(size: 13, weight: .medium).monospaced())
                        .frame(minWidth: 150)
                }
                .buttonStyle(.bordered)
                .tint(settings.isRecording(slot) ? .accentColor : nil)
                .keyframeAnimator(initialValue: 0.0, trigger: rejected) { content, x in
                    content.offset(x: x)
                } keyframes: { _ in
                    KeyframeTrack {
                        SpringKeyframe(8, duration: 0.06)
                        SpringKeyframe(-8, duration: 0.08)
                        SpringKeyframe(0, duration: 0.12)
                    }
                }

                if settings.isRecording(slot) {
                    Button(tr("取消", "Cancel"), action: stopRecording)
                } else if settings.hotKey(slot) != standard {
                    Button(tr("恢复默认", "Reset")) { settings.setHotKey(standard, for: slot) }
                }
            }
            statusLine
        }
        .onDisappear(perform: stopRecording)
    }

    @ViewBuilder
    private var statusLine: some View {
        Group {
            if settings.isRecording(slot) {
                Text(tr("需包含 ⌘、⌥ 或 ⌃；Esc 取消，Delete 清除。若按下无反应，说明该组合已被其他应用占用。",
                        "Use ⌘, ⌥ or ⌃. Esc cancels, Delete clears. No response means another app owns that combination."))
                    .foregroundStyle(.secondary)
            } else {
                switch settings.hotKeyStatus(slot) {
                case .registered:
                    VStack(alignment: .trailing, spacing: 2) {
                        Label(tr("已注册", "Registered"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        Text(tr("如果按下没有反应，可能被其他应用（例如 AI 助手的快捷唤出）抢先拦截，换一个组合即可。",
                                "If pressing it does nothing, another app (such as an AI assistant's quick launcher) may grab it first. Pick another combination."))
                            .foregroundStyle(.secondary)
                    }
                case .unavailable:
                    Label(tr("该组合已被其他应用占用，请换一个", "Another app already uses this shortcut. Pick another one."),
                          systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                case .disabled:
                    Text(tr("未启用全局快捷键", "Global shortcut is off")).foregroundStyle(.secondary)
                }
            }
        }
        .font(.caption)
        .multilineTextAlignment(.trailing)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var standard: HotKeyCombo { slot == .tasks ? .standard : .islandStandard }

    private func toggleRecording() {
        settings.isRecording(slot) ? stopRecording() : startRecording()
    }

    private func startRecording() {
        settings.setRecording(true, for: slot)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event)
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if settings.isRecording(slot) { settings.setRecording(false, for: slot) }
    }

    private func handle(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch Int(event.keyCode) {
        case kVK_Escape where flags.isEmpty:
            stopRecording()
        case kVK_Delete where flags.isEmpty, kVK_ForwardDelete where flags.isEmpty:
            settings.setHotKey(nil, for: slot)
            stopRecording()
        default:
            guard HotKeyCombo.isAcceptable(keyCode: event.keyCode, flags: flags) else {
                rejected += 1
                NSSound.beep()
                return
            }
            settings.setHotKey(HotKeyCombo(keyCode: event.keyCode, flags: flags), for: slot)
            stopRecording()
        }
    }
}
