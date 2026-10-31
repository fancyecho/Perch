import SwiftUI

/// The open island, with the date up beside the notch as on Alcove. Its first page holds what's
/// playing (and in merged style today's tasks beside it, or alone when nothing plays); the page
/// below it is the Mac's status. With neither playing nor tasks inside, the status is the one page.
/// Two fingers up and down, or the dots at the edge, move between pages.
struct ExpandedIslandView: View {
    @Environment(IslandModel.self) private var model
    @Environment(NowPlayingService.self) private var media
    @Environment(FocusController.self) private var focus
    @Environment(StatusPreferences.self) private var statusPrefs

    var body: some View {
        TimelineView(.everyMinute) { context in
            let now = context.date
            let hasMedia = media.track != nil
            let showsTasks = model.taskStyle == .merged && !model.isLocked
            let pages = IslandPage.available(hasMain: hasMedia || showsTasks, gauges: statusPrefs.islandGauges, locked: model.isLocked)
            let page = pages.contains(model.page) ? model.page : pages[0]
            VStack(spacing: 0) {
                Group {
                    if let hud = model.inlineLevel {
                        LevelWings(hud: hud)
                    } else {
                        TopWings(now: now, hasMedia: hasMedia && page == .main, showsTasks: showsTasks && page == .main,
                                 showsStatus: page == .status && pages.count > 1)
                    }
                }
                .frame(height: model.geometry.notchSize.height)
                ZStack(alignment: .top) {
                    if let pass = focus.passes.first {
                        PassStrip(pass: pass).padding(.top, 12)
                    } else {
                        pageContent(page, now: now, hasMedia: hasMedia, showsTasks: showsTasks)
                            .id(page)
                            // The pages stack like the dots: the status page sits below, so it comes up
                            // from the bottom, and going back the player comes down from the top.
                            .transition(.push(from: model.pageMovesForward ? .bottom : .top))
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .clipped()
                .overlay(alignment: .leading) {
                    if pages.count > 1, focus.passes.isEmpty {
                        PageDots(pages: pages, current: page)
                            .padding(.leading, 6)
                            .padding(.bottom, 8)
                    }
                }
            }
        }
        .foregroundStyle(.white)
    }

    @ViewBuilder
    private func pageContent(_ page: IslandPage, now: Date, hasMedia: Bool, showsTasks: Bool) -> some View {
        switch page {
        case .main:
            if showsTasks {
                HStack(alignment: .top, spacing: 16) {
                    if hasMedia {
                        MediaColumn().frame(width: 150)
                    }
                    TodayColumn(now: now)
                }
                .padding(.top, 10)
            } else {
                WidePlayer().padding(.top, 8)
            }
        case .status:
            StatusGlance(showsHint: !hasMedia && !showsTasks).padding(.top, 10)
        }
    }
}

/// Which page of the open island shows, as dots down its left edge; each one goes to its page.
private struct PageDots: View {
    let pages: [IslandPage]
    let current: IslandPage
    @Environment(IslandModel.self) private var model

    var body: some View {
        VStack(spacing: 4) {
            ForEach(pages, id: \.self) { page in
                Button { model.pageHandler?(page) } label: {
                    Capsule()
                        .fill(Color.white.opacity(page == current ? 0.9 : 0.28))
                        .frame(width: 4, height: page == current ? 12 : 4)
                        .padding(3)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(page == .main ? tr("正在播放", "Now Playing") : tr("系统状态", "System Status"))
            }
        }
        .animation(.spring(duration: 0.35, bounce: 0.3), value: current)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(tr("灵动岛页面，双指上下滑切换", "Island pages; swipe up or down with two fingers"))
    }
}

/// Beside the notch: where the sound comes from (or how today is going), and the date.
private struct TopWings: View {
    let now: Date
    let hasMedia: Bool
    let showsTasks: Bool
    var showsStatus = false
    @Environment(NowPlayingService.self) private var media
    @Environment(TaskStore.self) private var store

    var body: some View {
        WingsLayout {
            if hasMedia, let icon = media.sourceIcon {
                HStack(spacing: 5) {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 15, height: 15)
                    Text(media.sourceName ?? "")
                        .lineLimit(1)
                }
            } else if showsStatus {
                Label(tr("系统状态", "Status"), systemImage: "gauge.with.dots.needle.67percent")
                    .lineLimit(1)
            } else if showsTasks {
                let progress = store.progress(now: now)
                let remaining = progress.total - progress.done
                HStack(spacing: 5) {
                    ProgressRing(done: progress.done, total: progress.total, lineWidth: 2)
                        .frame(width: 13, height: 13)
                    Text(remaining > 0 ? tr("还剩 \(remaining) 项", "\(remaining) left") : tr("都做完了", "All done"))
                        .lineLimit(1)
                }
            }
        } trailing: {
            let today = DateText.today(now)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(DateText.weekday(today))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(red: 1, green: 0.36, blue: 0.32))
                Text("\(today.day)")
                    .font(.system(size: 19, weight: .semibold, design: .rounded).monospacedDigit())
            }
            .fixedSize()
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.white.opacity(0.6))
    }
}

