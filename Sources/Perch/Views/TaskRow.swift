import SwiftUI

struct TaskRow: View {
    enum Style { case regular, compact }

    let task: TaskItem
    let now: Date
    var style: Style = .regular
    /// Off when a section header already names the day.
    var showsDay = true

    @Environment(TaskStore.self) private var store
    @Environment(SwipeTracker.self) private var swipe
    @State private var hovering = false
    @State private var completing = false
    @GestureState(resetTransaction: Transaction(animation: .spring(duration: 0.35, bounce: 0.25)))
    private var dragOffset: CGFloat = 0
    @State private var isEditing = false
    @State private var draft = ""
    @State private var editorFocusRequest = 0

    private var offset: CGFloat { (swipe.rowID == task.id ? swipe.offset : 0) + dragOffset }
    private var isChecked: Bool { task.isDone || completing }
    private var isFocusTask: Bool { store.focus?.taskID == task.id }

    var body: some View {
        ZStack(alignment: offset >= 0 ? .leading : .trailing) {
            if offset != 0 { swipeReveal }
            content
                .offset(x: offset)
        }
        .clipShape(.rect(cornerRadius: 10, style: .continuous))
        .contentShape(.rect)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { self.hovering = hovering }
            swipe.hover(task.id, hovering)
        }
        .simultaneousGesture(dragToSwipe)
        .onChange(of: abs(offset) >= SwipeTracker.threshold) { Haptics.tick() }
        .contextMenu { TaskMenu(task: task, onEdit: beginEditing) }
    }

    // MARK: - Content

    private var content: some View {
        HStack(spacing: style == .compact ? 6 : 8) {
            CheckCircle(isOn: isChecked, tint: task.priority.tint, size: style == .compact ? 16 : 18, action: toggle)

            VStack(alignment: .leading, spacing: 2) {
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
                        .font(.system(size: 13, weight: isFocusTask ? .semibold : .regular))
                        .strikethrough(isChecked, color: .secondary)
                        .foregroundStyle(isChecked ? .secondary : .primary)
                        .lineLimit(style == .compact ? 1 : 2)
                        .onTapGesture(count: 2, perform: beginEditing)
                }
                if style == .regular { metadata }
            }

            Spacer(minLength: 4)

            if style == .compact {
                if let label = DateText.dueLabel(task, now: now), task.hasTime || DateText.isOverdue(task, now: now) {
                    Text(label)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(DateText.isOverdue(task, now: now) ? Color.red : .secondary)
                }
            } else if hovering && !isChecked && !isEditing {
                hoverActions.transition(.opacity)
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
        if dueLabel != nil || !task.tags.isEmpty || isFocusTask {
            HStack(spacing: 8) {
                if isFocusTask {
                    Label(tr("专注中", "Focusing"), systemImage: "scope")
                        .foregroundStyle(Color.accentColor)
                }
                if let dueLabel = showsDay ? dueLabel : task.schedule?.time.map(DateText.time),
                   task.hasTime || (showsDay && !DateText.isDueToday(task, now: now)) {
                    Label(dueLabel, systemImage: task.hasTime ? "clock" : "calendar")
                        .foregroundStyle(DateText.isOverdue(task, now: now) ? Color.red : .secondary)
                }
                ForEach(task.tags, id: \.self) { tag in
                    Text("#\(tag)").foregroundStyle(Color.accentColor.opacity(0.9))
                }
            }
            .font(.system(size: 11).monospacedDigit())
            .labelStyle(CompactLabelStyle())
            .lineLimit(1)
        }
    }

    private var hoverActions: some View {
        HStack(spacing: 0) {
            if !isFocusTask {
                IconButton(symbol: "scope", help: tr("开始专注", "Start focus"), size: 22) {
                    withAnimation(.snappy) { store.startFocus(task.id) }
                }
            }
            Menu {
                ScheduleMenuItems(task: task)
            } label: {
                Image(systemName: "calendar")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .contentShape(.circle)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(tr("改期", "Reschedule"))
        }
        .foregroundStyle(.secondary)
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
        guard style == .regular, !isEditing, abs(value.translation.width) > abs(value.translation.height) else { return nil }
        return SwipeTracker.rubberBand(value.translation.width)
    }

    private func toggle() {
        if task.isDone {
            withAnimation(.snappy) { store.reopen(task.id) }
            return
        }
        guard !completing else { return }
        Haptics.confirm()
        completing = true
        let id = task.id
        Task {
            try? await Task.sleep(for: .milliseconds(480))
            withAnimation(.snappy(duration: 0.35)) { store.complete(id) }
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
    @Environment(TaskStore.self) private var store

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
            Divider()
            Menu(tr("日期", "Date")) { ScheduleMenuItems(task: task) }
            Menu(tr("优先级", "Priority")) {
                ForEach(Priority.allCases.reversed(), id: \.self) { priority in
                    Toggle(priority.title, isOn: Binding(
                        get: { task.priority == priority },
                        set: { _ in store.setPriority(task.id, priority) }
                    ))
                }
            }
        }
        Divider()
        Button(tr("删除", "Delete"), role: .destructive) { withAnimation(.snappy) { store.delete(task.id) } }
    }
}
