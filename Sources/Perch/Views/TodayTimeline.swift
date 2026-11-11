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
    /// A capsule this tall has room for its end time at its foot.
    static let endLabelHeight: CGFloat = 56

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

/// What the timeline's vertical axis means at one moment: which time sits at which height.
/// The timeline isn't to scale (free time is squeezed, capsules are capped), so a task being
/// dragged reads its new time off the rows it passes rather than off the distance moved.
struct TimelineRuler: Equatable {
    struct Mark: Equatable {
        var y: CGFloat
        var time: Date
    }

    private(set) var marks: [Mark]

    /// Past the first and last mark there is nothing to read from: a point is a minute.
    static let edgeRate = 60.0

    /// Marks are put in order down the axis; time never runs backwards along it, so where
    /// tasks overlap the later mark holds the time until the axis catches up.
    init(_ marks: [Mark]) {
        var latest = Date.distantPast
        self.marks = marks.sorted { ($0.y, $0.time) < ($1.y, $1.time) }.map { mark in
            latest = max(latest, mark.time)
            return Mark(y: mark.y, time: latest)
        }
    }

    func time(at y: CGFloat) -> Date? {
        guard let first = marks.first, let last = marks.last else { return nil }
        if y <= first.y { return first.time.addingTimeInterval(Double(y - first.y) * Self.edgeRate) }
        if y >= last.y { return last.time.addingTimeInterval(Double(y - last.y) * Self.edgeRate) }
        guard let upper = marks.firstIndex(where: { $0.y >= y }), upper > 0 else { return first.time }
        let a = marks[upper - 1], b = marks[upper]
        guard b.y > a.y else { return b.time }
        return a.time.addingTimeInterval(b.time.timeIntervalSince(a.time) * Double((y - a.y) / (b.y - a.y)))
    }

    /// How much time a point covers at this height, in seconds.
    func rate(at y: CGFloat) -> Double {
        guard let upper = marks.firstIndex(where: { $0.y >= y }), upper > 0 else { return Self.edgeRate }
        let a = marks[upper - 1], b = marks[upper]
        return b.y > a.y ? b.time.timeIntervalSince(a.time) / Double(b.y - a.y) : Self.edgeRate
    }

    /// Where a time sits on the axis (the first place, if the axis holds it for a stretch).
    func y(of time: Date) -> CGFloat? {
        guard let first = marks.first, let last = marks.last else { return nil }
        if time <= first.time { return first.y - CGFloat(first.time.timeIntervalSince(time) / Self.edgeRate) }
        if time > last.time { return last.y + CGFloat(time.timeIntervalSince(last.time) / Self.edgeRate) }
        guard let upper = marks.firstIndex(where: { $0.time >= time }), upper > 0 else { return first.y }
        let a = marks[upper - 1], b = marks[upper]
        return a.y + (b.y - a.y) * CGFloat(time.timeIntervalSince(a.time) / b.time.timeIntervalSince(a.time))
    }
}

/// Where the timeline's rows currently sit, so a drag can build its ruler. Plain storage: rows
/// write their frames in as they lay out, and nothing redraws because of it.
final class TimelineLayout {
    nonisolated static let space = "timeline"

    private enum Span {
        case task(start: Date, end: Date, height: CGFloat, isOpen: Bool)
        case now(Date)
        /// A turn of the day (morning, afternoon…) or the line's open or close.
        case point(Date)
    }

    var frames: [String: CGRect] = [:]
    private var spans: [String: Span] = [:]

    #if DEBUG
    /// The layout of the timeline last put on screen, for tests that drive a real one.
    nonisolated(unsafe) static weak var latest: TimelineLayout?
    init() { Self.latest = self }
    #endif

    func update(_ entries: [TodayTimeline.Entry], now: Date) {
        spans = [:]
        for entry in entries {
            switch entry.kind {
            case .task(let task, let node):
                guard let start = task.schedule?.time, let end = task.end else { continue }
                spans[entry.id] = .task(start: start, end: end, height: node.height, isOpen: !task.isDone)
            case .now:
                spans[entry.id] = .now(now)
            case .edge(_, let time, _):
                spans[entry.id] = .point(time)
            case .gap, .overlap, .anytime, .details:
                break
            }
        }
        frames = frames.filter { spans[$0.key] != nil }
    }

