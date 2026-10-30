import SwiftUI

/// The lamp at the end of the panel's tabs, lit while a schedule runs or a task is being focused on.
struct FocusTabLabel: View {
    let selected: Bool
    let now: Date
    @Environment(TaskStore.self) private var store

    var body: some View {
        let lit = store.focus != nil || !ScheduleStore.shared.activeOccurrences(at: now).isEmpty
        Image(systemName: selected ? "lamp.desk.fill" : "lamp.desk")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(lit ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(.foreground))
            .contentTransition(.symbolEffect(.replace))
            .help(tr("专注（⌘5）", "Focus (⌘5)"))
            .accessibilityLabel(tr("专注", "Focus"))
    }
}

/// The panel's Focus tab: how today went, the task being focused on, starting a session, and the
/// schedules with their switches.
struct FocusPage: View {
    let now: Date
    @Environment(TaskStore.self) private var store
    @Environment(PanelModel.self) private var model
    @Bindable private var schedules = ScheduleStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                FocusHero(now: now)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(tr("时段", "Schedules"))
                            .font(.system(size: 13, weight: .semibold))
                        if schedules.blockedCount(on: now) > 0 {
                            Text(tr("今天拦下 \(schedules.blockedCount(on: now)) 次", "\(schedules.blockedCount(on: now)) blocked today"))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        IconButton(symbol: "plus", help: tr("新建时段", "New schedule")) {
                            SchedulesWindowController.shared.show(creating: true)
                        }
                    }
                    if schedules.rules.isEmpty {
                        EmptySchedulesRow()
                    }
                    ForEach(schedules.rules) { rule in
                        PanelScheduleRow(rule: rule, now: now, locked: schedules.isLocked(rule, at: now),
                                         isEnabled: enabledBinding(rule.id))
                    }
                }

                Button { model.openSettings(.focus) } label: {
                    Label(tr("专注设置…", "Focus Settings…"), systemImage: "gearshape")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 14)
            .padding(.top, 4)
            .padding(.bottom, 60)
        }
        .scrollIndicators(.never)
    }

    private func enabledBinding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { schedules.rules.first { $0.id == id }?.isEnabled ?? false },
            set: { value in
                if let index = schedules.rules.firstIndex(where: { $0.id == id }) {
                    withAnimation(.snappy) { schedules.rules[index].isEnabled = value }
                }
            })
    }
}

/// Today's focus beside the week, the task in focus, and the way to start.
private struct FocusHero: View {
    let now: Date
    @Environment(TaskStore.self) private var store
    @Environment(FocusController.self) private var focus
    private let focusStore = FocusStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(tr("今日专注", "Focused today"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(focusStore.todaySeconds < 60 ? tr("还没开始", "Not yet") : DurationText.long(focusStore.todaySeconds))
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    if focusStore.streakDays > 0 {
                        Label(tr("连续 \(focusStore.streakDays) 天", "\(focusStore.streakDays)-day streak"), systemImage: "flame.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Brand.glow)
                    }
                }
                Spacer(minLength: 8)
                WeekChart(days: focusStore.lastWeek)
                    .frame(width: 160)
            }

            if let session = store.focus, let task = store.task(session.taskID) {
                FocusingRow(task: task, session: session)
            }

            Button { focus.startSession() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "lamp.desk.fill")
                    Text(store.focus == nil ? tr("开始专注", "Start Focus") : tr("离开电脑去做", "Step Away to Do It"))
                    Text(focus.shortcutText).opacity(0.7)
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Brand.gradient, in: .capsule)
                .shadow(color: Brand.glow.opacity(0.3), radius: 8, y: 3)
                .contentShape(.capsule)
            }
            .buttonStyle(SoftPressStyle())

            Text(tr("屏幕会慢慢模糊；长按 \(focus.shortcutText) 或打出一句话才解除", "The screens blur; hold \(focus.shortcutText) or type a phrase to come back"))
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Brand.glow.opacity(0.08))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06))
        }
    }
}

