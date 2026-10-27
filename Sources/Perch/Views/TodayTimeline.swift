import SwiftUI

/// Where a row sits on the Today timeline and how the line looks on either side of its node.
struct TimelineNode: Equatable {
    enum Segment: Equatable {
        case none
        /// Before "now": drawn in the accent color.
        case elapsed
        /// Still ahead: a quiet line.
        case ahead
        /// Untimed tasks: dashed.
        case anytime
    }

    var time: String?
    var hint: String?
    var isLate = false
    var above: Segment = .none
    var below: Segment = .none
    /// Position in the list, used to stagger the line growing in.
    var order = 0
}

enum TimelineMetrics {
    static let labelWidth: CGFloat = 40
    /// Row padding + label + spacing + half of the 26pt checkbox.
    static let lineX: CGFloat = 8 + labelWidth + 8 + 13
}

/// Today's open tasks threaded on a vertical line: timed ones in order with a live "now" marker
/// between past and upcoming, untimed ones after it on a dashed stretch.
struct TodayTimeline: View {
    let tasks: [TaskItem]
    let now: Date

    var body: some View {
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
            case .anytime(let node):
                AnytimeMarker(node: node)
            }
        }
    }

    struct Entry: Identifiable {
        enum Kind {
            case task(TaskItem, TimelineNode)
            case now(TimelineNode)
            case anytime(TimelineNode)
        }

        let id: String
        let kind: Kind
    }

    static func entries(for tasks: [TaskItem], now: Date) -> [Entry] {
        let timed = tasks.filter(\.hasTime).sorted { ($0.schedule?.time ?? now) < ($1.schedule?.time ?? now) }
        let untimed = tasks.filter { !$0.hasTime }

        enum Item { case task(TaskItem), now, anytime }
        var items: [Item] = []
        let firstAhead = timed.firstIndex { ($0.schedule?.time ?? now) > now } ?? timed.count
        items += timed[..<firstAhead].map(Item.task)
        items.append(.now)
        items += timed[firstAhead...].map(Item.task)
        if !untimed.isEmpty {
            if !timed.isEmpty { items.append(.anytime) }
            items += untimed.map(Item.task)
        }

        // The segment leaving each item, which is also the one arriving at the next.
        func outgoing(_ item: Item, isLast: Bool) -> TimelineNode.Segment {
            if isLast { return .none }
            switch item {
            case .now: return timed.count > firstAhead ? .ahead : .anytime
            case .anytime: return .anytime
            case .task(let task):
                guard let time = task.schedule?.time else { return .anytime }
                if time <= now { return .elapsed }
                return task.id == timed.last?.id ? .anytime : .ahead
            }
        }

        let nextUp = timed.indices.contains(firstAhead) ? timed[firstAhead].id : nil
        var previous = TimelineNode.Segment.none
        return items.enumerated().map { index, item in
            let below = outgoing(item, isLast: index == items.count - 1)
            defer { previous = below }
            switch item {
            case .now:
                return Entry(id: "now", kind: .now(TimelineNode(above: previous, below: below, order: index)))
            case .anytime:
                return Entry(id: "anytime", kind: .anytime(TimelineNode(above: previous, below: below, order: index)))
            case .task(let task):
                let time = task.schedule?.time
                let node = TimelineNode(
                    time: time.map(DateText.time),
                    hint: task.id == nextUp ? time.map { countdown(to: $0, from: now) } : nil,
                    isLate: time.map { $0 <= now } ?? false,
                    above: previous,
                    below: below,
                    order: index
                )
                return Entry(id: task.id.uuidString, kind: .task(task, node))
            }
        }
    }

    private static func countdown(to date: Date, from now: Date) -> String {
        let minutes = max(1, Int((date.timeIntervalSince(now) / 60).rounded(.up)))
        if minutes < 60 { return tr("\(minutes) 分钟后", "in \(minutes)m") }
        let hours = minutes / 60, rest = minutes % 60
        if rest == 0 { return tr("\(hours) 小时后", "in \(hours)h") }
        return tr("\(hours)小时\(rest)分后", "in \(hours)h \(rest)m")
    }
}

