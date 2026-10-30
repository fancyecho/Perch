import AppKit
import SwiftUI

/// A transparent, click-through window over the notch, above the menu bar on every Space.
///
/// It is a FloatingPanel so the task list it can grow into gets the same keyboard handling (Esc,
/// the editing shortcuts) as the floating panel; it only takes the keyboard while that list is open.
final class IslandPanel: FloatingPanel {
    var acceptsKey = false

    override init() {
        super.init()
        styleMask.remove(.fullSizeContentView)
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isMovable = false
        ignoresMouseEvents = true
        acceptsMouseMovedEvents = true
    }

    override var canBecomeKey: Bool { acceptsKey }

    /// The island belongs over the menu bar, where AppKit would otherwise refuse to put a window.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// Lets a click on the island act right away instead of first "activating" the window.
final class IslandHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
