import SwiftUI

/// One stretch of the line, from the top or bottom edge of a row to its node.
struct TimelineSegment: Equatable {
    enum Style: Equatable {
        case none
        /// Already behind us: drawn in the colors of the tasks it joins.
        case elapsed
        /// Still ahead: a quiet line.
        case ahead
        /// Untimed tasks: dashed.
        case anytime
        /// Between two tasks booked for the same time: dashed, in a warning color.
        case conflict
    }

    var style: Style = .none
    var top: Color = .clear
    var bottom: Color = .clear

    static let none = TimelineSegment()
}

/// Where a row sits on the Today timeline and how it draws.
struct TimelineNode: Equatable {
    var start: Date?
    /// Shown at the foot of the time column when the capsule is tall enough.
    var end: Date?
    /// "15:00 – 16:30 · 1h 30m", or with a live hint in place of the length.
    var detail: String?
    var hint: String?
    var isLate = false
    /// How much of the capsule is filled: the share of the task's time already passed.
    var progress: Double = 0
    var height: CGFloat = TimelineMetrics.capsuleWidth
    /// Finished: folded to one quiet line with a small dot on the timeline.
    var isCollapsed = false
    var above = TimelineSegment.none
    var below = TimelineSegment.none
    /// Position in the list.
    var order = 0
    /// When the opening sweep reaches this row: it colors the line above, fills the capsule,
    /// then colors the line below, so the day fills in the order it happened.
    var reveal = Reveal()

    struct Window: Equatable {
        var delay: Double = 0
        var duration: Double = 0
    }

    struct Reveal: Equatable {
        var above = Window()
        var fill = Window()
        var below = Window()
    }
}

enum TimelineMetrics {
    /// Room for "10:00", or "10:00 AM" with a small AM.
    static var labelWidth: CGFloat { AppSettings.shared.uses12HourTime ? 46 : 36 }
    static let capsuleWidth: CGFloat = 30
    /// A finished task's capsule, folded down to a dot.
    static let collapsedSize: CGFloat = 20
    static let spacing: CGFloat = 8
    /// Row padding + time column + spacing + half the capsule.
    static var lineX: CGFloat { 8 + labelWidth + spacing + capsuleWidth / 2 }
    /// Where titles start, so marker rows can line their text up with them.
    static var textX: CGFloat { 8 + labelWidth + spacing + capsuleWidth + 10 }
    static let gapThreshold = 30

    /// Capsules grow with the task's length: a circle up to 15 minutes, then taller, capped
    /// near three hours so a long block doesn't swallow the panel.
    static func capsuleHeight(minutes: Int) -> CGFloat {
        min(capsuleWidth + CGFloat(max(0, minutes - 15)) * 0.6, 118)
    }

    /// Free time between tasks shows as a longer stretch of line.
    static func gapHeight(minutes: Int) -> CGFloat {
        20 + CGFloat(min(minutes, 240)) * 0.07
    }
}

/// Today's tasks on a vertical line, in the spirit of a day planner: timed tasks as capsules
/// as tall as they are long, filling up as their time passes, with free time between them;
/// a live "now" point when nothing is under way; untimed tasks after it on a dashed stretch.
struct TodayTimeline: View {
    let tasks: [TaskItem]
    let now: Date

    // Read so the timeline redraws when the color settings change.
    @AppStorage(Pref.taskDefaultColor) private var defaultColor = TaskColor.coral.rawValue
    @AppStorage(Pref.taskTopicColors) private var topicColors = true

