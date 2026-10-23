// Renders the app icon: a small round bird perched on a branch.
// Usage: swift scripts/make-icon.swift [iconset-dir] [preview.png]
import AppKit

/// Drawn on a 1024 canvas with y pointing up, following the macOS icon grid (824pt body).
func drawIcon(in ctx: CGContext) {
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = superellipse(in: body, exponent: 5)

    // The shadow is cast by the finished tile as one layer, so its edge stays clean.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: NSColor.black.withAlphaComponent(0.28).cgColor)
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.addPath(squircle)
    ctx.clip()
    let sky = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [
        NSColor(srgbRed: 0.45, green: 0.70, blue: 1.00, alpha: 1).cgColor,
        NSColor(srgbRed: 0.20, green: 0.38, blue: 0.94, alpha: 1).cgColor,
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sky, start: CGPoint(x: 260, y: 924), end: CGPoint(x: 760, y: 100), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

    // Faint top sheen, like light on glass.
    let sheen = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [
        NSColor.white.withAlphaComponent(0.22).cgColor,
        NSColor.white.withAlphaComponent(0).cgColor,
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 560), options: [])

    let white = NSColor.white.cgColor
    let ink = NSColor(srgbRed: 0.12, green: 0.22, blue: 0.55, alpha: 1).cgColor

    // Branch.
    ctx.setStrokeColor(white.copy(alpha: 0.92)!)
    ctx.setLineWidth(38)
    ctx.setLineCap(.round)
    ctx.move(to: CGPoint(x: 236, y: 352))
    ctx.addLine(to: CGPoint(x: 788, y: 352))
    ctx.strokePath()

    // Everything below belongs to the bird, seated on the branch.
    ctx.translateBy(x: 0, y: -14)

    // Tail: a soft wedge behind the body.
    ctx.setFillColor(white)
    let tail = CGMutablePath()
    tail.move(to: CGPoint(x: 420, y: 470))
    tail.addQuadCurve(to: CGPoint(x: 268, y: 548), control: CGPoint(x: 330, y: 470))
    tail.addQuadCurve(to: CGPoint(x: 440, y: 600), control: CGPoint(x: 330, y: 610))
    tail.closeSubpath()
    ctx.addPath(tail)
    ctx.fillPath()

    // Body.
    let center = CGPoint(x: 548, y: 536)
    let radius: CGFloat = 162
    ctx.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))

    // Wing.
    ctx.saveGState()
    ctx.translateBy(x: 500, y: 500)
    ctx.rotate(by: -0.38)
    ctx.setFillColor(NSColor(srgbRed: 0.80, green: 0.88, blue: 1.0, alpha: 1).cgColor)
    ctx.fillEllipse(in: CGRect(x: -92, y: -46, width: 184, height: 92))
    ctx.restoreGState()

    // Beak.
    ctx.setFillColor(NSColor(srgbRed: 1.0, green: 0.70, blue: 0.20, alpha: 1).cgColor)
    let beak = CGMutablePath()
    beak.move(to: CGPoint(x: 700, y: 604))
    beak.addLine(to: CGPoint(x: 776, y: 580))
    beak.addLine(to: CGPoint(x: 696, y: 556))
    beak.closeSubpath()
    ctx.addPath(beak)
    ctx.fillPath()

    // Eye.
    ctx.setFillColor(ink)
    ctx.fillEllipse(in: CGRect(x: 612 - 21, y: 610 - 21, width: 42, height: 42))
    ctx.endTransparencyLayer()
    ctx.restoreGState()
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
