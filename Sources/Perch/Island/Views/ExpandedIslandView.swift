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
                            // The pages stack like the dots: the status page sits below, so it rises
                            // into place, and going back the player settles down from above.
                            .transition(.islandPage(forward: model.pageMovesForward))
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
            leading
                .id(showsStatus)
                .transition(.opacity.animation(.easeInOut(duration: 0.25)))
        } trailing: {
            trailing
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.white.opacity(0.6))
    }

    @ViewBuilder
    private var leading: some View {
        Group {
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
        }
    }

    private var trailing: some View {
        let today = DateText.today(now)
        return HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(DateText.weekday(today))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color(red: 1, green: 0.36, blue: 0.32))
            Text("\(today.day)")
                .font(.system(size: 19, weight: .semibold, design: .rounded).monospacedDigit())
        }
        .fixedSize()
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
            .overlay(alignment: .trailing) { OutputPicker() }
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

/// Where the sound plays, drawn as the device; a click lists the others to send it to.
private struct OutputPicker: View {
    @Environment(SystemVolume.self) private var volume
    @Environment(BluetoothMonitor.self) private var bluetooth
    @State private var hovering = false

    var body: some View {
        Menu {
            Section(tr("输出到", "Play On")) {
                ForEach(volume.outputs) { output in
                    Toggle(isOn: Binding(get: { output.id == volume.outputID }, set: { _ in volume.selectOutput(output.id) })) {
                        Label(output.route.name, systemImage: bluetooth.refine(output.route).symbol)
                    }
                }
            }
        } label: {
            Image(systemName: bluetooth.refine(volume.route).symbol)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.white.opacity(hovering ? 0.95 : 0.6))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 22, height: 20)
                .background(Circle().fill(Color.white.opacity(hovering ? 0.12 : 0)))
                .contentShape(.circle)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .help(volume.route.name.isEmpty ? tr("选择输出设备", "Choose where it plays") : tr("正在通过「\(volume.route.name)」播放", "Playing on \(volume.route.name)"))
        .accessibilityLabel(tr("输出设备", "Output device"))
    }
}

