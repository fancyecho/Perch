import ServiceManagement
import SwiftUI

/// The pages of Settings, shown under a toolbar of tabs.
enum SettingsTab: Int, CaseIterable {
    case general, tasks, focus, status, island, help

    var title: String {
        switch self {
        case .general: tr("通用", "General")
        case .tasks: tr("待办", "Tasks")
        case .focus: tr("专注", "Focus")
        case .status: tr("状态", "Status")
        case .island: tr("灵动岛", "Island")
        case .help: tr("帮助", "Help")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .tasks: "checklist"
        case .focus: "lamp.desk"
        case .status: "gauge.with.dots.needle.67percent"
        case .island: "rectangle.topthird.inset.filled"
        case .help: "questionmark.circle"
        }
    }

    /// Each page is as tall as its content, so the window resizes as the tabs switch.
    var height: CGFloat {
        switch self {
        case .general: 440
        case .tasks: 470
        case .focus: 720
        case .status: 640
        case .island: 660
        case .help: 600
        }
    }
}

struct SettingsPane: View {
    let tab: SettingsTab

    var body: some View {
        Group {
            switch tab {
            case .general: GeneralPane()
            case .tasks: TasksPane()
            case .focus: FocusPane()
            case .status: StatusPane()
            case .island: IslandPane()
            case .help: HelpPane()
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: tab.height)
    }
}

// MARK: - General

private struct GeneralPane: View {
    @Environment(AppSettings.self) private var settings
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Picker(tr("语言", "Language"), selection: $settings.language) {
                    Text(tr("跟随系统", "System")).tag(AppLanguage.system)
                    Text("中文").tag(AppLanguage.chinese)
                    Text("English").tag(AppLanguage.english)
                }
                TimeZoneRow()
                if FocusStore.shared.keepAlive {
                    // The keep-alive agent starts Perch at login itself.
                    Toggle(isOn: .constant(true)) {
                        SettingLabel(tr("登录时启动", "Launch at login"), tr("已包含在 专注 › 防止被强行退出 里", "Included in Focus › Keep Perch alive"))
                    }
                    .disabled(true)
                } else {
                    Toggle(tr("登录时启动", "Launch at login"), isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { _, enabled in updateLoginItem(enabled) }
                }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
            }

            Section(tr("快捷键", "Shortcut")) {
                LabeledContent(tr("唤出 / 收起任务", "Show / hide tasks")) {
                    HotKeyRecorder()
                }
            }

            UpdateSection()
        }
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

