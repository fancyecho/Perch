import SwiftUI

enum PanelMode: Equatable {
    case pill, peek, panel
}

enum TaskTab: Int, CaseIterable, Identifiable {
    case today, upcoming, inbox, done

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .today: tr("今天", "Today")
        case .upcoming: tr("即将", "Upcoming")
        case .inbox: tr("收件箱", "Inbox")
        case .done: tr("已完成", "Done")
        }
    }
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
    var tab: TaskTab = .today

    @ObservationIgnored var router: ((PanelMode, Bool) -> Void)?
    @ObservationIgnored var hoverHandler: ((Bool) -> Void)?
    @ObservationIgnored var settingsHandler: (() -> Void)?

    var cardRect: CGRect {
        switch mode {
        case .pill: pillRect
        case .peek: peekRect
        case .panel: panelRect
        }
    }

    var growsUpward: Bool { anchor == .bottomLeading || anchor == .bottomTrailing }

    func go(_ mode: PanelMode, focusInput: Bool = false) {
        router?(mode, focusInput)
    }

    func setHovering(_ hovering: Bool) {
        guard isHovering != hovering else { return }
        isHovering = hovering
        hoverHandler?(hovering)
    }

    func openSettings() {
        settingsHandler?()
    }
}
