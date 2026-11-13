import SwiftUI

enum Layout {
    /// How big the photos hang, from Size in the menu bar. The clip, the rope
    /// and the glass frame keep their size; the photos and the room they take
    /// grow or shrink. Medium is the original size.
    enum Size: String, CaseIterable {
        case small, medium, large

        var scale: CGFloat {
            switch self {
            case .small: 0.8
            case .medium: 1
            case .large: 1.35
            }
        }
    }

    static var size: Size {
        get { Size(rawValue: UserDefaults.standard.string(forKey: "lineSize") ?? "") ?? .medium }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "lineSize") }
    }

    static var photoMaxHeight: CGFloat { (104 * size.scale).rounded() }
    static var cardWidth: CGFloat { (150 * size.scale).rounded() }
    static var spacing: CGFloat { cardWidth + 24 }
    /// Room above the rope for the birds that come to sit on it.
    static var panelHeight: CGFloat { photoMaxHeight + 114 }
    static let ropeTop: CGFloat = 18
    static let pinAbove: CGFloat = 9.5

    /// The rope hangs as a parabola from edge to edge of the screen.
    static func sag(width: CGFloat) -> CGFloat { min(30, width * 0.018) }

    // MARK: Two lines either side of the middle

    /// The stretch left empty in the middle, in the panel's coordinates: there the island and the
    /// task capsule hang from the notch. Nil on a screen without them.
    static var gap: ClosedRange<CGFloat>?

    /// The two lengths of line, left and right of the middle, each with its own photos, sag and
    /// places. Without the island they still part in the middle, a little apart.
    static func segments(width: CGFloat) -> [ClosedRange<CGFloat>] {
        if let gap, gap.lowerBound > cardWidth, gap.upperBound < width - cardWidth {
            return [0...gap.lowerBound, gap.upperBound...width]
        }
        let half = min(110, width / 6)
        return [0...(width / 2 - half), (width / 2 + half)...width]
    }

    static func segment(_ side: LineSide, width: CGFloat) -> ClosedRange<CGFloat> {
        segments(width: width)[side == .left ? 0 : 1]
    }

    /// The line a point across the screen belongs to.
    static func side(at x: CGFloat, width: CGFloat) -> LineSide {
        let all = segments(width: width)
        return x > (all[0].upperBound + all[1].lowerBound) / 2 ? .right : .left
    }

    /// How many photos hang `spacing` apart on one length, clear of both its ends.
    static func places(in segment: ClosedRange<CGFloat>) -> Int {
        max(1, Int((segment.upperBound - segment.lowerBound - 40) / spacing))
    }

    /// The resting places of a full line, left to right.
    static func placeCenters(_ side: LineSide, width: CGFloat) -> [CGFloat] {
        let segment = segment(side, width: width)
        let n = places(in: segment)
        let mid = (segment.lowerBound + segment.upperBound) / 2
        return (0..<n).map { mid + (CGFloat($0) - CGFloat(n - 1) / 2) * spacing }
    }

    /// How far a photo is from where it would start to slip out of sight: the ends of its line,
    /// the screen's edge on one side and the island on the other.
    static func edgeDistance(_ x: CGFloat, width: CGFloat) -> CGFloat {
        let all = segments(width: width)
        if x <= all[0].upperBound { return min(x, all[0].upperBound - x) }
        if x >= all[1].lowerBound { return min(x - all[1].lowerBound, width - x) }
        return 0
    }

    static func anchorsPinned(_ pinned: Int, visible: Int) -> Bool {
        pinned > 0 && pinned < visible - 1
    }

    /// On a line that scrolls with pinned photos anchored, where the last
    /// pinned one rests. Nil otherwise.
    static func pinnedEdge(count: Int, side: LineSide, width: CGFloat, pinned: Int) -> CGFloat? {
        let centers = placeCenters(side, width: width)
        guard Line.keepOnLine != nil, count > centers.count, anchorsPinned(pinned, visible: centers.count) else { return nil }
        return centers[pinned - 1]
    }

    static func ropeY(x: CGFloat, width: CGFloat) -> CGFloat {
        guard width > 0 else { return ropeTop }
        let segment = segment(side(at: x, width: width), width: width)
        let length = segment.upperBound - segment.lowerBound
        let f = min(max((x - segment.lowerBound) / length, 0), 1)
        return ropeTop + 4 * sag(width: length) * f * (1 - f)
    }

    /// The rope as drawn, a little past both ends of its line: where a bird's feet go.
    static func ropeCurveY(x: CGFloat, width: CGFloat) -> CGFloat {
        let segment = segment(side(at: x, width: width), width: width)
        let length = segment.upperBound - segment.lowerBound
        let u = min(max((x - segment.lowerBound + 20) / (length + 40), 0), 1)
        return ropeTop + 4 * sag(width: length) * u * (1 - u)
    }

    /// Where a photo hangs on its line, `spacing` apart and centred. When
    /// there are more than fit: with Keep on line set, they keep their
    /// spacing, the newest stays in the last place and `scroll` brings older
    /// ones in from the left. Otherwise (a line hung on a wider screen) they
    /// move closer together so none is past the end.
    ///
    /// The first `pinned` photos are the pinned ones. On a line that
    /// scrolls they stay put at its left end, and the rest scroll behind
    /// them, unless they would leave almost no room for the rest.
    static func x(index: Int, count: Int, side: LineSide, width: CGFloat, scroll: CGFloat, pinned: Int = 0) -> CGFloat {
        let segment = segment(side, width: width)
        let centers = placeCenters(side, width: width)
        let visible = centers.count
        if Line.keepOnLine != nil && count > visible {
            if anchorsPinned(pinned, visible: visible), index < pinned { return centers[index] }
            let place = CGFloat(visible - 1 - (count - 1 - index)) + scroll / spacing
            return centers[0] + place * spacing
        }
        let gaps = CGFloat(max(count - 1, 0))
        let room = segment.upperBound - segment.lowerBound - cardWidth - 40
        let step = gaps > 0 ? min(spacing, max(0, room) / gaps) : spacing
        return (segment.lowerBound + segment.upperBound) / 2 - gaps * step / 2 + CGFloat(index) * step
    }
}

