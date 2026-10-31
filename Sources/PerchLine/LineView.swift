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
    static var panelHeight: CGFloat { photoMaxHeight + 106 }
    static let ropeTop: CGFloat = 10
    static let pinAbove: CGFloat = 9.5

    /// The rope hangs as a parabola from edge to edge of the screen.
    static func sag(width: CGFloat) -> CGFloat { min(30, width * 0.018) }

    // MARK: Two lines either side of the middle

    /// The stretch left empty in the middle, in the panel's coordinates: there the island and the
    /// task capsule hang from the notch. The line becomes two, one on each side, each with its own
    /// sag and its own places; nil keeps one line from edge to edge.
    static var gap: ClosedRange<CGFloat>?

    /// The lengths of line photos hang on.
    static func segments(width: CGFloat) -> [ClosedRange<CGFloat>] {
        guard let gap, gap.lowerBound > cardWidth, gap.upperBound < width - cardWidth else { return [0...width] }
        return [0...gap.lowerBound, gap.upperBound...width]
    }

    private static func segment(at x: CGFloat, width: CGFloat) -> ClosedRange<CGFloat> {
        let all = segments(width: width)
        return all.count == 2 && x > (all[0].upperBound + all[1].lowerBound) / 2 ? all[1] : all[0]
    }

    /// How many photos hang `spacing` apart on one length, clear of both its ends.
    static func places(in segment: ClosedRange<CGFloat>) -> Int {
        max(1, Int((segment.upperBound - segment.lowerBound - 40) / spacing))
    }

    /// The resting places of a full split line, left to right.
    static func placeCenters(width: CGFloat) -> [CGFloat] {
        segments(width: width).flatMap { segment -> [CGFloat] in
            let n = places(in: segment)
            let mid = (segment.lowerBound + segment.upperBound) / 2
            return (0..<n).map { mid + (CGFloat($0) - CGFloat(n - 1) / 2) * spacing }
        }
    }

    /// A position along the places, fractional while a photo scrolls from one to the next: across
    /// the middle it moves straight over to the other side. Past either end it keeps the spacing.
    static func placeX(_ s: CGFloat, width: CGFloat) -> CGFloat {
        let centers = placeCenters(width: width)
        let last = CGFloat(centers.count - 1)
        if s <= 0 { return centers[0] + s * spacing }
        if s >= last { return centers[centers.count - 1] + (s - last) * spacing }
        let i = Int(s.rounded(.down))
        return centers[i] + (centers[i + 1] - centers[i]) * (s - CGFloat(i))
    }

    /// How far a photo is from where it would start to slip out of sight: the screen's edges, and
    /// on a split line the island in the middle.
    static func edgeDistance(_ x: CGFloat, width: CGFloat) -> CGFloat {
        let all = segments(width: width)
        guard all.count == 2 else { return min(x, width - x) }
        if x <= all[0].upperBound { return min(x, all[0].upperBound - x) }
        if x >= all[1].lowerBound { return min(x - all[1].lowerBound, width - x) }
        return 0
    }

    static func anchorsPinned(_ pinned: Int, visible: Int) -> Bool {
        pinned > 0 && pinned < visible - 1
    }

    /// On a line that scrolls with pinned photos anchored, where the photos
    /// scrolling behind them should have faded out. Nil otherwise.
    static func pinnedEdge(count: Int, width: CGFloat, visible: Int, pinned: Int) -> CGFloat? {
        guard Line.keepOnLine != nil, count > visible, anchorsPinned(pinned, visible: visible) else { return nil }
        if segments(width: width).count == 2 { return placeX(CGFloat(pinned - 1), width: width) }
        let newest = width / 2 + CGFloat(visible - 1) * spacing / 2
        return newest - CGFloat(visible - pinned) * spacing
    }

    static func ropeY(x: CGFloat, width: CGFloat) -> CGFloat {
        guard width > 0 else { return ropeTop }
        let segment = segment(at: x, width: width)
        let length = segment.upperBound - segment.lowerBound
        let f = min(max((x - segment.lowerBound) / length, 0), 1)
        return ropeTop + 4 * sag(width: length) * f * (1 - f)
    }

    /// Photos hang `spacing` apart, centred. When there are more than the
    /// `visible` that fit: with Keep on line set, they keep their spacing,
    /// the newest stays where the last one would hang on a full line, and
    /// `scroll` brings older ones in from the left. Otherwise (a line hung
    /// on a wider screen) they move closer together so none is past the edge.
    ///
    /// The first `pinned` photos are the pinned ones. On a line that
    /// scrolls they stay put at its left end, and the rest scroll behind
    /// them, unless they would leave almost no room for the rest.
    static func x(index: Int, count: Int, width: CGFloat, visible: Int, scroll: CGFloat,
                  pinned: Int = 0) -> CGFloat {
        let segments = segments(width: width)
        if segments.count == 2 {
            return splitX(index: index, count: count, width: width, segments: segments, scroll: scroll, pinned: pinned)
        }
        if Line.keepOnLine != nil && count > visible {
            let newest = width / 2 + CGFloat(visible - 1) * spacing / 2
            if anchorsPinned(pinned, visible: visible), index < pinned {
                return newest - CGFloat(visible - 1 - index) * spacing
            }
            return newest - CGFloat(count - 1 - index) * spacing + scroll
        }
        let gaps = CGFloat(max(count - 1, 0))
        let step = gaps > 0 ? min(spacing, max(0, width - 200) / gaps) : spacing
        return width / 2 - gaps * step / 2 + CGFloat(index) * step
    }

    /// The same on a split line. Scrolling, photos move along the places, through the middle from
    /// one side to the other. Otherwise the older half hangs on the left and the newer on the
    /// right, each centred on its side, closer together when there are more than fit.
    private static func splitX(index: Int, count: Int, width: CGFloat, segments: [ClosedRange<CGFloat>],
                               scroll: CGFloat, pinned: Int) -> CGFloat {
        let left = segments[0], right = segments[1]
        let leftPlaces = places(in: left), rightPlaces = places(in: right)
        let visible = leftPlaces + rightPlaces
        if Line.keepOnLine != nil && count > visible {
            if anchorsPinned(pinned, visible: visible), index < pinned {
                return placeX(CGFloat(index), width: width)
            }
            return placeX(CGFloat(visible - 1 - (count - 1 - index)) + scroll / spacing, width: width)
        }
        var onRight = count / 2
        var onLeft = count - onRight
        if count <= visible {
            if onLeft > leftPlaces {
                onLeft = leftPlaces
                onRight = count - onLeft
            } else if onRight > rightPlaces {
                onRight = rightPlaces
                onLeft = count - onRight
            }
        }
        let (segment, i, n) = index < onLeft ? (left, index, onLeft) : (right, index - onLeft, onRight)
        let gaps = CGFloat(max(n - 1, 0))
        let room = segment.upperBound - segment.lowerBound - cardWidth - 40
        let step = gaps > 0 ? min(spacing, max(0, room) / gaps) : spacing
        return (segment.lowerBound + segment.upperBound) / 2 - gaps * step / 2 + CGFloat(i) * step
    }
}

