import SwiftUI

/// The glass task capsule hanging under the island (capsule style). It shares the island's window and
/// springs: it matches the island's width at rest, rides down whenever the island grows (a banner,
/// the open player) and back up after, swells a little under the pointer, peeks at the next few
/// tasks, and opens into the full task panel, all as one glass shape.
struct TaskCard: View {
    @Environment(IslandModel.self) private var model
    @Environment(Feedback.self) private var feedback
    @AppStorage(Pref.idleOpacity) private var idleOpacity = 0.6
    @State private var isPressed = false

    var body: some View {
        let size = model.cardSize
        let shape = RoundedRectangle(cornerRadius: cornerRadius(for: size), style: .continuous)
        // Today's tasks are nobody else's business on the lock screen, and a menu dropping out of
        // the menu bar shouldn't have the capsule over it.
        let hidden = model.isLocked || model.isCurtained || (model.isMenuOpen && model.cardMode != .panel)
        ZStack(alignment: .top) {
            if model.cardMode == .panel {
                PanelView()
                    .frame(width: IslandModel.panelSize.width, height: IslandModel.panelSize.height)
                    .transition(.opacity.animation(.easeOut(duration: 0.22).delay(0.06)))
            } else {
                CapsuleContent(
                    hovering: model.isCardHovering || model.cardMode == .peek,
                    peeking: model.cardMode == .peek,
                    onPress: { isPressed = $0 }
                )
                .frame(width: size.width, height: size.height, alignment: .top)
                .transition(.opacity.animation(.easeOut(duration: 0.14)))
            }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .overlay { ConfettiRain(trigger: feedback.celebrationCount) }
        .clipShape(shape)
        .glassEffect(.regular, in: shape)
        .contentShape(shape)
        // The whole glass dips a little under a click, then opens.
        .scaleEffect(isPressed ? 0.965 : 1)
        .animation(.spring(duration: 0.25, bounce: 0.4), value: isPressed)
        .opacity(hidden ? 0 : model.isCardFaded ? idleOpacity : 1)
        .offset(y: model.cardTop)
        .allowsHitTesting(!hidden)
        .animation(.smooth(duration: 0.3), value: hidden)
    }

    private func cornerRadius(for size: CGSize) -> CGFloat {
        switch model.cardMode {
        case .capsule: size.height / 2
        case .peek: 20
        case .panel: 24
        }
    }
}

/// The capsule's own face: one line at rest, two under the pointer, and the next few tasks below it
/// while peeking.
private struct CapsuleContent: View {
    let hovering: Bool
    let peeking: Bool
    let onPress: (Bool) -> Void
    @AppStorage(Pref.clockMode) private var clockMode = CapsuleClockMode.onTheMinute.rawValue

    var body: some View {
        // The time taking turns with the task needs the seconds; otherwise minutes will do.
        if clockMode == CapsuleClockMode.off.rawValue {
            TimelineView(.everyMinute) { context in content(context.date) }
        } else {
            TimelineView(.periodic(from: .now, by: 1)) { context in content(context.date) }
        }
    }

