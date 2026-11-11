import ServiceManagement
import SwiftUI

/// The pages of Settings, shown under a toolbar of tabs.
/// Settings, one page per part of Perch, with what they share (language, time zone, launching,
/// every shortcut) on the first.
enum SettingsTab: Int, CaseIterable {
    case general, island, tasks, focus, line, help

    var title: String {
        switch self {
        case .general: tr("通用", "General")
        case .island: tr("灵动岛", "Island")
        case .tasks: tr("待办", "Tasks")
        case .focus: tr("专注", "Focus")
        case .line: tr("晾衣绳", "Line")
        case .help: tr("帮助", "Help")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .island: "rectangle.topthird.inset.filled"
        case .tasks: "checklist"
        case .focus: "lamp.desk"
        case .line: "tshirt"
        case .help: "questionmark.circle"
        }
    }

    /// Every page is the same size, so the window holds still as the tabs switch; longer pages scroll.
    static let pageSize = CGSize(width: 540, height: 620)
}

struct SettingsPane: View {
    let tab: SettingsTab

    var body: some View {
        Group {
            switch tab {
            case .general: GeneralPane()
            case .island: IslandPane()
            case .tasks: TasksPane()
            case .focus: FocusPane()
            case .line: LinePane()
            case .help: HelpPane()
            }
        }
        .formStyle(.grouped)
        .scrollIndicators(.automatic)
        .frame(width: SettingsTab.pageSize.width, height: SettingsTab.pageSize.height)
    }
}

// MARK: - General

