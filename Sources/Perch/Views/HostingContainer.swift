import AppKit

extension NSView {
    /// A plain view holding `hosting` edge to edge. As a window's content view, a hosting view
    /// still sizes the window to its SwiftUI content, animating along with it whatever its sizing
    /// options say; each step lays the window out again, and an unfolding panel could set off more
    /// layout passes than AppKit allows, which ends the app. One level down it just fills the window.
    static func container(for hosting: NSView) -> NSView {
        let container = NSView()
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        return container
    }
}