    var body: some View {
        let _ = (defaultColor, topicColors)
        let entries = Self.entries(for: tasks, now: now)
        ForEach(entries) { entry in
            switch entry.kind {
            case .task(let task, let node):
                TaskRow(task: task, now: now, timeline: node)
                    .transition(.asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .opacity.combined(with: .scale(scale: 0.96, anchor: .leading))
                    ))
            case .now(let node):
                NowMarker(now: now, node: node)
            case .gap(let minutes, let node):
                FreeTimeMarker(minutes: minutes, node: node)
            case .overlap(let overlap, let node):
                OverlapMarker(overlap: overlap, node: node)
            case .anytime(let node):
                AnytimeMarker(node: node)
            }
        }
    }

    /// Two open tasks booked over the same stretch of time.
    struct Overlap: Equatable {
        var minutes: Int
        /// The later task, which "start after" moves.
        var taskID: UUID
        /// When the earlier one ends.
        var freeAt: Date
        var otherTitle: String
    }

    struct Entry: Identifiable {
        enum Kind {
            case task(TaskItem, TimelineNode)
            case now(TimelineNode)
            case gap(minutes: Int, TimelineNode)
            case overlap(Overlap, TimelineNode)
            case anytime(TimelineNode)
        }

        let id: String
        var kind: Kind

        var node: TimelineNode {
            get {
                switch kind {
                case .task(_, let node), .now(let node), .gap(_, let node), .overlap(_, let node), .anytime(let node): node
                }
            }
            set {
                switch kind {
                case .task(let task, _): kind = .task(task, newValue)
                case .now: kind = .now(newValue)
                case .gap(let minutes, _): kind = .gap(minutes: minutes, newValue)
                case .overlap(let overlap, _): kind = .overlap(overlap, newValue)
                case .anytime: kind = .anytime(newValue)
                }
            }
        }
    }

    private enum Item {
        case task(TaskItem)
        case now
        case gap(from: Date, to: Date)
        case overlap(Overlap)
        case anytime

        /// Where the item starts and ends in time; nil for untimed items.
        var span: (start: Date, end: Date)? {
            switch self {
            case .task(let task): task.schedule?.time.flatMap { start in task.end.map { (start, $0) } }
            case .now: nil
            case .gap(let from, let to): (from, to)
            case .overlap, .anytime: nil
            }
        }

        var isUntimed: Bool {
            switch self {
            case .task(let task): !task.hasTime
            case .anytime: true
            case .now, .gap, .overlap: false
            }
        }
    }

    static func entries(for tasks: [TaskItem], now: Date) -> [Entry] {
        let timed = tasks.filter(\.hasTime).sorted {
            ($0.schedule?.time ?? now, $0.end ?? now) < ($1.schedule?.time ?? now, $1.end ?? now)
        }
        let untimed = tasks.filter { !$0.hasTime && !$0.isDone }
        let current = timed.first { task in
            guard !task.isDone, let start = task.schedule?.time, let end = task.end else { return false }
            return start <= now && now < end
        }
        let nextUp = current == nil ? timed.first { !$0.isDone && ($0.schedule?.time ?? now) > now } : nil

        // Order: timed tasks with free time between them, "now" wherever it falls (unless a task
        // is under way, whose capsule shows it), then the untimed ones.
        var items: [Item] = []
        var placedNow = current != nil
        var lastEnd: Date?
        var lastOwner: TaskItem?
        for task in timed {
            guard let start = task.schedule?.time, let end = task.end else { continue }
            var justPlacedNow = false
            if !placedNow && start > now {
                items.append(.now)
                placedNow = true
                justPlacedNow = true
            }
            if let lastEnd, let owner = lastOwner, start < lastEnd {
                // Booked over something still running. Only worth flagging while both are open.
                let minutes = Int(min(lastEnd, end).timeIntervalSince(start) / 60)
                if !task.isDone, !owner.isDone, minutes >= 1 {
                    items.append(.overlap(Overlap(minutes: minutes, taskID: task.id, freeAt: lastEnd, otherTitle: owner.title)))
                }
            } else if !justPlacedNow, let lastEnd, start.timeIntervalSince(lastEnd) >= Double(TimelineMetrics.gapThreshold * 60) {
                items.append(.gap(from: lastEnd, to: start))
            }
            items.append(.task(task))
            if end > (lastEnd ?? .distantPast) {
                lastEnd = end
                lastOwner = task
            }
        }
        if !placedNow { items.append(.now) }
        if !untimed.isEmpty {
            if !timed.isEmpty { items.append(.anytime) }
            items += untimed.map(Item.task)
        }

        // Colors along the line: each task's own; markers borrow from their neighbours.
        let accent = Color.accentColor
        let ownColors: [Color?] = items.map { item in
            switch item {
            case .task(let task): task.tint.color
            case .now: accent
            case .gap, .overlap, .anytime: nil
            }
        }
        let colors: [Color] = ownColors.indices.map { index in
            if let own = ownColors[index] { return own }
            let before = ownColors[..<index].last { $0 != nil } ?? nil
            let after = ownColors[(index + 1)...].first { $0 != nil } ?? nil
            switch (before, after) {
            case let (before?, after?): return before.mix(with: after, by: 0.5)
            case let (color?, nil), let (nil, color?): return color
            case (nil, nil): return accent
            }
        }

        // The stretch between two items is behind us once the lower one has begun.
        func joinStyle(_ upper: Int, _ lower: Int) -> TimelineSegment.Style {
            if items[upper].isUntimed || items[lower].isUntimed { return .anytime }
            if case .overlap = items[upper] { return .conflict }
            if case .overlap = items[lower] { return .conflict }
            if case .now = items[lower] { return .elapsed }
            if case .now = items[upper] { return .ahead }
            return (items[lower].span?.start ?? now) <= now ? .elapsed : .ahead
        }

        let entries = items.enumerated().map { index, item in
            var node = TimelineNode(order: index)
            if index > 0 {
                node.above = TimelineSegment(
                    style: joinStyle(index - 1, index),
                    top: colors[index - 1].mix(with: colors[index], by: 0.5),
                    bottom: colors[index]
                )
            }
            if index < items.count - 1 {
                node.below = TimelineSegment(
                    style: joinStyle(index, index + 1),
                    top: colors[index],
                    bottom: colors[index].mix(with: colors[index + 1], by: 0.5)
                )
            }

            switch item {
            case .now:
                node.height = 10
                return Entry(id: "now", kind: .now(node))
            case .anytime:
                node.height = 8
                return Entry(id: "anytime", kind: .anytime(node))
            case .gap(let from, let to):
                let minutes = Int(to.timeIntervalSince(from) / 60)
                node.height = 0
                return Entry(id: "gap-\(from.timeIntervalSince1970)", kind: .gap(minutes: minutes, node))
            case .overlap(let overlap):
                node.height = 12
                return Entry(id: "overlap-\(overlap.taskID)", kind: .overlap(overlap, node))
            case .task(let task):
                if let start = task.schedule?.time, let end = task.end {
                    node.height = TimelineMetrics.capsuleHeight(minutes: task.minutes)
                    node.start = start
                    node.end = node.height >= 56 ? end : nil
                    node.isLate = DateText.isOverdue(task, now: now)
                    node.progress = task.isDone ? 1 : min(max(now.timeIntervalSince(start) / end.timeIntervalSince(start), 0), 1)
                    if task.id == current?.id {
                        node.hint = remaining(until: end, from: now)
                    } else if task.id == nextUp?.id {
                        node.hint = countdown(to: start, from: now)
                    }
                    let range = "\(DateText.time(start)) – \(DateText.time(end))"
                    node.detail = "\(range) · \(node.hint ?? DateText.duration(task.minutes))"
                    if task.isDone {
                        // Done: it keeps its place in the day but stops taking up the room of its hours.
                        node.isCollapsed = true
                        node.height = TimelineMetrics.collapsedSize
                        node.end = nil
                        node.detail = range
                    }
                } else {
                    node.height = TimelineMetrics.capsuleWidth
                }
                return Entry(id: task.id.uuidString, kind: .task(task, node))
            }
        }
        return sweep(entries)
    }

    /// Times the opening animation: one pass from the top down to "now", coloring each
    /// stretch of line and filling each capsule in turn, kept under a second and a half.
    private static func sweep(_ entries: [Entry]) -> [Entry] {
        let segment = 0.08
        var cursor = 0.0
        var timed = entries
        for index in timed.indices {
            var node = timed[index].node
            if node.above.style == .elapsed {
                node.reveal.above = .init(delay: cursor, duration: segment)
                cursor += segment
            }
            switch timed[index].kind {
            case .task where node.progress > 0:
                let duration = 0.12 + 0.4 * node.progress
                node.reveal.fill = .init(delay: cursor, duration: duration)
                cursor += duration
            case .now:
                node.reveal.fill = .init(delay: cursor, duration: 0.3)
                cursor += 0.1
            default:
                break
            }
            if node.below.style == .elapsed {
                node.reveal.below = .init(delay: cursor, duration: segment)
                cursor += segment
            }
            timed[index].node = node
        }
        let scale = cursor > 1.5 ? 1.5 / cursor : 1
        guard scale < 1 else { return timed }
        for index in timed.indices {
            var reveal = timed[index].node.reveal
            for keyPath in [\TimelineNode.Reveal.above, \.fill, \.below] {
                reveal[keyPath: keyPath].delay *= scale
                reveal[keyPath: keyPath].duration *= scale
            }
            timed[index].node.reveal = reveal
        }
        return timed
    }

    private static func countdown(to date: Date, from now: Date) -> String {
        let minutes = max(1, Int((date.timeIntervalSince(now) / 60).rounded(.up)))
        return tr("\(DateText.duration(minutes))后", "in \(DateText.duration(minutes))")
    }

    private static func remaining(until date: Date, from now: Date) -> String {
        let minutes = max(1, Int((date.timeIntervalSince(now) / 60).rounded(.up)))
        return tr("还剩 \(DateText.duration(minutes))", "\(DateText.duration(minutes)) left")
    }
}