    var body: some View {
        Form {
            Section(tr("体验", "Experience")) {
                Toggle(tr("「今天」显示时间轴", "Show timeline in Today"), isOn: $showsTimeline)
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

            Section(tr("胶囊", "Capsule")) {
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
                Toggle(tr("浮动胶囊始终置顶", "Keep the floating pill on top"), isOn: $pinned)
            }
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
    @AppStorage(Pref.islandTaskStyle) private var taskStyle = TaskStyle.capsule.rawValue
    @AppStorage(Pref.islandHaptics) private var haptics = true
    @AppStorage(Pref.hudColorful) private var hudColorful = true
    @AppStorage(Pref.hudShowsValue) private var hudShowsValue = false
    @AppStorage(Pref.hudDuration) private var hudDuration = 1.6

    var body: some View {
        Form {
            Section {
                Toggle(tr("在刘海处显示灵动岛", "Show the island at the notch"), isOn: $enabled)
                if enabled {
                    Picker(tr("待办显示方式", "Today's tasks"), selection: $taskStyle) {
                        Text(tr("刘海下的胶囊", "Capsule under the notch")).tag(TaskStyle.capsule.rawValue)
                        Text(tr("融入灵动岛", "Inside the island")).tag(TaskStyle.merged.rawValue)
                        Text(tr("独立浮动胶囊", "Floating pill")).tag(TaskStyle.floating.rawValue)
                    }
                    Toggle(tr("悬停时展开", "Expand on hover"), isOn: $hoverToExpand)
                    Toggle(tr("触感反馈", "Haptic feedback"), isOn: $haptics)
                }
            }
            if enabled {
                Section(tr("显示内容", "What it shows")) {
                    Toggle(tr("正在播放", "Now Playing"), isOn: $nowPlaying)
                    Toggle(tr("蓝牙设备与音频输出", "Bluetooth devices & audio output"), isOn: $devices)
                    Toggle(tr("充电与电量", "Charging & battery"), isOn: $battery)
                    Toggle(tr("任务到点时在刘海提醒", "Remind me at the notch when tasks are due"), isOn: $reminders)
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
        }
    }
}

// MARK: - Help

private struct HelpPane: View {
    var body: some View {
        Form {
            Section(tr("快速输入", "Quick entry")) {
                ReferenceRow(example: "明天 / 周五 / 下周三 / 10月1日 · tomorrow / fri / next wed / 10/1", meaning: tr("日期", "Date"))
                ReferenceRow(example: "下午3点 / 晚上8点半 / 15:30 · 3pm / at 9", meaning: tr("时间", "Time"))
                ReferenceRow(example: "2小时后 / 3天后 · in 30 min / in 3 days", meaning: tr("相对时间", "Relative"))
                ReferenceRow(example: "! / !! / !!!  · p3 / p2 / p1", meaning: tr("优先级 低 / 中 / 高", "Priority low / med / high"))
                ReferenceRow(example: "#工作 · #work", meaning: tr("标签", "Tag"))
            }

            Section(tr("任务", "Tasks")) {
                ReferenceRow(example: tr("触控板向右扫 / 鼠标向右拖", "Swipe or drag right"), meaning: tr("完成", "Complete"))
                ReferenceRow(example: tr("触控板向左扫 / 鼠标向左拖", "Swipe or drag left"), meaning: tr("推迟到明天", "Move to tomorrow"))
                ReferenceRow(example: tr("双击任务文字", "Double-click a title"), meaning: tr("编辑", "Edit"))
                ReferenceRow(example: "⌘1 – ⌘5 · ⌘N · Esc", meaning: tr("切换分组（⌘5 专注）· 新任务 · 收起", "Switch list (⌘5 Focus) · New task · Collapse"))
            }

            Section(tr("灵动岛", "Island")) {
                ReferenceRow(example: tr("在刘海上双指左右滑", "Two-finger swipe sideways on the notch"), meaning: tr("下一首 / 上一首", "Next / previous track"))
                ReferenceRow(example: tr("在刘海上双指下滑", "Two-finger swipe down on the notch"), meaning: tr("展开", "Open"))
                ReferenceRow(example: tr("展开后双指上下滑 · 点边上的圆点", "Once open, swipe up / down · the dots at the edge"), meaning: tr("切换正在播放 / 系统状态", "Switch Now Playing / Status"))
                ReferenceRow(example: tr("在胶囊上双指右滑 / 左滑", "Two-finger swipe right / left on the capsule"), meaning: tr("完成 / 推迟到明天", "Complete / move to tomorrow"))
                ReferenceRow(example: tr("右键刘海或胶囊", "Right-click the notch or capsule"), meaning: tr("菜单与设置", "Menu & settings"))
            }

            Section(tr("专注", "Focus")) {
                ReferenceRow(example: "⌥⌘F", meaning: tr("开始专注，模糊所有屏幕", "Start focus: blur every screen"))
                ReferenceRow(example: tr("长按 ⌥⌘F 约 4 秒 · 或输入解锁语句", "Hold ⌥⌘F for 4 s · or type the phrase"), meaning: tr("解除模糊", "Lift the blur"))
                ReferenceRow(example: tr("专注横幅上的台灯按钮", "The lamp on a task's focus banner"), meaning: tr("离开电脑去做这项任务", "Step away to do that task"))
                ReferenceRow(example: tr("拦截界面上按住按钮 3 秒", "Hold the button on the shield for 3 s"), meaning: tr("温和时段里再用 5 分钟", "Five more minutes (gentle schedules)"))
                ReferenceRow(example: tr("展开刘海上的倒计时", "Open the countdown at the notch"), meaning: tr("提前结束临时使用", "End a pass early"))
            }

            Section(tr("状态", "Status")) {
                ReferenceRow(example: tr("灵动岛的状态页 · 点读数切换详情", "The island's status page · click a gauge"), meaning: tr("系统状态与详情", "Status and details"))
                ReferenceRow(example: tr("菜单栏读数 · Perch 菜单", "Menu bar readout · Perch menu"), meaning: tr("完整的系统状态面板", "The full status panel"))
                ReferenceRow(example: tr("右键进程", "Right-click a process"), meaning: tr("在访达中显示、切换或退出", "Show in Finder, switch, or quit"))
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
