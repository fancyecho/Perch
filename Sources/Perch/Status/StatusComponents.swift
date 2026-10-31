import SwiftUI

enum Palette {
    static let cpu = Color(red: 0.38, green: 0.56, blue: 1.00)
    static let memory = Color(red: 0.66, green: 0.48, blue: 1.00)
    static let gpu = Color(red: 0.20, green: 0.78, blue: 0.72)
    static let disk = Color(red: 1.00, green: 0.62, blue: 0.28)
    static let down = Color(red: 0.25, green: 0.70, blue: 1.00)
    static let up = Color(red: 1.00, green: 0.42, blue: 0.58)
    static let battery = Color(red: 0.30, green: 0.82, blue: 0.45)

    static func level(_ percent: Double) -> Color {
        percent >= 90 ? Color(red: 1, green: 0.36, blue: 0.36) : percent >= 70 ? Color(red: 1, green: 0.72, blue: 0.2) : .clear
    }
}

// MARK: - Text

/// Secondary text colors. SwiftUI's .secondary/.tertiary use vibrancy in frosted windows and blur into the
/// background; fixed opacities instead, tuned for contrast in light and dark.
enum Ink {
    static let secondary = dynamic(dark: 0.76, light: 0.68)
    static let tertiary = dynamic(dark: 0.58, light: 0.52)

    private static func dynamic(dark: CGFloat, light: CGFloat) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(white: 1, alpha: dark)
                : NSColor(white: 0, alpha: light)
        })
    }
}

// MARK: - Card

/// A frosted card: a translucent light layer with a brighter hairline at the top, over the panel's glass.
struct CardBackground: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
        let dark = scheme == .dark
        content
            .background { shape.fill(Color.white.opacity(dark ? 0.065 : 0.5)) }
            .overlay {
                shape.strokeBorder(
                    LinearGradient(colors: [.white.opacity(dark ? 0.16 : 0.9), .white.opacity(dark ? 0.03 : 0.35)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 0.7)
            }
            // In light mode the white highlight vanishes on light backgrounds, so a faint dark hairline outlines the card.
            .overlay {
                if !dark { shape.strokeBorder(Color.black.opacity(0.07), lineWidth: 0.5) }
            }
            .shadow(color: .black.opacity(dark ? 0.16 : 0.07), radius: dark ? 3 : 4, y: 1)
    }
}

extension View {
    func card() -> some View { modifier(CardBackground()) }
}

struct Tile<Accessory: View, Content: View>: View {
    let title: String
    let symbol: String
    let tint: Color
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(Typeface.ui(10, .bold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(Typeface.ui(11, .medium))
                    .foregroundStyle(Ink.secondary)
                Spacer(minLength: 0)
                accessory
                    .font(Typeface.ui(10.5, .medium))
                    .foregroundStyle(Ink.tertiary)
            }
            .frame(height: 15)   // The same height whether or not there's something in the corner.
            content
        }
        .padding(11)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card()
    }
}

extension Tile where Accessory == EmptyView {
    init(title: String, symbol: String, tint: Color, @ViewBuilder content: () -> Content) {
        self.init(title: title, symbol: symbol, tint: tint, accessory: { EmptyView() }, content: content)
    }
}

// MARK: - Numbers

/// Words in SF Pro, figures in SF Pro Rounded, as everywhere else in Perch.
enum Typeface {
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    static func number(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    static func tracking(_ size: CGFloat) -> CGFloat {
        size >= 18 ? -size * 0.01 : 0
    }
}

struct BigNumber: View {
    let value: String
    let unit: String
    var size: CGFloat = 24

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(value)
                .font(Typeface.number(size))
                .tracking(Typeface.tracking(size))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(unit)
                .font(Typeface.ui(size * 0.5, .medium))
                .foregroundStyle(Ink.secondary)
        }
        .animation(.snappy(duration: 0.35), value: value)
    }
}

/// One “label …… value” line with a dot or small symbol on the left. Single line and tabular figures, so changing values never change its height.
struct Legend: View {
    let color: Color
    let label: String
    let value: String
    var symbol: String? = nil