// MARK: - Focus

/// A running pass, opened up: what it lets through, how long is left, and the way to end it now.
private struct PassStrip: View {
    let pass: ActivePass
    @Environment(FocusController.self) private var focus
    @State private var hovering = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = max(0, Int(pass.end.timeIntervalSince(context.date).rounded(.up)))
            let urgent = remaining <= 30
            HStack(spacing: 12) {
                PassRing(icon: pass.icon, isSite: pass.site != nil,
                         fraction: min(Double(remaining) / ActivePass.duration, 1), urgent: urgent, lineWidth: 3)
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(pass.name)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        Text(urgent ? tr("马上结束", "Ending") : tr("临时使用", "Pass"))
                        Text(String(format: "%d:%02d", remaining / 60, remaining % 60))
                            .monospacedDigit()
                            .foregroundStyle(urgent ? PassRing.urgentColor : .white.opacity(0.85))
                            .contentTransition(.numericText(countsDown: true))
                            .animation(.snappy(duration: 0.3), value: remaining)
                    }
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                }
                Spacer(minLength: 8)
                Button { focus.endPass(pass.key) } label: {
                    Text(tr("现在结束", "End Now"))
                        .font(.system(size: 11.5, weight: .semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.white.opacity(hovering ? 0.22 : 0.14)))
                        .contentShape(.capsule)
                }
                .buttonStyle(PressScaleStyle())
                .onHover { hovering = $0 }
                .help(tr("回到时段里，App 会被收起", "Back to the schedule; the app is put away"))
            }
        }
    }
}

// MARK: - Now Playing

private struct MediaColumn: View {
    @Environment(NowPlayingService.self) private var media

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Button { media.openSourceApp() } label: {
                    ArtworkView(size: 40, cornerRadius: 9)
                        .background {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(media.accent ?? .clear)
                                .blur(radius: 12)
                                .opacity(0.5)
                        }
                }
                .buttonStyle(PressScaleStyle())
                .help(tr("打开正在播放的 App", "Open the playing app"))

                VStack(alignment: .leading, spacing: 2) {
                    MarqueeText(text: media.track?.title ?? "", font: .system(size: 13, weight: .semibold))
                    Text(media.track?.artist ?? "")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
            }
            MiniProgress()
                .padding(.top, 11)
            HStack(spacing: 4) {
                IslandButton(symbol: "backward.fill", size: 12, label: tr("上一首", "Previous")) { media.send(.previous) }
                IslandButton(
                    symbol: media.isPlaying ? "pause.fill" : "play.fill",
                    size: 17,
                    label: media.isPlaying ? tr("暂停", "Pause") : tr("播放", "Play")
                ) { media.send(.toggle) }
                IslandButton(symbol: "forward.fill", size: 12, label: tr("下一首", "Next")) { media.send(.next) }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 6)
        }
    }
}

/// The player across the whole island: artwork, title and controls on one row, timed progress below.
private struct WidePlayer: View {
    @Environment(NowPlayingService.self) private var media

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Button { media.openSourceApp() } label: {
                    ArtworkView(size: 52, cornerRadius: 12)
                        .background {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(media.accent ?? .clear)
                                .blur(radius: 14)
                                .opacity(0.5)
                        }
                }
                .buttonStyle(PressScaleStyle())
                .help(tr("打开正在播放的 App", "Open the playing app"))

                VStack(alignment: .leading, spacing: 3) {
                    MarqueeText(text: media.track?.title ?? "", font: .system(size: 14, weight: .semibold))
                    Text(media.track?.artist ?? "")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                HStack(spacing: 2) {
                    IslandButton(symbol: "backward.fill", size: 12, label: tr("上一首", "Previous")) { media.send(.previous) }
                    IslandButton(
                        symbol: media.isPlaying ? "pause.fill" : "play.fill",
                        size: 17,
                        label: media.isPlaying ? tr("暂停", "Pause") : tr("播放", "Play")
                    ) { media.send(.toggle) }
                    IslandButton(symbol: "forward.fill", size: 12, label: tr("下一首", "Next")) { media.send(.next) }
                }
            }
            TimedProgress()
        }
    }
}

