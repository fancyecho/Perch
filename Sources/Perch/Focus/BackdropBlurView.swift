import AppKit
import QuartzCore

/// A real, animatable Gaussian blur of whatever is behind the window, done with CABackdropLayer (what
/// the system's own materials use underneath): the radius deepens from zero instead of a frosted
/// sheet fading in. Without the private class it falls back to fading in an NSVisualEffectView.
final class BackdropBlurView: NSView {
    private static let blurRadius: CGFloat = 42
    private static let saturation: CGFloat = 1.5
    private static let tintOpacity: Float = 0.3

    private var backdrop: CALayer?
    private var fallback: NSVisualEffectView?
    private let tint = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        autoresizingMask = [.width, .height]

        if let backdrop = Self.makeBackdropLayer() {
            backdrop.frame = bounds
            backdrop.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            layer?.addSublayer(backdrop)
            self.backdrop = backdrop
        } else {
            let effect = NSVisualEffectView(frame: bounds)
            effect.autoresizingMask = [.width, .height]
            effect.material = .fullScreenUI
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.alphaValue = 0
            addSubview(effect)
            fallback = effect
        }

        // A dark wash keeps white text readable over bright wallpapers and white windows.
        tint.frame = bounds
        tint.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        tint.backgroundColor = NSColor.black.cgColor
        tint.opacity = 0
        layer?.addSublayer(tint)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setBlurred(_ blurred: Bool, duration: TimeInterval) {
        setBlur(blurred ? 1 : 0, duration: duration, timing: CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1))
    }

    /// 0 is clear, 1 fully blurred; holding or typing uses the values between, so the blur lifts as
    /// they progress.
    func setBlur(_ amount: CGFloat, duration: TimeInterval, timing: CAMediaTimingFunction = CAMediaTimingFunction(name: .easeOut)) {
        if let backdrop {
            animate(backdrop, "filters.gaussianBlur.inputRadius", to: Self.blurRadius * amount, duration, timing)
            animate(backdrop, "filters.colorSaturate.inputAmount", to: 1 + (Self.saturation - 1) * amount, duration, timing)
        } else if let fallback {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.timingFunction = timing
                fallback.animator().alphaValue = amount
            }
        }
        animate(tint, "opacity", to: CGFloat(Self.tintOpacity) * amount, duration, timing)
    }

    private func animate(_ layer: CALayer, _ keyPath: String, to value: CGFloat, _ duration: TimeInterval, _ timing: CAMediaTimingFunction) {
        let from = layer.presentation()?.value(forKeyPath: keyPath) ?? layer.value(forKeyPath: keyPath)
        layer.setValue(value, forKeyPath: keyPath)
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = value
        animation.duration = duration
        animation.timingFunction = timing
        layer.add(animation, forKey: keyPath)
    }

    private static func makeBackdropLayer() -> CALayer? {
        guard let layerClass = NSClassFromString("CABackdropLayer") as? CALayer.Type,
              let blur = makeFilter("gaussianBlur"),
              let saturate = makeFilter("colorSaturate") else { return nil }
        blur.setValue(0, forKey: "inputRadius")
        blur.setValue(true, forKey: "inputNormalizeEdges")
        saturate.setValue(1, forKey: "inputAmount")

        let layer = layerClass.init()
        layer.setValue(true, forKey: "windowServerAware")
        layer.filters = [blur, saturate]
        return layer
    }

    private static func makeFilter(_ type: String) -> NSObject? {
        guard let filterClass = NSClassFromString("CAFilter") as? NSObject.Type else { return nil }
        let selector = NSSelectorFromString("filterWithType:")
        guard filterClass.responds(to: selector),
              let filter = filterClass.perform(selector, with: type)?.takeUnretainedValue() as? NSObject
        else { return nil }
        filter.setValue(type, forKey: "name")
        return filter
    }
}

/// Borderless windows can't take the keyboard by default; the blur needs it for the unlock phrase.
final class CurtainWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