    var body: some View {
        HStack(spacing: 5) {
            if let symbol {
                Image(systemName: symbol)
                    .font(Typeface.ui(8.5, .heavy))
                    .foregroundStyle(color)
                    .frame(width: 8)
            } else {
                Circle().fill(color).frame(width: 6, height: 6)
            }
            Text(label).foregroundStyle(Ink.secondary)
            Spacer(minLength: 4)
            Text(value).monospacedDigit()
        }
        .font(Typeface.ui(11))
        .lineLimit(1)
    }
}

// MARK: - Bars

struct MeterBar: View {
    let fraction: Double
    let tint: Color
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(LinearGradient(colors: [tint.opacity(0.75), tint], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(height, geo.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: height)
        .animation(.easeOut(duration: 0.4), value: fraction)
    }
}

struct SegmentBar: View {
    let segments: [(value: Double, color: Color)]
    let total: Double
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 1.5) {
                ForEach(segments.indices, id: \.self) { i in
                    Rectangle()
                        .fill(segments[i].color)
                        .frame(width: max(0, geo.size.width * segments[i].value / max(total, 1) - 1.5))
                }
                Spacer(minLength: 0)
            }
            .background(Color.primary.opacity(0.08))
            .clipShape(Capsule())
        }
        .frame(height: height)
        .animation(.easeOut(duration: 0.4), value: segments.map(\.value))
    }
}

struct CoreBars: View {
    let cores: [Double]
    let tint: Color

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(cores.indices, id: \.self) { i in
                GeometryReader { geo in
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 1.5).fill(Color.primary.opacity(0.08))
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(tint.opacity(0.4 + 0.6 * cores[i] / 100))
                            .frame(height: max(1.5, geo.size.height * min(cores[i], 100) / 100))
                    }
                }
                .hint(tr("核心 \(i + 1)：", "Core \(i + 1): ") + "\(Int(cores[i].rounded()))%")
            }
        }
        .animation(.easeOut(duration: 0.4), value: cores)
    }
}

// MARK: - Charts

private func chartPoints(_ values: [Double], capacity: Int, maxValue: Double, in size: CGSize, inset: CGFloat) -> [CGPoint] {
    guard values.count > 1 else { return [] }
    let step = size.width / CGFloat(max(capacity - 1, 1))
    let startX = size.width - CGFloat(values.count - 1) * step
    let usable = size.height - inset
    return values.enumerated().map { i, v in
        CGPoint(x: startX + CGFloat(i) * step,
                y: size.height - usable * CGFloat(min(max(v / maxValue, 0), 1)))
    }
}

private func smoothLine(_ points: [CGPoint]) -> Path {
    var path = Path()
    guard let first = points.first else { return path }
    path.move(to: first)
    for i in 1..<points.count {
        let prev = points[i - 1], cur = points[i]
        let mid = CGPoint(x: (prev.x + cur.x) / 2, y: (prev.y + cur.y) / 2)
        path.addQuadCurve(to: mid, control: prev)
    }
    path.addLine(to: points[points.count - 1])
    return path
}

private func closedArea(_ line: Path, points: [CGPoint], bottom: CGFloat) -> Path {
    var area = line
    area.addLine(to: CGPoint(x: points[points.count - 1].x, y: bottom))
    area.addLine(to: CGPoint(x: points[0].x, y: bottom))
    area.closeSubpath()
    return area
}

struct Sparkline: View {
    let values: [Double]
    var maxValue: Double? = nil
    let tint: Color
    var capacity = SystemMonitor.historyLength
    /// What to show under the pointer; nil doesn't respond to hovering.
    var readout: ChartReadout? = nil

