import AppKit
import Carbon.HIToolbox

/// Borderless, always-on-top panel that can take keyboard focus without activating the app,
/// so typing a task never pulls the user out of whatever they are working in.
class FloatingPanel: NSPanel {
    var onCancel: (() -> Void)?

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        animationBehavior = .none
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// A pill snapped close under the menu bar has its transparent margin reaching up behind the menu
    /// bar, which stays on top and keeps its clicks. Without this AppKit would shove the whole window
    /// down below the menu bar.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    /// Some input methods swallow Esc even with nothing composed, so catch it before the text
    /// system does. While a composition is open, Esc still goes to the input method to cancel it.
    override func sendEvent(_ event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.type == .keyDown, event.keyCode == UInt16(kVK_Escape), modifiers.isEmpty {
            if let editor = firstResponder as? NSTextView {
                if !editor.hasMarkedText(), let handler = (editor.delegate as? NSTextField)?.delegate as? EscapeHandling {
                    handler.handleEscape()
                    return
                }
            } else {
                onCancel?()
                return
            }
        }
        super.sendEvent(event)
    }

    /// An agent app has no visible Edit menu, so route the standard editing shortcuts ourselves.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command || flags == [.command, .shift], let key = event.charactersIgnoringModifiers?.lowercased() {
            let action: Selector? = switch (key, flags.contains(.shift)) {
            case ("x", false): #selector(NSText.cut(_:))
            case ("c", false): #selector(NSText.copy(_:))
            case ("v", false): #selector(NSText.paste(_:))
            case ("a", false): #selector(NSResponder.selectAll(_:))
            case ("z", false): Selector(("undo:"))
            case ("z", true): Selector(("redo:"))
            default: nil
            }
            if let action, firstResponder is NSText, NSApp.sendAction(action, to: nil, from: self) {
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}