struct LineView: View {
    @ObservedObject var line: Line

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .topLeading) {
                lines(width: width)
                    // Tucked away, the whole line waits above the top edge and slides
                    // out from under the menu bar, the way an auto-hiding Dock does.
                    .offset(y: line.revealed ? 0 : -(Layout.panelHeight + 12))
                    .animation(line.revealed ? .spring(response: 0.42, dampingFraction: 0.82)
                                             : .easeIn(duration: 0.22), value: line.revealed)
            }
        }
        .onPreferenceChange(HitRectsKey.self) { rects in
            line.hitRects = rects
        }
        .onPreferenceChange(LabelRectsKey.self) { rects in
            line.labelRects = rects
        }
    }

    private func lines(width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(LineSide.allCases, id: \.self) { side in
                let segment = Layout.segment(side, width: width)
                Rope(width: segment.upperBound - segment.lowerBound, start: segment.lowerBound,
                     flock: line.flock, lit: line.dropSide == side)
                    .frame(width: segment.upperBound - segment.lowerBound, height: Layout.panelHeight, alignment: .topLeading)
                    .offset(x: segment.lowerBound)
            }

            labels(width: width)

            if line.items.isEmpty {
                let segment = Layout.segment(line.target, width: width)
                let hintX = (segment.lowerBound + segment.upperBound) / 2
                Hint()
                    .position(x: hintX, y: Layout.ropeY(x: hintX, width: width) + 34)
                    .transition(.opacity)
            }

            ForEach(LineSide.allCases, id: \.self) { side in
                if let x = knotX(side, width: width) {
                    Knot()
                        .position(x: x, y: Layout.ropeY(x: x, width: width) + 0.5)
                        .transition(.opacity)
                }
            }

            ForEach(line.items) { item in
                card(item, width: width)
            }
        }
        .animation(.spring(response: 0.55, dampingFraction: 0.78), value: line.items.map(\.id))
        .animation(.spring(response: 0.55, dampingFraction: 0.78), value: line.items.map(\.side))
        .animation(.easeInOut(duration: 0.3), value: line.items.isEmpty)
        .animation(.spring(response: 0.55, dampingFraction: 0.78), value: line.items.map(\.kept))
    }

    private func card(_ item: Pegged, width: CGFloat) -> some View {
        let side = item.side
        let mine = line.items(on: side)
        let index = mine.firstIndex { $0.id == item.id } ?? 0
        let pinned = line.pinnedLead(on: side)
        let x = Layout.x(index: index, count: mine.count, side: side, width: width,
                         scroll: line.scroll(on: side), pinned: pinned)
        // On a line that scrolls, a photo reaching the end of its line, or
        // the knot it slips behind, dims and stops taking clicks as soon as it starts to.
        let bounds = index >= pinned ? scrollBounds(side, width: width) : nil
        let cardLeft = x - Layout.cardWidth / 2, cardRight = x + Layout.cardWidth / 2
        let out = bounds.map { cardLeft < $0.lowerBound || cardRight > $0.upperBound } == true
        // On the left it fades gradually: whole in the first place,
        // gone once halfway behind the limit.
        let fadeIn = bounds.map { bounds -> CGFloat in
            let gone = bounds.lowerBound - Layout.cardWidth / 2
            let rest = firstLooseX(side, width: width) - Layout.cardWidth / 2
            return min(1, max(0, (cardLeft - gone) / max(1, rest - gone)))
        } ?? 1
        let ropeY = Layout.ropeY(x: x, width: width)
        return PeggedView(item: item, line: line)
            .frame(width: Layout.cardWidth, height: Layout.panelHeight - ropeY, alignment: .top)
            // Photos scrolled towards an end fade out before they reach it.
            .opacity(min(1, max(0, Layout.edgeDistance(x, width: width) / 90)) * fadeIn
                     * (bounds.map { cardRight > $0.upperBound } == true ? 0.35 : 1))
            .animation(.easeOut(duration: 0.2), value: out)
            .allowsHitTesting(!out)
            .zIndex(index < pinned ? 1 : 0)
            .position(x: x, y: ropeY - Layout.pinAbove + (Layout.panelHeight - ropeY) / 2)
    }

    /// The two labels at the inner ends of the lines, just clear of the island and the capsule:
    /// which folder each line keeps, and which one new screenshots hang on. Small, a dot and an
    /// icon, until the pointer comes to one; a click switches.
    private func labels(width: CGFloat) -> some View {
        let left = Layout.segment(.left, width: width), right = Layout.segment(.right, width: width)
        let room: CGFloat = 170
        return ZStack(alignment: .topLeading) {
            ForEach(LineSide.allCases, id: \.self) { side in
                let inner = side == .left ? left.upperBound - 6 : right.lowerBound + 6
                SideLabel(side: side, name: Line.name(of: side), active: line.target == side,
                          dropping: line.dropSide == side) {
                    guard line.target != side else { return }
                    line.target = side
                    if line.soundOn { NSSound(named: "Pop")?.play() }
                }
                .frame(width: room, height: 26, alignment: side == .left ? .trailing : .leading)
                .position(x: side == .left ? inner - room / 2 : inner + room / 2,
                          y: Layout.ropeCurveY(x: inner, width: width) + 1)
            }
        }
    }

    /// Where the first photo past the pinned ones hangs at rest on a
    /// scrolling line: the first place, or the one just past the knot.
    private func firstLooseX(_ side: LineSide, width: CGFloat) -> CGFloat {
        let centers = Layout.placeCenters(side, width: width)
        let lead = line.pinnedLead(on: side)
        let pinned = Layout.anchorsPinned(lead, visible: centers.count) ? lead : 0
        return centers[min(pinned, centers.count - 1)]
    }

    /// Where a photo on a scrolling line stops being whole in view: the
    /// knot when pinned photos stay put, or else the start of its line, and
    /// its end. Nil on a line that does not scroll.
    private func scrollBounds(_ side: LineSide, width: CGFloat) -> ClosedRange<CGFloat>? {
        let count = line.items(on: side).count
        guard Line.keepOnLine != nil, count > line.visible(on: side) else { return nil }
        let segment = Layout.segment(side, width: width)
        let pinnedStay = Layout.pinnedEdge(count: count, side: side, width: width, pinned: line.pinnedLead(on: side)) != nil
        let start = pinnedStay ? knotX(side, width: width) ?? segment.lowerBound : segment.lowerBound
        return start...segment.upperBound
    }

    /// Halfway between the last pinned photo and the next one, or half a
    /// step past it when nothing hangs loose. The empty place a pinned photo
    /// leaves still counts, so the knot stays put until the gaps close.
    private func knotX(_ side: LineSide, width: CGFloat) -> CGFloat? {
        let mine = line.items(on: side)
        guard let last = mine.lastIndex(where: \.kept) else { return nil }
        let pinned = line.pinnedLead(on: side)
        let x = { (i: Int) in Layout.x(index: i, count: mine.count, side: side, width: width,
                                       scroll: line.scroll(on: side), pinned: pinned) }
        // On a line that scrolls, the pinned photos stay put, and the knot with them.
        if Layout.pinnedEdge(count: mine.count, side: side, width: width, pinned: pinned) != nil {
            return x(last) + Layout.spacing / 2
        }
        let next = last + 1 < mine.count ? x(last + 1) : x(last) + Layout.spacing
        return (x(last) + next) / 2
    }
}