private struct TimedProgress: View {
    @Environment(NowPlayingService.self) private var media

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let duration = media.duration
            let position = media.position(at: context.date)
            HStack(spacing: 8) {
                Text(Self.format(position))
                    .frame(width: 34, alignment: .leading)
                MiniProgress()
                Text("-" + Self.format(max(duration - position, 0)))
                    .frame(width: 38, alignment: .trailing)
            }
            .font(.system(size: 10, weight: .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.5))
            .opacity(duration > 0 ? 1 : 0)
        }
    }

    private static func format(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        let hours = total / 3600
        let minutes = total / 60 % 60
        let rest = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%d:%02d", minutes, rest)
    }
}

/// With nothing playing: the battery, headphones and where sound goes, and the Mac's vital signs,
/// at a glance.
private struct StatusGlance: View {
    @Environment(SystemVolume.self) private var volume
    @Environment(BluetoothMonitor.self) private var bluetooth
    @Environment(PowerMonitor.self) private var power
    @Environment(StatusPreferences.self) private var statusPrefs
    /// Whether to say nothing is playing, when there's no gauge row to show instead.
    var showsHint = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                if let battery = power.battery {
                    StatusChip(text: "\(battery.level)%") {
                        BatteryGlyph(level: battery.level, isCharging: battery.isPluggedIn && battery.isCharging, tint: battery.tint)
                            .frame(width: 20, height: 9)
                    }
                }
                ForEach(bluetooth.devices.prefix(2)) { device in
                    StatusChip(text: device.battery.main.map { "\($0)%" } ?? device.name) { Image(systemName: device.symbol) }
                        .help(device.name)
                }
                if !volume.route.name.isEmpty {
                    StatusChip(text: volume.route.name) { Image(systemName: volume.route.symbol) }
                }
            }
            if statusPrefs.islandGauges || !showsHint {
                SystemGauges()
            } else {
                HStack(spacing: 7) {
                    Image(systemName: "music.note")
                        .foregroundStyle(.white.opacity(0.35))
                    Text(tr("没有正在播放的内容 · 在任意 App 中播放就能在这里控制", "Nothing playing · play something in any app to control it here"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// CPU, memory, temperature and network as small rings; a click opens the full status.
private struct SystemGauges: View {
    @Environment(SystemMonitor.self) private var monitor
    @Environment(IslandModel.self) private var model
    @State private var hovering = false

    var body: some View {
        Button { model.statusHandler?() } label: {
            HStack(spacing: 0) {
                MiniGauge(symbol: "cpu", fraction: monitor.cpu.usage / 100, value: "\(Fmt.percent(monitor.cpu.usage))%",
                          label: "CPU", tint: tint(Palette.cpu, monitor.cpu.usage))
                    .frame(maxWidth: .infinity, alignment: .leading)
                MiniGauge(symbol: "memorychip", fraction: monitor.memory.usedPercent / 100,
                          value: "\(Fmt.percent(monitor.memory.usedPercent))%", label: tr("内存", "Memory"),
                          tint: monitor.memory.pressureLevel > 1 ? .orange : Palette.memory)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let celsius = monitor.temperature?.cpu {
                    MiniGauge(symbol: "thermometer.medium", fraction: (celsius - 30) / 70, value: "\(Int(celsius.rounded()))°",
                              label: tr("温度", "Temp"), tint: celsius >= 90 ? .red : celsius >= 75 ? .orange : .mint)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                NetworkGauge(down: monitor.network.down, up: monitor.network.up)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(hovering ? 0.1 : 0.05)))
            .contentShape(.rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .help(tr("打开系统状态", "Open System Status"))
        .accessibilityLabel(tr("系统状态", "System Status"))
    }

    /// Past 90% a gauge turns red.
    private func tint(_ base: Color, _ percent: Double) -> Color {
        percent >= 90 ? Color(red: 1, green: 0.38, blue: 0.36) : base
    }
}

private struct MiniGauge: View {
    let symbol: String
    let fraction: Double
    let value: String
    let label: String
    let tint: Color

    var body: some View {
        HStack(spacing: 6) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.12), lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: min(max(fraction, 0.02), 1))
                    .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.smooth(duration: 0.6), value: fraction)
                Image(systemName: symbol)
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(.white.opacity(0.75))
            }
            .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 0) {
                Text(value)
                    .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText())
                    .animation(.snappy, value: value)
                Text(label)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .lineLimit(1)
            .fixedSize()
        }
    }
}

private struct NetworkGauge: View {
    let down: Double
    let up: Double

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "network")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.down)
                .frame(width: 24, height: 24)
                .background(Circle().stroke(Color.white.opacity(0.12), lineWidth: 2.5))
            VStack(alignment: .leading, spacing: 0) {
                Text("↓ " + Fmt.compactRate(down))
                Text("↑ " + Fmt.compactRate(up))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .font(.system(size: 10, weight: .semibold, design: .rounded).monospacedDigit())
            .lineLimit(1)
            .fixedSize()
        }
    }
}

