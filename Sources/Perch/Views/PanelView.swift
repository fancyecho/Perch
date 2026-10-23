import AppKit
import SwiftUI

struct PanelView: View {
    @Environment(TaskStore.self) private var store
    @Environment(PanelModel.self) private var model

    var body: some View {
        TimelineView(.everyMinute) { context in
            let now = context.date
            VStack(spacing: 0) {
                PanelHeader(now: now)
                QuickAddField(now: now)
                    .padding(.horizontal, 14)
                TabBar(now: now)
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                if let focus = store.focus, let task = store.task(focus.taskID) {
                    FocusBanner(task: task, session: focus)
                        .padding(.horizontal, 14)
                        .padding(.top, 10)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                TaskList(tab: model.tab, now: now)
                    .padding(.top, 6)
            }
        }
        .overlay(alignment: .bottom) { NoticeToast().padding(.bottom, 14) }
        .background { KeyboardShortcuts() }
        .onExitCommand { model.go(.pill) }
    }
}

// MARK: - Header

private struct PanelHeader: View {
    let now: Date
    @Environment(TaskStore.self) private var store
    @Environment(PanelModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @Environment(Updater.self) private var updater
    @AppStorage(Pref.pinned) private var pinned = true
    @AppStorage(Pref.peekOnHover) private var peekOnHover = true

    var body: some View {
        let progress = store.progress(now: now)
        let today = DateText.today(now)
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(DateText.weekdayLong(today))
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                HStack(spacing: 6) {
                    Text("\(DateText.monthDay(today)) · \(summary(progress))")
                        .contentTransition(.numericText())
                    if settings.timeZoneID != nil {
                        Text(settings.timeZone.abbreviation(for: now) ?? DateText.utcOffset(settings.timeZone, at: now))
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.primary.opacity(0.08)))
                            .help(settings.timeZone.identifier)
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }
            Spacer()
            ProgressRing(done: progress.done, total: progress.total, lineWidth: 3.5, showsCount: true)
                .frame(width: 30, height: 30)
                .padding(.trailing, 4)
            Menu {
                Toggle(tr("始终置顶", "Always on Top"), isOn: $pinned)
                Toggle(tr("悬停预览", "Peek on Hover"), isOn: $peekOnHover)
                Divider()
                if let release = updater.availableRelease {
                    Button(tr("更新到 \(release.version)", "Update to \(release.version)")) {
                        Task { await updater.install(release) }
                    }
                }
                Button(tr("设置…", "Settings…")) { model.openSettings() }
                Button(tr("退出 Perch", "Quit Perch")) { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .overlay(alignment: .topTrailing) {
                        if updater.availableRelease != nil {
                            Circle().fill(Color.accentColor).frame(width: 7, height: 7)
                        }
                    }
                    .contentShape(.circle)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(tr("更多", "More"))
            IconButton(symbol: "arrow.down.right.and.arrow.up.left", help: tr("收起（Esc）", "Collapse (Esc)")) { model.go(.pill) }
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .contentShape(.rect)
        .gesture(WindowDragGesture())
    }

    private func summary(_ progress: (done: Int, total: Int)) -> String {
        let remaining = progress.total - progress.done
        if progress.total == 0 { return tr("今天没有安排", "Nothing planned") }
        if remaining == 0 { return tr("全部完成，干得漂亮", "All done, nice work") }
        return tr("还剩 \(remaining) 项", "\(remaining) left")
    }
}

// MARK: - Quick add

private struct QuickAddField: View {
    let now: Date
    @Environment(TaskStore.self) private var store
    @Environment(PanelModel.self) private var model
    @State private var text = ""
    @State private var focused = false
    @State private var rejected = 0

    var body: some View {
        let parsed = QuickParser.parse(text, now: now, defaultDay: defaultDay)
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(focused ? Color.accentColor : .secondary)
                InputField(
                    text: $text,
                    placeholder: tr("添加任务，如「明天下午3点 写周报 !!」", "Add a task, e.g. “Report tomorrow 3pm !!”"),
                    focusRequest: model.inputFocusRequest,
                    focusOnAppear: true,
                    onSubmit: submit,
                    onCancel: cancel,
                    onFocusChange: { focused = $0 }
                )
                if !parsed.title.isEmpty {
                    Button { submit(text) } label: {
                        Image(systemName: "return")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 20, height: 20)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(tr("添加", "Add"))
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(focused ? 0.08 : 0.05))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(focused ? 0.55 : 0), lineWidth: 1)
            }
            .keyframeAnimator(initialValue: 0.0, trigger: rejected) { content, x in
                content.offset(x: x)
            } keyframes: { _ in
                KeyframeTrack {
                    SpringKeyframe(7, duration: 0.06)
                    SpringKeyframe(-7, duration: 0.08)
                    SpringKeyframe(0, duration: 0.14)
                }
            }

            if hasChips(parsed) {
                HStack(spacing: 6) {
                    if parsed.hasExplicitDate, let label = DateText.dueLabel(parsed.schedule, now: now) {
                        Chip(text: label, symbol: parsed.schedule?.time == nil ? "calendar" : "clock")
                    }
                    if parsed.priority != .none {
                        Chip(text: tr("\(parsed.priority.title)优先级", "\(parsed.priority.title) priority"), symbol: "flag.fill", tint: parsed.priority.tint)
                    }
                    ForEach(parsed.tags, id: \.self) { tag in
                        Chip(text: tag, symbol: "number", tint: .purple)
                    }
                }
                .padding(.leading, 4)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.snappy(duration: 0.22), value: hasChips(parsed))
        .animation(.snappy(duration: 0.22), value: parsed.title.isEmpty)
    }

