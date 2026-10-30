import AppKit
import SwiftUI

enum Metrics {
    static let panelRadius: CGFloat = 24
    static let panelPadding: CGFloat = 10
    /// Card radius = panel radius − padding, so the two stay concentric.
    static let cardRadius: CGFloat = panelRadius - panelPadding
    /// Gap between the panel and the menu bar.
    static let menuBarGap: CGFloat = 4
}

/// The panel's animations, tuned in one place.
enum Motion {
    /// STATUS_SLOW_MOTION=<factor>: slows the panel's animations down that many times, to check them frame by frame.
    private static let slowdown = max(Double(ProcessInfo.processInfo.environment["STATUS_SLOW_MOTION"] ?? "") ?? 1, 1)

    /// Opening unfolds down from the menu bar: a quick start and a slight bounce.
    static let open = Animation.spring(response: 0.3, dampingFraction: 0.82).speed(1 / slowdown)
    /// The fade-in runs faster than the shape, so the first frame is already legible.
    static let openFade = Animation.easeOut(duration: 0.1).speed(1 / slowdown)
    static let close = Animation.easeIn(duration: 0.16).speed(1 / slowdown)
    /// Switching pages and height changes.
    static let page = Animation.spring(response: 0.4, dampingFraction: 0.86).speed(1 / slowdown)
    static let pageExit = Animation.easeOut(duration: 0.14).speed(1 / slowdown)
    /// On opening the cards settle one after another, each a little later than the last.
    static func entrance(order: Int) -> Animation {
        // speed slows the delay too, so there's no need to multiply by slowdown here.
        .spring(response: 0.34, dampingFraction: 0.8).delay(0.018 * Double(order)).speed(1 / slowdown)
    }
    /// The window goes away only once the closing animation has finished.
    static var closeDuration: Double { 0.16 * slowdown }
}

/// Whether the panel is open. The window flips it; SwiftUI runs every animation.
@MainActor
final class PanelPresentation: ObservableObject {
    @Published var isPresented = false
}

/// A glass panel under a menu bar item, in place of MenuBarExtra for control over position, material and corners.
/// The window is one fixed transparent area; the glass, shadow, unfolding and height changes are all drawn by SwiftUI inside it,
/// so content and glass always move in one animation, never a window resize out of step with the content.
@MainActor
final class StatusPanel: NSPanel {
    static let panelWidth: CGFloat = 340
    /// Transparent margin around the panel for its shadow.
    static let shadowMargin: CGFloat = 30

    var onVisibilityChange: ((Bool) -> Void)?
    /// Called before the window shows, so the content redraws with fresh data.
    var onWillShow: (() -> Void)?
    /// Esc goes to the content first (back from a page, say); only false closes the panel.
    var onEscape: (() -> Bool)?

    private let presentation = PanelPresentation()
    private var panelSize: CGSize = .zero
    private var clickMonitor: Any?
    private var keyMonitor: Any?
    private var localClickMonitor: Any?
    private(set) var isShown = false
    /// Where the menu bar item is on screen, to tell clicking it from clicking elsewhere.
    private var anchorRect: NSRect = .zero
    private var lastClosed: TimeInterval = 0
    /// One more for each opening, to ignore stale “closing finished” callbacks.
    private var generation = 0

    /// Where the panel (its glass) is on screen.
    var panelFrame: NSRect {
        NSRect(x: frame.minX + Self.shadowMargin, y: frame.maxY - panelSize.height,
               width: Self.panelWidth, height: panelSize.height)
    }

