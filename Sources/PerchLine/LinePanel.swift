import AppKit

/// A transparent strip along the top of the screen that floats over every
/// app and every Space except full screen ones, never takes focus, and lets clicks pass through
/// everywhere except over the photos.
final class LinePanel: NSPanel {
    init(content: NSView) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        // Every Space, full screen ones included. Whether the line comes down
        // over a full screen app is up to the user, see FullScreen.showLineOver.
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isMovable = false
        becomesKeyOnlyIfNeeded = true
        ignoresMouseEvents = true
        contentView = content
    }

    /// Two-finger swipes and the scroll wheel, for moving along a long line.
    var onScroll: ((NSEvent) -> Void)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .scrollWheel, let onScroll {
            onScroll(event)
        } else {
            super.sendEvent(event)
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// The line hangs on the screen you are using, which is the one with the
    /// pointer: that is where you just took the screenshot.
    static func screenUnderPointer() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens.first
    }

    func placeOnScreen(_ screen: NSScreen? = nil) {
        guard let visible = (screen ?? LinePanel.screenUnderPointer())?.visibleFrame else { return }
        let target = NSRect(x: visible.minX, y: visible.maxY - Layout.panelHeight,
                            width: visible.width, height: Layout.panelHeight)
        if frame != target { setFrame(target, display: true) }
    }
}

/// Holds the line's view and takes one kind of drop: a photo dragged off one line onto the other,
/// which moves it there, file and all. Everything else is left to whatever is underneath.
final class LineDropView: NSView {
    /// The line a photo dragged to this point (in window coordinates) would move to, if any.
    var target: (NSPoint) -> LineSide? = { _ in nil }
    var onHover: (LineSide?) -> Void = { _ in }
    /// Dropped on the other line, at this point on the screen.
    var onDrop: (LineSide, NSPoint) -> Bool = { _, _ in false }

    init(content: NSView) {
        super.init(frame: .zero)
        content.autoresizingMask = [.width, .height]
        addSubview(content)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        subviews.first?.frame = bounds
    }

    private func update(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingSource is GrabView, let side = target(sender.draggingLocation) else {
            onHover(nil)
            return []
        }
        onHover(side)
        return .move
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { update(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { update(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { onHover(nil) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { onHover(nil) }
        guard sender.draggingSource is GrabView, let side = target(sender.draggingLocation),
              let window else { return false }
        return onDrop(side, window.convertPoint(toScreen: sender.draggingLocation))
    }
}