    var body: some View {
        GeometryReader { geo in
            let top = max(maxValue ?? (values.max() ?? 1), 0.0001)
            let points = chartPoints(values, capacity: capacity, maxValue: top, in: geo.size, inset: 1.5)
            if points.count > 1 {
                let line = smoothLine(points)
                let area = closedArea(line, points: points, bottom: geo.size.height)
                ZStack {
                    area.fill(LinearGradient(colors: [tint.opacity(0.32), tint.opacity(0.0)], startPoint: .top, endPoint: .bottom))
                    line.stroke(tint, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                }
            } else {
                Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 1).frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
        .overlay {
            if let readout {
                ChartScrubber(count: values.count, capacity: capacity, readout: readout) { index, size in
                    let top = max(maxValue ?? (values.max() ?? 1), 0.0001)
                    let points = chartPoints(values, capacity: capacity, maxValue: top, in: size, inset: 1.5)
                    return points.indices.contains(index) ? [(points[index], tint)] : []
                }
            }
        }
    }
}

/// Download above the midline, upload below.
struct MirrorChart: View {
    let top: [Double]
    let bottom: [Double]
    let topTint: Color
    let bottomTint: Color
    var readout: ChartReadout? = nil

    var body: some View {
        GeometryReader { geo in
            let half = CGSize(width: geo.size.width, height: geo.size.height / 2)
            let peak = max(top.max() ?? 0, bottom.max() ?? 0, 10_000)
            VStack(spacing: 0) {
                Sparkline(values: top, maxValue: peak, tint: topTint)
                    .frame(height: half.height)
                Sparkline(values: bottom, maxValue: peak, tint: bottomTint)
                    .frame(height: half.height)
                    .scaleEffect(x: 1, y: -1)
            }
            .overlay { Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 0.5) }
        }
        .overlay {
            if let readout {
                ChartScrubber(count: top.count, capacity: SystemMonitor.historyLength, readout: readout) { index, size in
                    let half = CGSize(width: size.width, height: size.height / 2)
                    let peak = max(top.max() ?? 0, bottom.max() ?? 0, 10_000)
                    let up = chartPoints(top, capacity: SystemMonitor.historyLength, maxValue: peak, in: half, inset: 1.5)
                    let down = chartPoints(bottom, capacity: SystemMonitor.historyLength, maxValue: peak, in: half, inset: 1.5)
                    var markers: [(CGPoint, Color)] = []
                    if up.indices.contains(index) { markers.append((up[index], topTint)) }
                    // The bottom half is drawn flipped; map back to the whole chart's coordinates.
                    if down.indices.contains(index) {
                        markers.append((CGPoint(x: down[index].x, y: size.height - down[index].y), bottomTint))
                    }
                    return markers
                }
            }
        }
    }
}

// MARK: - Chart hover

/// A chart's hover readout: seconds between points, and the text for a point.
struct ChartReadout {
    let interval: Double
    let text: (Int) -> String
}

final class HoverLocation: ObservableObject {
    @Published var x: CGFloat?
}

/// The hover readout's small card: value and time, in the light card style of the panel.
struct ReadoutBubble: View {
    let value: String
    let detail: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        HStack(spacing: 5) {
            Text(value)
                .font(Typeface.ui(10.5, .semibold))
                .foregroundStyle(.primary)
            Text(detail)
                .font(Typeface.ui(10, .medium))
                .foregroundStyle(Ink.secondary)
        }
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background {
            shape.fill(scheme == .dark ? Color(white: 0.2).opacity(0.94) : Color.white.opacity(0.96))
                .overlay { shape.strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.5) }
                .shadow(color: .black.opacity(scheme == .dark ? 0.35 : 0.12), radius: 5, y: 2)
        }
    }
}

/// The data point marked under the pointer: a small dot with a soft halo.
struct ReadoutDot: View {
    let tint: Color

    var body: some View {
        ZStack {
            Circle().fill(tint.opacity(0.22)).frame(width: 13, height: 13)
            Circle().fill(tint).frame(width: 6.5, height: 6.5)
                .overlay { Circle().strokeBorder(.white, lineWidth: 1.3) }
        }
    }
}

/// A vertical guide line, fading out at both ends.
struct ReadoutGuide: View {
    var body: some View {
        LinearGradient(colors: [.primary.opacity(0), .primary.opacity(0.3), .primary.opacity(0.05)],
                       startPoint: .top, endPoint: .bottom)
            .frame(width: 1)
    }
}

/// “8 s ago”, “now”, “2 min 10 s ago”
func agoText(seconds: Int) -> String {
    seconds <= 0 ? tr("现在", "now") : seconds < 60 ? tr("\(seconds) 秒前", "\(seconds)s ago")
        : tr("\(seconds / 60) 分 \(seconds % 60) 秒前", "\(seconds / 60)m \(seconds % 60)s ago")
}