    init<Content: View>(rootView: Content) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth + Self.shadowMargin * 2, height: 600),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        // SwiftUI draws the shadow along the panel's shape; a window shadow would follow the whole transparent window.
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        animationBehavior = .none

        let hosting = NSHostingView(rootView: PanelChrome(presentation: presentation,
                                                          onSize: { [weak self] in self?.panelSize = $0 }) { rootView })
        // The window's size is ours to decide; the SwiftUI content doesn't stretch it.
        hosting.sizingOptions = []
        contentView = hosting
    }

    override var canBecomeKey: Bool { true }

    /// From macOS 26 the panel uses the system's Liquid Glass, which draws its own edge highlight, so PanelEdge isn't added.
    static var usesSystemGlass: Bool {
        if #available(macOS 26.0, *) { true } else { false }
    }

    func toggle(below button: NSStatusBarButton) {
        if isShown {
            close()
        } else if ProcessInfo.processInfo.systemUptime - lastClosed > 0.3 {
            // Don't reopen right after the same click closed it.
            show(below: button)
        }
    }

    func show(below button: NSStatusBarButton) {
        guard let buttonWindow = button.window, let screen = buttonWindow.screen ?? NSScreen.main else { return }
        show(anchor: buttonWindow.convertToScreen(button.convert(button.bounds, to: nil)), on: screen)
    }

    /// Opens hanging from `anchor`, a rect in screen coordinates (the readout's button, or the
    /// menu bar's top-right corner when there's no button to hang from).
    func show(anchor: NSRect, on screen: NSScreen) {
        guard !isShown else { return }
        let visible = screen.visibleFrame
        let panelX = min(max(anchor.midX - Self.panelWidth / 2, visible.minX + 6), visible.maxX - Self.panelWidth - 6)
        let top = min(anchor.minY, visible.maxY) - Metrics.menuBarGap
        // The window reaches from the panel's top to the bottom of the screen, so taller pages need no resize; the clear part ignores clicks.
        setFrame(NSRect(x: panelX - Self.shadowMargin, y: visible.minY,
                        width: Self.panelWidth + Self.shadowMargin * 2, height: top - visible.minY),
                 display: false)
        anchorRect = anchor
        isShown = true
        generation += 1
        onWillShow?()
        makeKeyAndOrderFront(nil)
        // Start unfolding in the same pass the window shows, not the next one.
        withAnimation(Motion.open) { presentation.isPresented = true }
        installMonitors()
        onVisibilityChange?(true)
    }

    override func close() {
        guard isShown else { return }
        isShown = false
        lastClosed = ProcessInfo.processInfo.systemUptime
        removeMonitors()
        onVisibilityChange?(false)
        withAnimation(Motion.close) { presentation.isPresented = false }
        let closing = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + Motion.closeDuration) { [weak self] in
            MainActor.assumeIsolated {
                // Reopened while closing: stay.
                guard let self, !self.isShown, self.generation == closing else { return }
                self.orderOut(nil)
            }
        }
    }

    private func installMonitors() {
        // Clicking elsewhere or pressing Esc closes it, as with system menus.
        // Clicks on the menu bar item are left to it (it toggles), or the panel would close and reopen.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            let location = NSEvent.mouseLocation
            MainActor.assumeIsolated {
                guard let self, !self.anchorRect.insetBy(dx: -2, dy: -2).contains(location) else { return }
                self.close()
            }
        }
        // A click in the window but outside the panel (the shadow margin) closes it too.
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, event.window === self else { return event }
            let location = NSEvent.mouseLocation
            if self.panelFrame.contains(location) { return event }
            self.close()
            return nil
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, let self else { return event }
            if self.onEscape?() != true { self.close() }
            return nil
        }
    }

    private func removeMonitors() {
        for monitor in [clickMonitor, localClickMonitor, keyMonitor].compactMap({ $0 }) { NSEvent.removeMonitor(monitor) }
        clickMonitor = nil
        localClickMonitor = nil
        keyMonitor = nil
    }

    /// Continuous-curvature corners (the system windows' squircle), stretched as a nine-part image.
    static func roundedMask(radius: CGFloat) -> NSImage {
        let inset = ceil(radius * 1.6)
        let edge = inset * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.addPath(RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect).cgPath)
            context.setFillColor(NSColor.black.cgColor)
            context.fillPath()
            return true
        }
        image.capInsets = NSEdgeInsets(top: inset, left: inset, bottom: inset, right: inset)
        image.resizingMode = .stretch
        return image
    }
}

// MARK: - SwiftUI chrome

/// The panel's shell: unfolding and folding, content pinned to the top of the window. The content draws the glass and
/// shadow itself through PanelSurface, so they share an animation scope with the page height.
private struct PanelChrome<Content: View>: View {
    @ObservedObject var presentation: PanelPresentation
    let onSize: (CGSize) -> Void
    @ViewBuilder var content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shown = presentation.isPresented
        // Folded it squashes slightly against the menu bar, unfolding as if it hung down from it; Reduce Motion only fades.
        let folded = !shown && !reduceMotion
        content
            .environment(\.panelPresented, shown)
            .environment(\.panelSurfaceEnabled, true)
            .background { SizeReader(onChange: onSize) }
            .scaleEffect(x: folded ? 0.97 : 1, y: folded ? 0.92 : 1, anchor: .top)
            .offset(y: folded ? -6 : 0)
            // A spring for the shape and a faster curve for the fade: the outer animation only drives opacity.
            .animation(shown ? Motion.open : Motion.close, value: shown)
            .opacity(shown ? 1 : 0)
            .animation(shown ? Motion.openFade : Motion.close, value: shown)
            .padding([.horizontal, .bottom], StatusPanel.shadowMargin)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// The panel's glass, edge highlight and shadow, in the content's background (not drawn in static snapshots).
struct PanelSurface: View {
    @Environment(\.panelSurfaceEnabled) private var enabled
    @Environment(\.panelPresented) private var presented

