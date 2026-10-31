import SwiftUI

/// Settings › Focus: how today went, the focus screen, the schedules, the time zone they run on,
/// and keeping Perch alive for strict schedules.
struct FocusPane: View {
    @Environment(FocusController.self) private var focus
    @Bindable private var store = FocusStore.shared
    @Bindable private var schedules = ScheduleStore.shared

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let strictActive = schedules.hasStrictRuleActive
            Form {
                Section {
                    FocusOverview(store: store) { focus.startSession() }
                }

                Section(tr("专注画面", "Focus Screen")) {
                    LabeledContent(tr("开始专注 · 长按解除", "Start · hold to unlock")) {
                        HStack(spacing: 8) {
                            if focus.hotKeyStatus == .unavailable {
                                Label(tr("已被其他应用占用", "Taken by another app"), systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                                    .help(tr("如果旧的 Focus 还在运行，退出它即可", "If the old Focus app is still running, quit it"))
                            }
                            Text(focus.shortcutText)
                                .font(.system(size: 12, weight: .semibold).monospaced())
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                    Picker(selection: $store.idleMinutes) {
                        ForEach(FocusStore.idleOptions, id: \.self) { minutes in
                            Text(minutes == 0 ? tr("关闭", "Off") : tr("\(minutes) 分钟", "\(minutes) min")).tag(minutes)
                        }
                    } label: {
                        SettingLabel(tr("离开后自动模糊", "Blur when I step away"),
                                     store.autoPausedBy.map { tr("\($0) 正在播放，暂不自动模糊", "Waiting while \($0) plays") }
                                        ?? tr("多久不碰电脑屏幕就模糊下来，离开的这段也算进专注", "After this long untouched; the time away counts as focus"))
                    }
                    Picker(selection: $store.keepAwakeMinutes) {
                        ForEach(FocusStore.keepAwakeOptions, id: \.self) { minutes in
                            Text(Self.keepAwakeLabel(minutes)).tag(minutes)
                        }
                    } label: {
                        SettingLabel(tr("保持亮屏", "Keep the display on"),
                                     tr("没人碰电脑时最多亮多久，之后按系统设置熄屏", "With nobody at the Mac, for at most this long"))
                    }
                    Toggle(isOn: $store.soundEnabled) {
                        SettingLabel(tr("音效", "Sounds"), tr("开始、打字解锁和回来时的轻声提示；自动模糊时始终静音", "Soft cues when starting, typing and coming back; silent when it blurs on its own"))
                    }
                }

                Section {
                    if schedules.rules.isEmpty {
                        Text(tr("在固定的时间，让分心的 App 和网站暂停。", "Pause distracting apps and sites at set times."))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(schedules.rules) { rule in
                        ScheduleSettingsRow(rule: rule, now: context.date, locked: schedules.isLocked(rule, at: context.date),
                                            isEnabled: enabledBinding(rule.id))
                    }
                    HStack {
                        Button(tr("新建时段…", "New Schedule…")) { SchedulesWindowController.shared.show(creating: true) }
                        Spacer()
                        if !schedules.rules.isEmpty {
                            Button(tr("编辑时段…", "Edit Schedules…")) { SchedulesWindowController.shared.show() }
                        }
                    }
                } header: {
                    Text(tr("时段", "Schedules"))
                } footer: {
                    if schedules.rules.contains(where: { !$0.sites.isEmpty }) {
                        BrowserAccessRow(access: BrowserAccess.shared)
                            .padding(.top, 4)
                    }
                }

                Section {
                    TimeZoneRow()
                        .disabled(strictActive)
                } header: {
                    Text(tr("时区", "Time Zone"))
                } footer: {
                    Text(strictActive
                         ? tr("严格时段进行中，暂时不能改时区", "A strict schedule is running; the time zone can't change until it ends")
                         : tr("时段按这个时区的钟表时间生效，和待办共用", "Schedules run on this zone's clock, the same one your tasks use"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section(tr("启动与守护", "Launch & Keep Alive")) {
                    Toggle(isOn: $store.keepAlive) {
                        SettingLabel(tr("防止被强行退出", "Keep Perch alive"),
                                     strictActive && store.keepAlive
                                        ? tr("严格时段进行中，暂时不能关闭", "Can't turn off while a strict schedule runs")
                                        : tr("被活动监视器、强制退出结束后，几秒内自动重新打开，并在登录时启动。严格时段建议打开",
                                             "Reopens within seconds if Activity Monitor or Force Quit ends it, and starts at login. Recommended with strict schedules"))
                    }
                    .disabled(strictActive && store.keepAlive)
                    if store.keepAliveNeedsApproval {
                        LabeledContent {
                            Button(tr("去设置", "Open Settings")) { BackgroundAgent.openLoginItemsSettings() }
                        } label: {
                            Label(tr("还需要在「系统设置 › 通用 › 登录项」里允许 Perch 在后台运行",
                                     "Allow Perch in the background in System Settings › General › Login Items"),
                                  systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
        }
        .onAppear {
            store.refreshBackgroundStatus()
            BrowserAccess.shared.refreshAll()
        }
    }

    private func enabledBinding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { schedules.rules.first { $0.id == id }?.isEnabled ?? false },
            set: { value in
                if let index = schedules.rules.firstIndex(where: { $0.id == id }) { schedules.rules[index].isEnabled = value }
            })
    }

    private static func keepAwakeLabel(_ minutes: Int) -> String {
        switch minutes {
        case 0: tr("跟随系统", "System setting")
        case let m where m % 60 == 0: tr("\(m / 60) 小时", "\(m / 60) h")
        case let m where m > 60: tr("\(Double(m) / 60) 小时", "\(Double(m) / 60) h")
        default: tr("\(minutes) 分钟", "\(minutes) min")
        }
    }
}

/// A setting's name with a quieter line under it.
struct SettingLabel: View {
    let title: String
    let detail: String

    init(_ title: String, _ detail: String) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Today's focus, the streak, the last seven days and the button to start.
private struct FocusOverview: View {
    let store: FocusStore
    let start: () -> Void
    @Environment(FocusController.self) private var focus

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(tr("今日专注", "Focused today"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(store.todaySeconds < 60 ? tr("还没开始", "Not yet") : DurationText.long(store.todaySeconds))
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    if store.streakDays > 0 {
                        Label(tr("连续 \(store.streakDays) 天", "\(store.streakDays)-day streak"), systemImage: "flame.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Brand.glow)
                    }
                    Button(action: start) {
                        HStack(spacing: 8) {
                            Image(systemName: "lamp.desk.fill")
                            Text(tr("开始专注", "Start Focus"))
                            Text(focus.shortcutText).opacity(0.7)
                        }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Brand.gradient, in: .capsule)
                        .shadow(color: Brand.glow.opacity(0.35), radius: 8, y: 3)
                        .contentShape(.capsule)
                    }
                    .buttonStyle(SoftPressStyle())
                    .padding(.top, 6)
                }
                Spacer(minLength: 12)
                WeekChart(days: store.lastWeek)
                    .frame(width: 210)
            }
            Text(tr("模糊屏幕、专注某项任务、正常进行的时段都算专注；同一时间重叠只算一次，睡眠和合盖不算。", "The blur, focusing on a task and a schedule running as planned all count; overlapping time counts once, sleep doesn't."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 6)
    }
}

/// Focus over the last seven days, today lit in the lamp's colors.
struct WeekChart: View {
    let days: [(date: Date, seconds: TimeInterval)]

    var body: some View {
        let peak = max(days.map(\.seconds).max() ?? 0, 3600)
        HStack(alignment: .bottom, spacing: 8) {
            ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                let isToday = index == days.count - 1
                VStack(spacing: 6) {
                    Capsule()
                        .fill(isToday ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(.quaternary))
                        .frame(width: 12, height: max(4, 56 * day.seconds / peak))
                        .frame(height: 56, alignment: .bottom)
                    Text(isToday ? tr("今", "Today") : ScheduleText.shortWeekday(ScheduleClock.calendar.component(.weekday, from: day.date)))
                        .font(.system(size: 10, weight: isToday ? .bold : .regular))
                        .foregroundStyle(isToday ? .primary : .secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
                .frame(maxWidth: .infinity)
                .help(DurationText.long(day.seconds))
                .accessibilityElement(children: .ignore)
                .accessibilityValue(day.seconds < 60 ? tr("没有专注", "No focus") : DurationText.long(day.seconds))
            }
        }
        .animation(.smooth(duration: 0.6), value: days.map(\.seconds))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(tr("最近 7 天专注", "Focus, last 7 days"))
    }
}

/// A schedule in Settings: its color, name, when, what it pauses, and a switch.
private struct ScheduleSettingsRow: View {
    let rule: BlockRule
    let now: Date
    let locked: Bool
    @Binding var isEnabled: Bool

    var body: some View {
        let active = rule.activeOccurrence(at: now)
        HStack(spacing: 12) {
            Circle()
                .fill(RuleTint.gradient(rule.tint))
                .frame(width: 10, height: 10)
                .shadow(color: active != nil ? RuleTint.color(rule.tint) : .clear, radius: 5)
                .opacity(rule.isEnabled ? 1 : 0.35)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(rule.name.isEmpty ? tr("未命名", "Untitled") : rule.name)
                        .fontWeight(.medium)
                    if let active {
                        StatusPill(text: tr("进行中 · 至 \(ScheduleText.time(active.end))", "Until \(ScheduleText.time(active.end))"), tint: rule.tint)
                    }
                    if rule.isStrict {
                        Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(.secondary)
                            .help(tr("严格时段", "Strict schedule"))
                    }
                }
                Text(ScheduleText.summary(rule))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .opacity(rule.isEnabled ? 1 : 0.55)
            Spacer(minLength: 8)
            if !rule.hasNoTargets {
                TargetStack(rule: rule, size: 18, limit: 3)
            }
            Button {
                SchedulesWindowController.shared.show(selecting: rule.id)
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .buttonStyle(.borderless)
            .help(tr("编辑", "Edit"))
            Toggle(tr("启用", "On"), isOn: $isEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(locked)
        }
        .contentShape(.rect)
        .onTapGesture(count: 2) { SchedulesWindowController.shared.show(selecting: rule.id) }
    }
}
