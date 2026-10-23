import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @AppStorage(Pref.pinned) private var pinned = true
    @AppStorage(Pref.peekOnHover) private var peekOnHover = true
    @AppStorage(Pref.fadeWhenIdle) private var fadeWhenIdle = true
    @AppStorage(Pref.idleOpacity) private var idleOpacity = 0.6
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section(tr("通用", "General")) {
                Picker(tr("语言", "Language"), selection: $settings.language) {
                    Text(tr("跟随系统", "System")).tag(AppLanguage.system)
                    Text("中文").tag(AppLanguage.chinese)
                    Text("English").tag(AppLanguage.english)
                }
                TimeZoneRow()
                Toggle(tr("登录时启动", "Launch at login"), isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in updateLoginItem(enabled) }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
            }

            UpdateSection()

            Section(tr("快捷键", "Shortcut")) {
                LabeledContent(tr("唤出 / 收起", "Show / hide")) {
                    HotKeyRecorder()
                }
            }

            Section(tr("窗口", "Window")) {
                Toggle(tr("始终置顶", "Always on top"), isOn: $pinned)
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
            }

            Section(tr("快速输入", "Quick entry")) {
                syntaxRow("明天 / 周五 / 下周三 / 10月1日 · tomorrow / fri / next wed / 10/1", tr("日期", "Date"))
                syntaxRow("下午3点 / 晚上8点半 / 15:30 · 3pm / at 9", tr("时间", "Time"))
                syntaxRow("2小时后 / 3天后 · in 30 min / in 3 days", tr("相对时间", "Relative"))
                syntaxRow("! / !! / !!!  · p3 / p2 / p1", tr("优先级 低 / 中 / 高", "Priority low / med / high"))
                syntaxRow("#工作 · #work", tr("标签", "Tag"))
            }

            Section(tr("操作", "Gestures")) {
                syntaxRow(tr("触控板向右扫 / 鼠标向右拖", "Swipe or drag right"), tr("完成", "Complete"))
                syntaxRow(tr("触控板向左扫 / 鼠标向左拖", "Swipe or drag left"), tr("推迟到明天", "Move to tomorrow"))
                syntaxRow(tr("双击任务文字", "Double-click a title"), tr("编辑", "Edit"))
                syntaxRow("⌘1 – ⌘4 · ⌘N · Esc", tr("切换分组 · 新任务 · 收起", "Switch list · New task · Collapse"))
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 700)
        .background(WindowTitle(title: tr("Perch 设置", "Perch Settings")))
    }

    private func syntaxRow(_ example: String, _ meaning: String) -> some View {
        LabeledContent {
            Text(example)
                .foregroundStyle(.secondary)
                .font(.callout)
                .multilineTextAlignment(.trailing)
        } label: {
            Text(meaning)
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

private struct TimeZoneRow: View {
    @Environment(AppSettings.self) private var settings
    @State private var choosing = false

    var body: some View {
        LabeledContent(tr("时区", "Time zone")) {
            VStack(alignment: .trailing, spacing: 4) {
                Button {
                    choosing = true
                } label: {
                    HStack(spacing: 4) {
                        Text(settings.timeZoneID == nil ? tr("跟随系统", "System") + " · " + settings.timeZone.identifier : settings.timeZone.identifier)
                        Image(systemName: "chevron.up.chevron.down").imageScale(.small)
                    }
                }
                .buttonStyle(.bordered)
                .popover(isPresented: $choosing, arrowEdge: .bottom) {
                    TimeZonePicker(isPresented: $choosing)
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

private struct TimeZonePicker: View {
    @Binding var isPresented: Bool
    @Environment(AppSettings.self) private var settings
    @State private var query = ""

    private struct Zone: Identifiable {
        let id: String
        let offset: Int
        let name: String
    }

    private var zones: [Zone] {
        let now = Date.now
        let all = TimeZone.knownTimeZoneIdentifiers.compactMap { id -> Zone? in
            guard let zone = TimeZone(identifier: id) else { return nil }
            return Zone(id: id, offset: zone.secondsFromGMT(for: now), name: zone.localizedName(for: .generic, locale: settings.locale) ?? "")
        }
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = needle.isEmpty ? all : all.filter {
            $0.id.lowercased().contains(needle) || $0.name.lowercased().contains(needle)
                || $0.id.replacingOccurrences(of: "_", with: " ").lowercased().contains(needle)
        }
        return filtered.sorted { ($0.offset, $0.id) < ($1.offset, $1.id) }
    }

    var body: some View {
        VStack(spacing: 8) {
            TextField(tr("搜索城市或时区", "Search city or zone"), text: $query)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.leading)
            List {
                row(id: nil, title: tr("跟随系统", "Follow system"), subtitle: TimeZone.current.identifier)
                ForEach(zones) { zone in
                    row(id: zone.id, title: zone.id.replacingOccurrences(of: "_", with: " "), subtitle: "\(DateText.utcOffset(TimeZone(identifier: zone.id) ?? .gmt, at: .now)) · \(zone.name)")
                }
            }
            .listStyle(.plain)
        }
        .padding(10)
        .frame(width: 340, height: 420)
    }

    private func row(id: String?, title: String, subtitle: String) -> some View {
        Button {
            settings.timeZoneID = id
            isPresented = false
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if settings.timeZoneID == id {
                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// Keeps the hosting window's title in the current language.
private struct WindowTitle: NSViewRepresentable {
    let title: String

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { view.window?.title = title }
    }
}