/// Moving over a chart marks the nearest point with a guide line and a dot, with the reading and “how long ago” on top.
/// The marks ignore the mouse, or touching them would count as leaving the chart and the readout would flicker.
private struct ChartScrubber: View {
    let count: Int
    let capacity: Int
    let readout: ChartReadout
    let markers: (Int, CGSize) -> [(CGPoint, Color)]
    @StateObject private var hover = HoverLocation()

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let index = hover.x.flatMap { index(at: $0, width: size.width) }
            ZStack(alignment: .topLeading) {
                Color.clear
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let point): hover.x = point.x
                        case .ended: hover.x = nil
                        }
                    }
                if let index {
                    let markerX = position(of: index, width: size.width)
                    Group {
                        ReadoutGuide()
                            .frame(height: size.height)
                            .offset(x: markerX - 0.5)
                        ForEach(Array(markers(index, size).enumerated()), id: \.offset) { _, marker in
                            ReadoutDot(tint: marker.1)
                                .offset(x: marker.0.x - 6.5, y: marker.0.y - 6.5)
                        }
                        ReadoutBubble(value: readout.text(index),
                                      detail: agoText(seconds: Int((Double(count - 1 - index) * readout.interval).rounded())))
                            // Centered on the guide line, but kept inside the chart.
                            .alignmentGuide(.leading) { d in -min(max(markerX - d.width / 2, 0), size.width - d.width) }
                            .offset(y: -4)
                    }
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }
            }
            // Glides between points instead of jumping from one to the next.
            .animation(.interactiveSpring(response: 0.2, dampingFraction: 0.9), value: index)
            .animation(.easeOut(duration: 0.12), value: index == nil)
        }
    }

    /// Data is right-aligned (newest at the right edge), as chartPoints lays it out.
    private func position(of index: Int, width: CGFloat) -> CGFloat {
        let step = width / CGFloat(max(capacity - 1, 1))
        return width - CGFloat(count - 1 - index) * step
    }

    private func index(at x: CGFloat, width: CGFloat) -> Int? {
        guard count > 1 else { return nil }
        let step = width / CGFloat(max(capacity - 1, 1))
        let fromRight = Int(((width - x) / step).rounded())
        let index = count - 1 - fromRight
        return index >= 0 ? min(index, count - 1) : nil
    }
}

// MARK: - Hover hints

/// Custom hover hints. The panel belongs to a background app whose window doesn't activate, so the system's .help bubbles never show; these are drawn instead.
/// They go where the pointer really is on screen (under it, like the system's), converted into the hint layer when shown.
/// Not SwiftUI layout coordinates: elements are often mid-unfold, mid-page or mid-scroll, so measured positions go stale or convert wrong and the hint lands off.
@MainActor
final class HintCenter: ObservableObject {
    struct Hint: Equatable {
        let id: UUID
        let text: String
        /// Screen coordinates (origin bottom left)
        let screenPoint: CGPoint
    }
    @Published private(set) var hint: Hint?
    private var pending: DispatchWorkItem?

    /// The pointer moves over an element with a hint: it shows after the pointer settles; an open hint switches straight over.
    func track(id: UUID, text: String) {
        if hint?.id == id { return }
        pending?.cancel()
        let next = Hint(id: id, text: text, screenPoint: NSEvent.mouseLocation)
        if hint != nil {
            hint = next
            return
        }
        // Use where the pointer settled.
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.hint = Hint(id: id, text: text, screenPoint: NSEvent.mouseLocation) }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func end(id: UUID) {
        pending?.cancel()
        if hint?.id == id { hint = nil }
    }

    func dismiss() {
        pending?.cancel()
        hint = nil
    }
}

private struct HintCenterKey: EnvironmentKey {
    static let defaultValue: HintCenter? = nil
}

extension EnvironmentValues {
    var hintCenter: HintCenter? {
        get { self[HintCenterKey.self] }
        set { self[HintCenterKey.self] = newValue }
    }
}