struct LineView: View {
    @ObservedObject var line: Line

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .topLeading) {
                ForEach(Layout.segments(width: width), id: \.lowerBound) { segment in
                    Rope(width: segment.upperBound - segment.lowerBound)
                        .frame(width: segment.upperBound - segment.lowerBound, height: Layout.panelHeight, alignment: .topLeading)
                        .offset(x: segment.lowerBound)
                }

                if line.items.isEmpty {
                    let hintX = Layout.segments(width: width).count == 2
                        ? (Layout.segments(width: width)[0].lowerBound + Layout.segments(width: width)[0].upperBound) / 2
                        : width / 2
                    Hint()
                        .position(x: hintX, y: Layout.ropeY(x: hintX, width: width) + 34)
                        .transition(.opacity)
                }

                if let x = knotX(width: width) {
                    Knot()
                        .position(x: x, y: Layout.ropeY(x: x, width: width) + 0.5)
                        .transition(.opacity)
                }

                ForEach(Array(line.items.enumerated()), id: \.element.id) { index, item in
                    let x = Layout.x(index: index, count: line.items.count, width: width,
                                     visible: line.visibleCount, scroll: line.scroll, pinned: line.pinnedLead)
                    // On a line that scrolls, a photo reaching the edge of the
                    // screen, or the knot it slips behind, dims and stops taking
                    // clicks as soon as it starts to.
                    let bounds = index >= line.pinnedLead ? scrollBounds(width: width) : nil
                    let cardLeft = x - Layout.cardWidth / 2, cardRight = x + Layout.cardWidth / 2
                    let out = bounds.map { cardLeft < $0.lowerBound || cardRight > $0.upperBound } == true
                    // On the left it fades gradually: whole in the first place,
                    // gone once halfway behind the limit.
                    let fadeIn = bounds.map { bounds -> CGFloat in
                        let gone = bounds.lowerBound - Layout.cardWidth / 2
                        let rest = firstLooseX(width: width) - Layout.cardWidth / 2
                        return min(1, max(0, (cardLeft - gone) / max(1, rest - gone)))
                    } ?? 1
                    let ropeY = Layout.ropeY(x: x, width: width)
                    PeggedView(item: item, line: line)
                        .frame(width: Layout.cardWidth, height: Layout.panelHeight - ropeY, alignment: .top)
                        // Photos scrolled towards an edge fade out before they reach it.
                        .opacity(min(1, max(0, Layout.edgeDistance(x, width: width) / 90)) * fadeIn
                                 * (bounds.map { cardRight > $0.upperBound } == true ? 0.35 : 1))
                        .animation(.easeOut(duration: 0.2), value: out)
                        .allowsHitTesting(!out)
                        .zIndex(index < line.pinnedLead ? 1 : 0)
                        .position(x: x, y: ropeY - Layout.pinAbove + (Layout.panelHeight - ropeY) / 2)
                }
            }
            .animation(.spring(response: 0.55, dampingFraction: 0.78), value: line.items.map(\.id))
            .animation(.easeInOut(duration: 0.3), value: line.items.isEmpty)
            .animation(.spring(response: 0.55, dampingFraction: 0.78), value: line.items.map(\.kept))
            // Tucked away, the whole line waits above the top edge and slides
            // out from under the menu bar, the way an auto-hiding Dock does.
            .offset(y: line.revealed ? 0 : -(Layout.panelHeight + 12))
            .animation(line.revealed ? .spring(response: 0.42, dampingFraction: 0.82)
                                     : .easeIn(duration: 0.22), value: line.revealed)
        }
        .onPreferenceChange(HitRectsKey.self) { rects in
            line.hitRects = rects
        }
    }

    /// Where the first photo past the pinned ones hangs at rest on a
    /// scrolling line: the first place, or the one just past the knot.
    private func firstLooseX(width: CGFloat) -> CGFloat {
        if Layout.segments(width: width).count == 2 {
            let pinned = Layout.anchorsPinned(line.pinnedLead, visible: line.visibleCount) ? line.pinnedLead : 0
            return Layout.placeX(CGFloat(pinned), width: width)
        }
        let newest = width / 2 + CGFloat(line.visibleCount - 1) * Layout.spacing / 2
        let first = newest - CGFloat(line.visibleCount - 1) * Layout.spacing
        let pinned = Layout.anchorsPinned(line.pinnedLead, visible: line.visibleCount) ? line.pinnedLead : 0
        return first + CGFloat(pinned) * Layout.spacing
    }

    /// Where a photo on a scrolling line stops being whole in view: the
    /// knot when pinned photos stay put, or else the left edge of the screen,
    /// and the right edge. Nil on a line that does not scroll.
    private func scrollBounds(width: CGFloat) -> ClosedRange<CGFloat>? {
        guard Line.keepOnLine != nil, line.items.count > line.visibleCount else { return nil }
        let pinnedStay = Layout.pinnedEdge(count: line.items.count, width: width,
                                           visible: line.visibleCount, pinned: line.pinnedLead) != nil
        let start = pinnedStay ? knotX(width: width) ?? 0 : 0
        return start...width
    }

    /// Halfway between the last pinned photo and the next one, or half a
    /// step past it when nothing hangs loose. The empty place a pinned photo
    /// leaves still counts, so the knot stays put until the gaps close.
    private func knotX(width: CGFloat) -> CGFloat? {
        guard let last = line.items.lastIndex(where: \.kept) else { return nil }
        let x = { (i: Int) in Layout.x(index: i, count: line.items.count, width: width,
                                       visible: line.visibleCount, scroll: line.scroll, pinned: line.pinnedLead) }
        // On a line that scrolls, the pinned photos stay put, and the knot with them.
        if Layout.pinnedEdge(count: line.items.count, width: width,
                             visible: line.visibleCount, pinned: line.pinnedLead) != nil {
            return x(last) + Layout.spacing / 2
        }
        let next = last + 1 < line.items.count ? x(last + 1) : x(last) + Layout.spacing
        return (x(last) + next) / 2
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
/// both ends so it seems to come from beyond the screen.
struct Rope: View {
    let width: CGFloat

    private var path: Path {
        Path { p in
            let top = Layout.ropeTop
            p.move(to: CGPoint(x: -20, y: top))
            p.addQuadCurve(
                to: CGPoint(x: width + 20, y: top),
                control: CGPoint(x: width / 2, y: top + 2 * Layout.sag(width: width)))
        }
    }

    var body: some View {
        ZStack {
            path.stroke(Color.black.opacity(0.22), lineWidth: 1.4).offset(y: 1.2).blur(radius: 1.2)
            path.stroke(Color(white: 0.55), lineWidth: 1.2)
            path.stroke(Color.white.opacity(0.45), lineWidth: 0.4).offset(y: -0.35)
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
}

struct HitRectsKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}
