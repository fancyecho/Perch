import SwiftUI

/// Places the glass card inside the (possibly larger, transparent) window.
struct RootView: View {
    @Environment(PanelModel.self) private var model

    var body: some View {
        let rect = model.cardRect
        GlassCard()
            .frame(width: rect.width, height: rect.height)
            .offset(x: rect.minX, y: rect.minY)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// One glass surface that morphs between the three forms. Each form's content is laid out at its
/// final size and pinned to the anchor corner, so the card appears to unfold from the pill.
private struct GlassCard: View {
    @Environment(PanelModel.self) private var model

    private var cornerRadius: CGFloat {
        switch model.mode {
        case .pill: PanelController.pillSize.height / 2
        case .peek: 20
        case .panel: 24
        }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack(alignment: model.anchor) {
            if model.mode == .panel {
                PanelView()
                    .frame(width: PanelController.panelSize.width, height: PanelController.panelSize.height)
                    .transition(.opacity.animation(.easeOut(duration: 0.22).delay(0.06)))
            } else {
                CompactView()
                    .frame(width: PanelController.pillSize.width)
                    .frame(maxHeight: .infinity, alignment: model.growsUpward ? .bottom : .top)
                    .transition(.opacity.animation(.easeOut(duration: 0.14)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: model.anchor)
        .clipShape(shape)
        .glassEffect(.regular, in: shape)
        .contentShape(shape)
        .onHover { model.setHovering($0) }
    }
}
