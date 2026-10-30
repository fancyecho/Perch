import AppKit
import SwiftUI

/// Owns the floating window and morphs the glass card between pill, peek and panel.
///
/// While collapsed the window hugs the pill so it never blocks clicks elsewhere. When the card
/// opens, the window grows once to cover pill ∪ panel; every morph after that is a pure SwiftUI
/// spring inside the window (interruptible), and the window shrinks back after the card collapses.
final class PanelController: NSObject, NSWindowDelegate {
    static let margin: CGFloat = 24
    static let pillSize = CGSize(width: 268, height: 46)
    static let panelSize = CGSize(width: 368, height: 560)
    static let peekRowHeight: CGFloat = 34
    static let peekMaxRows = 3
    static let morph = Animation.spring(duration: 0.48, bounce: 0.18)

    let panel = FloatingPanel()
    private let model: PanelModel
    private let store: TaskStore
    private var isWindowExpanded = false
    private var generation = 0
    private var hoverTask: Task<Void, Never>?
    private var peekWatchTask: Task<Void, Never>?
    private var fadeTask: Task<Void, Never>?
    private var settleTask: Task<Void, Never>?
    private var ignoresMoves = false
    private var isSuspended = false

    init(store: TaskStore, model: PanelModel, swipe: SwipeTracker, settings: AppSettings) {
        self.store = store
        self.model = model
        super.init()

        let root = RootView()
            .environment(store)
            .environment(model)
            .environment(swipe)
            .environment(settings)
            .environment(Updater.shared)
            .environment(Feedback.shared)
        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = []
        panel.contentView = hosting
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.go(.pill) }

        model.router = { [weak self] mode, focusInput in self?.go(mode, focusInput: focusInput) }
        model.hoverHandler = { [weak self] hovering in self?.hoverChanged(hovering) }

        applyPreferences()
        layoutCollapsed(home: restoredHome())
        panel.orderFrontRegardless()
        scheduleFade(after: 1.5)

        NotificationCenter.default.addObserver(self, selector: #selector(preferencesChanged), name: UserDefaults.didChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    // MARK: - Public

    func toggle() {
        model.mode == .panel ? go(.pill) : go(.panel, focusInput: true)
    }

    func go(_ target: PanelMode, focusInput: Bool = false) {
        guard !isSuspended else { return }
        hoverTask?.cancel()
        generation += 1
        let token = generation

        let needsGrow = !isWindowExpanded && target != .pill
        if needsGrow { growWindow() }

        if target == .peek {
            let rect = peekRect()
            if model.mode == .peek {
                withAnimation(Self.morph) { model.peekRect = rect }
            } else {
                withoutAnimation { model.peekRect = rect }
            }
        }

        if target == .panel {
            panel.makeKeyAndOrderFront(nil)
            if focusInput { model.inputFocusRequest += 1 }
        }
        setAlpha(1, duration: 0.12)

        let animate: @MainActor @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            withAnimation(Self.morph) {
                self.model.mode = target
            } completion: { [weak self] in
                guard let self, token == self.generation, target == .pill else { return }
                self.finishCollapse()
            }
        }
        // Give the instantly re-laid-out window one frame before the spring starts.
        if needsGrow {
            DispatchQueue.main.async(execute: animate)
        } else {
            animate()
        }
    }

    /// While the notch island hosts today's tasks, the floating pill steps aside.
    func setSuspended(_ suspended: Bool) {
        guard suspended != isSuspended else { return }
        isSuspended = suspended
        guard suspended else {
            panel.orderFrontRegardless()
            scheduleFade(after: 1.2)
            return
        }
        hoverTask?.cancel()
        peekWatchTask?.cancel()
        if model.mode != .pill {
            generation += 1
            withoutAnimation { model.mode = .pill }
            layoutCollapsed(home: homeScreenRect)
        }
        panel.orderOut(nil)
    }

    // MARK: - Window geometry

    private var homeScreenRect: NSRect {
        let frame = panel.frame
        let pill = model.pillRect
        return NSRect(x: frame.minX + pill.minX, y: frame.maxY - pill.maxY, width: pill.width, height: pill.height)
    }

