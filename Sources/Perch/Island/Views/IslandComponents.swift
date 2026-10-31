import AppKit
import SwiftUI

/// The current track's artwork; the playing app's icon when there is none.
struct ArtworkView: View {
    let size: CGFloat
    let cornerRadius: CGFloat
    @Environment(NowPlayingService.self) private var media
    @Environment(IslandModel.self) private var model

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            if let artwork = media.artwork {
                Image(nsImage: artwork)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            } else if let icon = media.sourceIcon {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(size * 0.06)
            } else {
                shape.fill(Color.white.opacity(0.1))
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        // A hairline keeps dark covers from melting into the black island.
        .overlay { shape.strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5) }
        // Paused, the cover steps back a little, as the bars settle into dots.
        .scaleEffect(media.isPlaying || media.track == nil ? 1 : 0.92)
        .brightness(media.isPlaying || media.track == nil ? 0 : -0.12)
        .animation(.spring(duration: 0.45, bounce: 0.25), value: media.isPlaying)
        .animation(.smooth(duration: 0.35), value: media.artwork)
        .offset(x: model.mediaNudge * size * 0.35)
        .rotation3DEffect(.degrees(model.mediaNudge * -18), axis: (x: 0, y: 1, z: 0))
    }
}

/// A little level meter that dances while something plays and settles into dots when paused: a few
/// solid, round-ended bars in a softened tone of the artwork, the middle ones reaching highest.
struct EqualizerBars: View {
    let isPlaying: Bool
    var tint: Color = .white
    var barCount = 4
    var barWidth: CGFloat = 2.6
    var spacing: CGFloat = 2.4
    var maxHeight: CGFloat = 14

    var body: some View {
        EqualizerLayers(isPlaying: isPlaying, color: NSColor(tint), barCount: barCount, barWidth: barWidth, spacing: spacing)
            .frame(width: CGFloat(barCount) * (barWidth + spacing) - spacing, height: maxHeight)
            .opacity(isPlaying ? 1 : 0.45)
            .animation(.smooth(duration: 0.4), value: isPlaying)
            .accessibilityHidden(true)
    }
}

/// The bars run as Core Animation keyframes, so the window server animates them while music plays
/// all day and Perch itself stays idle.
private struct EqualizerLayers: NSViewRepresentable {
    let isPlaying: Bool
    let color: NSColor
    let barCount: Int
    let barWidth: CGFloat
    let spacing: CGFloat

    func makeNSView(context: Context) -> EqualizerNSView {
        EqualizerNSView(barCount: barCount, barWidth: barWidth, spacing: spacing)
    }

    func updateNSView(_ view: EqualizerNSView, context: Context) {
        view.update(isPlaying: isPlaying, color: color)
    }
}

final class EqualizerNSView: NSView {
    private let bars: [CALayer]
    private let barWidth: CGFloat
    private var isPlaying = false
    private var color: NSColor?