// MARK: - Row parts

/// The time column: start beside the top of the capsule, end beside its foot.
struct TimelineTimes: View {
    let node: TimelineNode

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            if let start = node.start {
                time(start, size: node.isCollapsed ? 10.5 : 11, weight: node.isCollapsed ? .regular : .medium)
                    .foregroundStyle(node.isLate ? AnyShapeStyle(Color.red.opacity(0.85)) : node.isCollapsed ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                    .padding(.top, node.end == nil ? 0 : 2)
            }
            if let end = node.end {
                Spacer(minLength: 0)
                time(end, size: 10, weight: .regular)
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, 2)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .frame(width: TimelineMetrics.labelWidth, height: node.height, alignment: node.end == nil ? .trailing : .topTrailing)
    }

    private func time(_ date: Date, size: CGFloat, weight: Font.Weight) -> some View {
        let parts = AppSettings.shared.timeParts(date)
        return HStack(alignment: .firstTextBaseline, spacing: 1) {
            Text(parts.clock)
                .font(.system(size: size, weight: weight, design: .rounded).monospacedDigit())
            if let period = parts.period {
                Text(period)
                    .font(.system(size: size - 3, weight: .semibold, design: .rounded))
            }
        }
    }
}

/// The task's capsule: a soft tint that fills with color from the top as its time passes,
/// the edge of the fill feathered rather than cut.
struct TimelineCapsule: View {
    let tint: Color
    let glyph: TaskGlyph
    let progress: Double
    let height: CGFloat
    let reveal: TimelineNode.Window
    /// Following a finger (a swipe in progress): the fill keeps up instead of easing slowly.
    var interactive = false
    var width: CGFloat = TimelineMetrics.capsuleWidth

    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    private static let feather: CGFloat = 9