    private var defaultDay: Day? {
        let today = DateText.today(now)
        switch model.tab {
        case .today, .done: return today
        case .upcoming: return today.adding(days: 1)
        case .inbox: return nil
        }
    }

    private func hasChips(_ parsed: ParsedInput) -> Bool {
        parsed.hasExplicitDate || parsed.priority != .none || !parsed.tags.isEmpty
    }

    /// Parses the field's live text at the moment of submission, never a value cached by the view.
    private func submit(_ value: String) {
        let parsed = QuickParser.parse(value, now: .now, defaultDay: defaultDay)
        guard !value.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        guard let task = withAnimation(.snappy, { store.add(parsed) }) else {
            rejected += 1
            NSSound.beep()
            store.announce(tr("先写下要做什么", "Add what needs doing first"), undo: nil)
            return
        }
        Haptics.tick()
        text = ""
        let destination = destinationTab(for: task)
        if destination != model.tab {
            let label = DateText.dueLabel(task, now: now).map { " · \($0)" } ?? ""
            store.announce(tr("已添加到「\(destination.title)」\(label)", "Added to \(destination.title)\(label)"), undo: nil)
        }
    }

    private func cancel() {
        if text.isEmpty { model.go(.pill) } else { text = "" }
    }

    private func destinationTab(for task: TaskItem) -> TaskTab {
        guard let day = task.day(in: AppSettings.shared.calendar) else { return .inbox }
        return day <= DateText.today(now) ? .today : .upcoming
    }
}

// MARK: - Tabs

private struct TabBar: View {
    let now: Date
    @Environment(TaskStore.self) private var store
    @Environment(PanelModel.self) private var model
    @Namespace private var selection

    var body: some View {
        HStack(spacing: 2) {
            ForEach(TaskTab.allCases) { tab in
                let selected = model.tab == tab
                let count = store.count(for: tab, now: now)
                Button {
                    withAnimation(.snappy(duration: 0.28)) { model.tab = tab }
                } label: {
                    HStack(spacing: 4) {
                        Text(tab.title)
                            .font(.system(size: 12, weight: selected ? .semibold : .medium))
                        if count > 0 && tab != .done {
                            Text("\(count)")
                                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                                .foregroundStyle(.secondary)
                                .contentTransition(.numericText())
                        }
                    }
                    .foregroundStyle(selected ? .primary : .secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .background {
                        if selected {
                            Capsule()
                                .fill(Color.primary.opacity(0.1))
                                .matchedGeometryEffect(id: "selection", in: selection)
                        }
                    }
                    .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.primary.opacity(0.045)))
    }
}

// MARK: - Focus

private struct FocusBanner: View {
    let task: TaskItem
    let session: FocusSession
    @Environment(TaskStore.self) private var store
    @State private var pulsing = false

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color.accentColor)
                .frame(width: 8, height: 8)
                .scaleEffect(pulsing ? 1.25 : 0.8)
                .opacity(pulsing ? 1 : 0.55)
                .animation(.easeInOut(duration: 1).repeatForever(autoreverses: true), value: pulsing)
                .onAppear { pulsing = true }
            VStack(alignment: .leading, spacing: 1) {
                Text(tr("专注中", "Focusing"))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text(task.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            FocusTimer(start: session.startedAt)
                .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
            IconButton(symbol: "checkmark", help: tr("完成", "Complete")) {
                Haptics.confirm()
                withAnimation(.snappy) { store.complete(task.id) }
            }
            IconButton(symbol: "xmark", help: tr("结束专注", "Stop focus")) {
                withAnimation(.snappy) { store.stopFocus() }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.accentColor.opacity(0.13))
        }
    }
}

// MARK: - Lists

private struct TaskList: View {
    let tab: TaskTab
    let now: Date
    @Environment(TaskStore.self) private var store
    @State private var showsDoneToday = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                switch tab {
                case .today: today
                case .upcoming: upcoming
                case .inbox: inbox
                case .done: done
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 60)
        }
        .scrollIndicators(.never)
        .id(tab)
        .transition(.opacity)
    }

