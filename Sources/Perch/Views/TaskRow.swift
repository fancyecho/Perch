import SwiftUI

struct TaskRow: View {
    enum Style { case regular, compact }

    let task: TaskItem
    let now: Date
    var style: Style = .regular
    /// Off when a section header already names the day.
    var showsDay = true
    /// Set when the row sits on the Today timeline.
    var timeline: TimelineNode?
    /// Where the timeline's rows sit, for reading a dragged task's new time off them.
    var layout: TimelineLayout?
    /// The task currently picked up, so the timeline can draw it above its neighbours.
    var lifted: Binding<TimelineLift?> = .constant(nil)

    @Environment(TaskStore.self) private var store
    @Environment(SwipeTracker.self) private var swipe
    @Environment(Feedback.self) private var feedback
    @State private var hovering = false
    @State private var completing = false
    @GestureState(resetTransaction: Transaction(animation: .spring(duration: 0.35, bounce: 0.25)))
    private var dragOffset: CGFloat = 0
    @State private var isEditing = false
    @State private var draft = ""
    @State private var editorFocusRequest = 0
    @State private var editingSchedule = false
    /// The task being carried to a new time, or stretched to a new length (timeline only).
    @State private var liveDrag: TimelineDrag?
    /// While dragging: how far the pointer has moved on screen, and where the list was scrolled
    /// when the drag began. The two together say how far along the timeline the task has gone.
    @State private var pointerTravel: CGFloat = 0
    @State private var scrollAtStart: CGFloat = 0
    @Environment(TimelineScroller.self) private var scroller: TimelineScroller?
    @Environment(PanelModel.self) private var model: PanelModel?
    @State private var hoveringCapsule = false
    @AppStorage(Pref.taskDefaultColor) private var defaultColor = TaskColor.coral.rawValue
    @AppStorage(Pref.taskTopicColors) private var topicColors = true

    #if DEBUG
    /// Lets a snapshot show a row mid-drag.
    static var debugDrag: (id: UUID, drag: TimelineDrag)?
    private var timeDrag: TimelineDrag? { liveDrag ?? (Self.debugDrag?.id == task.id ? Self.debugDrag?.drag : nil) }
    #else
    private var timeDrag: TimelineDrag? { liveDrag }
    #endif
    private var isMoving: Bool { timeDrag?.mode == .move }
    #if DEBUG
    /// Lets a snapshot show a row as it is under the pointer.
    static var debugHover: UUID?
    private var isHovered: Bool { hovering || Self.debugHover == task.id }
    #else
    private var isHovered: Bool { hovering }
    #endif

    private var offset: CGFloat { (swipe.rowID == task.id ? swipe.offset : 0) + dragOffset }
    private var isChecked: Bool { task.isDone || completing }
    private var isFocusTask: Bool { store.focus?.taskID == task.id }

    private var isExpanded: Bool { model?.isExpanded(task.id) ?? false }

    var body: some View {
        // On the timeline the details are a row of their own (see TodayTimeline), so the line
        // runs on past them; in a list they open up under the row.
        VStack(alignment: .leading, spacing: 0) {
            row
            if timeline == nil, style == .regular, isExpanded {
                TaskDetails(task: task, tint: task.priority.tint)
                    .padding(.leading, Self.listTextX - 4)
                    .padding(.trailing, 8)
                    .padding(.bottom, 2)
                    .transition(.opacity.combined(with: .offset(y: -4)))
            }
        }
    }

    /// Where a list row's title starts: padding, the checkbox and its touch margin, spacing.
    private static let listTextX: CGFloat = 8 + 18 + 8 + 8