    var body: some View {
        let shown = appeared ? progress : 0
        ZStack {
            Capsule(style: .circular).fill(tint.opacity(colorScheme == .dark ? 0.2 : 0.14))
            Capsule(style: .circular).strokeBorder(tint.opacity(0.28), lineWidth: 0.6)
            glyphView.foregroundStyle(tint)
            ZStack {
                Capsule(style: .circular).fill(LinearGradient(
                    colors: [tint.mix(with: .white, by: 0.14), tint, tint.mix(with: .black, by: 0.04)],
                    startPoint: .top, endPoint: .bottom
                ))
                Capsule(style: .circular).strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom),
                    lineWidth: 0.7
                )
                glyphView.foregroundStyle(.white)
            }
            .mask(alignment: .top) {
                // Solid down to just above the fill line, then a soft fade across it.
                let band = featherBand(shown)
                VStack(spacing: 0) {
                    Rectangle().frame(height: band.solid)
                    LinearGradient(colors: [.black, .black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: band.fade)
                }
                .frame(width: width)
            }
            // A zero-height mask still lets a hairline through.
            .opacity(shown > 0 ? 1 : 0)
        }
        .frame(width: width, height: height)
        .shadow(color: tint.opacity(shown > 0 ? 0.22 : 0), radius: 4, y: 2)
        .animation(interactive ? .spring(duration: 0.22, bounce: 0) : .easeInOut(duration: 0.8), value: progress)
        .animation(.spring(duration: 0.3, bounce: 0.3), value: glyph)
        .animation(.spring(duration: 0.45, bounce: 0.2), value: height)
        .animation(.spring(duration: 0.45, bounce: 0.2), value: width)
        .onAppear {
            guard !appeared else { return }
            if reduceMotion || progress == 0 {
                appeared = true
            } else {
                withAnimation(.timingCurve(0.35, 0, 0.6, 1, duration: reveal.duration).delay(reveal.delay)) { appeared = true }
            }
        }
        .accessibilityHidden(true)
    }

    /// The fade straddles the fill line; empty and full have no soft edge at all.
    private func featherBand(_ progress: Double) -> (solid: CGFloat, fade: CGFloat) {
        let feather = Self.feather
        if progress <= 0 { return (0, 0) }
        if progress >= 1 { return (height, 0) }
        let line = height * progress
        let solid = max(0, line - feather)
        return (solid, line + feather - solid)
    }

    @ViewBuilder
    private var glyphView: some View {
        switch glyph {
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: width < TimelineMetrics.capsuleWidth ? 9 : 12, weight: .semibold))
        case .text(let text):
            Text(text)
                .font(.system(size: width < TimelineMetrics.capsuleWidth ? 10 : 13, weight: .semibold, design: .rounded))
        }
    }
}

