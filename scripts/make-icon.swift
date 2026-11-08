// Renders the app icon: Perch's task capsule as a glossy blue check button, with the next task
// waiting beneath it in a paler capsule, on a light tile.
// Usage: swift scripts/make-icon.swift [iconset-dir] [preview.png]
import AppKit

/// Drawn on a 1024 canvas with y pointing up, following the macOS icon grid (824pt body).
func drawIcon(in ctx: CGContext) {
    let tile = superellipse(in: CGRect(x: 100, y: 100, width: 824, height: 824), exponent: 5)
    // The capsule and the one below it sit centred as one group.
    let capsule = CGRect(x: 512 - 272, y: 384, width: 544, height: 324)

    // The shadow is cast by the finished tile as one layer, so its edge stays clean.
    ctx.layer(shadow: black(0.22), blur: 28, offset: CGSize(width: 0, height: -10)) {
        ctx.fillVertical(tile, [(0, rgb(1.0, 1.0, 1.0)), (1, rgb(0.91, 0.94, 1.0))])
        ctx.clipped(tile) {
            drawStack(in: ctx, below: capsule)
            drawCapsule(in: ctx, capsule)
        }
        ctx.innerShadow(tile, color: white(0.9), blur: 6, offset: CGSize(width: 0, height: -3))
    }
}

/// The next task: a paler, slightly narrower capsule peeking out below.
func drawStack(in ctx: CGContext, below capsule: CGRect) {
    let card = pill(CGRect(x: capsule.minX + 40, y: capsule.minY - 56, width: capsule.width - 80, height: capsule.height))
    ctx.fillVertical(card, [(0, rgb(0.76, 0.86, 1.0)), (1, rgb(0.72, 0.84, 1.0))])
    ctx.innerShadow(card, color: white(0.7), blur: 8, offset: CGSize(width: 0, height: -3))
}

/// The front capsule: blue fading to lavender at the bottom, a glassy lip and a white check.
func drawCapsule(in ctx: CGContext, _ r: CGRect) {
    let shape = pill(r)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 34, color: rgb(0.20, 0.40, 1.0, 0.35))
    ctx.addPath(shape)
    ctx.setFillColor(rgb(0.22, 0.52, 1.0))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.fillVertical(shape, [(0, rgb(0.32, 0.60, 1.0)), (0.58, rgb(0.20, 0.50, 1.0)), (1, rgb(0.64, 0.62, 1.0))])
    // Soft light pooled at the top, and a bright lip along the upper edge.
    ctx.fillRadial(shape, [(0, white(0.22)), (1, white(0))], center: CGPoint(x: r.midX, y: r.maxY), radius: r.height * 0.75)
    ctx.innerShadow(shape, color: white(0.55), blur: 10, offset: CGSize(width: 0, height: -4))

    let c = CGPoint(x: r.midX + 4, y: r.midY + 2)
    let tick = CGMutablePath()
    tick.move(to: CGPoint(x: c.x - 92, y: c.y + 4))
    tick.addLine(to: CGPoint(x: c.x - 30, y: c.y - 58))
    tick.addLine(to: CGPoint(x: c.x + 96, y: c.y + 68))
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: rgb(0.08, 0.20, 0.60, 0.30))
    ctx.addPath(tick)
    ctx.setStrokeColor(white(1))
    ctx.setLineWidth(46)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.strokePath()
    ctx.restoreGState()
}

// MARK: - Drawing helpers

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(colorSpace: srgb, components: [r, g, b, a])! }
func white(_ a: CGFloat) -> CGColor { rgb(1, 1, 1, a) }
func black(_ a: CGFloat) -> CGColor { rgb(0, 0, 0, a) }
func pill(_ r: CGRect) -> CGPath { CGPath(roundedRect: r, cornerWidth: r.height / 2, cornerHeight: r.height / 2, transform: nil) }
func circle(_ c: CGPoint, _ r: CGFloat) -> CGPath { CGPath(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r), transform: nil) }

extension CGContext {
    func clipped(_ path: CGPath, _ body: () -> Void) {
        saveGState(); addPath(path); clip(); body(); restoreGState()
    }

    /// Vertical gradient filling `path`; stops run from its top to its bottom unless given.
    func fillVertical(_ path: CGPath, _ stops: [(CGFloat, CGColor)], top: CGFloat? = nil, bottom: CGFloat? = nil) {
        let b = path.boundingBoxOfPath
        let gradient = CGGradient(colorsSpace: srgb, colors: stops.map(\.1) as CFArray, locations: stops.map(\.0))!
        clipped(path) {
            drawLinearGradient(gradient, start: CGPoint(x: b.midX, y: top ?? b.maxY), end: CGPoint(x: b.midX, y: bottom ?? b.minY),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
    }

    func fillRadial(_ path: CGPath, _ stops: [(CGFloat, CGColor)], center: CGPoint, radius: CGFloat) {
        let gradient = CGGradient(colorsSpace: srgb, colors: stops.map(\.1) as CFArray, locations: stops.map(\.0))!
        clipped(path) {
            drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius,
                               options: [.drawsAfterEndLocation])
        }
    }

    /// A glow cast inward from the shape's edge.
    func innerShadow(_ path: CGPath, color: CGColor, blur: CGFloat, offset: CGSize) {
        clipped(path) {
            setShadow(offset: offset, blur: blur, color: color)
            let ring = CGMutablePath()
            ring.addRect(path.boundingBoxOfPath.insetBy(dx: -400, dy: -400))
            ring.addPath(path)
            addPath(ring)
            setFillColor(black(1))
            fillPath(using: .evenOdd)
        }
    }

    /// A shadow cast only outside the shape, so a translucent fill on top stays clean.
    func outerShadow(_ path: CGPath, color: CGColor, blur: CGFloat, offset: CGSize) {
        saveGState()
        let outside = CGMutablePath()
        outside.addRect(path.boundingBoxOfPath.insetBy(dx: -400, dy: -400))
        outside.addPath(path)
        addPath(outside)
        clip(using: .evenOdd)
        setShadow(offset: offset, blur: blur, color: color)
        addPath(path)
        setFillColor(black(1))
        fillPath()
        restoreGState()
    }

    func layer(shadow color: CGColor, blur: CGFloat, offset: CGSize, _ body: () -> Void) {
        saveGState()
        setShadow(offset: offset, blur: blur, color: color)
        beginTransparencyLayer(auxiliaryInfo: nil)
        body()
        endTransparencyLayer()
        restoreGState()
    }
}

func superellipse(in rect: CGRect, exponent n: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    let c = CGPoint(x: rect.midX, y: rect.midY)
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let ct = cos(t), st = sin(t)
        let x = c.x + a * copysign(pow(abs(ct), 2 / n), ct)
        let y = c.y + b * copysign(pow(abs(st), 2 / n), st)
        i == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
    }
    path.closeSubpath()
    return path
}

func renderPNG(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    let ctx = context.cgContext
    ctx.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    ctx.setShouldAntialias(true)
    drawIcon(in: ctx)
    context.flushGraphics()
    return rep.representation(using: .png, properties: [:])!
}

let arguments = CommandLine.arguments
let iconset = URL(fileURLWithPath: arguments.count > 1 ? arguments[1] : "build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try renderPNG(pixels: base * scale).write(to: iconset.appendingPathComponent(name))
    }
}
if arguments.count > 2 {
    try renderPNG(pixels: 1024).write(to: URL(fileURLWithPath: arguments[2]))
}