    @ViewBuilder
    private var today: some View {
        let overdue = store.overdue(now: now)
        let due = store.dueToday(now: now)
        let doneToday = store.doneToday(now: now)

        if overdue.isEmpty && due.isEmpty {
            EmptyState(
                symbol: doneToday.isEmpty ? "sun.max" : "checkmark.seal",
                title: doneToday.isEmpty ? tr("今天还没有安排", "Nothing planned for today") : tr("今天的事都做完了", "All done for today"),
                subtitle: doneToday.isEmpty ? tr("在上面输入第一件要做的事", "Type your first task above") : tr("歇一会儿，或者看看「即将」", "Take a break, or check Upcoming")
            )
        }
        if !overdue.isEmpty {
            SectionHeader(title: tr("已逾期", "Overdue"), tint: .red)
            rows(overdue)
        }
        if !due.isEmpty {
            if !overdue.isEmpty { SectionHeader(title: tr("今天", "Today")) }
            rows(due)
        }
        if !doneToday.isEmpty {
            Button {
                withAnimation(.snappy) { showsDoneToday.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Text(tr("今日已完成 \(doneToday.count)", "Done today \(doneToday.count)"))
                    Image(systemName: "chevron.right")
                        .imageScale(.small)
                        .rotationEffect(.degrees(showsDoneToday ? 90 : 0))
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.top, 14)
                .padding(.bottom, 4)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if showsDoneToday { rows(doneToday) }
        }
    }

    @ViewBuilder
    private var upcoming: some View {
        let groups = store.upcoming(now: now)
        if groups.isEmpty {
            EmptyState(symbol: "calendar", title: tr("接下来很空", "Nothing coming up"), subtitle: tr("试试「下周五 交报告」", "Try “Send report next fri”"))
        }
        ForEach(groups, id: \.day) { group in
            SectionHeader(title: DateText.dayHeader(group.day, now: now))
            rows(group.tasks, showsDay: false)
        }
    }

    @ViewBuilder
    private var inbox: some View {
        let tasks = store.inbox()
        if tasks.isEmpty {
            EmptyState(symbol: "tray", title: tr("收件箱是空的", "Inbox is empty"), subtitle: tr("没有日期的想法会放在这里", "Ideas without a date land here"))
        }
        rows(tasks)
    }

    @ViewBuilder
    private var done: some View {
        let tasks = store.completed()
        if tasks.isEmpty {
            EmptyState(symbol: "checkmark.circle", title: tr("还没有完成的任务", "Nothing completed yet"), subtitle: tr("完成的任务会出现在这里", "Completed tasks show up here"))
        } else {
            HStack {
                SectionHeader(title: tr("共 \(tasks.count) 项", "\(tasks.count) items"))
                Spacer()
                Button(tr("清空", "Clear")) { withAnimation(.snappy) { store.clearCompleted() } }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.trailing, 10)
                    .padding(.top, 10)
            }
            rows(tasks)
        }
    }

    private func rows(_ tasks: [TaskItem], showsDay: Bool = true) -> some View {
        ForEach(tasks) { task in
            TaskRow(task: task, now: now, showsDay: showsDay)
                .transition(.asymmetric(
                    insertion: .move(edge: .top).combined(with: .opacity),
                    removal: .opacity.combined(with: .scale(scale: 0.96, anchor: .leading))
                ))
        }
    }
}

private struct SectionHeader: View {
    let title: String
    var tint: Color = .secondary

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.top, 12)
            .padding(.bottom, 4)
    }
}

private struct EmptyState: View {
    let symbol: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.secondary)
                .symbolEffect(.bounce, options: .nonRepeating)
            Text(title)
                .font(.system(size: 14, weight: .semibold))
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }
}

// MARK: - Toast & shortcuts

private struct NoticeToast: View {
    @Environment(TaskStore.self) private var store

    var body: some View {
        ZStack {
            if let notice = store.notice {
                HStack(spacing: 10) {
                    Text(notice.message)
                        .lineLimit(1)
                    if notice.undo != nil {
                        Button(tr("撤销", "Undo")) { withAnimation(.snappy) { store.undo() } }
                            .buttonStyle(.plain)
                            .fontWeight(.semibold)
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Capsule().fill(Color.black.opacity(0.78)))
                .padding(.horizontal, 20)
                .id(notice.id)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: notice.id) {
                    try? await Task.sleep(for: .seconds(notice.undo == nil ? 2.2 : 4))
                    guard !Task.isCancelled, store.notice?.id == notice.id else { return }
                    withAnimation(.snappy) { store.notice = nil }
                }
            }
        }
        .animation(.spring(duration: 0.35, bounce: 0.25), value: store.notice)
    }
}

private struct KeyboardShortcuts: View {
    @Environment(PanelModel.self) private var model

    var body: some View {
        ZStack {
            ForEach(TaskTab.allCases) { tab in
                Button("") { withAnimation(.snappy(duration: 0.28)) { model.tab = tab } }
                    .keyboardShortcut(KeyEquivalent(Character("\(tab.rawValue + 1)")), modifiers: .command)
            }
            Button("") { model.inputFocusRequest += 1 }
                .keyboardShortcut("n", modifiers: .command)
        }
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