    init(barCount: Int, barWidth: CGFloat, spacing: CGFloat) {
        self.barWidth = barWidth
        bars = (0..<barCount).map { _ in CALayer() }
        super.init(frame: .zero)
        wantsLayer = true
        for (index, bar) in bars.enumerated() {
            bar.cornerRadius = barWidth / 2
            bar.cornerCurve = .circular
            bar.frame = CGRect(x: CGFloat(index) * (barWidth + spacing), y: 0, width: barWidth, height: barWidth)
            layer?.addSublayer(bar)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for bar in bars {
            bar.position.y = bounds.midY
            if !isPlaying { bar.bounds.size.height = barWidth }
        }
        CATransaction.commit()
        // The dance is measured in points, so a new height needs it again.
        if isPlaying { startDancing() }
    }

    func update(isPlaying playing: Bool, color newColor: NSColor) {
        if newColor != color {
            color = newColor
            let tone = Self.tone(of: newColor).cgColor
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            bars.forEach { $0.backgroundColor = tone }
            CATransaction.commit()
        }
        guard playing != isPlaying else { return }
        isPlaying = playing
        if playing {
            startDancing()
        } else {
            // Freeze each bar where it is, then let it settle into a dot.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for bar in bars {
                if let current = bar.presentation()?.bounds { bar.bounds = current }
                bar.removeAnimation(forKey: "dance")
            }
            CATransaction.commit()
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.35)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
            bars.forEach { $0.bounds.size.height = barWidth }
            CATransaction.commit()
        }
    }

    /// The artwork's color, calmed: never so dark it sinks into the black island, never so
    /// saturated it shouts.
    private static func tone(of color: NSColor) -> NSColor {
        guard let rgb = color.usingColorSpace(.sRGB) else { return .white }
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        rgb.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return NSColor(hue: hue, saturation: min(saturation, 0.55), brightness: max(brightness, 0.92), alpha: 1)
    }

    private func startDancing() {
        guard bounds.height > 0 else { return }
        for (index, bar) in bars.enumerated() {
            bar.add(Self.dance(for: index, of: bars.count, height: bounds.height, floor: barWidth), forKey: "dance")
        }
    }

    /// Out-of-step loops of different lengths per bar read as music without listening to any; the
    /// middle bars reach highest, so the meter has a shape rather than a row of equal sticks. The
    /// height itself animates, not a stretch, so the bars keep their round ends.
    private static func dance(for index: Int, of count: Int, height: CGFloat, floor: CGFloat) -> CAKeyframeAnimation {
        let patterns: [[Double]] = [
            [0.30, 0.82, 0.45, 1.00, 0.35, 0.70, 0.50, 0.92, 0.30],
            [0.62, 0.28, 0.95, 0.48, 0.78, 0.32, 0.88, 0.55, 0.62],
            [0.45, 1.00, 0.38, 0.72, 0.96, 0.42, 0.66, 0.30, 0.45],
            [0.78, 0.40, 0.70, 0.30, 1.00, 0.55, 0.36, 0.86, 0.78],
            [0.40, 0.66, 0.30, 0.90, 0.50, 0.78, 0.34, 0.60, 0.40],
        ]
        let middle = Double(count - 1) / 2
        let reach = 1 - 0.3 * abs(Double(index) - middle) / max(middle, 1)
        let animation = CAKeyframeAnimation(keyPath: "bounds.size.height")
        animation.values = patterns[index % patterns.count].map { max(floor, height * $0 * reach) }
        animation.duration = 1.55 + Double((index * 7) % 5) * 0.21
        animation.timeOffset = Double(index) * 0.37
        animation.calculationMode = .cubic
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        return animation
    }
}

/// One line of text that scrolls when it doesn't fit, pausing at the start of each pass.
struct MarqueeText: View {
    let text: String
    let font: Font

    @State private var textWidth: CGFloat = 0
    @State private var startedAt = Date.now

    private static let gap: CGFloat = 36
    private static let speed: Double = 28
    private static let pause: Double = 2.4

    var body: some View {
        Text(text)
            .font(font)
            .lineLimit(1)
            .hidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    let overflows = textWidth > proxy.size.width + 1
                    TimelineView(.animation(minimumInterval: 1 / 30, paused: !overflows)) { context in
                        HStack(spacing: Self.gap) {
                            label
                            if overflows { label }
                        }
                        .offset(x: overflows ? -offset(at: context.date) : 0)
                    }
                    .frame(width: proxy.size.width, alignment: .leading)
                    .mask(fade(enabled: overflows))
                }
            }
            .background(label.hidden().onGeometryChange(for: CGFloat.self) { $0.size.width } action: { textWidth = $0 })
            .clipped()
            .onChange(of: text) { startedAt = .now }
    }

    private var label: some View {
        Text(text).font(font).lineLimit(1).fixedSize()
    }

    private func offset(at date: Date) -> CGFloat {
        let distance = Double(textWidth + Self.gap)
        let cycle = Self.pause + distance / Self.speed
        let t = date.timeIntervalSince(startedAt).truncatingRemainder(dividingBy: cycle)
        return t < Self.pause ? 0 : CGFloat((t - Self.pause) * Self.speed)
    }

    private func fade(enabled: Bool) -> some View {
        HStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                .frame(width: enabled ? 6 : 0)
            Rectangle()
            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: enabled ? 14 : 0)
        }
    }
}