/// A line's label: the folder it keeps its photos in. Small until the pointer comes to it, or a
/// photo is dragged over its line; the one new screenshots hang on has a lit dot.
private struct SideLabel: View {
    let side: LineSide
    let name: String
    let active: Bool
    let dropping: Bool
    let action: () -> Void
    @State private var hovering = false

    private var open: Bool { hovering || dropping }
    private static let green = Color(red: 0.42, green: 0.86, blue: 0.55)

    var body: some View {
        HStack(spacing: 4) {
            if side == .right { mark }
            if open {
                Text(dropping ? String(format: L("Hang on “%@”"), name) : name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .fixedSize()
                    .transition(.opacity.combined(with: .scale(scale: 0.85, anchor: side == .left ? .trailing : .leading)))
            }
            if side == .left { mark }
        }
        .font(.system(size: 11, weight: .medium, design: .rounded))
        .foregroundStyle(.white.opacity(active || open ? 0.95 : 0.6))
        .padding(.horizontal, open ? 8 : 5)
        .padding(.vertical, open ? 4 : 3)
        .background(Capsule().fill(Color.black.opacity(open ? 0.55 : 0.34)))
        .background(Capsule().fill(.ultraThinMaterial))
        .overlay(Capsule().strokeBorder(Color.white.opacity(dropping ? 0.5 : open ? 0.22 : 0.1), lineWidth: dropping ? 1 : 0.5))
        .opacity(active || open ? 1 : 0.75)
        .animation(.spring(response: 0.32, dampingFraction: 0.8), value: open)
        .animation(.easeOut(duration: 0.25), value: active)
        .contentShape(Capsule())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
        .help(active ? L("New screenshots hang on this line") : L("Click to hang new screenshots on this line"))
        .background(
            GeometryReader { g in
                Color.clear.preference(key: LabelRectsKey.self, value: [g.frame(in: .global)])
            }
        )
    }

    /// The dot, lit on the line new screenshots hang on, and the line's icon.
    private var mark: some View {
        HStack(spacing: 3) {
            if side == .right { dot }
            Image(systemName: side == .left ? "folder.fill" : "camera.viewfinder")
                .font(.system(size: 9.5, weight: .semibold))
            if side == .left { dot }
        }
    }

    private var dot: some View {
        Circle()
            .fill(active ? Self.green : Color.white.opacity(0.35))
            .frame(width: 5, height: 5)
            .shadow(color: active ? Self.green.opacity(0.9) : .clear, radius: 2.5)
    }
}

struct LabelRectsKey: PreferenceKey {
    static var defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) {
        value += nextValue()
    }
}