/// The task being focused on, with its timer and the ways to finish.
private struct FocusingRow: View {
    let task: TaskItem
    let session: FocusSession
    @Environment(TaskStore.self) private var store

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "scope")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Brand.glow)
            VStack(alignment: .leading, spacing: 1) {
                Text(tr("专注中", "Focusing"))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(task.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            FocusTimer(start: session.startedAt)
                .font(.system(size: 14, weight: .semibold, design: .rounded).monospacedDigit())
            IconButton(symbol: "checkmark", help: tr("完成", "Complete")) {
                Haptics.confirm()
                withAnimation(.snappy) { store.complete(task.id) }
            }
            IconButton(symbol: "xmark", help: tr("结束专注", "Stop focus")) {
                withAnimation(.snappy) { store.stopFocus() }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// A schedule in the panel: its color, what it's doing now, what it pauses, and a switch. A click
/// opens it in the editor.
private struct PanelScheduleRow: View {
    let rule: BlockRule
    let now: Date
    let locked: Bool
    @Binding var isEnabled: Bool
    @State private var hovering = false

    var body: some View {
        let active = ScheduleStore.shared.activeOccurrences(at: now).first { $0.rule.id == rule.id }
        let tint = RuleTint.color(rule.tint)
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                Circle()
                    .fill(RuleTint.gradient(rule.tint))
                    .frame(width: 9, height: 9)
                    .shadow(color: active != nil ? tint : .clear, radius: 4)
                    .opacity(rule.isEnabled ? 1 : 0.35)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(rule.name.isEmpty ? tr("未命名", "Untitled") : rule.name)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                        if rule.isStrict {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 8.5))
                                .foregroundStyle(.secondary)
                                .help(tr("严格时段", "Strict schedule"))
                        }
                    }
                    Text(status(active))
                        .font(.system(size: 10.5))
                        .foregroundStyle(active != nil ? AnyShapeStyle(tint) : AnyShapeStyle(.secondary))
                        .monospacedDigit()
                        .lineLimit(1)
                }
                .opacity(rule.isEnabled ? 1 : 0.55)
                Spacer(minLength: 6)
                if !rule.hasNoTargets {
                    TargetStack(rule: rule, size: 16, limit: 3)
                }
                Toggle(tr("启用", "On"), isOn: $isEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .disabled(locked)
                    .help(locked ? tr("严格时段进行中，结束后才能关闭", "Can't be turned off until this strict schedule ends") : "")
            }
            if let active {
                // What's left of it, burning down.
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.08))
                        Capsule().fill(RuleTint.gradient(rule.tint))
                            .frame(width: proxy.size.width * (1 - active.progress(at: now)))
                    }
                }
                .frame(height: 3)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(Color.primary.opacity(hovering ? 0.07 : 0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(.rect(cornerRadius: 12))
        .onHover { hovering = $0 }
        .onTapGesture { SchedulesWindowController.shared.show(selecting: rule.id) }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .help(tr("点击编辑", "Click to edit"))
    }

    private func status(_ active: Occurrence?) -> String {
        if let active {
            return tr("进行中 · \(ScheduleText.time(active.end)) 结束 · 还剩 \(ScheduleText.remaining(until: active.end, from: now))",
                      "On · ends \(ScheduleText.time(active.end)) · \(ScheduleText.remaining(until: active.end, from: now)) left")
        }
        if !rule.isEnabled { return tr("已停用 · \(ScheduleText.summary(rule))", "Off · \(ScheduleText.summary(rule))") }
        if rule.hasNoTargets { return tr("还没有选要暂停的 App 或网站", "No apps or sites to pause yet") }
        if let next = rule.nextOccurrence(after: now) {
            return tr("下一次 \(ScheduleText.moment(next.start, from: now))", "Next \(ScheduleText.moment(next.start, from: now))")
        }
        return ScheduleText.summary(rule)
    }
}

private struct EmptySchedulesRow: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(tr("在固定的时间，让分心的 App 和网站暂停，到点自动开始和结束。", "Pause distracting apps and sites at set times; they start and end on their own."))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(tr("新建时段…", "New Schedule…")) { SchedulesWindowController.shared.show(creating: true) }
                .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