// MARK: - Levels

struct LevelIcon: View {
    let hud: LevelHUD

    var body: some View {
        icon
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .contentTransition(.symbolEffect(.replace))
            .frame(width: 20)
    }

    private var icon: Image {
        switch hud.kind {
        case .volume:
            if hud.isSilent { return Image(systemName: "speaker.slash.fill") }
            if let route = hud.route, route.isPersonal { return Image(systemName: route.symbol) }
            return Image(systemName: "speaker.wave.3.fill", variableValue: hud.value)
        case .brightness:
            return Image(systemName: hud.value < 0.5 ? "sun.min.fill" : "sun.max.fill")
        case .keyboard:
            return Image(systemName: hud.value < 0.5 ? "light.min" : "light.max")
        }
    }
}

/// A slim level bar that thickens under the pointer and can be dragged to set the level, glowing in
/// the color at its tip. Sound is one color for the whole bar, green that turns amber and then red
/// as it gets loud. Brightness is a grey-to-white gradient uncovered up to the level, so a brighter
/// screen shows more white and glows more.
struct LevelBar: View {
    let hud: LevelHUD
    var onChange: ((Double) -> Void)?

    @AppStorage(Pref.hudColorful) private var colorful = true
    @State private var hovering = false
    @State private var dragging = false

    /// Colors at points along the level; between them the fill blends from one to the next.
    private var stops: [(at: Double, color: RGB)] {
        guard colorful else { return [(0, RGB(red: 1, green: 1, blue: 1))] }
        switch hud.kind {
        case .volume:
            // Three colors, each held over its stretch with only a step's blend between them, so the
            // whole bar changes at once: green up to ten steps of sixteen, amber to thirteen, then red.
            let green = RGB(red: 0.3, green: 0.86, blue: 0.5)
            let amber = RGB(red: 1, green: 0.76, blue: 0.26)
            let red = RGB(red: 1, green: 0.34, blue: 0.3)
            return [(0.63, green), (0.68, amber), (0.82, amber), (0.87, red)]
        case .brightness:
            return [(0, RGB(red: 0.36, green: 0.36, blue: 0.39)), (1, RGB(red: 1, green: 1, blue: 1))]
        case .keyboard:
            return [(0, RGB(red: 0.4, green: 0.45, blue: 0.58)), (1, RGB(red: 0.86, green: 0.9, blue: 1))]
        }
    }

    var body: some View {
        let value = hud.isSilent ? 0 : hud.value
        let thickness: CGFloat = hovering || dragging ? 7 : 5
        let color = Self.color(at: value, in: stops)
        let solid = hud.kind == .volume || !colorful
        // White light only glows as much as it's bright; color glows the same throughout.
        let glow = value > 0 ? (hud.kind == .volume || !colorful ? 1 : 0.35 + 0.65 * value) : 0
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.14))
                let filled = value > 0 ? max(width * value, thickness) : 0
                Group {
                    if solid {
                        Capsule().fill(color)
                    } else {
                        // Stretched across the whole track, so its grey end stays put and only the
                        // white end comes and goes with the level.
                        Capsule()
                            .fill(LinearGradient(colors: stops.map(\.color.color), startPoint: .leading, endPoint: .trailing))
                            .frame(width: width)
                            .frame(width: filled, alignment: .leading)
                            .clipShape(.capsule)
                    }
                }
                .frame(width: filled)
                .shadow(color: color.opacity(0.6 * glow), radius: 2)
                .shadow(color: color.opacity(0.4 * glow), radius: 7)
            }
            .frame(height: thickness)
            .frame(maxHeight: .infinity)
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        dragging = true
                        onChange?(min(max(drag.location.x / max(width, 1), 0), 1))
                    }
                    .onEnded { _ in dragging = false }
            )
        }
        .frame(height: 22)
        .onHover { hovering = $0 }
        .animation(dragging ? .smooth(duration: 0.2) : .snappy(duration: 0.25), value: value)
        .animation(.snappy(duration: 0.2), value: thickness)
        .accessibilityElement()
        .accessibilityValue("\(Int((value * 100).rounded()))%")
        .accessibilityAdjustableAction { direction in
            let step = direction == .increment ? 1.0 / 16 : -1.0 / 16
            onChange?(min(max(value + step, 0), 1))
        }
    }

    /// The fill's color at a level: the nearest stop's below the first and above the last, blended
    /// between neighbors round the color wheel, so green turns amber through clear yellows rather
    /// than through a muddy olive.
    static func color(at fraction: Double, in stops: [(at: Double, color: RGB)]) -> Color {
        guard let first = stops.first, let last = stops.last else { return .white }
        let x = min(max(fraction, 0), 1)
        if x <= first.at { return first.color.color }
        if x >= last.at { return last.color.color }
        let upper = stops.firstIndex { $0.at >= x } ?? stops.count - 1
        let a = stops[upper - 1], b = stops[upper]
        let t = (x - a.at) / max(b.at - a.at, 0.0001)
        let from = a.color.hsb, to = b.color.hsb
        var hueStep = to.hue - from.hue
        if abs(hueStep) > 0.5 { hueStep -= hueStep.sign == .minus ? -1 : 1 }
        let hue = (from.hue + hueStep * t).truncatingRemainder(dividingBy: 1)
        return Color(hue: hue < 0 ? hue + 1 : hue, saturation: from.saturation + (to.saturation - from.saturation) * t,
                     brightness: from.brightness + (to.brightness - from.brightness) * t)
    }
}