private struct TimedProgress: View {
    @Environment(NowPlayingService.self) private var media

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let duration = media.duration
            let position = media.position(at: context.date)
            HStack(spacing: 8) {
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
                OutputPicker()
            }
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

/// The island's status page, in four calm rows: the battery and what's connected, the Mac's vital
/// signs as four gauges, the chosen one over the last two minutes, and how full the disk is.
private struct StatusGlance: View {
    @Environment(StatusPreferences.self) private var statusPrefs
    /// Whether to say nothing is playing, when there are no gauges to show instead.
    var showsHint = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StatusHeader()
            if statusPrefs.islandGauges || !showsHint {
                SystemGauges()
                StatusDetail()
                DiskRow()
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

/// The battery, the headphones and where the sound goes, as icons and numbers only; the names are
/// in the tooltips, so nothing gets cut short.
private struct StatusHeader: View {
    @Environment(SystemVolume.self) private var volume
    @Environment(BluetoothMonitor.self) private var bluetooth
    @Environment(PowerMonitor.self) private var power

    var body: some View {
        let devices = Array(bluetooth.devices.prefix(3))
        HStack(spacing: 16) {
            if let battery = power.battery {
                HStack(spacing: 5) {
                    BatteryGlyph(level: battery.level, isCharging: battery.isPluggedIn && battery.isCharging, tint: battery.tint)
                        .frame(width: 19, height: 8.5)
                    Text("\(battery.level)%")
                }
            }
            ForEach(devices) { device in
                HStack(spacing: 4) {
                    Image(systemName: device.symbol)
                    if let level = device.battery.main { Text("\(level)%") }
                }
                .help(device.name)
            }
            // The output is often one of those devices already; then it isn't shown twice.
            if !volume.route.name.isEmpty,
               !devices.contains(where: { $0.name.caseInsensitiveCompare(volume.route.name) == .orderedSame }) {
                Image(systemName: bluetooth.refine(volume.route).symbol)
                    .help(volume.route.name)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 11, weight: .medium).monospacedDigit())
        .foregroundStyle(.white.opacity(0.62))
        .lineLimit(1)
        .padding(.horizontal, 6)
    }
}

/// CPU, memory, temperature and network as small rings, each in an equal slot. CPU, memory and
/// network choose the chart below; temperature is a reading on its own. Each ring stays put in its
/// slot while its number changes width (spreading them with spacers let every new reading nudge
/// all four sideways).
private struct SystemGauges: View {
    @Environment(SystemMonitor.self) private var monitor
    @Environment(IslandModel.self) private var model

    var body: some View {
        HStack(spacing: 6) {
            tile(.cpu) {
                MiniGauge(symbol: "cpu", fraction: monitor.cpu.usage / 100, value: "\(Fmt.percent(monitor.cpu.usage))%",
                          label: "CPU", tint: tint(Palette.cpu, monitor.cpu.usage))
            }
            tile(.memory) {
                MiniGauge(symbol: "memorychip", fraction: monitor.memory.usedPercent / 100,
                          value: "\(Fmt.percent(monitor.memory.usedPercent))%", label: tr("内存", "Memory"),
                          tint: monitor.memory.pressureLevel > 1 ? .orange : Palette.memory)
            }
            if let celsius = monitor.temperature?.cpu {
                MiniGauge(symbol: celsius >= 75 ? "thermometer.high" : celsius >= 50 ? "thermometer.medium" : "thermometer.low",
                          fraction: (celsius - 25) / 75, value: "\(Int(celsius.rounded()))°",
                          label: tr("温度", "Temp"), tint: StatusDetail.temperatureTint(celsius), arc: Self.heat)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 5)
                    .help(monitor.temperature?.gpu.map { "GPU \(Int($0.rounded()))°" } ?? "")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            tile(.network) {
                // Measured against the last two minutes' busiest moment, so the ring shows how busy
                // the link is now compared with lately, and a quiet link stays near empty.
                let peak = max(monitor.downHistory.max() ?? 0, monitor.upHistory.max() ?? 0, 256_000)
                NetworkGauge(down: monitor.network.down, up: monitor.network.up, peak: peak)
            }
        }
    }

    /// The chosen gauge sits on a faint plate; the others step back a little.
    private func tile<Content: View>(_ metric: StatusMetric, @ViewBuilder content: () -> Content) -> some View {
        let selected = StatusDetail.charted(model.statusMetric) == metric
        return Button { model.metricHandler?(metric) } label: {
            content()
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(selected ? 0.09 : 0)))
                .contentShape(.rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .opacity(selected ? 1 : 0.72)
        .animation(.smooth(duration: 0.25), value: selected)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Temperature along the ring: cool mint where it starts, warming to amber and red as it
    /// wraps round, so a hot reading carries its color at the tip.
    private static let heat = AnyShapeStyle(AngularGradient(
        stops: [.init(color: .mint, location: 0), .init(color: .mint, location: 0.3),
                .init(color: .yellow, location: 0.55), .init(color: .orange, location: 0.75),
                .init(color: Color(red: 1, green: 0.32, blue: 0.3), location: 1)],
        center: .center, startAngle: .degrees(-8), endAngle: .degrees(352)))

    /// Past 90% a gauge turns red.
    private func tint(_ base: Color, _ percent: Double) -> Color {
        percent >= 90 ? Color(red: 1, green: 0.38, blue: 0.36) : base
    }
}

/// The chosen gauge over the last two minutes: a chart, and above it what reading it needs, the
/// average and the peak of what's drawn, or the totals the ring can't say.
private struct StatusDetail: View {
    @Environment(SystemMonitor.self) private var monitor
    @Environment(IslandModel.self) private var model

    /// Only CPU, memory and network have a chart; a heat warning opens on the CPU's.
    static func charted(_ metric: StatusMetric) -> StatusMetric {
        metric == .memory || metric == .network ? metric : .cpu
    }

    var body: some View {
        let metric = Self.charted(model.statusMetric)
        let facts = facts(metric)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(facts.0)
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.85))
                Spacer(minLength: 10)
                Text(facts.1)
                    .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(facts.2 ?? .white.opacity(0.45))
            }
            .lineLimit(1)
            chart(metric)
                .frame(height: 30)
        }
        .padding(.horizontal, 6)
        .id(metric)
        .transition(.opacity.animation(.smooth(duration: 0.25)))
    }