/// The line through a row: one segment above the node, one below. The quiet track shows at
/// once; the color of time already passed then flows down it with the opening sweep.
struct TimelineTrack: View {
    let node: TimelineNode

    @State private var appeared = false
    @State private var aboveColored = false
    @State private var belowColored = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let middle = geometry.size.height / 2
            let radius = node.height / 2
            // Rows sit 1pt apart; the segment above bridges that gap, so joins never double up.
            let aboveRange = (-1.0, middle - radius)
            let belowRange = (middle + radius, geometry.size.height)
            ZStack(alignment: .topLeading) {
                base(node.above, from: aboveRange.0, to: aboveRange.1)
                base(node.below, from: belowRange.0, to: belowRange.1)
                colored(node.above, from: aboveRange.0, to: aboveRange.1, grown: aboveColored)
                colored(node.below, from: belowRange.0, to: belowRange.1, grown: belowColored)
            }
        }
        .opacity(appeared ? 1 : 0)
        .allowsHitTesting(false)
        .animation(.easeInOut(duration: 0.6), value: node.above)
        .animation(.easeInOut(duration: 0.6), value: node.below)
        .onAppear {
            guard !appeared else { return }
            if reduceMotion {
                appeared = true
                aboveColored = true
                belowColored = true
                return
            }
            withAnimation(.easeOut(duration: 0.25)) { appeared = true }
            withAnimation(.linear(duration: node.reveal.above.duration).delay(node.reveal.above.delay)) { aboveColored = true }
            withAnimation(.linear(duration: node.reveal.below.duration).delay(node.reveal.below.delay)) { belowColored = true }
        }
    }

    private func line(from top: CGFloat, to bottom: CGFloat) -> Path {
        Path { path in
            path.move(to: CGPoint(x: TimelineMetrics.lineX, y: top))
            path.addLine(to: CGPoint(x: TimelineMetrics.lineX, y: bottom))
        }
    }

    @ViewBuilder
    private func base(_ segment: TimelineSegment, from top: CGFloat, to bottom: CGFloat) -> some View {
        if segment.style != .none, bottom > top {
            line(from: top, to: bottom)
                .stroke(
                    segment.style == .conflict ? Color.orange.opacity(0.7)
                        : Color.primary.opacity(segment.style == .anytime ? 0.22 : 0.12),
                    style: StrokeStyle(lineWidth: 2, lineCap: .butt, dash: segment.style == .anytime || segment.style == .conflict ? [2, 4] : [])
                )
        }
    }

    @ViewBuilder
    private func colored(_ segment: TimelineSegment, from top: CGFloat, to bottom: CGFloat, grown: Bool) -> some View {
        if segment.style == .elapsed, bottom > top {
            line(from: top, to: bottom)
                .trim(from: 0, to: grown ? 1 : 0)
                .stroke(
                    LinearGradient(colors: [segment.top.opacity(0.8), segment.bottom.opacity(0.8)], startPoint: .top, endPoint: .bottom),
                    style: StrokeStyle(lineWidth: 2, lineCap: .butt)
                )
        }
    }
}

// MARK: - Markers

/// The live "now" point, when it falls between tasks: a pulsing dot with the time beside it.
private struct NowMarker: View {
    let now: Date
    let node: TimelineNode