private struct GeneralPane: View {
    @Environment(AppSettings.self) private var settings
    @Environment(FocusController.self) private var focus
    @Bindable private var focusStore = FocusStore.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        @Bindable var settings = settings
        let strictActive = ScheduleStore.shared.hasStrictRuleActive
        Form {
            Section {
                Picker(tr("语言", "Language"), selection: $settings.language) {
                    Text(tr("跟随系统", "System")).tag(AppLanguage.system)
                    Text("中文").tag(AppLanguage.chinese)
                    Text("English").tag(AppLanguage.english)
                }
                TimeZoneRow()
                    .disabled(strictActive)
            } footer: {
                Text(strictActive
                     ? tr("严格时段进行中，暂时不能改时区。", "A strict schedule is running; the time zone can't change until it ends.")
                     : tr("待办的日期、专注时段和胶囊里的时间都按这个时区走。", "Tasks, Focus schedules and the capsule's clock all run on this zone."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(tr("启动", "Launch")) {
                if focusStore.keepAlive {
                    // The keep-alive agent starts Perch at login itself.
                    Toggle(isOn: .constant(true)) {
                        SettingLabel(tr("登录时启动", "Launch at login"), tr("已包含在下面的「防止被强行退出」里", "Included in Keep Perch alive below"))
                    }
                    .disabled(true)
                } else {
                    Toggle(tr("登录时启动", "Launch at login"), isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { _, enabled in updateLoginItem(enabled) }
                }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
                Toggle(isOn: $focusStore.keepAlive) {
                    SettingLabel(tr("防止被强行退出", "Keep Perch alive"),
                                 strictActive && focusStore.keepAlive
                                    ? tr("严格时段进行中，暂时不能关闭", "Can't turn off while a strict schedule runs")
                                    : tr("被活动监视器或强制退出结束后几秒内重新打开，严格时段建议打开",
                                         "Reopens within seconds if Activity Monitor or Force Quit ends it; recommended with strict schedules"))
                }
                .disabled(strictActive && focusStore.keepAlive)
                if focusStore.keepAliveNeedsApproval {
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

            Section(tr("快捷键", "Shortcuts")) {
                LabeledContent(tr("唤出 / 收起任务", "Show / hide tasks")) {
                    HotKeyRecorder()
                }
                LabeledContent(tr("展开 / 收起灵动岛", "Open / close the island")) {
                    HotKeyRecorder(slot: .island)
                }
                LabeledContent(tr("开始专注 · 长按解除", "Start focus · hold to unlock")) {
                    ShortcutKeys(text: focus.shortcutText, warning: focus.hotKeyStatus == .unavailable)
                }
                if let line = LineHost.controller() {
                    LabeledContent(tr("放下 / 收起晾衣绳", "Show / hide the line")) {
                        HStack(spacing: 8) {
                            ShortcutKeys(text: line.shortcutText, warning: false)
                            Button(tr("更改…", "Change…")) { line.recordShortcut() }
                        }
                    }
                }
            }

            UpdateSection()
        }
        .onAppear { focusStore.refreshBackgroundStatus() }
    }

    private func updateLoginItem(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginError = nil
        } catch {
            loginError = tr("无法更新登录项：", "Couldn't update the login item: ") + error.localizedDescription
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

/// A fixed shortcut, shown as keys.
private struct ShortcutKeys: View {
    let text: String
    let warning: Bool

    var body: some View {
        HStack(spacing: 6) {
            if warning {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(tr("已被其他应用占用", "Taken by another app"))
            }
            Text(text)
                .font(.system(size: 12, weight: .semibold).monospaced())
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}

// MARK: - Tasks

private struct TasksPane: View {
    @AppStorage(Pref.pinned) private var pinned = true
    @AppStorage(Pref.peekOnHover) private var peekOnHover = true
    @AppStorage(Pref.fadeWhenIdle) private var fadeWhenIdle = true
    @AppStorage(Pref.idleOpacity) private var idleOpacity = 0.6
    @AppStorage(Pref.todayTimeline) private var showsTimeline = true
    @AppStorage(Pref.completionSound) private var completionSound = true
    @AppStorage(Pref.celebrations) private var celebrations = true
    @AppStorage(Pref.chimeStyle) private var chimeStyle = ChimeStyle.perch.rawValue
    @AppStorage(Pref.islandTaskStyle) private var taskStyle = TaskStyle.capsule.rawValue
    @AppStorage(Pref.taskDefaultColor) private var defaultColor = TaskColor.coral.rawValue
    @AppStorage(Pref.taskTopicColors) private var topicColors = true
    @AppStorage(Pref.remindAtStart) private var remindAtStart = false
    @AppStorage(Pref.remindAtEnd) private var remindAtEnd = true
    @AppStorage(Pref.reviewEnabled) private var reviewEnabled = true
    @AppStorage(Pref.reviewTime) private var reviewTime = 21 * 60 + 30
    @AppStorage(Pref.timelineStart) private var timelineStart = 7 * 60
    @AppStorage(Pref.timelineEnd) private var timelineEnd = 23 * 60

    /// A time of day kept as minutes after midnight, as a date today for a time picker. The
    /// day's start stays before its end.
    private func clock(_ minutes: Binding<Int>, range: ClosedRange<Int>) -> Binding<Date> {
        Binding(
            get: { Calendar.current.date(bySettingHour: minutes.wrappedValue / 60, minute: minutes.wrappedValue % 60, second: 0, of: .now) ?? .now },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                let value = (c.hour ?? 0) * 60 + (c.minute ?? 0)
                if range.contains(value) { minutes.wrappedValue = value }
            }
        )
    }

    /// The review time as a date today, for the time picker.
    private var reviewDate: Binding<Date> {
        Binding(
            get: { Calendar.current.date(bySettingHour: reviewTime / 60, minute: reviewTime % 60, second: 0, of: .now) ?? .now },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                reviewTime = (c.hour ?? 21) * 60 + (c.minute ?? 30)
            }
        )
    }

    var body: some View {
        Form {
            Section {
                Picker(tr("今天的任务显示在", "Today's tasks"), selection: $taskStyle) {
                    Text(tr("刘海下的胶囊", "Capsule under the notch")).tag(TaskStyle.capsule.rawValue)
                    Text(tr("灵动岛里", "Inside the island")).tag(TaskStyle.merged.rawValue)
                    Text(tr("独立浮动胶囊", "Floating pill")).tag(TaskStyle.floating.rawValue)
                }
                Toggle(tr("悬停时预览接下来的任务", "Peek at upcoming tasks on hover"), isOn: $peekOnHover)
                Toggle(tr("闲置时淡化", "Fade when idle"), isOn: $fadeWhenIdle)
                if fadeWhenIdle {
                    Slider(value: $idleOpacity, in: 0.25...0.9) {
                        Text(tr("闲置透明度", "Idle opacity"))
                    } minimumValueLabel: {
                        Image(systemName: "circle.dotted")
                    } maximumValueLabel: {
                        Image(systemName: "circle.fill")
                    }
                }
                if taskStyle == TaskStyle.floating.rawValue {
                    Toggle(tr("浮动胶囊始终置顶", "Keep the floating pill on top"), isOn: $pinned)
                }
            }

            CapsuleClockSection()

            Section {
                Toggle(tr("任务开始时", "When a task starts"), isOn: $remindAtStart)
                Toggle(tr("时间段结束时", "When its time is up"), isOn: $remindAtEnd)
                Toggle(tr("每晚整理没做完的任务", "Review what's left each evening"), isOn: $reviewEnabled)
                if reviewEnabled {
                    DatePicker(tr("整理时间", "Review at"), selection: reviewDate, displayedComponents: .hourAndMinute)
                }
            } header: {
                Text(tr("提醒", "Reminders"))
            } footer: {
                Text(tr("只对设了时间的任务；没设时长的按 30 分钟算。到了整理时间，「今天」顶上会列出还没做完的，一键勾掉或挪到明天。",
                        "Only for tasks with a time; without a length they last 30 minutes. At review time, Today leads with what's still open, to check off or move to tomorrow."))
                    .foregroundStyle(.secondary)
            }

            Section(tr("体验", "Experience")) {
                Toggle(tr("「今天」显示时间轴", "Show timeline in Today"), isOn: $showsTimeline)
                if showsTimeline {
                    LabeledContent(tr("时间轴从", "Timeline runs from")) {
                        HStack(spacing: 6) {
                            DatePicker("", selection: clock($timelineStart, range: 0...(timelineEnd - 60)), displayedComponents: .hourAndMinute)
                                .labelsHidden()
                            Text(tr("到", "to")).foregroundStyle(.secondary)
                            DatePicker("", selection: clock($timelineEnd, range: (timelineStart + 60)...(24 * 60 - 1)), displayedComponents: .hourAndMinute)
                                .labelsHidden()
                        }
                    }
                }
                LabeledContent(tr("任务默认颜色", "Default task color")) {
                    ColorSwatchPicker(selection: $defaultColor)
                }
                Toggle(tr("按任务类型自动配色（学习、运动、会议…）", "Color tasks by kind (study, exercise, meetings…)"), isOn: $topicColors)
                Toggle(tr("完成音效", "Completion sound"), isOn: $completionSound)
                if completionSound {
                    LabeledContent(tr("音色", "Sound")) {
                        HStack(spacing: 8) {
                            Picker("", selection: $chimeStyle) {
                                Text(tr("嘀嗒（默认）", "Di-da (default)")).tag(ChimeStyle.perch.rawValue)
                                Text(tr("Apple Pay 原声", "Apple Pay")).tag(ChimeStyle.applePay.rawValue)
                                Text(tr("玻璃", "Glass")).tag(ChimeStyle.glass.rawValue)
                                Text(tr("轻敲", "Tink")).tag(ChimeStyle.tink.rawValue)
                                Text(tr("木塞", "Bottle")).tag(ChimeStyle.bottle.rawValue)
                                Text(tr("木琴", "Marimba")).tag(ChimeStyle.marimba.rawValue)
                            }
                            .labelsHidden()
                            .fixedSize()
                            .onChange(of: chimeStyle) { _, style in
                                Feedback.shared.preview(ChimeStyle(rawValue: style))
                            }
                            Button {
                                Feedback.shared.preview()
                            } label: {
                                Image(systemName: "play.fill")
                            }
                            .help(tr("试听", "Preview"))
                        }
                    }
                }
                Toggle(tr("清空今天时撒彩带", "Confetti when today is cleared"), isOn: $celebrations)
            }
        }
    }
}

/// The time in the capsule, in Dayline's styles.
private struct CapsuleClockSection: View {
    private var clockFooter: String {
        let exceptions = tr("悬停或专注中显示任务；没有任务时一直显示时间。",
                            "The task shows while hovered or focusing; with nothing to do it's always the time.")
        switch CapsuleClockMode(rawValue: mode) ?? .onTheMinute {
        case .off: return tr("胶囊只显示任务。", "The capsule shows only the task.")
        case .onTheMinute: return tr("每分钟最后几秒，时间翻上来，看着分钟数字滚过去再换回任务。", "In the last seconds of each minute the time rolls in, its minute turns over, then the task comes back. ") + exceptions
        case .alternate: return tr("任务 10 秒、时间 5 秒轮流显示。", "Ten seconds of the task, five of the time. ") + exceptions
        case .always: return tr("胶囊平时是一枚时钟，指上去就翻出任务；任务逾期或 15 分钟内到期时和时间轮流显示。", "The capsule is a clock; point at it and the task rolls in. A late task, or one due within 15 minutes, takes turns with the time. ") + exceptions
        }
    }

    @AppStorage(Pref.clockMode) private var mode = CapsuleClockMode.onTheMinute.rawValue
    @AppStorage(Pref.clockShowsDate) private var showsDate = true
    @AppStorage(Pref.clockShowsWeekday) private var showsWeekday = true
    @AppStorage(Pref.clockUses24Hour) private var uses24Hour = true
    @AppStorage(Pref.clockWideTracking) private var wideTracking = true
    @AppStorage(Pref.clockEmphasizesTime) private var emphasizesTime = false
    @AppStorage(Pref.clockRollsDigits) private var rollsDigits = true
    var body: some View {
        Section {
            Picker(tr("显示时间", "Show the time"), selection: $mode) {
                Text(tr("关闭", "Off")).tag(CapsuleClockMode.off.rawValue)
                Text(tr("整分钟前后", "As the minute turns")).tag(CapsuleClockMode.onTheMinute.rawValue)
                Text(tr("和任务轮流", "Taking turns with the task")).tag(CapsuleClockMode.alternate.rawValue)
                Text(tr("常显时间，悬停看任务", "Always the time, the task on hover")).tag(CapsuleClockMode.always.rawValue)
            }
            if mode != CapsuleClockMode.off.rawValue {
                LabeledContent(tr("预览", "Preview")) {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        ClockLine(now: context.date)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(Color.primary.opacity(0.07)))
                    }
                }
                Toggle(tr("显示日期", "Show the date"), isOn: $showsDate)
                Toggle(tr("显示星期", "Show the weekday"), isOn: $showsWeekday)
                Toggle(tr("24 小时制", "24-hour clock"), isOn: $uses24Hour)
                Toggle(isOn: $wideTracking) {
                    SettingLabel(tr("宽字距", "Wide tracking"), tr("字距拉开，英文变成大写", "Letters spaced out, English in capitals"))
                }
                Toggle(isOn: $emphasizesTime) {
                    SettingLabel(tr("突出时间", "Emphasize the time"), tr("日期星期变淡，时间加粗", "Date and weekday fade, the time is bold"))
                }
                Toggle(isOn: $rollsDigits) {
                    SettingLabel(tr("数字滚动", "Rolling digits"), tr("整分钟时变化的数字向上滚动", "Changing digits roll up as the minute turns"))
                }
            }
        } header: {
            Text(tr("胶囊里的时间", "Time in the Capsule"))
        } footer: {
            Text(clockFooter)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Notch island

private struct IslandPane: View {
    @AppStorage(Pref.islandEnabled) private var enabled = true
    @AppStorage(Pref.islandHoverToExpand) private var hoverToExpand = true
    @AppStorage(Pref.islandNowPlaying) private var nowPlaying = true
    @AppStorage(Pref.islandLevels) private var levels = true
    @AppStorage(Pref.islandDevices) private var devices = true
    @AppStorage(Pref.islandBattery) private var battery = true
    @AppStorage(Pref.islandReminders) private var reminders = true
    @AppStorage(Pref.islandHaptics) private var haptics = true
    @AppStorage(Pref.hudColorful) private var hudColorful = true
    @AppStorage(Pref.hudShowsValue) private var hudShowsValue = false
    @AppStorage(Pref.hudDuration) private var hudDuration = 1.6

    var body: some View {
        Form {
            Section {
                Toggle(tr("在刘海处显示灵动岛", "Show the island at the notch"), isOn: $enabled)
                if enabled {
                    Toggle(tr("悬停时展开", "Expand on hover"), isOn: $hoverToExpand)
                    Toggle(tr("触感反馈", "Haptic feedback"), isOn: $haptics)
                }
            }
            if enabled {
                Section(tr("显示内容", "What it shows")) {
                    Toggle(tr("正在播放", "Now Playing"), isOn: $nowPlaying)
                    Toggle(tr("蓝牙设备与音频输出", "Bluetooth devices & audio output"), isOn: $devices)
                    Toggle(tr("充电与电量", "Charging & battery"), isOn: $battery)
                    Toggle(tr("在刘海显示任务提醒", "Show task reminders at the notch"), isOn: $reminders)
                }
                Section(tr("音量与亮度提示", "Volume & brightness")) {
                    Toggle(tr("显示音量与亮度提示", "Show volume & brightness"), isOn: $levels)
                    if levels {
                        AccessibilityRow()
                        Picker(tr("进度条颜色", "Bar color"), selection: $hudColorful) {
                            Text(tr("随程度变色", "Changes with the level")).tag(true)
                            Text(tr("单色", "Plain white")).tag(false)
                        }
                        Toggle(tr("显示百分比", "Show the percentage"), isOn: $hudShowsValue)
                        Picker(tr("停留时间", "Stays for"), selection: $hudDuration) {
                            Text(tr("短", "Short")).tag(1.0)
                            Text(tr("标准", "Standard")).tag(1.6)
                            Text(tr("长", "Long")).tag(2.6)
                        }
                    }
                }
            }
            StatusSections(islandEnabled: enabled)
        }
    }
}

// MARK: - Help

private struct HelpPane: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        Form {
            Section(tr("快速输入", "Quick entry")) {
                ReferenceRow(example: "明天 / 周五 / 下周三 / 10月1日 · tomorrow / fri / next wed / 10/1", meaning: tr("日期", "Date"))
                ReferenceRow(example: "下午3点 / 晚上8点半 / 15:30 · 3pm / at 9", meaning: tr("时间", "Time"))
                ReferenceRow(example: "2小时后 / 3天后 · in 30 min / in 3 days", meaning: tr("相对时间", "Relative"))
                ReferenceRow(example: "3点到5点 / 1小时 / 45分钟 · 3-5pm / for 1h", meaning: tr("时长", "Length"))
                ReferenceRow(example: "每天 / 工作日 / 每周一三五 / 每月 · every day / weekdays / every mon / monthly", meaning: tr("重复", "Repeat"))
                ReferenceRow(example: "! / !! / !!!  · p3 / p2 / p1", meaning: tr("优先级 低 / 中 / 高", "Priority low / med / high"))
                ReferenceRow(example: "#工作 · #work", meaning: tr("标签", "Tag"))
            }

            Section(tr("任务", "Tasks")) {
                ReferenceRow(example: tr("触控板向右扫 / 鼠标向右拖", "Swipe or drag right"), meaning: tr("完成", "Complete"))
                ReferenceRow(example: tr("触控板向左扫 / 鼠标向左拖", "Swipe or drag left"), meaning: tr("推迟到明天", "Move to tomorrow"))
                ReferenceRow(example: tr("双击任务文字", "Double-click a title"), meaning: tr("编辑", "Edit"))
                ReferenceRow(example: tr("悬停任务点清单按钮 · 右键 › 添加子任务 · 点「☑ 2/5」", "Hover a task, click the checklist button · Right-click › Add Step · click “☑ 2/5”"), meaning: tr("子任务和备注", "Steps and notes"))
                ReferenceRow(example: tr("在子任务里按 ↩ · 在空的子任务里按 ⌫", "↩ in a step · ⌫ in an empty step"), meaning: tr("加下一项 · 删掉这一项", "Add the next · remove it"))
                ReferenceRow(example: tr("在时间轴上按住任务上下拖 / 拖胶囊下边缘", "Drag a task along the timeline / a capsule's bottom edge"), meaning: tr("改时间 / 改时长", "Move / change length"))
                ReferenceRow(example: tr("点时间轴上的空闲时段", "Click free time on the timeline"), meaning: tr("在那个时间加一项", "Add a task then"))
                ReferenceRow(example: "⌘1 – ⌘5 · ⌘N · Esc", meaning: tr("切换分组（⌘5 专注）· 新任务 · 收起", "Switch list (⌘5 Focus) · New task · Collapse"))
                ReferenceRow(example: "⌘Z · ⇧⌘Z", meaning: tr("撤销 · 重做", "Undo · Redo"))
            }

            Section(tr("灵动岛", "Island")) {
                ReferenceRow(example: tr("在刘海上双指左右滑", "Two-finger swipe sideways on the notch"), meaning: tr("下一首 / 上一首", "Next / previous track"))
                ReferenceRow(example: tr("在刘海上双指下滑", "Two-finger swipe down on the notch"), meaning: tr("展开", "Open"))
                ReferenceRow(example: tr("展开后双指上下滑 · 滚动鼠标滚轮 · 点边上的圆点", "Once open, swipe up / down · scroll the wheel · the dots at the edge"), meaning: tr("切换正在播放 / 系统状态", "Switch Now Playing / Status"))
                ReferenceRow(example: settings.islandHotKey?.displayString ?? tr("通用里设置的快捷键", "The shortcut set in General"), meaning: tr("展开 / 收起灵动岛", "Open / close the island"))
                ReferenceRow(example: tr("在胶囊上双指右滑 / 左滑", "Two-finger swipe right / left on the capsule"), meaning: tr("完成 / 推迟到明天", "Complete / move to tomorrow"))
                ReferenceRow(example: tr("右键刘海或胶囊", "Right-click the notch or capsule"), meaning: tr("菜单与设置", "Menu & settings"))
            }

            Section(tr("专注", "Focus")) {
                ReferenceRow(example: "⌥⌘F", meaning: tr("开始专注，模糊所有屏幕", "Start focus: blur every screen"))
                ReferenceRow(example: tr("长按 ⌥⌘F 约 4 秒 · 或输入解锁语句", "Hold ⌥⌘F for 4 s · or type the phrase"), meaning: tr("解除模糊", "Lift the blur"))
                ReferenceRow(example: tr("专注横幅上的台灯按钮", "The lamp on a task's focus banner"), meaning: tr("离开电脑去做这项任务", "Step away to do that task"))
                ReferenceRow(example: tr("拦截界面上选好时长，按住按钮 3 秒", "Pick a length on the shield, hold the button for 3 s"), meaning: tr("休息一会儿（每天 3 次，5–30 分钟）", "Take a break (3 a day, 5–30 min)"))
                ReferenceRow(example: tr("展开刘海上的倒计时", "Open the countdown at the notch"), meaning: tr("提前结束休息", "End a break early"))
            }

            Section(tr("晾衣绳", "Line")) {
                ReferenceRow(example: tr("点一下 · 双击 · 按住", "Click · double click · press and hold"), meaning: tr("复制 · 用预览打开 · 标记", "Copy · open in Preview · mark up"))
                ReferenceRow(example: tr("拖进 App · 拖进文件夹 · 拖到废纸篓或点叉", "Drag into an app · into a folder · to the Trash, or the cross"), meaning: tr("发一份 · 存进去并取下 · 丢掉", "Send a copy · keep it there · let it go"))
                ReferenceRow(example: tr("指针在照片上按空格 · ⌫ · 在绳上按 ⌘Z", "Space · ⌫ on a photo · ⌘Z on the line"), meaning: tr("快速查看 · 丢掉 · 挂回刚丢的", "Quick Look · let it go · hang it back"))
                ReferenceRow(example: tr("右键 › 固定 · 拿在手上", "Right-click › Pin · Hold"), meaning: tr("钉在左边不被挤掉 · 取下放在眼前", "Keep it at the left · hold it in front of you"))
                ReferenceRow(example: tr("访达里右键图片 › 服务 › Hang on Perch", "In Finder, right-click an image › Services › Hang on Perch"), meaning: tr("把任意图片挂上绳", "Hang any image on the line"))
                ReferenceRow(example: tr("指针停在菜单栏中间三分之一（灵动岛两侧）· ⌃⌥T", "Rest in the middle third of the menu bar, beside the island · ⌃⌥T"), meaning: tr("放下 / 收起晾衣绳", "Bring the line down / put it away"))
            }

            Section(tr("状态", "Status")) {
                ReferenceRow(example: tr("展开灵动岛后上下滑 · 点菜单栏读数", "Swipe the open island up or down · click the menu bar readout"), meaning: tr("系统状态", "System status"))
                ReferenceRow(example: tr("点 CPU、内存、网络的读数", "Click the CPU, memory or network gauge"), meaning: tr("看它最近两分钟的曲线", "Its last two minutes"))
            }
        }
    }
}

private struct ReferenceRow: View {
    let example: String
    let meaning: String

    var body: some View {
        LabeledContent {
            Text(example)
                .foregroundStyle(.secondary)
                .font(.callout)
                .multilineTextAlignment(.trailing)
        } label: {
            Text(meaning)
        }
    }
}

/// Taking over the volume and brightness keys needs Accessibility; shows where that stands.
private struct AccessibilityRow: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.5)) { _ in
            let trusted = Accessibility.isTrusted
            LabeledContent {
                if trusted {
                    Label(tr("已授权", "Allowed"), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Button(tr("授权辅助功能…", "Allow Accessibility…")) {
                        Accessibility.requestAccess()
                        Accessibility.openSettings()
                    }
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr("替换系统的音量、亮度提示", "Replace the system volume & brightness HUD"))
                    Text(trusted
                        ? tr("音量、亮度键由 Perch 处理，系统提示不再出现", "Perch handles the volume and brightness keys; the system HUD stays hidden")
                        : tr("需要辅助功能权限；授权前系统提示会和灵动岛同时出现", "Needs Accessibility access; until then the system HUD appears as well"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Updates

private struct UpdateSection: View {
    @Environment(Updater.self) private var updater

    var body: some View {
        @Bindable var updater = updater
        Section(tr("更新", "Updates")) {
            LabeledContent(tr("当前版本", "Version"), value: updater.currentVersion)
            Toggle(tr("自动检查更新", "Check for updates automatically"), isOn: $updater.checksAutomatically)
            LabeledContent {
                HStack(spacing: 8) {
                    if let release = updater.availableRelease {
                        Link(tr("更新说明", "Release notes"), destination: release.pageURL)
                        Button(tr("安装 \(release.version) 并重启", "Install \(release.version) and Relaunch")) {
                            Task { await updater.install(release) }
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Button(tr("检查更新", "Check Now")) {
                            Task { await updater.check(userInitiated: true) }
                        }
                        .disabled(updater.state == .checking || updater.state == .installing)
                    }
                }
            } label: {
                statusText
            }
        }
    }

    @ViewBuilder
    private var statusText: some View {
        switch updater.state {
        case .idle:
            Text(tr("尚未检查", "Not checked yet")).foregroundStyle(.secondary)
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(tr("正在检查…", "Checking…"))
            }
        case .upToDate:
            Label(tr("已是最新版本", "You're up to date"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .available(let release):
            Label(tr("发现新版本 \(release.version)", "Version \(release.version) is available"), systemImage: "arrow.down.circle.fill")
                .foregroundStyle(Color.accentColor)
        case .installing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(tr("正在下载并校验…", "Downloading and verifying…"))
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }
}

// MARK: - Time zone

/// The app's time zone, shared by tasks and Focus schedules.
struct TimeZoneRow: View {
    @Environment(AppSettings.self) private var settings
    @State private var choosing = false

    var body: some View {
        LabeledContent(tr("时区", "Time zone")) {
            VStack(alignment: .trailing, spacing: 4) {
                Button {
                    choosing = true
                } label: {
                    HStack(spacing: 4) {
                        Text(settings.timeZoneID == nil ? tr("跟随系统", "System") + " · " + ZoneCatalog.title(for: settings.timeZone) : ZoneCatalog.title(for: settings.timeZone))
                        Image(systemName: "chevron.up.chevron.down").imageScale(.small)
                    }
                }
                .buttonStyle(.bordered)
                .popover(isPresented: $choosing, arrowEdge: .bottom) {
                    @Bindable var settings = settings
                    ZonePicker(selection: $settings.timeZoneID) { choosing = false }
                }
                TimelineView(.everyMinute) { context in
                    Text(status(at: context.date))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
    }

    /// Current offset, whether DST is in effect, and when the next switch happens.
    private func status(at now: Date) -> String {
        let zone = settings.timeZone
        var parts = [DateText.utcOffset(zone, at: now)]
        if let name = zone.localizedName(for: zone.isDaylightSavingTime(for: now) ? .daylightSaving : .standard, locale: settings.locale) {
            parts.append(name)
        }
        if let transition = zone.nextDaylightSavingTimeTransition(after: now) {
            let formatter = DateFormatter()
            formatter.locale = settings.locale
            formatter.timeZone = zone
            formatter.setLocalizedDateFormatFromTemplate("yMMMd")
            let after = DateText.utcOffset(zone, at: transition.addingTimeInterval(1))
            parts.append(tr("\(formatter.string(from: transition)) 切换为 \(after)", "switches to \(after) on \(formatter.string(from: transition))"))
        } else {
            parts.append(tr("不实行夏令时", "no daylight saving"))
        }
        return parts.joined(separator: " · ")
    }
}

/// A row of color dots; the chosen one wears a ring.
private struct ColorSwatchPicker: View {
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 7) {
            ForEach(TaskColor.allCases, id: \.self) { color in
                let isOn = selection == color.rawValue
                Button {
                    selection = color.rawValue
                } label: {
                    Circle()
                        .fill(color.color)
                        .frame(width: 16, height: 16)
                        .padding(3)
                        .overlay(Circle().strokeBorder(color.color.opacity(isOn ? 0.9 : 0), lineWidth: 1.5))
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .help(color.title)
                .accessibilityLabel(color.title)
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
        .animation(.snappy(duration: 0.2), value: selection)
    }
}