    private func layoutCollapsed(home: NSRect) {
        let m = Self.margin
        let local = CGRect(x: m, y: m, width: home.width, height: home.height)
        withoutAnimation {
            model.pillRect = local
            model.peekRect = local
            model.panelRect = local
        }
        setWindowFrame(home.insetBy(dx: -m, dy: -m))
        isWindowExpanded = false
    }

    private func growWindow() {
        let home = homeScreenRect
        let visible = screen(containing: home).visibleFrame.insetBy(dx: 6, dy: 6)
        let trailing = home.midX > visible.midX
        let top = home.midY > visible.midY
        let size = Self.panelSize
        let panelRect = clamp(
            NSRect(
                x: trailing ? home.maxX - size.width : home.minX,
                y: top ? home.maxY - size.height : home.minY,
                width: size.width,
                height: size.height
            ),
            into: visible
        )
        let window = home.union(panelRect).insetBy(dx: -Self.margin, dy: -Self.margin)
        withoutAnimation {
            model.anchor = top ? (trailing ? .topTrailing : .topLeading) : (trailing ? .bottomTrailing : .bottomLeading)
            model.pillRect = local(home, in: window)
            model.peekRect = model.pillRect
            model.panelRect = local(panelRect, in: window)
        }
        setWindowFrame(window)
        isWindowExpanded = true
    }

    private func finishCollapse() {
        layoutCollapsed(home: homeScreenRect)
        if panel.isKeyWindow {
            // Hand keyboard focus back to whatever app the user was in.
            panel.orderOut(nil)
            panel.orderFrontRegardless()
        }
        if !model.isHovering { scheduleFade(after: 1.2) }
    }

    private func peekRect() -> CGRect {
        let pill = model.pillRect
        let rows = min(store.peekTasks(now: .now).count, Self.peekMaxRows)
        let height = Self.pillSize.height + CGFloat(max(rows, 1)) * Self.peekRowHeight + 12
        var rect = CGRect(x: pill.minX, y: model.growsUpward ? pill.maxY - height : pill.minY, width: pill.width, height: height)
        let bounds = CGRect(origin: .zero, size: panel.frame.size).insetBy(dx: Self.margin, dy: Self.margin)
        rect.origin.y = min(max(rect.minY, bounds.minY), bounds.maxY - height)
        return rect
    }

    private func local(_ rect: NSRect, in window: NSRect) -> CGRect {
        CGRect(x: rect.minX - window.minX, y: window.maxY - rect.maxY, width: rect.width, height: rect.height)
    }

    private func setWindowFrame(_ frame: NSRect) {
        ignoresMoves = true
        panel.setFrame(frame, display: true)
        panel.contentView?.layoutSubtreeIfNeeded()
        ignoresMoves = false
    }

    private func screen(containing rect: NSRect) -> NSScreen {
        NSScreen.screens.first { $0.frame.contains(NSPoint(x: rect.midX, y: rect.midY)) }
            ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func clamp(_ rect: NSRect, into bounds: NSRect) -> NSRect {
        var r = rect
        r.origin.x = min(max(r.minX, bounds.minX), bounds.maxX - r.width)
        r.origin.y = min(max(r.minY, bounds.minY), bounds.maxY - r.height)
        return r
    }

    private func restoredHome() -> NSRect {
        let size = Self.pillSize
        if let saved = UserDefaults.standard.string(forKey: Pref.pillOrigin) {
            let rect = NSRect(origin: NSPointFromString(saved), size: size)
            if NSScreen.screens.contains(where: { $0.visibleFrame.contains(rect) }) { return rect }
        }
        let visible = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        return NSRect(x: visible.maxX - size.width - 16, y: visible.maxY - size.height - 12, width: size.width, height: size.height)
    }

    // MARK: - Dragging & magnetic edges

    func windowDidMove(_ notification: Notification) {
        guard !ignoresMoves else { return }
        hoverTask?.cancel()
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            while NSEvent.pressedMouseButtons != 0 {
                try? await Task.sleep(for: .milliseconds(40))
                if Task.isCancelled { return }
            }
            self?.settleAfterDrag()
        }
    }

    private func settleAfterDrag() {
        if model.mode == .pill { snapToEdges() }
        UserDefaults.standard.set(NSStringFromPoint(homeScreenRect.origin), forKey: Pref.pillOrigin)
    }