    @State private var pulsing = false
    @State private var arrived = false

    var body: some View {
        HStack(spacing: TimelineMetrics.spacing) {
            Text(DateText.time(now))
                .font(.system(size: 10, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.accentColor))
                .contentTransition(.numericText())
                .frame(width: TimelineMetrics.labelWidth, alignment: .trailing)
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.25))
                    .frame(width: 18, height: 18)
                    .scaleEffect(pulsing ? 1.2 : 0.5)
                    .opacity(pulsing ? 0 : 1)
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 10, height: 10)
                    .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 2))
                    .shadow(color: Color.accentColor.opacity(0.6), radius: 3)
            }
            .frame(width: TimelineMetrics.capsuleWidth)
            .scaleEffect(arrived ? 1 : 0.3)
            .opacity(arrived ? 1 : 0)
            LinearGradient(colors: [Color.accentColor.opacity(0.4), Color.accentColor.opacity(0)], startPoint: .leading, endPoint: .trailing)
                .frame(height: 1)
                .scaleEffect(x: arrived ? 1 : 0, anchor: .leading)
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background { TimelineTrack(node: node) }
        .onAppear {
            withAnimation(.spring(duration: 0.5, bounce: 0.35).delay(node.reveal.fill.delay)) { arrived = true }
            withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false).delay(node.reveal.fill.delay + 0.4)) { pulsing = true }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tr("现在 \(DateText.time(now))", "Now \(DateText.time(now))"))
    }
}

/// Free time between two tasks: a longer stretch of line with a quiet note.
private struct FreeTimeMarker: View {
    let minutes: Int
    let node: TimelineNode

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "cup.and.saucer")
                .imageScale(.small)
            Text(tr("空闲 \(DateText.duration(minutes))", "\(DateText.duration(minutes)) free"))
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.tertiary)
        .padding(.leading, TimelineMetrics.textX)
        .frame(maxWidth: .infinity, minHeight: TimelineMetrics.gapHeight(minutes: minutes), alignment: .leading)
        .background { TimelineTrack(node: node) }
        .accessibilityElement(children: .combine)
    }
}

/// Two tasks booked over the same time: a warning on the line, and one click to move the later
/// one to when the earlier one ends.
private struct OverlapMarker: View {
    let overlap: TodayTimeline.Overlap
    let node: TimelineNode

    @Environment(TaskStore.self) private var store
    @State private var hovering = false

    var body: some View {
        HStack(spacing: TimelineMetrics.spacing) {
            Color.clear.frame(width: TimelineMetrics.labelWidth)
            Image(systemName: "exclamationmark")
                .font(.system(size: 8, weight: .heavy))
                .foregroundStyle(.white)
                .frame(width: 14, height: 14)
                .background(Circle().fill(Color.orange))
                .frame(width: TimelineMetrics.capsuleWidth)
            Text(tr("与「\(overlap.otherTitle)」重叠 \(DateText.duration(overlap.minutes))", "Overlaps “\(overlap.otherTitle)” by \(DateText.duration(overlap.minutes))"))
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Color.orange)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.leading, 2)
            Spacer(minLength: 4)
            Button {
                Haptics.tick()
                withAnimation(.snappy) { store.startAfter(overlap.taskID, at: overlap.freeAt) }
            } label: {
                Text(tr("顺延到 \(DateText.time(overlap.freeAt))", "Start at \(DateText.time(overlap.freeAt))"))
                    .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Color.orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.orange.opacity(hovering ? 0.22 : 0.13)))
                    .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(tr("把后一项移到前一项结束时开始，时长不变", "Move the later task to start when the earlier one ends, keeping its length"))
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background { TimelineTrack(node: node) }
        .accessibilityElement(children: .contain)
    }
}

/// Where the timed part ends and the "whenever" tasks begin.
private struct AnytimeMarker: View {
    let node: TimelineNode

    var body: some View {
        HStack(spacing: TimelineMetrics.spacing) {
            Text(tr("随时", "Anytime"))
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(width: TimelineMetrics.labelWidth, alignment: .trailing)
            Circle()
                .strokeBorder(Color.primary.opacity(0.3), lineWidth: 1.5)
                .frame(width: 8, height: 8)
                .frame(width: TimelineMetrics.capsuleWidth)
            Spacer()
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background { TimelineTrack(node: node) }
    }
}