/// Where the line is tied: what hangs left of it is pinned and stays.
private struct Knot: View {
    var body: some View {
        ZStack {
            Ellipse()
                .fill(Color(white: 0.5))
                .frame(width: 7, height: 5.5)
                .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
            // Two short loose ends hanging from it.
            Path { p in
                p.move(to: CGPoint(x: 3.5, y: 3))
                p.addQuadCurve(to: CGPoint(x: 1.5, y: 11), control: CGPoint(x: 3.8, y: 7))
                p.move(to: CGPoint(x: 4, y: 3))
                p.addQuadCurve(to: CGPoint(x: 6.5, y: 10), control: CGPoint(x: 4.5, y: 7))
            }
            .stroke(Color(white: 0.55), style: StrokeStyle(lineWidth: 1, lineCap: .round))
            .frame(width: 8, height: 12)
            .offset(y: 5)
        }
        .allowsHitTesting(false)
    }
}

private struct Hint: View {
    var body: some View {
        Text(L("Take a screenshot and it will hang here"))
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
    }
}

/// A thin, neutral line: a mid gray core with a faint highlight and a soft
/// shadow, so it reads on light and dark backgrounds alike. It fades out at
/// both ends so it seems to come from beyond the screen. Where a bird sits it
/// gives a little, and bounces when one lands or takes off.
struct Rope: View {
    let width: CGFloat
    /// Where this length of line starts across the panel, to find the birds on it.
    var start: CGFloat = 0
    var flock: Flock?
    /// A photo dragged over this line would hang on it.
    var lit = false