    var body: some View {
        if enabled {
            ZStack {
                PanelShadow()
                // The glass is inserted and removed with the open state, so the system condenses it in and out instead of a plain fade.
                if presented { PanelBackdrop() }
                if !StatusPanel.usesSystemGlass { PanelEdge() }
            }
        }
    }
}

/// The panel's background. From macOS 26 it's SwiftUI's Liquid Glass, drawn by SwiftUI itself, so it stretches
/// in the same animation as the content (SwiftUI doesn't interpolate an AppKit view's size frame by frame).
/// In light mode regular glass reads too white over light backgrounds; a slight dark tint sits closer to the background and sharpens the cards' edges.
private struct PanelBackdrop: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if #available(macOS 26.0, *) {
            Color.clear
                .glassEffect(.regular.tint(scheme == .dark ? nil : .black.opacity(0.06)),
                             in: RoundedRectangle(cornerRadius: Metrics.panelRadius, style: .continuous))
        } else {
            LegacyBackdrop()
        }
    }
}

/// macOS 14–25: frosted material with a continuous-corner mask.
private struct LegacyBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let effectView = NSVisualEffectView()
        effectView.material = .popover
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.maskImage = StatusPanel.roundedMask(radius: Metrics.panelRadius)
        return effectView
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// A shadow drawn only outside the panel: hollowed out inside, so it never darkens the translucent glass.
private struct PanelShadow: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.panelRadius, style: .continuous)
        let dark = scheme == .dark
        shape.fill(.black)
            .shadow(color: .black.opacity(dark ? 0.42 : 0.16), radius: 18, y: 10)
            .shadow(color: .black.opacity(dark ? 0.3 : 0.08), radius: 1.5, y: 0.5)
            .mask {
                Rectangle()
                    .padding(-StatusPanel.shadowMargin)
                    .overlay { shape.blendMode(.destinationOut) }
                    .compositingGroup()
            }
            .allowsHitTesting(false)
    }
}

private struct PanelPresentedKey: EnvironmentKey {
    static let defaultValue = true
}

private struct PanelSurfaceEnabledKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Whether the panel is open (anything outside a panel, like static snapshots, counts as open).
    var panelPresented: Bool {
        get { self[PanelPresentedKey.self] }
        set { self[PanelPresentedKey.self] = newValue }
    }

    /// Whether this is inside a real panel window (which draws its own glass and shadow).
    var panelSurfaceEnabled: Bool {
        get { self[PanelSurfaceEnabledKey.self] }
        set { self[PanelSurfaceEnabledKey.self] = newValue }
    }
}

/// On opening, settle in order from the top; on closing, all go back together.
private struct PanelEntrance: ViewModifier {
    let order: Int
    @Environment(\.panelPresented) private var presented
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .offset(y: presented || reduceMotion ? 0 : -8)
            .opacity(presented ? 1 : 0)
            .animation(presented ? Motion.entrance(order: order) : Motion.close, value: presented)
    }
}

extension View {
    func panelEntrance(_ order: Int) -> some View { modifier(PanelEntrance(order: order)) }
}

/// A faint highlight around the panel's edge, like the edge of glass.
struct PanelEdge: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        RoundedRectangle(cornerRadius: Metrics.panelRadius, style: .continuous)
            .strokeBorder(
                LinearGradient(colors: [.white.opacity(scheme == .dark ? 0.22 : 0.65),
                                        .white.opacity(scheme == .dark ? 0.06 : 0.2)],
                               startPoint: .top, endPoint: .bottom),
                lineWidth: 0.8)
            .allowsHitTesting(false)
    }
}

private struct SizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

private struct SizeReader: View {
    let onChange: (CGSize) -> Void

    var body: some View {
        GeometryReader { geo in
            Color.clear.preference(key: SizeKey.self, value: geo.size)
        }
        .onPreferenceChange(SizeKey.self) { size in
            MainActor.assumeIsolated { onChange(size) }
        }
    }
}
