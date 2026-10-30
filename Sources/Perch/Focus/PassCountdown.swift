import AppKit
import SwiftUI

/// "Five more minutes" counting down, for when the notch island is off: a glass pill at the top of
/// the screen. It never takes focus, clicks through its empty space, and can end the pass early
/// under the pointer. With the island on, the same countdown sits beside the notch instead.
final class PassCountdownController {
    private static let size = NSSize(width: 440, height: 220)
    private static let topGap: CGFloat = 8

    private let store = ScheduleStore.shared
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    var onEndEarly: (String) -> Void = { _ in }

    /// Up while any pass runs, away when none does.
    func refresh(enabled: Bool) {
        if enabled, store.passes.values.contains(where: { $0 > .now }) { show() } else { hide() }
    }

    private func show() {
        hideTask?.cancel()
        hideTask = nil
        let panel = panel ?? makePanel()
        self.panel = panel
        position(panel)
        panel.orderFrontRegardless()
    }

    /// The pill animates out first; the window goes once it has.
    private func hide() {
        guard panel != nil, hideTask == nil else { return }
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            self?.panel?.orderOut(nil)
            self?.hideTask = nil
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: PassCountdownView(store: store) { [weak self] key in
            self?.onEndEarly(key)
        }.environment(AppSettings.shared))
        return panel
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: visible.midX - Self.size.width / 2, y: visible.maxY - Self.topGap - Self.size.height))
    }
}

private struct PassCountdownView: View {
    let store: ScheduleStore
    let onEndEarly: (String) -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let live = store.passes.filter { $0.value > context.date }.sorted { $0.value < $1.value }
                .map { ActivePass(key: $0.key, end: $0.value) }
            VStack(spacing: 8) {
                ForEach(live) { pass in
                    PassPill(pass: pass, now: context.date) { onEndEarly(pass.key) }
                        .transition(.asymmetric(
                            insertion: .move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.8, anchor: .top)),
                            removal: .opacity.combined(with: .scale(scale: 0.9, anchor: .top))))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 4)
            .animation(.spring(duration: 0.55, bounce: 0.3), value: live.map(\.key))
        }
    }
}

private struct PassPill: View {
    let pass: ActivePass
    let now: Date
    let onEndEarly: () -> Void

    /// Opens after the pointer rests a moment and closes a moment after it leaves, so passing over
    /// it doesn't flicker.
    @State private var expanded = false
    @State private var hoverTask: Task<Void, Never>?

    private var remaining: Int { max(0, Int(pass.end.timeIntervalSince(now).rounded(.up))) }
    private var urgent: Bool { remaining <= 30 }

    var body: some View {
        let fraction = min(Double(remaining) / ActivePass.duration, 1)
        // The last 30 seconds breathe once a second, like a lamp burning down.
        let breathing = urgent && remaining % 2 == 0

        HStack(spacing: 10) {
            PassRing(icon: pass.icon, isSite: pass.site != nil, fraction: fraction, urgent: urgent, lineWidth: 2.5)
                .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 0) {
                Text(urgent ? tr("\(pass.name) · 马上结束", "\(pass.name) · ending") : tr("\(pass.name) · 临时使用", "\(pass.name) · pass"))
                    .font(.system(size: 10.5, weight: .semibold))
                    .opacity(0.65)
                    .contentTransition(.interpolate)
                Text(String(format: "%d:%02d", remaining / 60, remaining % 60))
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(urgent ? AnyShapeStyle(PassRing.urgentColor) : AnyShapeStyle(.primary))
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.snappy(duration: 0.35), value: remaining)
            }
            .fixedSize()

            // "End" is always there, in a drawer that opens from zero width: the pill widening and the
            // button appearing are one animation, and the button never pokes out of the pill.
            HStack(spacing: 10) {
                Rectangle()
                    .fill(.primary.opacity(0.15))
                    .frame(width: 1, height: 18)
                EndPassButton(action: onEndEarly)
            }
            .padding(.leading, 10)
            .fixedSize()
            .frame(width: expanded ? nil : 0, alignment: .leading)
            .clipped()
            .opacity(expanded ? 1 : 0)
            .allowsHitTesting(expanded)
            .accessibilityHidden(!expanded)
        }
        .padding(.leading, 7)
        .padding(.trailing, expanded ? 8 : 16)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: .capsule)
        .shadow(color: (urgent ? PassRing.urgentColor : Brand.glow).opacity(breathing ? 0.55 : 0.18), radius: breathing ? 16 : 10, y: 3)
        .animation(.easeInOut(duration: 0.9), value: breathing)
        .contentShape(Capsule())
        .onHover(perform: hoverChanged)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(tr("\(pass.name) 临时使用，还剩 \(remaining / 60) 分 \(remaining % 60) 秒",
                               "\(pass.name) pass, \(remaining / 60) min \(remaining % 60) s left"))
    }

    private func hoverChanged(_ hovering: Bool) {
        hoverTask?.cancel()
        hoverTask = Task {
            try? await Task.sleep(for: .milliseconds(hovering ? 250 : 350))
            guard !Task.isCancelled else { return }
            withAnimation(.smooth(duration: 0.38)) { expanded = hovering }
        }
    }
}

/// An app or site icon inside the ring of time its pass has left; red in the last half minute.
struct PassRing: View {
    let icon: NSImage
    let isSite: Bool
    let fraction: Double
    let urgent: Bool
    var lineWidth: CGFloat = 2.5

    static let urgentColor = Color(red: 1.0, green: 0.42, blue: 0.36)

    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            ZStack {
                Circle().stroke(.white.opacity(0.14), lineWidth: lineWidth)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(urgent ? AnyShapeStyle(Self.urgentColor) : AnyShapeStyle(Brand.gradient),
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 1), value: fraction)
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size * 0.6, height: size * 0.6)
                    .clipShape(RoundedRectangle(cornerRadius: isSite ? size * 0.13 : 0, style: .continuous))
            }
            .frame(width: size, height: size)
        }
    }
}

/// "End" in the pill: quiet text until pointed at.
struct EndPassButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(tr("结束", "End"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(hovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.primary.opacity(hovering ? 0.12 : 0), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(SoftPressStyle())
        .onHover { hovering = $0 }
        .animation(.smooth(duration: 0.18), value: hovering)
        .accessibilityHint(tr("提前结束这次临时使用", "Ends this pass early"))
    }
}