    private var row: some View {
        // On the timeline only the text card slides (see timelineContent), so the capsule never
        // leaves the line.
        ZStack(alignment: offset >= 0 ? .leading : .trailing) {
            if offset != 0 && timeline == nil { swipeReveal }
            content
                .offset(x: timeline == nil ? offset : 0)
        }
        // The clip is for swipes; in the air it opens up so the capsule's shadow isn't cut off.
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous).inset(by: isMoving ? -24 : 0))
        // Picked up, the task itself slides along the line under the pointer (the rest of the
        // timeline fades back so it reads clearly over the rows it passes).
        .offset(y: isMoving ? timeDrag?.shownTranslation ?? 0 : 0)
        // Outside the clip, so the line can bridge the gap to the next row. It stays behind when
        // the row is picked up, with an outline of where the task was.
        .background {
            if let timeline {
                TimelineTrack(node: isMoving ? vacated(timeline) : dragged(timeline))
                if isMoving { originGhost(timeline) }
            }
        }
        .contentShape(.rect)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { self.hovering = hovering }
            swipe.hover(task.id, hovering)
        }
        .simultaneousGesture(dragToSwipe)
        // The list scrolling under a task being carried takes it further along the line.
        .onChange(of: liveDrag == nil ? nil : scroller?.offset) { _, scrolled in
            guard var drag = liveDrag, let scrolled else { return }
            drag.translation = pointerTravel + scrolled - scrollAtStart
            liveDrag = drag
        }
        .onChange(of: abs(offset) >= SwipeTracker.threshold) { Haptics.tick() }
        .contextMenu { TaskMenu(task: task, onEdit: beginEditing, onSchedule: { editingSchedule = true }) }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let timeline {
            timelineContent(timeline)
        } else {
            listContent
        }
    }

    /// How far a swipe has gone toward its threshold, 0…1, and which way.
    private var swipeFraction: CGFloat { min(abs(offset) / SwipeTracker.threshold, 1) }

    /// On the Today timeline: time column, capsule, then the text, with the checkbox at the end.
    /// A swipe moves only the text card: the time and capsule stay on the line, the capsule fills
    /// as a right swipe nears "done" and fades as a left swipe nears "tomorrow".
    private func timelineContent(_ base: TimelineNode) -> some View {
        let node = dragged(base)
        let completing = offset > 0
        let armed = swipeFraction >= 1
        return HStack(spacing: TimelineMetrics.spacing) {
            TimelineTimes(node: node, accent: timeDrag == nil ? nil : task.tint.color)
                .contentShape(.rect)
                .onTapGesture { if !isChecked { editingSchedule = true } }
                .gesture(retimeGesture(.move), including: canRetime(node) ? .all : .subviews)
            TimelineCapsule(
                tint: task.tint.color,
                glyph: completing && armed ? .symbol("checkmark") : task.glyph,
                progress: isChecked ? 1 : completing ? max(node.progress, swipeFraction) : node.progress,
                height: node.height,
                reveal: node.reveal.fill,
                interactive: offset != 0,
                width: node.isCollapsed ? TimelineMetrics.collapsedSize : TimelineMetrics.capsuleWidth
            )
            .overlay(alignment: .bottom) {
                if canRetime(node) { resizeHandle(node) }
            }
            // In the air it is solid, so the line and the capsules it passes don't show through.
            .background {
                if isMoving { Capsule(style: .circular).fill(Color(nsColor: .windowBackgroundColor)) }
            }
            .scaleEffect(isMoving ? 1.08 : 1)
            .shadow(color: task.tint.color.opacity(timeDrag == nil ? 0 : 0.4), radius: isMoving ? 8 : 5, y: isMoving ? 4 : 2)
            .contentShape(Capsule(style: .circular))
            .pointerStyle(canRetime(node) ? (isMoving ? .grabActive : .grabIdle) : .default)
            .onHover { hovering in withAnimation(.easeOut(duration: 0.15)) { hoveringCapsule = hovering } }
            .gesture(retimeGesture(.move), including: canRetime(node) ? .all : .subviews)
            .help(canRetime(node) ? tr("拖到新的时间，拖下边缘改时长", "Drag to a new time, drag the bottom edge to change the length") : "")
            .frame(width: TimelineMetrics.capsuleWidth)
            .opacity(offset < 0 ? 1 - 0.45 * swipeFraction : 1)
            .scaleEffect(offset < 0 ? 1 - 0.06 * swipeFraction : 1)
            .padding(.trailing, 2)
            .animation(.spring(duration: 0.3, bounce: 0.3), value: timeDrag?.mode)

            ZStack(alignment: completing ? .leading : .trailing) {
                if offset != 0 { timelineSwipeReveal(completing: completing, armed: armed) }
                timelineCard(node)
                    .offset(x: offset)
                    .opacity(1 - 0.35 * swipeFraction)
            }
            // Clipped only while it slides, so the rounded corner never shaves the edge of the
            // text at rest.
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous).inset(by: offset == 0 ? -12 : 0))
            // The text picks the task up too; a sideways drag is still a swipe.
            .simultaneousGesture(retimeGesture(.move, minimumDistance: 6), including: canRetime(node) ? .all : .subviews)
        }
        .padding(.top, node.isCollapsed ? 3 : 7)
        // Opened, its details follow straight on in the next row.
        .padding(.bottom, node.isCollapsed ? 3 : isExpanded ? 2 : 7)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity((hovering || offset != 0) && !isMoving ? 0.035 : 0))
        }
    }

    // MARK: - Dragging on the timeline

    private func canRetime(_ node: TimelineNode) -> Bool {
        task.hasTime && !isChecked && !node.isCollapsed && !isEditing && offset == 0
    }

    /// The node as it would be with the drag in progress applied: new times, a capsule as tall
    /// as the new length, and the detail line in the task's color.
    private func dragged(_ node: TimelineNode) -> TimelineNode {
        guard let drag = timeDrag, let result = dragResult(drag) else { return node }
        var node = node
        let end = result.start.addingTimeInterval(Double(result.minutes) * 60)
        node.start = result.start
        node.height = TimelineMetrics.capsuleHeight(minutes: result.minutes)
        node.end = node.height >= 44 ? end : nil
        node.hint = DateText.duration(result.minutes)
        node.detail = "\(DateText.time(result.start)) – \(DateText.time(end)) · \(DateText.duration(result.minutes))"
        node.isLate = false
        return node
    }

    /// The row's place on the line once the task has been lifted out of it: just the line.
    private func vacated(_ node: TimelineNode) -> TimelineNode {
        var node = node
        node.height = 0
        return node
    }

    /// A dashed outline where the task was picked up from.
    private func originGhost(_ node: TimelineNode) -> some View {
        let tint = task.tint.color
        return Capsule(style: .circular)
            .strokeBorder(tint.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            .frame(width: TimelineMetrics.capsuleWidth, height: node.height)
            .padding(.leading, TimelineMetrics.lineX - TimelineMetrics.capsuleWidth / 2)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .transition(.opacity)
            .allowsHitTesting(false)
    }

    private func dragResult(_ drag: TimelineDrag) -> TimelineDrag.Result? {
        guard let start = task.schedule?.time else { return nil }
        return drag.result(start: start, minutes: task.minutes, calendar: AppSettings.shared.calendar)
    }

    /// A short bar along the capsule's foot: grab it to stretch or shrink the task.
    private func resizeHandle(_ node: TimelineNode) -> some View {
        let active = timeDrag?.mode == .resize
        return Capsule()
            .fill(Color.white.opacity(active ? 0.95 : 0.8))
            .frame(width: active ? 14 : 10, height: 3)
            .shadow(color: .black.opacity(0.15), radius: 1, y: 0.5)
            .opacity(hoveringCapsule || active ? 1 : 0)
            .padding(.bottom, 4)
            .frame(width: TimelineMetrics.capsuleWidth, height: min(12, node.height / 2.5), alignment: .bottom)
            .contentShape(.rect)
            .pointerStyle(.frameResize(position: .bottom))
            .highPriorityGesture(retimeGesture(.resize))
    }

    private func retimeGesture(_ mode: TimelineDrag.Mode, minimumDistance: CGFloat = 2) -> some Gesture {
        // Measured on screen, not in the row: the row moves with the drag, and measuring in its
        // own space would feed that movement back into the drag and make it shake. Scrolling is
        // added on top, so a task carried to the edge keeps going as the list scrolls under it.
        DragGesture(minimumDistance: minimumDistance, coordinateSpace: .global)
            .onChanged { value in
                var next: TimelineDrag
                if let drag = liveDrag {
                    // The foot's own gesture outranks the capsule's, but not the text's.
                    guard drag.mode == mode else { return }
                    next = drag
                } else {
                    // Sideways is a swipe; only an up-or-down drag picks the task up.
                    guard offset == 0, abs(value.translation.height) > abs(value.translation.width) else { return }
                    next = beginDrag(mode)
                    scrollAtStart = scroller?.offset ?? 0
                }
                pointerTravel = value.translation.height
                next.translation = pointerTravel + (scroller?.offset ?? 0) - scrollAtStart
                // A soft detent at every step, and as the task clicks against a neighbour.
                if liveDrag.flatMap(dragResult) != dragResult(next) { Haptics.tick() }
                liveDrag = next
                scroller?.follow(pointer: value.location.y)
            }
            .onEnded { _ in
                guard let drag = liveDrag, drag.mode == mode else { return }
                scroller?.stop()
                let result = dragResult(drag)
                // One spring carries the card from where it was let go into its new slot.
                withAnimation(.spring(duration: 0.4, bounce: 0.18)) {
                    liveDrag = nil
                    if lifted.wrappedValue?.id == task.id { lifted.wrappedValue?.isSettling = true }
                    if let result { store.retime(task.id, start: result.start, minutes: result.minutes) }
                }
                // It stays on top until it has settled into its slot.
                Task {
                    try? await Task.sleep(for: .milliseconds(450))
                    if liveDrag == nil, lifted.wrappedValue?.id == task.id { lifted.wrappedValue = nil }
                }
            }
    }

    /// A drag starts by fixing the timeline as it stands, so the times under the pointer don't
    /// shift while the task is in the air.
    private func beginDrag(_ mode: TimelineDrag.Mode) -> TimelineDrag {
        var drag = TimelineDrag(mode: mode, translation: 0)
        let id = task.id.uuidString
        if mode == .move, let layout, let top = layout.capsuleTop(of: id) {
            drag.origin = top
            drag.ruler = layout.ruler()
            drag.magnets = layout.magnets(for: id, minutes: task.minutes)
        }
        if mode == .move {
            withAnimation(.easeOut(duration: 0.2)) { lifted.wrappedValue = TimelineLift(id: task.id) }
        }
        Haptics.confirm()
        return drag
    }

    /// The pill that opens up behind the sliding card: next to the capsule for "done", in the
    /// checkbox's place for "tomorrow".
    private func timelineSwipeReveal(completing: Bool, armed: Bool) -> some View {
        let width = max(abs(offset) - 8, 0)
        let color = completing ? Color.green : Color.orange
        return HStack(spacing: 4) {
            Image(systemName: completing ? "checkmark" : "arrow.turn.down.right")
                .font(.system(size: 11, weight: .bold))
                .scaleEffect(armed ? 1.15 : 0.9)
            if width > 70 {
                Text(completing ? tr("完成", "Done") : tr("明天", "Tomorrow"))
                    .font(.system(size: 11, weight: .semibold))
                    .transition(.opacity)
            }
        }
        .foregroundStyle(.white)
        .frame(width: width, height: 28)
        .background(Capsule(style: .circular).fill(color.opacity(armed ? 0.85 : 0.5)))
        .opacity(width > 18 ? 1 : 0)
        .animation(.spring(duration: 0.25, bounce: 0.5), value: armed)
        .animation(.easeOut(duration: 0.12), value: width > 70)
    }

    private func timelineCard(_ node: TimelineNode) -> some View {
        HStack(spacing: TimelineMetrics.spacing) {
            if node.isCollapsed {
                collapsedText(node)
            } else {
                expandedText(node)
            }

            Spacer(minLength: 4)

            hoverActions
                .frame(width: node.isCollapsed ? 0 : nil)
            CheckCircle(isOn: isChecked, tint: checkTint, size: node.isCollapsed ? 16 : 20, action: toggle)
                .frame(width: 20)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
    }

    /// A finished task in one line: the struck title, then its time in small print.
    private func collapsedText(_ node: TimelineNode) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(task.title)
                .font(.system(size: 12.5))
                .strikethrough(true)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .layoutPriority(1)
            if let detail = node.detail {
                Text(detail)
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            detailsHint
                .font(.system(size: 10.5))
                .opacity(isExpanded ? 1 : 0.7)
        }
        .transition(.opacity)
    }

    private func expandedText(_ node: TimelineNode) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let detail = node.detail {
                HStack(spacing: 4) {
                    Text(detail)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .contentTransition(.numericText())
                    if task.recurrence != nil {
                        Image(systemName: "repeat")
                            .imageScale(.small)
                            .help(task.recurrence?.title ?? "")
                    }
                }
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(detailColor(node))
            }
            title(weight: .medium, size: 13.5)
            tagLine
        }
        .transition(.opacity)
    }

    private func detailColor(_ node: TimelineNode) -> Color {
        // Lateness shows once, on the start time in the column.
        if isChecked || node.isLate { return .secondary }
        if node.hint != nil { return task.tint.color }
        return .secondary
    }

    /// High-priority tasks keep their flag color on the checkbox; the rest wear the task's own.
    private var checkTint: Color {
        task.priority == .none ? task.tint.color : task.priority.tint
    }

    /// "☑ 2/5" and a notes glyph, when the task has either.
    @ViewBuilder
    private var detailsHint: some View {
        if task.hasDetails {
            DetailsHint(task: task, tint: timeline == nil ? task.priority.tint : checkTint, isOpen: isExpanded) {
                withAnimation(.snappy) { model?.toggleDetails(task.id) }
            }
        }
    }

    /// Under the title: repeat, focus, the details hint and tags (the time line above has no room
    /// to spare for a hint while it counts down).
    @ViewBuilder
    private var tagLine: some View {
        let hint = task.hasDetails
        if !task.tags.isEmpty || isFocusTask || (task.recurrence != nil && !task.hasTime) || hint {
            HStack(spacing: 8) {
                if let recurrence = task.recurrence, !task.hasTime {
                    Label(recurrence.title, systemImage: "repeat")
                        .foregroundStyle(.secondary)
                }
                if isFocusTask {
                    Label(tr("专注中", "Focusing"), systemImage: "scope")
                        .foregroundStyle(Color.accentColor)
                }
                if hint { detailsHint }
                ForEach(task.tags, id: \.self) { tag in
                    Text("#\(tag)").foregroundStyle(task.tint.color)
                }
            }
            .font(.system(size: 11))
            .labelStyle(CompactLabelStyle())
            .lineLimit(1)
        }
    }

    @ViewBuilder
    private func title(weight: Font.Weight, size: CGFloat) -> some View {
        if isEditing {
            InputField(
                text: $draft,
                placeholder: tr("任务", "Task"),
                focusRequest: editorFocusRequest,
                focusOnAppear: true,
                onSubmit: { _ in commitEdit() },
                onCancel: { isEditing = false },
                onFocusChange: { focused in if !focused { commitEdit() } }
            )
        } else {
            Text(task.title)
                .font(.system(size: size, weight: isFocusTask ? .semibold : weight))
                .strikethrough(isChecked, color: .secondary)
                .foregroundStyle(isChecked ? .secondary : .primary)
                .lineLimit(style == .compact ? 1 : 2)
                .onTapGesture(count: 2, perform: beginEditing)
        }
    }

    private var listContent: some View {
        HStack(spacing: style == .compact ? 6 : 8) {
            CheckCircle(isOn: isChecked, tint: task.priority.tint, size: style == .compact ? 16 : 18, action: toggle)

            VStack(alignment: .leading, spacing: 2) {
                title(weight: .regular, size: 13)
                if style == .regular { metadata }
            }

            Spacer(minLength: 4)

            if style == .compact {
                if let label = DateText.dueLabel(task, now: now), task.hasTime || DateText.isOverdue(task, now: now) {
                    Text(label)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(DateText.isOverdue(task, now: now) ? Color.red : .secondary)
                }
            } else {
                // A fixed slot, so the title never re-wraps when the button fades in.
                hoverActions
            }
        }
        .padding(.vertical, style == .compact ? 4 : 6)
        .padding(.horizontal, style == .compact ? 6 : 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(hovering || offset != 0 ? 0.06 : 0))
        }
        .opacity(completing && style == .regular ? 0.75 : 1)
    }

    @ViewBuilder
    private var metadata: some View {
        let dueLabel = DateText.dueLabel(task, now: now)
        if dueLabel != nil || !task.tags.isEmpty || isFocusTask || task.recurrence != nil || task.hasDetails {
            HStack(spacing: 8) {
                if isFocusTask {
                    Label(tr("专注中", "Focusing"), systemImage: "scope")
                        .foregroundStyle(Color.accentColor)
                }
                if let dueLabel = showsDay ? dueLabel : task.schedule?.time.map(DateText.time),
                   task.hasTime || (showsDay && !DateText.isDueToday(task, now: now)) {
                    Button { editingSchedule = true } label: {
                        Label(dueLabel, systemImage: task.hasTime ? "clock" : "calendar")
                            .foregroundStyle(DateText.isOverdue(task, now: now) ? Color.red : .secondary)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .disabled(isChecked)
                    .help(tr("修改日期和时间", "Change date and time"))
                }
                if let recurrence = task.recurrence {
                    Label(recurrence.title, systemImage: "repeat")
                        .foregroundStyle(.secondary)
                }
                detailsHint
                ForEach(task.tags, id: \.self) { tag in
                    Text("#\(tag)").foregroundStyle(Color.accentColor.opacity(0.9))
                }
            }
            .font(.system(size: 11).monospacedDigit())
            .labelStyle(CompactLabelStyle())
            .lineLimit(1)
        }
    }

    /// The buttons that fade in on hover, each in a fixed slot so the title never re-wraps:
    /// steps and notes, then date and time.
    private var hoverActions: some View {
        let showsButtons = isHovered && !isChecked && !isEditing
        let showsDetails = showsButtons && model != nil
        let showsSchedule = showsButtons || editingSchedule
        return HStack(spacing: 0) {
            detailsButton
                .opacity(showsDetails ? 1 : 0)
                .allowsHitTesting(showsDetails)
            rescheduleButton
                .opacity(showsSchedule ? 1 : 0)
                .allowsHitTesting(showsSchedule)
        }
    }

    /// Opens the task to add steps or notes (straight into a new step when it has none yet),
    /// or folds it away again.
    private var detailsButton: some View {
        Button {
            withAnimation(.snappy) {
                if task.hasDetails || isExpanded {
                    model?.toggleDetails(task.id)
                } else {
                    model?.editDetails(task.id, .newSubtask)
                }
            }
        } label: {
            Image(systemName: "checklist")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.primary.opacity(isExpanded ? 0.1 : 0)))
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isExpanded ? Color.accentColor : .secondary)
        .help(isExpanded ? tr("收起子任务和备注", "Hide steps and notes")
            : task.hasDetails ? tr("显示子任务和备注", "Show steps and notes") : tr("添加子任务或备注", "Add steps or notes"))
    }

    private var rescheduleButton: some View {
        Button { editingSchedule.toggle() } label: {
            Image(systemName: task.hasTime ? "clock" : "calendar")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.primary.opacity(editingSchedule ? 0.1 : 0)))
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .foregroundStyle(editingSchedule ? Color.accentColor : .secondary)
        .help(tr("修改日期和时间", "Change date and time"))
        .popover(isPresented: $editingSchedule, arrowEdge: .bottom) {
            ScheduleEditor(taskID: task.id)
        }
    }

    private var swipeReveal: some View {
        let completes = offset > 0
        let armed = abs(offset) >= SwipeTracker.threshold
        return ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill((completes ? Color.green : Color.orange).opacity(armed ? 0.9 : 0.55))
            Image(systemName: completes ? "checkmark" : "arrow.turn.down.right")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .scaleEffect(armed ? 1.15 : 0.85)
                .animation(.spring(duration: 0.25, bounce: 0.5), value: armed)
        }
        .frame(width: max(abs(offset) - 4, 0))
        .frame(maxHeight: .infinity)
    }

    // MARK: - Actions

    private var dragToSwipe: some Gesture {
        DragGesture(minimumDistance: 14)
            .updating($dragOffset) { value, offset, _ in
                guard let x = swipeDistance(value) else { return }
                offset = x
            }
            .onEnded { value in
                guard let x = swipeDistance(value) else { return }
                if x >= SwipeTracker.threshold {
                    Haptics.confirm()
                    withAnimation(.snappy) { store.complete(task.id) }
                } else if x <= -SwipeTracker.threshold {
                    Haptics.confirm()
                    withAnimation(.snappy) { store.postponeToTomorrow(task.id) }
                }
            }
    }

    private func swipeDistance(_ value: DragGesture.Value) -> CGFloat? {
        guard style == .regular, !isEditing, timeDrag == nil, abs(value.translation.width) > abs(value.translation.height) else { return nil }
        return SwipeTracker.rubberBand(value.translation.width)
    }

    private func toggle() {
        if task.isDone {
            withAnimation(.snappy) { store.reopen(task.id) }
            return
        }
        guard !completing else { return }
        Haptics.confirm()
        feedback.taskChecked()
        completing = true
        let id = task.id
        Task {
            try? await Task.sleep(for: .milliseconds(520))
            withAnimation(.snappy(duration: 0.35)) { store.complete(id, playsSound: false) }
        }
    }

    private func beginEditing() {
        guard style == .regular, !task.isDone else { return }
        draft = task.title
        isEditing = true
        editorFocusRequest += 1
    }

    private func commitEdit() {
        guard isEditing else { return }
        isEditing = false
        store.rename(task.id, to: draft)
    }
}

private struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

struct ScheduleMenuItems: View {
    let task: TaskItem
    @Environment(TaskStore.self) private var store

    var body: some View {
        let today = DateText.today(.now)
        Button(tr("今天", "Today")) { set(today) }
        Button(tr("明天", "Tomorrow")) { set(today.adding(days: 1)) }
        Button(tr("下周一", "Next Monday")) { set(today.adding(days: 7 - today.mondayIndex)) }
        Divider()
        Button(tr("移到收件箱（无日期）", "Move to Inbox (no date)")) { set(nil) }
    }

    private func set(_ day: Day?) {
        withAnimation(.snappy) { store.schedule(task.id, day: day) }
    }
}

struct TaskMenu: View {
    let task: TaskItem
    let onEdit: () -> Void
    let onSchedule: () -> Void
    @Environment(TaskStore.self) private var store
    @Environment(PanelModel.self) private var model: PanelModel?

    var body: some View {
        if task.isDone {
            Button(tr("标记为未完成", "Mark as Not Done")) { withAnimation(.snappy) { store.reopen(task.id) } }
        } else {
            Button(tr("完成", "Complete")) { withAnimation(.snappy) { store.complete(task.id) } }
            if store.focus?.taskID == task.id {
                Button(tr("结束专注", "Stop Focus")) { withAnimation(.snappy) { store.stopFocus() } }
            } else {
                Button(tr("开始专注", "Start Focus")) { withAnimation(.snappy) { store.startFocus(task.id) } }
            }
            Button(tr("编辑标题", "Edit Title"), action: onEdit)
            Button(tr("修改日期和时间…", "Change Date & Time…"), action: onSchedule)
            if let model {
                Button(tr("添加子任务", "Add Step")) { withAnimation(.snappy) { model.editDetails(task.id, .newSubtask) } }
                Button(task.hasNotes ? tr("编辑备注", "Edit Notes") : tr("添加备注", "Add Notes")) {
                    withAnimation(.snappy) { model.editDetails(task.id, .notes) }
                }
            }
            Divider()
            Menu(tr("日期", "Date")) { ScheduleMenuItems(task: task) }
            if task.hasTime {
                Menu(tr("时长", "Duration")) {
                    ForEach(DurationChoice.menu, id: \.self) { minutes in
                        Toggle(DateText.duration(minutes), isOn: Binding(
                            get: { task.minutes == minutes },
                            set: { _ in withAnimation(.snappy) { store.setDuration(task.id, minutes: minutes) } }
                        ))
                    }
                }
            }
            Menu(tr("重复", "Repeat")) {
                let weekday = task.day(in: AppSettings.shared.calendar)?.mondayIndex ?? DateText.today(.now).mondayIndex
                ForEach(RepeatChoice.all(weekday: weekday), id: \.label) { choice in
                    Toggle(choice.label, isOn: Binding(
                        get: { choice.matches(task.recurrence) },
                        set: { _ in withAnimation(.snappy) { store.setRecurrence(task.id, choice.rule) } }
                    ))
                }
                if task.recurrence != nil {
                    Divider()
                    Button(tr("跳过这次", "Skip This One")) { withAnimation(.snappy) { store.skip(task.id) } }
                }
            }
            Menu(tr("颜色", "Color")) {
                Toggle(tr("自动", "Automatic"), isOn: Binding(
                    get: { task.color == nil },
                    set: { _ in withAnimation(.snappy) { store.setColor(task.id, nil) } }
                ))
                Divider()
                ForEach(TaskColor.allCases, id: \.self) { color in
                    Button {
                        withAnimation(.snappy) { store.setColor(task.id, color) }
                    } label: {
                        Label {
                            Text(color.title)
                        } icon: {
                            Image(nsImage: color.swatch)
                        }
                    }
                }
            }
            Menu(tr("优先级", "Priority")) {
                ForEach(Priority.allCases.reversed(), id: \.self) { priority in
                    Toggle(priority.title, isOn: Binding(
                        get: { task.priority == priority },
                        set: { _ in store.setPriority(task.id, priority) }
                    ))
                }
            }
        }
        if let model, task.isDone, task.hasDetails {
            Button(model.isExpanded(task.id) ? tr("收起子任务和备注", "Hide Steps and Notes") : tr("显示子任务和备注", "Show Steps and Notes")) {
                withAnimation(.snappy) { model.toggleDetails(task.id) }
            }
        }
        Divider()
        Button(tr("删除", "Delete"), role: .destructive) { withAnimation(.snappy) { store.delete(task.id) } }
    }
}

/// The repeat rules a menu offers; "weekly" means on the task's own weekday.
struct RepeatChoice {
    let label: String
    let rule: Recurrence?

    static func all(weekday: Int) -> [RepeatChoice] {
        [
            RepeatChoice(label: tr("不重复", "Never"), rule: nil),
            RepeatChoice(label: tr("每天", "Every Day"), rule: .daily),
            RepeatChoice(label: tr("工作日", "Weekdays"), rule: .weekdays),
            RepeatChoice(label: Recurrence.weekly([weekday]).title, rule: .weekly([weekday])),
            RepeatChoice(label: tr("每月", "Monthly"), rule: .monthly),
        ]
    }

    func matches(_ recurrence: Recurrence?) -> Bool {
        switch (rule, recurrence) {
        case (nil, nil), (.daily?, .daily?), (.weekdays?, .weekdays?), (.monthly?, .monthly?): true
        case (.weekly?, .weekly?): rule == recurrence
        default: false
        }
    }
}

enum DurationChoice {
    static let quick = [15, 30, 45, 60, 120]
    static let menu = [15, 30, 45, 60, 90, 120, 180]
}