    @ViewBuilder
    private func chart(_ metric: StatusMetric) -> some View {
        switch metric {
        case .memory:
            Sparkline(values: monitor.memoryHistory, maxValue: 100, tint: monitor.memory.pressureLevel > 1 ? .orange : Palette.memory)
        case .network:
            MirrorChart(top: monitor.downHistory, bottom: monitor.upHistory, topTint: Palette.down, bottomTint: Palette.up)
        default:
            Sparkline(values: monitor.cpuHistory, maxValue: 100, tint: Palette.cpu)
        }
    }

    /// The headline, the quieter note on the right, and that note's color when it's a warning.
    private func facts(_ metric: StatusMetric) -> (String, String, Color?) {
        switch metric {
        case .memory:
            let m = monitor.memory
            let swap = m.swapUsed > 512 * 1_048_576 ? tr(" · 交换 \(Fmt.memory(m.swapUsed))", " · swap \(Fmt.memory(m.swapUsed))") : ""
            let note: (String, Color?) = switch m.pressureLevel {
            case 4: (tr("内存压力严重", "Critical pressure") + swap, .red)
            case 2: (tr("内存压力偏高", "Pressure rising") + swap, .orange)
            default: (tr("内存压力正常", "Pressure normal") + swap, nil)
            }
            return (tr("已用 \(Fmt.memory(m.used)) / \(Fmt.memory(m.total))", "\(Fmt.memory(m.used)) of \(Fmt.memory(m.total)) used"), note.0, note.1)
        case .network:
            let down = monitor.downHistory.max() ?? monitor.network.down
            let up = monitor.upHistory.max() ?? monitor.network.up
            let link: String
            if let wifi = monitor.wifi {
                let rate = wifi.rate >= 1000 ? String(format: "%.1f Gbps", wifi.rate / 1000) : String(format: "%.0f Mbps", wifi.rate)
                link = "Wi-Fi \(rate)" + (monitor.latency?.internet.map { " · \(Int($0.rounded())) ms" } ?? "")
            } else {
                link = tr("有线网络", "Wired")
            }
            return (tr("峰值 ↓ \(Fmt.rate(down))  ↑ \(Fmt.rate(up))", "Peak ↓ \(Fmt.rate(down))  ↑ \(Fmt.rate(up))"), link, nil)
        default:
            let history = monitor.cpuHistory
            let average = history.isEmpty ? monitor.cpu.usage : history.reduce(0, +) / Double(history.count)
            let hot = (monitor.temperature?.cpu ?? 0) >= 90
            return (tr("平均 \(Fmt.percent(average))% · 峰值 \(Fmt.percent(history.max() ?? monitor.cpu.usage))%",
                       "Average \(Fmt.percent(average))% · peak \(Fmt.percent(history.max() ?? monitor.cpu.usage))%"),
                    tr("用户 \(Fmt.percent(monitor.cpu.user))% · 系统 \(Fmt.percent(monitor.cpu.system))%",
                       "user \(Fmt.percent(monitor.cpu.user))% · system \(Fmt.percent(monitor.cpu.system))%"), hot ? .red : nil)
        }
    }

    static func temperatureTint(_ celsius: Double) -> Color {
        celsius >= 90 ? .red : celsius >= 75 ? .orange : .mint
    }
}

/// How full the disk is: a bar across the page, its share and what's free. The sizes are in the
/// tooltip.
private struct DiskRow: View {
    @Environment(SystemMonitor.self) private var monitor