    private func snapToEdges() {
        let home = homeScreenRect
        let visible = screen(containing: home).visibleFrame
        let reach: CGFloat = 40
        let gap: CGFloat = 10
        var target = home
        if home.minX - visible.minX < reach { target.origin.x = visible.minX + gap }
        if visible.maxX - home.maxX < reach { target.origin.x = visible.maxX - gap - home.width }
        if abs(home.midX - visible.midX) < reach { target.origin.x = visible.midX - home.width / 2 }
        if home.minY - visible.minY < reach { target.origin.y = visible.minY + gap }
        if visible.maxY - home.maxY < reach { target.origin.y = visible.maxY - gap - home.height }
        target = clamp(target, into: visible)
        guard target != home else { return }
        ignoresMoves = true
        panel.setFrame(target.insetBy(dx: -Self.margin, dy: -Self.margin), display: true, animate: true)
        ignoresMoves = false
    }

    @objc private func screensChanged() {
        guard model.mode == .pill else { return }
        let home = homeScreenRect
        if !NSScreen.screens.contains(where: { $0.visibleFrame.contains(home) }) {
            layoutCollapsed(home: restoredHome())
        }
    }

    // MARK: - Hover peek & idle fade

    private func hoverChanged(_ hovering: Bool) {
        hoverTask?.cancel()
        if hovering {
            fadeTask?.cancel()
            setAlpha(1, duration: 0.15)
        } else {
            scheduleFade(after: 1.2)
        }

        if hovering, model.mode == .pill, UserDefaults.standard.bool(forKey: Pref.peekOnHover) {
            hoverTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(320))
                guard let self, !Task.isCancelled, self.isMouseInsideCard, self.model.mode == .pill,
                      NSEvent.pressedMouseButtons == 0 else { return }
                self.go(.peek)
                self.watchPeek()
            }
        }
    }

    /// Hover-exit events are unreliable while the window resizes underneath a still cursor,
    /// so the peek closes based on where the pointer actually is.
    private func watchPeek() {
        peekWatchTask?.cancel()
        peekWatchTask = Task { [weak self] in
            var outsideTicks = 0
            while let self, !Task.isCancelled, self.model.mode == .peek {
                try? await Task.sleep(for: .milliseconds(100))
                outsideTicks = self.isMouseInsideCard ? 0 : outsideTicks + 1
                if outsideTicks >= 3, self.model.mode == .peek {
                    self.go(.pill)
                    return
                }
            }
        }
    }

    private var isMouseInsideCard: Bool {
        let frame = panel.frame
        let card = model.cardRect
        let rect = NSRect(x: frame.minX + card.minX, y: frame.maxY - card.maxY, width: card.width, height: card.height)
        return rect.contains(NSEvent.mouseLocation)
    }

    private func scheduleFade(after delay: Double) {
        fadeTask?.cancel()
        fadeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            let defaults = UserDefaults.standard
            // An open popover (such as the date editor) is a child window: stay solid while it's up.
            let hasPopover = self.panel.childWindows?.contains(where: \.isVisible) ?? false
            let idle = defaults.bool(forKey: Pref.fadeWhenIdle) && !self.isMouseInsideCard && !self.panel.isKeyWindow && !hasPopover
            self.setAlpha(idle ? CGFloat(defaults.double(forKey: Pref.idleOpacity)) : 1, duration: 0.6)
        }
    }

    private func setAlpha(_ alpha: CGFloat, duration: Double) {
        guard abs(panel.alphaValue - alpha) > 0.01 else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            panel.animator().alphaValue = alpha
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        fadeTask?.cancel()
        setAlpha(1, duration: 0.15)
    }

    func windowDidResignKey(_ notification: Notification) {
        if !model.isHovering { scheduleFade(after: 1.2) }
    }

    // MARK: - Preferences

    @objc private func preferencesChanged() {
        applyPreferences()
        if !model.isHovering && !panel.isKeyWindow { scheduleFade(after: 0.1) }
    }

    private func applyPreferences() {
        let pinned = UserDefaults.standard.bool(forKey: Pref.pinned)
        let level: NSWindow.Level = pinned ? .floating : .normal
        if panel.level != level { panel.level = level }
    }
}

func withoutAnimation(_ body: () -> Void) {
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction, body)
}
