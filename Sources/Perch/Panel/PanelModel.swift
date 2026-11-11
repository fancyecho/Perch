import SwiftUI

enum PanelMode: Equatable {
    case pill, peek, panel
}

enum TaskTab: Int, CaseIterable, Identifiable {
    case today, upcoming, inbox, done
    /// Not a list of tasks: today's focus and the schedules.
    case focus

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .today: tr("今天", "Today")
        case .upcoming: tr("即将", "Upcoming")
        case .inbox: tr("收件箱", "Inbox")
        case .done: tr("已完成", "Done")
        case .focus: tr("专注", "Focus")
        }
    }
}

/// A request to put the caret in an opened task's checklist or notes.
struct DetailFocus: Equatable {
    enum Field: Equatable { case newSubtask, notes }

    var taskID: UUID
    var field: Field
    /// Asking twice for the same field still moves the caret.
    var token = UUID()
}

/// View-facing state of the floating card. Rects are in the window's SwiftUI (top-left) space.
@Observable
final class PanelModel {
    var mode: PanelMode = .pill
    var pillRect: CGRect = .zero
    var peekRect: CGRect = .zero
    var panelRect: CGRect = .zero
    /// The corner of the card that stays put while it grows.
    var anchor: Alignment = .topTrailing
    var isHovering = false
    var inputFocusRequest = 0
    /// Text to put in the quick-add field (and focus it), e.g. a free slot's time.
    var prefill: String?
    var tab: TaskTab = .today
    /// The task opened up to show its checklist and notes (one at a time).
    var expandedTaskID: UUID?
    /// Where to put the caret once that task's details are on screen.
    var detailFocus: DetailFocus?
    /// The panel is shown inside the notch island rather than the floating window.
    @ObservationIgnored var isInIsland = false

    @ObservationIgnored var router: ((PanelMode, Bool) -> Void)?
    @ObservationIgnored var hoverHandler: ((Bool) -> Void)?
    @ObservationIgnored var settingsHandler: ((SettingsTab) -> Void)?

    var cardRect: CGRect {
        switch mode {
        case .pill: pillRect
        case .peek: peekRect
        case .panel: panelRect
        }
    }

    var growsUpward: Bool { anchor == .bottomLeading || anchor == .bottomTrailing }

    func isExpanded(_ id: UUID) -> Bool { expandedTaskID == id }

    /// Opens a task's details, or closes them if they are open and nothing asks for the caret.
    func toggleDetails(_ id: UUID) {
        expandedTaskID = expandedTaskID == id ? nil : id
        detailFocus = nil
    }

    /// Opens a task's details with the caret in its checklist or its notes.
    func editDetails(_ id: UUID, _ field: DetailFocus.Field) {
        expandedTaskID = id
        detailFocus = DetailFocus(taskID: id, field: field)
    }

    func go(_ mode: PanelMode, focusInput: Bool = false) {
        router?(mode, focusInput)
    }

    func setHovering(_ hovering: Bool) {
        guard isHovering != hovering else { return }
        isHovering = hovering
        hoverHandler?(hovering)
    }

    func openSettings(_ tab: SettingsTab = .tasks) {
        settingsHandler?(tab)
    }
}