/// A hairline of progress; it thickens under the pointer and can be dragged to seek.
private struct MiniProgress: View {
    @Environment(NowPlayingService.self) private var media
    @State private var scrub: Double?
    @State private var hovering = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.5, paused: !media.isPlaying || scrub != nil)) { context in
            let duration = media.duration
            let fraction = scrub ?? (duration > 0 ? media.position(at: context.date) / duration : 0)
            let active = hovering || scrub != nil
            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.16))
                    Capsule()
                        .fill(media.accent ?? .white)
                        .frame(width: max(width * min(max(fraction, 0), 1), active ? 5 : 3))
                }
                .frame(height: active ? 5 : 3)
                .frame(maxHeight: .infinity)
                .contentShape(.rect)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { scrub = min(max($0.location.x / max(width, 1), 0), 1) }
                        .onEnded { _ in
                            if let scrub { media.seek(to: scrub * media.duration) }
                            scrub = nil
                        }
                )
            }
            .opacity(duration > 0 ? 1 : 0)
            .animation(.snappy(duration: 0.2), value: active)
        }
        .frame(height: 9)
        .onHover { hovering = $0 }
    }
}

// MARK: - Today

/// The next few things to do today, checkable right here; the rest is one click away.
private struct TodayColumn: View {
    let now: Date
    @Environment(TaskStore.self) private var store
    @Environment(IslandModel.self) private var model

    private static let rows = 3

    var body: some View {
        let tasks = store.overdue(now: now) + store.dueToday(now: now)
        VStack(alignment: .leading, spacing: 5) {
            if tasks.isEmpty {
                let progress = store.progress(now: now)
                Text(progress.total > 0 ? tr("今天的事都做完了", "All done for today") : tr("今天没有安排", "Nothing planned today"))
                    .font(.system(size: 13, weight: .semibold))
                Text(tr("想到什么，随手记下来", "Jot down what comes up"))
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
                Spacer(minLength: 0)
                IslandLinkButton(title: tr("添加任务", "Add a task"), symbol: "plus") { model.tasksHandler?(true) }
            } else {
                ForEach(tasks.prefix(Self.rows)) { task in
                    IslandTaskRow(task: task, now: now)
                        .transition(.asymmetric(insertion: .opacity, removal: .opacity.combined(with: .move(edge: .leading))))
                }
                Spacer(minLength: 0)
                HStack {
                    IslandLinkButton(
                        title: tasks.count > Self.rows ? tr("还有 \(tasks.count - Self.rows) 项", "\(tasks.count - Self.rows) more") : tr("全部任务", "All tasks"),
                        symbol: "chevron.right",
                        trailingSymbol: true
                    ) { model.tasksHandler?(false) }
                    Spacer()
                    IslandLinkButton(title: nil, symbol: "plus") { model.tasksHandler?(true) }
                        .help(tr("添加任务", "Add a task"))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.snappy(duration: 0.35), value: tasks.map(\.id))
    }
}

private struct IslandTaskRow: View {
    let task: TaskItem
    let now: Date
    @Environment(TaskStore.self) private var store
    @Environment(Feedback.self) private var feedback
    @Environment(IslandModel.self) private var model
    @State private var completing = false

    var body: some View {
        HStack(alignment: .top, spacing: 5) {
            CheckCircle(isOn: completing, tint: task.priority.tint, size: 14, action: complete)
                .padding(-3)
            VStack(alignment: .leading, spacing: 1) {
                Text(task.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .strikethrough(completing, color: .white.opacity(0.5))
                    .foregroundStyle(completing ? .white.opacity(0.5) : .white)
                    .lineLimit(1)
                if let label = DateText.dueLabel(task, now: now) {
                    Text(label)
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(DateText.isOverdue(task, now: now) ? Color.red.opacity(0.9) : .white.opacity(0.5))
                }
            }
            .padding(.top, 1)
            Spacer(minLength: 0)
        }
        .contentShape(.rect)
        .onTapGesture { model.tasksHandler?(false) }
        .help(task.title)
    }

    private func complete() {
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
}

private struct IslandLinkButton: View {
    let title: String?
    let symbol: String
    var trailingSymbol = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                if !trailingSymbol { Image(systemName: symbol) }
                if let title { Text(title) }
                if trailingSymbol { Image(systemName: symbol).imageScale(.small) }
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white.opacity(hovering ? 0.95 : 0.6))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.white.opacity(hovering ? 0.14 : 0.07)))
            .contentShape(.capsule)
        }
        .buttonStyle(PressScaleStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}
