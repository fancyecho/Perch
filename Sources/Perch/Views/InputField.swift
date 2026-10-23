import AppKit
import SwiftUI

/// A plain single-line text field backed by NSTextField.
///
/// SwiftUI's TextField can hand `onSubmit` a stale value when an input method (Pinyin etc.)
/// commits text just before Return. This reads the field editor's live string instead, and
/// leaves Return alone while a composition is still open so the IME can commit it.
struct InputField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var fontSize: CGFloat = 13
    /// Bump to move keyboard focus into the field.
    var focusRequest = 0
    var focusOnAppear = false
    var onSubmit: (String) -> Void
    var onCancel: () -> Void = {}
    var onFocusChange: (Bool) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> FocusReportingTextField {
        let field = FocusReportingTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: fontSize)
        field.lineBreakMode = .byClipping
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.delegate = context.coordinator
        field.stringValue = text
        context.coordinator.lastFocusRequest = focusRequest
        if focusOnAppear { focus(field) }
        return field
    }

    func updateNSView(_ field: FocusReportingTextField, context: Context) {
        context.coordinator.parent = self
        field.placeholderString = placeholder
        field.onFocus = { onFocusChange(true) }

        let editor = field.currentEditor() as? NSTextView
        let isComposing = editor?.hasMarkedText() ?? false
        if !isComposing, (editor?.string ?? field.stringValue) != text {
            field.stringValue = text
        }

        if context.coordinator.lastFocusRequest != focusRequest {
            context.coordinator.lastFocusRequest = focusRequest
            focus(field)
        }
    }

    /// Waits a beat so the field is in its window and that window is key.
    private func focus(_ field: NSTextField) {
        Task {
            try? await Task.sleep(for: .milliseconds(60))
            field.window?.makeFirstResponder(field)
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate, EscapeHandling {
        var parent: InputField
        var lastFocusRequest = 0

        init(_ parent: InputField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            if let editor = field.currentEditor() as? NSTextView, editor.hasMarkedText() { return }
            parent.text = field.stringValue
        }

        func handleEscape() {
            parent.onCancel()
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            parent.onFocusChange(false)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                guard !textView.hasMarkedText() else { return false }
                let value = textView.string
                parent.text = value
                parent.onSubmit(value)
                return true
            // A text field maps Esc to `complete:` (autocompletion) rather than `cancelOperation:`.
            case #selector(NSResponder.cancelOperation(_:)), #selector(NSResponder.complete(_:)):
                guard !textView.hasMarkedText() else { return false }
                parent.onCancel()
                return true
            default:
                return false
            }
        }
    }
}

/// Something that reacts to Esc in place of the text system.
protocol EscapeHandling: AnyObject {
    func handleEscape()
}

final class FocusReportingTextField: NSTextField {
    var onFocus: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocus?() }
        return accepted
    }
}