    private func path(at t: Double?) -> Path {
        let top = Layout.ropeTop
        let sag = Layout.sag(width: width)
        guard let t, let flock, flock.weighs(between: start...(start + width), at: t) else {
            return Path { p in
                p.move(to: CGPoint(x: -20, y: top))
                p.addQuadCurve(to: CGPoint(x: width + 20, y: top), control: CGPoint(x: width / 2, y: top + 2 * sag))
            }
        }
        return Path { p in
            let span = width + 40
            var x: CGFloat = -20
            p.move(to: CGPoint(x: x, y: top))
            while x < width + 20 {
                x = min(width + 20, x + 3)
                let u = (x + 20) / span
                p.addLine(to: CGPoint(x: x, y: top + 4 * sag * u * (1 - u) + flock.ropeDip(at: start + x, t: t)))
            }
        }
    }

    var body: some View {
        Group {
            if let flock, !flock.birds.isEmpty {
                TimelineView(.animation(minimumInterval: 1.0 / 60)) { context in
                    strokes(path(at: context.date.timeIntervalSinceReferenceDate))
                }
            } else {
                strokes(path(at: nil))
            }
        }
        .mask(
            LinearGradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.08),
                .init(color: .black, location: 0.92),
                .init(color: .clear, location: 1),
            ], startPoint: .leading, endPoint: .trailing)
        )
        .allowsHitTesting(false)
    }

    private func strokes(_ path: Path) -> some View {
        ZStack {
            path.stroke(Color.black.opacity(0.22), lineWidth: 1.4).offset(y: 1.2).blur(radius: 1.2)
            path.stroke(Color(white: lit ? 0.85 : 0.55), lineWidth: lit ? 1.6 : 1.2)
            path.stroke(Color.white.opacity(0.45), lineWidth: 0.4).offset(y: -0.35)
            if lit {
                path.stroke(Color.white.opacity(0.7), lineWidth: 3).blur(radius: 3)
            }
        }
        .animation(.easeOut(duration: 0.2), value: lit)
    }
}

struct HitRectsKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}