extension RGB {
    var color: Color { Color(.sRGB, red: red, green: green, blue: blue) }
}

// MARK: - Batteries

/// A battery outline filled to its level, with a bolt while charging. Fills up when it appears.
struct BatteryGlyph: View {
    let level: Int
    var isCharging = false
    var tint: Color = .white

    @State private var shown = false

    var body: some View {
        GeometryReader { proxy in
            let height = proxy.size.height
            let nub = max(height * 0.13, 1.5)
            let bodyWidth = proxy.size.width - nub - 1
            HStack(spacing: 1) {
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: height * 0.3, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.4), lineWidth: 1)
                    RoundedRectangle(cornerRadius: height * 0.18, style: .continuous)
                        .fill(tint)
                        .frame(width: max((bodyWidth - 4) * CGFloat(shown ? level : 0) / 100, 1.5))
                        .padding(2)
                    if isCharging {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: height * 0.62, weight: .heavy))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.6), radius: 1)
                            .frame(maxWidth: .infinity)
                    }
                }
                .frame(width: bodyWidth)
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.white.opacity(0.4))
                    .frame(width: nub, height: height * 0.36)
            }
        }
        .onAppear {
            withAnimation(.smooth(duration: 0.8).delay(0.15)) { shown = true }
        }
        .accessibilityElement()
        .accessibilityLabel(tr("电量 \(level)%", "Battery \(level)%"))
    }
}

/// A small ring gauge for a Bluetooth device's battery.
struct BatteryRing: View {
    let level: Int
    var size: CGFloat = 15
    var lineWidth: CGFloat = 2.5

    @State private var shown = false

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.16), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: shown ? CGFloat(level) / 100 : 0)
                .stroke(level <= 20 ? Color.red : Color.green, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
        .onAppear {
            withAnimation(.smooth(duration: 0.8).delay(0.2)) { shown = true }
        }
    }
}

extension BatteryState {
    var tint: Color {
        if isPluggedIn { return .green }
        if level <= 20 { return .red }
        return ProcessInfo.processInfo.isLowPowerModeEnabled ? .yellow : .white
    }
}

/// A round transport button that lights up under the pointer and dips when pressed.
struct IslandButton: View {
    let symbol: String
    var size: CGFloat = 15
    let label: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: size * 2, height: size * 2)
                .background(Circle().fill(Color.white.opacity(hovering ? 0.12 : 0)))
                .contentShape(.circle)
        }
        .buttonStyle(PressScaleStyle())
        .foregroundStyle(.white)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .accessibilityLabel(label)
    }
}

struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.86 : 1)
            .animation(.spring(duration: 0.25, bounce: 0.4), value: configuration.isPressed)
    }
}