final class HintAnchor: ObservableObject {
    let id = UUID()
}

private struct HintModifier: ViewModifier {
    let text: String
    @Environment(\.hintCenter) private var center
    @StateObject private var anchor = HintAnchor()

    func body(content: Content) -> some View {
        if let center, !text.isEmpty {
            content
                .onContinuousHover { phase in
                    switch phase {
                    case .active: center.track(id: anchor.id, text: text)
                    case .ended: center.end(id: anchor.id)
                    }
                }
        } else {
            content
        }
    }
}

extension View {
    /// A note shown after hovering a moment (instead of .help).
    func hint(_ text: String) -> some View { modifier(HintModifier(text: text)) }
}

/// Draws the current hint at the panel's root: below right of the pointer, above it if there's no room, never past the panel's sides.
struct HintOverlay: View {
    @ObservedObject var center: HintCenter

    var body: some View {
        GeometryReader { geo in
            let hint = center.hint
            let point = hint.flatMap { Self.localPoint($0.screenPoint, overlay: geo.frame(in: .global)) }
            HintPlacement(point: point ?? .zero) {
                if let hint, point != nil {
                    HintBubble(text: hint.text)
                        .id(hint.id)
                        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .topLeading)))
                }
            }
        }
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.14), value: center.hint)
    }

    /// Screen → hint layer: into the panel window first (SwiftUI's global space is the window content, origin top left), then minus the layer's position.
    private static func localPoint(_ screen: CGPoint, overlay: CGRect) -> CGPoint? {
        guard let window = NSApp.windows.first(where: { $0 is StatusPanel }), let content = window.contentView else { return nil }
        let inWindow = window.convertPoint(fromScreen: screen)
        return CGPoint(x: inWindow.x - overlay.minX, y: content.bounds.height - inWindow.y - overlay.minY)
    }
}

/// Measures the bubble at up to 250 wide first (the text wraps), then places it.
/// Not .frame(maxWidth:): a flexible frame fills all 250, and the right edge computed from it pushes the hint left.
private struct HintPlacement: Layout {
    let point: CGPoint

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let bubble = subviews.first else { return }
        let size = bubble.sizeThatFits(ProposedViewSize(width: min(250, bounds.width - 16), height: nil))
        let x = min(max(point.x - 14, 8), bounds.width - size.width - 8)
        let below = point.y + 20
        let y = below + size.height <= bounds.height - 6 ? below : point.y - size.height - 10
        bubble.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y), proposal: ProposedViewSize(size))
    }
}

/// The hint card: frosted, with a hairline and a soft shadow, the same language as the panel's cards.
/// In a hint of several lines the first is the title (primary color), the rest explain (secondary).
struct HintBubble: View {
    let text: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        let lines = text.split(separator: "\n", maxSplits: 1).map(String.init)
        VStack(alignment: .leading, spacing: 3) {
            Text(lines[0])
                .font(Typeface.ui(11, lines.count > 1 ? .medium : .regular))
                .foregroundStyle(.primary)
            if lines.count > 1 {
                Text(lines[1])
                    .font(Typeface.ui(10.5))
                    .foregroundStyle(Ink.secondary)
            }
        }
        .lineSpacing(1.5)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background {
            shape.fill(.thickMaterial)
                .overlay { shape.fill(scheme == .dark ? Color.white.opacity(0.04) : Color.white.opacity(0.35)) }
                .overlay { shape.strokeBorder(Color.primary.opacity(scheme == .dark ? 0.14 : 0.1), lineWidth: 0.5) }
                .shadow(color: .black.opacity(scheme == .dark ? 0.3 : 0.1), radius: 10, y: 4)
        }
    }
}

// MARK: - Scrolling

@MainActor
// MARK: - Buttons