    private func content(_ now: Date) -> some View {
        VStack(spacing: 0) {
            CapsuleRow(now: now, hovering: hovering, onPress: onPress)
                .frame(height: hovering ? IslandModel.capsuleHoverHeight : IslandModel.capsuleHeight)
            if peeking {
                CapsulePeek(now: now)
                    .transition(.opacity)
            }
        }
    }
}

/// One click opens the full panel; the tooltip names the shortcut that does the same.
private struct CapsuleRow: View {
    let now: Date
    let hovering: Bool
    let onPress: (Bool) -> Void
    @Environment(TaskStore.self) private var store
    @Environment(IslandModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @Environment(ScheduleStore.self) private var schedules
    @AppStorage(Pref.clockMode) private var clockMode = CapsuleClockMode.onTheMinute.rawValue

    var body: some View {
        Button { model.tasksHandler?(false) } label: {
            ZStack {
                swipeReveal
                let showsClock = showsClock
                ZStack {
                    if showsClock {
                        ClockLine(now: now)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .transition(.capsuleRoll)
                    } else {
                        content
                            .transition(.capsuleRoll)
                    }
                }
                .animation(.smooth(duration: 0.4), value: showsClock)
                .offset(x: model.capsuleSwipe)
            }
        }
        .buttonStyle(PressReportingStyle(onPress: onPress))
        .contextMenu { CapsuleMenu(now: now) }
        .help(settings.hotKey.map { tr("全部任务（\($0.displayString)）", "All tasks (\($0.displayString))") } ?? tr("全部任务", "All tasks"))
    }

    /// Dayline's time takes the capsule now and then (see CapsuleClockMode), and for good when
    /// there's nothing left to do. Never while it's being looked at or swiped, or while its task is
    /// being focused on. A late task, or one due within a quarter of an hour, still lets the time
    /// through, since a task can stay late all day.
    private var showsClock: Bool {
        let mode = CapsuleClockMode(rawValue: clockMode) ?? .onTheMinute
        guard mode != .off, !hovering, model.capsuleSwipe == 0 else { return false }
        guard let headline = store.headline(now: now) else { return true }
        if store.focus?.taskID == headline.id { return false }
        return mode.showsClock(at: now, urgentTask: isUrgent(headline))
    }

    private func isUrgent(_ task: TaskItem) -> Bool {
        if DateText.isOverdue(task, now: now) { return true }
        guard let time = task.schedule?.time else { return false }
        return time > now && time.timeIntervalSince(now) < 15 * 60
    }

    private var content: some View {
        let progress = store.progress(now: now)
        let headline = store.headline(now: now)
        let isFocusing = store.focus != nil && headline?.id == store.focus?.taskID
        let ring: CGFloat = hovering ? 22 : 16
        let schedule = schedules.activeOccurrences(at: now).last

        return HStack(spacing: hovering ? 10 : 8) {
            ProgressRing(done: progress.done, total: progress.total, lineWidth: hovering ? 2.6 : 2.2)
                .frame(width: ring, height: ring)
                .overlay {
                    // A schedule running: a ring of lamp oil around today's progress, burning down.
                    if let schedule {
                        ScheduleHalo(occurrence: schedule, now: now)
                            .padding(hovering ? -4 : -3.5)
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, schedule == nil ? 0 : 2)

            VStack(alignment: .leading, spacing: 1) {
                // The next task slides up into place when the current one is done.
                Text(headline?.title ?? (progress.total > 0 ? tr("今天的事都做完了", "All done for today") : tr("今天很清闲", "Nothing planned today")))
                    .font(.system(size: hovering ? 13 : 12, weight: .semibold))
                    .lineLimit(1)
                    .id(headline?.id)
                    .transition(.push(from: .bottom))
                if hovering {
                    Text(subtitle(headline: headline, isFocusing: isFocusing, schedule: schedule, remaining: progress.total - progress.done))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .transition(.opacity.combined(with: .offset(y: -4)))
                }
            }

            Spacer(minLength: 4)

            if isFocusing, let focus = store.focus {
                FocusTimer(start: focus.startedAt)
                    .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Color.accentColor)
            } else if let headline, headline.hasTime || DateText.isOverdue(headline, now: now),
                      let label = DateText.dueLabel(headline, now: now) {
                Text(label)
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(DateText.isOverdue(headline, now: now) ? Color.red : .secondary)
                    .fixedSize()
            }
        }
        .padding(.horizontal, hovering ? 13 : 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(.rect)
        .animation(.snappy(duration: 0.35), value: headline?.id)
        .accessibilityElement(children: .combine)
        .accessibilityHint(tr("打开任务面板", "Opens the task panel"))
    }

    /// What a sideways swipe will do, uncovered as the task slides: green to complete, orange to
    /// move it to tomorrow, filling in once it has gone far enough.
    @ViewBuilder
    private var swipeReveal: some View {
        let offset = model.capsuleSwipe
        if offset != 0 {
            let completes = offset > 0
            let armed = abs(offset) >= SwipeTracker.threshold
            ZStack {
                Capsule().fill((completes ? Color.green : Color.orange).opacity(armed ? 0.9 : 0.55))
                Image(systemName: completes ? "checkmark" : "arrow.turn.down.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .scaleEffect(armed ? 1.15 : 0.85)
                    .animation(.spring(duration: 0.25, bounce: 0.5), value: armed)
            }
            .frame(width: max(abs(offset) - 4, 0))
            .padding(4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: completes ? .leading : .trailing)
        }
    }

    private func subtitle(headline: TaskItem?, isFocusing: Bool, schedule: Occurrence?, remaining: Int) -> String {
        if isFocusing { return tr("专注中", "Focusing") }
        if let schedule {
            return tr("\(schedule.rule.name) · 至 \(ScheduleText.time(schedule.end))", "\(schedule.rule.name) · until \(ScheduleText.time(schedule.end))")
        }
        if headline == nil { return tr("点击添加任务", "Click to add a task") }
        return remaining > 1 ? tr("下一项 · 还剩 \(remaining) 项", "Up next · \(remaining) left") : tr("最后一项", "Last one")
    }
}

/// What's left of a running schedule, as a thin ring in its color.
private struct ScheduleHalo: View {
    let occurrence: Occurrence
    let now: Date

    var body: some View {
        let color = RuleTint.color(occurrence.rule.tint)
        Circle()
            .trim(from: 0, to: 1 - occurrence.progress(at: now))
            .stroke(color, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            .rotationEffect(.degrees(-90))
            // A flame's light: tight and bright at the line, a softer halo around it.
            .shadow(color: color.opacity(0.75), radius: 1.5)
            .shadow(color: color.opacity(0.4), radius: 4)
            // No animation of its own: it burns down by a hair a second, and an animation here would
            // also take over the hover's resize and drag the ring behind the progress ring.
            .help(tr("\(occurrence.rule.name) · \(ScheduleText.moment(occurrence.end, from: now)) 结束", "\(occurrence.rule.name) · ends \(ScheduleText.moment(occurrence.end, from: now))"))
    }
}

/// The next few tasks under the capsule, checkable without opening the panel.
private struct CapsulePeek: View {
    let now: Date
    @Environment(TaskStore.self) private var store
    @Environment(IslandModel.self) private var model

    var body: some View {
        let tasks = store.peekTasks(now: now)
        VStack(spacing: 0) {
            if tasks.isEmpty {
                Button { model.tasksHandler?(true) } label: {
                    Label(tr("添加一项任务", "Add a task"), systemImage: "plus")
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity, minHeight: IslandModel.peekRowHeight)
                }
                .buttonStyle(.plain)
            } else {
                ForEach(tasks.prefix(PanelController.peekMaxRows)) { task in
                    TaskRow(task: task, now: now, style: .compact)
                        .frame(height: IslandModel.peekRowHeight)
                        .transition(.asymmetric(insertion: .opacity, removal: .opacity.combined(with: .scale(scale: 0.96))))
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 8)
        .overlay(alignment: .top) {
            Divider().padding(.horizontal, 14).opacity(0.6)
        }
    }
}

/// Hands the pressed state up, so the whole card (not just this row) can dip under a click.
private struct PressReportingStyle: ButtonStyle {
    let onPress: (Bool) -> Void

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, pressed in onPress(pressed) }
    }
}

/// Right-click on the capsule: act on the task it shows, open the list, or its settings.
private struct CapsuleMenu: View {
    let now: Date
    @Environment(TaskStore.self) private var store
    @Environment(IslandModel.self) private var model
    @Environment(Feedback.self) private var feedback

    var body: some View {
        if let headline = store.headline(now: now) {
            Text(headline.title.count > 18 ? headline.title.prefix(18) + "…" : headline.title)
            Button(tr("完成", "Complete")) {
                feedback.taskChecked()
                withAnimation(.snappy) { store.complete(headline.id, playsSound: false) }
            }
            Button(tr("推迟到明天", "Move to Tomorrow")) {
                withAnimation(.snappy) { store.postponeToTomorrow(headline.id) }
            }
            Divider()
        }
        Button(tr("全部任务", "All Tasks")) { model.tasksHandler?(false) }
        Button(tr("新建任务", "New Task")) { model.tasksHandler?(true) }
        Divider()
        FocusMenuItems()
        Divider()
        Button(tr("待办设置…", "Task Settings…")) { model.settingsHandler?(.tasks) }
    }
}

/// The task and the time trade places in the capsule by rolling upward, like a split-flap, one
/// after the other: the outgoing line lifts away quickly, and only then does the incoming one rise
/// into place. Overlapping, the two crossed each other, and while the capsule grew under the pointer
/// the outgoing one drifted sideways with it.
private struct CapsuleRoll: ViewModifier {
    let offset: CGFloat
    let active: Bool

    func body(content: Content) -> some View {
        content
            .offset(y: offset)
            .blur(radius: active ? 3 : 0)
            .opacity(active ? 0 : 1)
    }
}

extension AnyTransition {
    static var capsuleRoll: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: CapsuleRoll(offset: 9, active: true), identity: CapsuleRoll(offset: 0, active: false))
                .animation(.spring(duration: 0.42, bounce: 0.12).delay(0.13)),
            removal: .modifier(active: CapsuleRoll(offset: -7, active: true), identity: CapsuleRoll(offset: 0, active: false))
                .animation(.easeIn(duration: 0.15))
        )
    }
}