    /// Where times are already written in the time column: a task's start (and its end, when
    /// the capsule is tall enough to show it), "now", and the ends of the line.
    func writtenTimes() -> [CGFloat] {
        spans.flatMap { id, span -> [CGFloat] in
            guard let frame = frames[id] else { return [] }
            switch span {
            case .task(_, _, let height, _):
                // Tall capsules carry the start at the top and the end at the foot.
                guard height >= TimelineMetrics.endLabelHeight else { return [frame.midY] }
                return [frame.midY - height / 2 + 8, frame.midY + height / 2 - 8]
            case .now, .point:
                return [frame.midY]
            }
        }
    }

    /// The top of a task's capsule, which is the point that stands for its start.
    func capsuleTop(of id: String) -> CGFloat? {
        guard let frame = frames[id], case .task(_, _, let height, _)? = spans[id] else { return nil }
        return frame.midY - height / 2
    }

    /// Each capsule's top is its start and its foot its end; the "now" point is now, and each
    /// turn of the day its own time.
    func ruler() -> TimelineRuler {
        TimelineRuler(spans.flatMap { id, span -> [TimelineRuler.Mark] in
            guard let frame = frames[id] else { return [] }
            switch span {
            case .task(let start, let end, let height, _):
                return [.init(y: frame.midY - height / 2, time: start), .init(y: frame.midY + height / 2, time: end)]
            case .now(let time), .point(let time):
                return [.init(y: frame.midY, time: time)]
            }
        })
    }

    /// Start times a task of this length would want to click into as it passes: right after
    /// another task, right up against the next one, or now.
    func magnets(for id: String, minutes: Int) -> [Date] {
        spans.flatMap { other, span -> [Date] in
            guard other != id else { return [] }
            switch span {
            case .task(let start, let end, _, let isOpen):
                return isOpen ? [end, start.addingTimeInterval(-Double(minutes) * 60)] : []
            case .now(let now):
                return [Date(timeIntervalSince1970: (now.timeIntervalSince1970 / 60).rounded(.up) * 60)]
            case .point:
                return []
            }
        }
    }
}

/// Dragging on the timeline: a task picked up and carried along the line takes the time of
/// wherever its capsule's top is set down; its foot changes how long it lasts. Times snap to
/// five minutes, or to the edge of a neighbouring task, and stay within the task's day.
struct TimelineDrag: Equatable {
    enum Mode: Equatable { case move, resize }

    struct Result: Equatable {
        var start: Date
        var minutes: Int
    }

    var mode: Mode
    /// Vertical distance dragged, in points.
    var translation: CGFloat
    /// Where the capsule's top was when the drag began, on the ruler's axis.
    var origin: CGFloat = 0
    /// The axis as it stood when the drag began. Without one, a point is a minute.
    var ruler: TimelineRuler?
    var magnets: [Date] = []

    static let step = 5
    /// How close, in points, the capsule comes to a neighbour's edge before it clicks into it.
    static let magnetReach: CGFloat = 5