/// A segmented choice: a light track with the selection sliding between options; unselected options brighten under the pointer.
struct GlassSegmentedControl<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(Value, String)]
    var height: CGFloat = 20
    /// Each option in its own font (a font picker, say); nil uses the interface font.
    var labelFont: ((Value) -> Font)?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var thumb

    init(_ title: String, selection: Binding<Value>, options: [(Value, String)], height: CGFloat = 20,
         labelFont: ((Value) -> Font)? = nil) {
        self.title = title
        self._selection = selection
        self.options = options
        self.height = height
        self.labelFont = labelFont
    }

    var body: some View {
        let track = RoundedRectangle(cornerRadius: height / 2 - 1, style: .continuous)
        HStack(spacing: 0) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                SegmentButton(title: option.1, selected: selection == option.0, height: height,
                              font: labelFont?(option.0), thumb: thumb, reduceMotion: reduceMotion) {
                    selection = option.0
                }
            }
        }
        .padding(1.5)
        .background {
            track.fill(Color.primary.opacity(scheme == .dark ? 0.08 : 0.055))
                .overlay { track.strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5) }
        }
        .fixedSize()
        .animation(reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.3, dampingFraction: 0.8), value: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

private struct SegmentButton: View {
    let title: String
    let selected: Bool
    let height: CGFloat
    let font: Font?
    let thumb: Namespace.ID
    let reduceMotion: Bool
    let action: () -> Void
    @StateObject private var hover = HoverState()
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: height / 2 - 2.5, style: .continuous)
        Button(action: action) {
            Text(title)
                .font(font ?? Typeface.ui(height <= 18 ? 10.5 : 11, selected ? .semibold : .medium))
                .foregroundStyle(selected || hover.hovering ? Color.primary : Ink.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .padding(.horizontal, height <= 18 ? 8 : 9)
                .frame(height: height - 3)
                .fixedSize()
                .background {
                    if selected {
                        shape.fill(scheme == .dark ? Color.white.opacity(0.17) : Color.white)
                            .overlay { shape.strokeBorder(Color.primary.opacity(scheme == .dark ? 0.06 : 0.04), lineWidth: 0.5) }
                            .shadow(color: .black.opacity(scheme == .dark ? 0.25 : 0.1), radius: 1.5, y: 0.5)
                            .matchedGeometryEffect(id: "thumb", in: thumb)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(SoftPressStyle())
        .onHover { hover.hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hover.hovering)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Shrinks a little when pressed and springs back.
struct SubtleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverHighlight(pressed: configuration.isPressed) { configuration.label }
    }
}

/// Hover state lives in a StateObject, as it did in the standalone Status (its SDK lacked the @State macro plugin).
final class HoverState: ObservableObject {
    @Published var hovering = false
}

private struct HoverHighlight<Label: View>: View {
    let pressed: Bool
    @ViewBuilder var label: Label
    @StateObject private var state = HoverState()

    var body: some View {
        label
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(pressed ? 0.14 : state.hovering ? 0.08 : 0))
            }
            .contentShape(Rectangle())
            .onHover { state.hovering = $0 }
    }
}

private struct CardHoveredKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// The clickable card around this is under the pointer.
    var cardHovered: Bool {
        get { self[CardHoveredKey.self] }
        set { self[CardHoveredKey.self] = newValue }
    }
}

/// The small arrow on a clickable card: it nudges right while the card is hovered, to say it opens.
struct DisclosureChevron: View {
    var size: CGFloat = 10
    @Environment(\.cardHovered) private var hovered
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: "chevron.right")
            .font(Typeface.ui(size, .semibold))
            .foregroundStyle(hovered ? Ink.secondary : Ink.tertiary)
            .offset(x: hovered && !reduceMotion ? 2.5 : 0)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: hovered)
    }
}

/// A clickable card: slightly brighter under the pointer, slightly smaller when pressed.
struct CardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        CardHover(pressed: configuration.isPressed) { configuration.label }
    }
}

private struct CardHover<Label: View>: View {
    let pressed: Bool
    @ViewBuilder var label: Label
    @StateObject private var state = HoverState()

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
        label
            .environment(\.cardHovered, state.hovering)
            .overlay { shape.fill(Color.primary.opacity(pressed ? 0.07 : state.hovering ? 0.035 : 0)).allowsHitTesting(false) }
            .contentShape(shape)
            .scaleEffect(pressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.12), value: state.hovering)
            .animation(.easeOut(duration: 0.12), value: pressed)
            .onHover { state.hovering = $0 }
    }
}