/// The time column to the left of a node.
struct TimelineLabel: View {
    let node: TimelineNode

    var body: some View {
        VStack(alignment: .trailing, spacing: 1) {
            if let time = node.time {
                Text(time)
                    .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(node.isLate ? Color.red.opacity(0.9) : .primary.opacity(0.75))
            }
            if let hint = node.hint {
                Text(hint)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .frame(width: TimelineMetrics.labelWidth, alignment: .trailing)
    }
}

/// The line through a row: one segment above the node, one below, each growing in from the top.
struct TimelineTrack: View {
    let node: TimelineNode
    /// Gap kept clear around the node.
    let nodeRadius: CGFloat

    @State private var grown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let middle = geometry.size.height / 2
            ZStack(alignment: .topLeading) {
                segment(node.above, from: -0.5, to: middle - nodeRadius, grownFraction: grown ? 1 : 0)
                segment(node.below, from: middle + nodeRadius, to: geometry.size.height + 0.5, grownFraction: grown ? 1 : 0)
                    .animation(.easeOut(duration: 0.3).delay(stagger + 0.12), value: grown)
            }
        }
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.3).delay(stagger), value: grown)
        .animation(.easeInOut(duration: 0.6), value: node)
        .onAppear {
            if reduceMotion { grown = true } else { Task { grown = true } }
        }
    }

    private var stagger: Double { min(Double(node.order) * 0.07, 0.8) }

    @ViewBuilder
    private func segment(_ style: TimelineNode.Segment, from top: CGFloat, to bottom: CGFloat, grownFraction: CGFloat) -> some View {
        if style != .none, bottom > top {
            Path { path in
                path.move(to: CGPoint(x: TimelineMetrics.lineX, y: top))
                path.addLine(to: CGPoint(x: TimelineMetrics.lineX, y: bottom))
            }
            .trim(from: 0, to: grownFraction)
            .stroke(color(style), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: style == .anytime ? [2, 4] : []))
        }
    }

    private func color(_ style: TimelineNode.Segment) -> Color {
        switch style {
        case .elapsed: Color.accentColor.opacity(0.85)
        case .ahead: Color.primary.opacity(0.16)
        case .anytime, .none: Color.primary.opacity(0.22)
        }
    }
}

/// The live "now" point: a pulsing dot on the line with the current time.
private struct NowMarker: View {
    let now: Date
    let node: TimelineNode

    @State private var pulsing = false

    var body: some View {
        HStack(spacing: 8) {
            Text(tr("现在", "Now"))
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.accentColor)
                .frame(width: TimelineMetrics.labelWidth, alignment: .trailing)
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.25))
                    .frame(width: 16, height: 16)
                    .scaleEffect(pulsing ? 1.2 : 0.6)
                    .opacity(pulsing ? 0 : 1)
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 8, height: 8)
                    .shadow(color: Color.accentColor.opacity(0.6), radius: 3)
            }
            .frame(width: 26)
            LinearGradient(colors: [Color.accentColor.opacity(0.5), Color.accentColor.opacity(0)], startPoint: .leading, endPoint: .trailing)
                .frame(height: 1)
            Text(DateText.time(now))
                .font(.system(size: 10, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(Color.accentColor)
                .contentTransition(.numericText())
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background { TimelineTrack(node: node, nodeRadius: 6) }
        .onAppear {
            withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { pulsing = true }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Where the timed part ends and the "whenever" tasks begin.
private struct AnytimeMarker: View {
    let node: TimelineNode

    var body: some View {
        HStack(spacing: 8) {
            Text(tr("随时", "Anytime"))
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: TimelineMetrics.labelWidth, alignment: .trailing)
            Circle()
                .strokeBorder(Color.primary.opacity(0.3), lineWidth: 1.5)
                .frame(width: 8, height: 8)
                .frame(width: 26)
            Spacer()
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background { TimelineTrack(node: node, nodeRadius: 6) }
    }
}