    /// Resizing follows the capsule's own growth (0.6pt a minute), so its foot stays under
    /// the pointer.
    func result(start: Date, minutes: Int, calendar: Calendar) -> Result {
        let dayStart = calendar.startOfDay(for: start)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400)
        switch mode {
        case .move:
            let grid = Double(Self.step * 60)
            let latest = max(dayStart, dayEnd.addingTimeInterval(-Double(minutes) * 60))
            func kept(_ date: Date) -> Result { Result(start: min(max(date, dayStart), latest), minutes: minutes) }
            let y = origin + translation
            if let magnet = magnet(at: y) { return kept(magnet) }
            let moved = ruler?.time(at: y) ?? start.addingTimeInterval(Double(translation.rounded()) * 60)
            // Across squeezed free time a point is many minutes: settle on quarter hours there.
            let coarse = (ruler?.rate(at: y) ?? 0) > 180
            // Counted from midnight, so the steps fall on the clock's own round numbers.
            let step = coarse ? grid * 3 : grid
            let sinceMidnight = (moved.timeIntervalSince(dayStart) / step).rounded() * step
            return kept(dayStart.addingTimeInterval(sinceMidnight))
        case .resize:
            let raw = Double(minutes) + Double(translation) / 0.6
            let snapped = Int((raw / Double(Self.step)).rounded()) * Self.step
            let room = max(Self.step, Int(dayEnd.timeIntervalSince(start) / 60))
            return Result(start: start, minutes: min(max(snapped, Self.step), room))
        }
    }

    /// Where the task is drawn, relative to where it was picked up: under the pointer, except
    /// that it clicks flush against a neighbour's edge when it comes within reach of one.
    var shownTranslation: CGFloat {
        guard mode == .move, let ruler, let magnet = magnet(at: origin + translation),
              let y = ruler.y(of: magnet) else { return translation }
        return y - origin
    }

    /// The nearest neighbour's edge within reach of the capsule's top, if any.
    private func magnet(at y: CGFloat) -> Date? {
        guard let ruler else { return nil }
        return magnets
            .compactMap { time in ruler.y(of: time).map { (time: time, distance: abs($0 - y)) } }
            .filter { $0.distance <= Self.magnetReach }
            .min { $0.distance < $1.distance }?
            .time
    }
}

/// How much of the day the timeline spans as a rule, in minutes after midnight
/// (Settings › Tasks).
struct TimelineDay: Equatable {
    var start: Int
    var end: Int
}

/// The two ends of the line: where the day as set opens and closes.
enum TimelineEdge: Equatable {
    case open, close
}

/// Morning, afternoon and evening, named quietly in the time column.
enum DayParts {
    /// A part of the day, in minutes after midnight.
    struct Part: Equatable {
        var start: Int
        var end: Int
        var title: String
    }

    static var parts: [Part] {
        [
            Part(start: 0, end: 12 * 60, title: tr("上午", "AM")),
            Part(start: 12 * 60, end: 18 * 60, title: tr("下午", "PM")),
            Part(start: 18 * 60, end: 24 * 60, title: tr("晚上", "Eve")),
        ]
    }

    /// Where to write a part's name in the time column: the first height inside its stretch
    /// of the line, from the top, that's clear of every time already written there. A task
    /// running across noon gets "afternoon" written beside it, below its start time.
    static func labelY(start: CGFloat, end: CGFloat, clearOf taken: [CGFloat], room: CGFloat = 12) -> CGFloat? {
        var y = start + 7
        while y <= end - 4 {
            if !taken.contains(where: { abs($0 - y) < room }) { return y }
            y += 2
        }
        return nil
    }
}

/// The task picked up on the timeline. It is drawn above the other rows, which fade back while
/// it is carried; once let go it keeps its place on top until it has settled into its slot.
struct TimelineLift: Equatable {
    var id: UUID
    var isSettling = false
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
    @AppStorage(Pref.timelineStart) private var dayStart = 7 * 60
    @AppStorage(Pref.timelineEnd) private var dayEnd = 23 * 60

    @State private var layout = TimelineLayout()
    /// The task being carried along the line, drawn above the rows it passes.
    @State private var lifted: TimelineLift?
    /// The rows' times by height, and where times are written, for the day's part names.
    @State private var sky = Sky()
    @Environment(PanelModel.self) private var model: PanelModel?

    private struct Sky: Equatable {
        var marks: [TimelineRuler.Mark] = []
        var written: [CGFloat] = []
    }

    private var lift: TimelineLift? {
        #if DEBUG
        if let debug = TaskRow.debugDrag, debug.drag.mode == .move { return TimelineLift(id: debug.id) }
        #endif
        return lifted
    }

    private func isLifted(_ task: TaskItem) -> Bool { lift?.id == task.id }

    /// Everything but the task being carried, while it is in the air.
    private func fadesBack(_ entry: Entry) -> Bool {
        guard let lift, !lift.isSettling else { return false }
        if case .task(let task, _) = entry.kind { return task.id != lift.id }
        return true
    }

