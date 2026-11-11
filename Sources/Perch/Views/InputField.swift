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
    /// Focusing puts the caret after the text instead of selecting it (for prefilled text).
    var caretAtEnd = false
    /// A fainter placeholder, for fields that sit among other text rather than stand alone.
    var quietPlaceholder = false
    var onSubmit: (String) -> Void
    var onCancel: () -> Void = {}
    var onFocusChange: (Bool) -> Void = { _ in }
    /// Backspace in an empty field (a checklist row deletes itself). Nil lets it beep as usual.
    var onDeleteWhenEmpty: (() -> Void)?

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
        if quietPlaceholder {
            field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
                .foregroundColor: NSColor.tertiaryLabelColor, .font: NSFont.systemFont(ofSize: fontSize),
            ])
        } else {
            field.placeholderString = placeholder
        }
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
            if caretAtEnd, let editor = field.currentEditor() {
                editor.selectedRange = NSRange(location: (editor.string as NSString).length, length: 0)
            }
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
            case #selector(NSResponder.deleteBackward(_:)):
                guard let onDelete = parent.onDeleteWhenEmpty, textView.string.isEmpty, !textView.hasMarkedText() else { return false }
                onDelete()
                return true
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

/// A borderless text field that wraps and grows with its text, for a task's notes. Return
/// starts a new line; Esc or clicking elsewhere ends editing.
struct NotesField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var fontSize: CGFloat = 12
    /// Bump to move keyboard focus into the field.
    var focusRequest = 0
    var focusOnAppear = false
    var onFocusChange: (Bool) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> FocusReportingTextField {
        let field = FocusReportingTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: fontSize)
        field.textColor = .secondaryLabelColor
        field.lineBreakMode = .byWordWrapping
        field.usesSingleLineMode = false
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        field.maximumNumberOfLines = 0
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.delegate = context.coordinator
        field.stringValue = text
        context.coordinator.lastFocusRequest = focusRequest
        if focusOnAppear { focus(field) }
        return field
    }

    private func focus(_ field: NSTextField) {
        Task {
            try? await Task.sleep(for: .milliseconds(60))
            field.window?.makeFirstResponder(field)
            if let editor = field.currentEditor() {
                editor.selectedRange = NSRange(location: (editor.string as NSString).length, length: 0)
            }
        }
    }

    func updateNSView(_ field: FocusReportingTextField, context: Context) {
        context.coordinator.parent = self
        field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .foregroundColor: NSColor.tertiaryLabelColor, .font: NSFont.systemFont(ofSize: fontSize),
        ])
        field.onFocus = { onFocusChange(true) }
        let editor = field.currentEditor() as? NSTextView
        if !(editor?.hasMarkedText() ?? false), (editor?.string ?? field.stringValue) != text {
            field.stringValue = text
        }
        if context.coordinator.lastFocusRequest != focusRequest {
            context.coordinator.lastFocusRequest = focusRequest
            focus(field)
        }
    }

    /// As tall as the wrapped text at the offered width, and never less than one line.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView field: FocusReportingTextField, context: Context) -> CGSize? {
        let width = proposal.width ?? 240
        guard width.isFinite, width > 0, let cell = field.cell else { return nil }
        let line = ceil((field.font ?? .systemFont(ofSize: fontSize)).boundingRectForFont.height)
        let shown = cell.copy() as? NSCell ?? cell
        shown.stringValue = text.isEmpty ? " " : text
        let height = shown.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)).height
        return CGSize(width: width, height: max(ceil(height), line))
    }

    final class Coordinator: NSObject, NSTextFieldDelegate, EscapeHandling {
        var parent: NotesField
        var lastFocusRequest = 0

        init(_ parent: NotesField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            if let editor = field.currentEditor() as? NSTextView, editor.hasMarkedText() { return }
            parent.text = field.stringValue
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            parent.onFocusChange(false)
        }

        /// Esc puts the notes down, keeping what was written.
        func handleEscape() {
            NSApp.keyWindow?.makeFirstResponder(nil)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                guard !textView.hasMarkedText() else { return false }
                textView.insertNewlineIgnoringFieldEditor(nil)
                return true
            case #selector(NSResponder.cancelOperation(_:)), #selector(NSResponder.complete(_:)):
                guard !textView.hasMarkedText() else { return false }
                handleEscape()
                return true
            default:
                return false
            }
        }
    }
}