    var body: some View {
        let disk = monitor.disk
        let fraction = min(max(disk.usedPercent / 100, 0), 1)
        // Silver rather than the dashboard's orange, which a busy memory ring already wears.
        let tint = disk.usedPercent >= 90 ? Color.orange : Color(white: 0.82)
        HStack(spacing: 8) {
            Image(systemName: "internaldrive")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
            Capsule()
                .fill(Color.white.opacity(0.12))
                .overlay(alignment: .leading) {
                    GeometryReader { proxy in
                        Capsule()
                            .fill(LinearGradient(colors: [tint.opacity(0.75), tint], startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(proxy.size.height, proxy.size.width * fraction))
                    }
                }
                .frame(height: 4)
                .animation(.smooth(duration: 0.6), value: fraction)
            Text(tr("\(Fmt.percent(disk.usedPercent))% · \(Fmt.bytes(disk.free)) 可用", "\(Fmt.percent(disk.usedPercent))% · \(Fmt.bytes(disk.free)) free"))
                .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                .foregroundStyle(disk.usedPercent >= 90 ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.white.opacity(0.55)))
                .fixedSize()
        }
        .padding(.horizontal, 6)
        .opacity(disk.total > 0 ? 1 : 0)
        .help(tr("\(disk.name) · 已用 \(Fmt.bytes(disk.total - disk.free)) / \(Fmt.bytes(disk.total))",
                 "\(disk.name) · \(Fmt.bytes(disk.total - disk.free)) of \(Fmt.bytes(disk.total)) used"))
    }
}

private struct MiniGauge: View {
    let symbol: String
    let fraction: Double
    let value: String
    let label: String
    let tint: Color
    /// What the arc is drawn with, when it's more than the tint.
    var arc: AnyShapeStyle?

    var body: some View {
        HStack(spacing: 6) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.12), lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: min(max(fraction, 0.02), 1))
                    .stroke(arc ?? AnyShapeStyle(tint), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
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

/// Download and upload as two halves of one ring, like the chart below it: download fills the right
/// half clockwise from the top, upload the left half the other way.
private struct NetworkGauge: View {
    let down: Double
    let up: Double
    /// The rate a full half stands for.
    let peak: Double

    var body: some View {
        // A square root lifts light traffic off zero without letting a burst swamp everything else.
        let downShare = min(sqrt(down / peak), 1) * 0.5
        let upShare = min(sqrt(up / peak), 1) * 0.5
        HStack(spacing: 6) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.12), lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: max(downShare, 0.01))
                    .stroke(Palette.down, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Circle()
                    .trim(from: 1 - max(upShare, 0.01), to: 1)
                    .stroke(Palette.up, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: "network")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(.white.opacity(0.75))
            }
            .frame(width: 24, height: 24)
            .animation(.smooth(duration: 0.6), value: downShare)
            .animation(.smooth(duration: 0.6), value: upShare)
            VStack(alignment: .leading, spacing: 0) {
                // The arrows take their half's color, tying the numbers to the ring.
                Text("\(Text("↓").foregroundStyle(Palette.down)) \(Fmt.compactRate(down))")
                Text("\(Text("↑").foregroundStyle(Palette.up)) \(Fmt.compactRate(up))")
                    .foregroundStyle(.white.opacity(0.6))
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

/// A page of the open island arriving or leaving: a short rise or fall with a soft blur, the same
/// distance however tall the island grows meanwhile.
private struct PageSlide: ViewModifier {
    let offset: CGFloat
    let blur: CGFloat
    let opacity: Double

    func body(content: Content) -> some View {
        content
            .offset(y: offset)
            .blur(radius: blur)
            .opacity(opacity)
    }
}

extension AnyTransition {
    static func islandPage(forward: Bool) -> AnyTransition {
        .asymmetric(
            insertion: .modifier(active: PageSlide(offset: forward ? 22 : -22, blur: 6, opacity: 0),
                                 identity: PageSlide(offset: 0, blur: 0, opacity: 1))
                .animation(.smooth(duration: 0.42).delay(0.06)),
            removal: .modifier(active: PageSlide(offset: forward ? -14 : 14, blur: 5, opacity: 0),
                               identity: PageSlide(offset: 0, blur: 0, opacity: 1))
                .animation(.easeIn(duration: 0.16))
        )
    }
}