    var body: some View {
        let _ = (defaultColor, topicColors)
        let entries = Self.entries(for: tasks, now: now, day: TimelineDay(start: dayStart, end: dayEnd), expanded: model?.expandedTaskID)
        let _ = layout.update(entries, now: now)
        VStack(alignment: .leading, spacing: 1) {
            rows(entries)
        }
        .background {
            DayPartLabels(marks: sky.marks, written: sky.written, midnight: AppSettings.shared.calendar.startOfDay(for: now))
        }
        .coordinateSpace(.named(TimelineLayout.space))
    }

    /// Notes where a row sits, for drags and for the day's part names.
    private func measured(_ id: String, _ frame: CGRect) {
        layout.frames[id] = frame
        let next = Sky(marks: layout.ruler().marks, written: layout.writtenTimes().sorted())
        if next != sky { sky = next }
    }

    @ViewBuilder
    private func rows(_ entries: [Entry]) -> some View {
        ForEach(entries) { entry in
            switch entry.kind {
            case .task(let task, let node):
                TaskRow(task: task, now: now, timeline: node, layout: layout, lifted: $lifted)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(TimelineLayout.space)) } action: { measured(entry.id, $0) }
                    .opacity(fadesBack(entry) ? 0.3 : 1)
                    .zIndex(isLifted(task) ? 1 : 0)
                    .transition(.asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .opacity.combined(with: .scale(scale: 0.96, anchor: .leading))
                    ))
            case .now(let node):
                NowMarker(now: now, node: node)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(TimelineLayout.space)) } action: { measured(entry.id, $0) }
                    .opacity(fadesBack(entry) ? 0.3 : 1)
            case .gap(let from, let to, let node):
                FreeTimeMarker(from: from, to: to, now: now, node: node)
                    .opacity(fadesBack(entry) ? 0.3 : 1)
            case .overlap(let overlap, let node):
                OverlapMarker(overlap: overlap, node: node)
                    .opacity(fadesBack(entry) ? 0.3 : 1)
            case .anytime(let node):
                AnytimeMarker(node: node)
                    .opacity(fadesBack(entry) ? 0.3 : 1)
            case .details(let task, let node):
                // Picked up, the task leaves its details behind, out of sight.
                TimelineDetailsRow(task: task, node: node)
                    .opacity(isLifted(task) && lift?.isSettling == false ? 0 : fadesBack(entry) ? 0.3 : 1)
                    .transition(.opacity.combined(with: .offset(y: -4)))
            case .edge(let edge, let time, let node):
                DayEdgeMarker(edge: edge, time: time, node: node)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(TimelineLayout.space)) } action: { measured(entry.id, $0) }
                    .opacity(fadesBack(entry) ? 0.3 : 1)
                    .transition(.opacity)
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
            case gap(from: Date, to: Date, TimelineNode)
            case overlap(Overlap, TimelineNode)
            case anytime(TimelineNode)
            case edge(TimelineEdge, Date, TimelineNode)
            /// An opened task's checklist and notes, under it on the line.
            case details(TaskItem, TimelineNode)
        }

        let id: String
        var kind: Kind

        var node: TimelineNode {
            get {
                switch kind {
                case .task(_, let node), .now(let node), .gap(_, _, let node), .overlap(_, let node), .anytime(let node),
                     .edge(_, _, let node), .details(_, let node): node
                }
            }
            set {
                switch kind {
                case .task(let task, _): kind = .task(task, newValue)
                case .now: kind = .now(newValue)
                case .gap(let from, let to, _): kind = .gap(from: from, to: to, newValue)
                case .overlap(let overlap, _): kind = .overlap(overlap, newValue)
                case .anytime: kind = .anytime(newValue)
                case .edge(let edge, let time, _): kind = .edge(edge, time, newValue)
                case .details(let task, _): kind = .details(task, newValue)
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
        case edge(TimelineEdge, Date)
        case details(TaskItem)

        /// Where the item starts and ends in time; nil for untimed items.
        var span: (start: Date, end: Date)? {
            switch self {
            case .task(let task): task.schedule?.time.flatMap { start in task.end.map { (start, $0) } }
            case .now: nil
            case .gap(let from, let to): (from, to)
            case .edge(_, let time): (time, time)
            // Held at the task's end, like free time starting there.
            case .details(let task): task.end.map { ($0, $0) }
            case .overlap, .anytime: nil
            }
        }

        var isUntimed: Bool {
            switch self {
            case .task(let task), .details(let task): !task.hasTime
            case .anytime: true
            case .now, .gap, .overlap, .edge: false
            }
        }
    }

    /// Where the line opens and closes. It runs at least across the day as set (stretched to the
    /// hour to take in any task outside it), so a task can be carried anywhere in the day along
    /// it, not off into empty space.
    static func span(for timed: [TaskItem], day: TimelineDay?, now: Date) -> (open: Date, close: Date)? {
        guard let day, let first = timed.compactMap(\.schedule?.time).min(), let last = timed.compactMap(\.end).max() else { return nil }
        let cal = AppSettings.shared.calendar
        let midnight = cal.startOfDay(for: now)
        func at(_ minutes: Int) -> Date { midnight.addingTimeInterval(Double(minutes) * 60) }
        let hour = 3600.0
        let earliest = Date(timeIntervalSince1970: (first.timeIntervalSince1970 / hour).rounded(.down) * hour)
        let latest = Date(timeIntervalSince1970: (last.timeIntervalSince1970 / hour).rounded(.up) * hour)
        let open = max(midnight, min(at(day.start), earliest))
        let close = min(at(24 * 60), max(at(day.end), latest))
        return close > open ? (open, close) : nil
    }

    static func entries(for tasks: [TaskItem], now: Date, day: TimelineDay? = nil, expanded: UUID? = nil) -> [Entry] {
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
        var nowJustPlaced = false
        var lastEnd: Date?
        var lastOwner: TaskItem?
        let span = span(for: timed, day: day, now: now)
        var edges: ArraySlice<(TimelineEdge, Date)> = span.map { [(.open, $0.open), (.close, $0.close)][...] } ?? []

        func placeNow(before time: Date) {
            guard !placedNow, time > now else { return }
            items.append(.now)
            placedNow = true
            nowJustPlaced = true
        }
        // Free time is only noted between two fixed points, not up to or away from "now".
        func noteFreeTime(until time: Date) {
            guard !nowJustPlaced, let lastEnd, time.timeIntervalSince(lastEnd) >= Double(TimelineMetrics.gapThreshold * 60) else { return }
            items.append(.gap(from: lastEnd, to: time))
        }
        func placeEdges(through time: Date) {
            while let (edge, at) = edges.first, at <= time {
                edges.removeFirst()
                placeNow(before: at)
                noteFreeTime(until: at)
                items.append(.edge(edge, at))
                nowJustPlaced = false
                lastEnd = max(lastEnd ?? at, at)
            }
        }

        for task in timed {
            guard let start = task.schedule?.time, let end = task.end else { continue }
            placeEdges(through: start)
            placeNow(before: start)
            if let lastEnd, let owner = lastOwner, start < lastEnd {
                // Booked over something still running. Only worth flagging while both are open.
                let minutes = Int(min(lastEnd, end).timeIntervalSince(start) / 60)
                if !task.isDone, !owner.isDone, minutes >= 1 {
                    items.append(.overlap(Overlap(minutes: minutes, taskID: task.id, freeAt: lastEnd, otherTitle: owner.title)))
                }
            } else {
                noteFreeTime(until: start)
            }
            items.append(.task(task))
            if task.id == expanded { items.append(.details(task)) }
            nowJustPlaced = false
            if end > (lastEnd ?? .distantPast) {
                lastEnd = end
                lastOwner = task
            }
        }
        placeEdges(through: .distantFuture)
        if !placedNow { items.append(.now) }
        if !untimed.isEmpty {
            if !timed.isEmpty { items.append(.anytime) }
            items += untimed.flatMap { task in task.id == expanded ? [Item.task(task), .details(task)] : [.task(task)] }
        }

        // Colors along the line: each task's own; markers borrow from their neighbours.
        let accent = Color.accentColor
        let ownColors: [Color?] = items.map { item in
            switch item {
            case .task(let task), .details(let task): task.tint.color
            case .now: accent
            case .gap, .overlap, .anytime, .edge: nil
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
            case .details(let task):
                node.height = 0
                return Entry(id: "details-\(task.id)", kind: .details(task, node))
            case .edge(let edge, let time):
                node.height = DayEdgeMarker.dot
                node.start = time
                return Entry(id: "edge-\(edge)", kind: .edge(edge, time, node))
            case .gap(let from, let to):
                node.height = 0
                return Entry(id: "gap-\(from.timeIntervalSince1970)", kind: .gap(from: from, to: to, node))
            case .overlap(let overlap):
                node.height = 12
                return Entry(id: "overlap-\(overlap.taskID)", kind: .overlap(overlap, node))
            case .task(let task):
                if let start = task.schedule?.time, let end = task.end {
                    node.height = TimelineMetrics.capsuleHeight(minutes: task.minutes)
                    node.start = start
                    node.end = node.height >= TimelineMetrics.endLabelHeight ? end : nil
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
            case .now, .edge:
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
    /// Set while the task is being dragged: the start time stands out in the task's color.
    var accent: Color?

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            if let start = node.start {
                time(start, size: node.isCollapsed ? 10.5 : 11, weight: accent != nil ? .bold : node.isCollapsed ? .regular : .medium)
                    .foregroundStyle(accent.map { AnyShapeStyle($0) } ?? (node.isLate ? AnyShapeStyle(Color.red.opacity(0.85)) : node.isCollapsed ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary)))
                    .padding(.top, node.end == nil ? 0 : 2)
            }
            if let end = node.end {
                Spacer(minLength: 0)
                time(end, size: 10, weight: accent != nil ? .semibold : .regular)
                    .foregroundStyle(accent.map { AnyShapeStyle($0.opacity(0.7)) } ?? AnyShapeStyle(.tertiary))
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

/// Where the line starts or stops: the time, a small dot, and a word for the hour.
struct DayEdgeMarker: View {
    static let dot: CGFloat = 8

    let edge: TimelineEdge
    let time: Date
    let node: TimelineNode

    private var minutes: Double {
        time.timeIntervalSince(AppSettings.shared.calendar.startOfDay(for: time)) / 60
    }

    private var greeting: String {
        if edge == .close { return tr("晚安", "Good night") }
        return minutes < 11 * 60 ? tr("早安", "Good morning")
            : minutes < 18 * 60 ? tr("午安", "Good afternoon") : tr("晚上好", "Good evening")
    }

    var body: some View {
        HStack(spacing: TimelineMetrics.spacing) {
            Text(DateText.time(time))
                .font(.system(size: 10, weight: .medium, design: .rounded).monospacedDigit())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: TimelineMetrics.labelWidth, alignment: .trailing)
            Circle()
                .fill(Color.primary.opacity(0.28))
                .frame(width: Self.dot, height: Self.dot)
                .frame(width: TimelineMetrics.capsuleWidth)
            Text(greeting)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.tertiary)
                .padding(.leading, 2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background { TimelineTrack(node: node) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(greeting) \(DateText.time(time))")
    }
}

/// The parts of the day, each named in the time column at the first clear spot of its stretch
/// of the line, read off the same ruler a drag uses: a task running across noon gets
/// "afternoon" written beside it, under its start time.
struct DayPartLabels: View {
    let marks: [TimelineRuler.Mark]
    /// Heights where the time column already has a time.
    let written: [CGFloat]
    let midnight: Date

    var body: some View {
        let ruler = TimelineRuler(marks)
        ZStack(alignment: .topLeading) {
            if let first = ruler.marks.first, let last = ruler.marks.last, first.time < last.time {
                ForEach(labels(ruler, from: first, to: last), id: \.part.start) { label in
                    Text(label.part.title)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .fixedSize()
                        .frame(width: TimelineMetrics.labelWidth, alignment: .trailing)
                        .position(x: 8 + TimelineMetrics.labelWidth / 2, y: label.y)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private struct Label {
        var part: DayParts.Part
        var y: CGFloat
    }

    private func labels(_ ruler: TimelineRuler, from first: TimelineRuler.Mark, to last: TimelineRuler.Mark) -> [Label] {
        var taken = written
        return DayParts.parts.compactMap { part in
            let start = max(midnight.addingTimeInterval(Double(part.start) * 60), first.time)
            let end = min(midnight.addingTimeInterval(Double(part.end) * 60), last.time)
            guard start < end, let top = ruler.y(of: start), let bottom = ruler.y(of: end),
                  let y = DayParts.labelY(start: top, end: bottom, clearOf: taken) else { return nil }
            taken.append(y)
            return Label(part: part, y: y)
        }
    }
}

/// Free time between two tasks: a longer stretch of line with a quiet note. Hovering shows a
/// ghost capsule on the line; clicking puts the slot's time into the add field, ready for a title.
private struct FreeTimeMarker: View {
    let from: Date
    let to: Date
    let now: Date
    let node: TimelineNode

    @Environment(PanelModel.self) private var model
    @State private var hovering = false

    private var minutes: Int { Int(to.timeIntervalSince(from) / 60) }

    var body: some View {
        Button(action: fill) {
            HStack(spacing: TimelineMetrics.spacing) {
                Color.clear.frame(width: TimelineMetrics.labelWidth)
                Capsule(style: .circular)
                    .strokeBorder(Color.accentColor.opacity(0.55), style: StrokeStyle(lineWidth: 1.2, dash: [3, 3]))
                    .background(Capsule(style: .circular).fill(Color.accentColor.opacity(0.08)))
                    .overlay {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.accentColor)
                    }
                    .frame(width: 22, height: 22)
                    .frame(width: TimelineMetrics.capsuleWidth)
                    .scaleEffect(hovering ? 1 : 0.6)
                    .opacity(hovering ? 1 : 0)
                HStack(spacing: 4) {
                    Image(systemName: hovering ? "plus.circle" : "cup.and.saucer")
                        .imageScale(.small)
                        .contentTransition(.symbolEffect(.replace))
                    Text(hovering ? tr("在 \(DateText.time(slot.start)) 加一项", "Add at \(DateText.time(slot.start))") : tr("空闲 \(DateText.duration(minutes))", "\(DateText.duration(minutes)) free"))
                        .contentTransition(.opacity)
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(hovering ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                .padding(.leading, 2)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: max(TimelineMetrics.gapHeight(minutes: minutes), 26), alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .background { TimelineTrack(node: node) }
        .onHover { hovering in withAnimation(.spring(duration: 0.25, bounce: 0.3)) { self.hovering = hovering } }
        .help(tr("在这段空闲里添加任务", "Add a task in this free time"))
        .accessibilityLabel(tr("空闲 \(DateText.duration(minutes))，添加任务", "\(DateText.duration(minutes)) free, add a task"))
    }

    /// From the start of the gap (or now, if it's already begun), up to an hour.
    private var slot: (start: Date, minutes: Int) {
        let grid = 5.0 * 60
        let rounded = Date(timeIntervalSince1970: (now.timeIntervalSince1970 / grid).rounded(.up) * grid)
        let start = from < now && rounded < to ? rounded : from
        let room = Int(to.timeIntervalSince(start) / 60)
        return (start, max(min(room, 60), 5))
    }

    private func fill() {
        let cal = AppSettings.shared.calendar
        let slot = slot
        func clock(_ date: Date) -> String {
            let c = cal.dateComponents([.hour, .minute], from: date)
            return String(format: "%d:%02d", c.hour ?? 0, c.minute ?? 0)
        }
        let end = slot.start.addingTimeInterval(Double(slot.minutes) * 60)
        Haptics.tick()
        // "今天" keeps a slot earlier in the day from being read as tomorrow's.
        model.prefill = tr("今天 ", "today ") + "\(clock(slot.start))-\(clock(end)) "
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

/// An opened task's checklist and notes, lined up under its title with the line running on
/// beside them.
private struct TimelineDetailsRow: View {
    let task: TaskItem
    let node: TimelineNode

    var body: some View {
        TaskDetails(task: task, tint: task.priority == .none ? task.tint.color : task.priority.tint)
            .padding(.leading, TimelineMetrics.textX - 4)
            .padding(.trailing, 8)
            .padding(.bottom, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { TimelineTrack(node: node) }
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
