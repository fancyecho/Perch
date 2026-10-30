import ServiceManagement
import SwiftUI

/// The Mac at a glance: CPU, memory, GPU, disk, network, battery and the busiest processes, with
/// the battery's own page. It opens from the island's capsule, or under the menu bar readout.
struct StatusDashboard: View {
    /// Opens Settings › Status.
    let onSettings: () -> Void
    @Environment(SystemMonitor.self) private var monitor
    @Environment(StatusPreferences.self) private var prefs
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var pageHeights = PageHeights()
    @StateObject private var hints = HintCenter()
    /// The morph between the battery card and the battery page: the icon and level fly from the card to the top of the page.
    @Namespace private var batteryMorph

    var body: some View {
        VStack(spacing: 8) {
            header.panelEntrance(0)
            pages
            footer.panelEntrance(6)
        }
        .padding(Metrics.panelPadding)
        .padding(.top, 2)
        .frame(width: StatusPanel.panelWidth)
        .environment(\.hintCenter, hints)
        .overlay(alignment: .topLeading) { HintOverlay(center: hints) }
        .onChange(of: prefs.page) { _, _ in hints.dismiss() }
        .background { PanelSurface() }
        // Switching pages and the height change after it share one spring, and the glass stretches in the same scope.
        .animation(Motion.page, value: prefs.page)
        .animation(Motion.page, value: pageHeights.values[prefs.page])
    }

    /// Old and new pages cross-fade on top of each other; the container springs to the new page's measured height,
    /// and the glass stretches with the same animation.
    private var pages: some View {
        let page = prefs.page
        let height = pageHeights.values[page]
        return ZStack(alignment: .top) {
            pageContent(page)
                .fixedSize(horizontal: false, vertical: true)
                .background { PageHeightReader { pageHeights.update(page, $0) } }
                .id(page)
                .transition(pageTransition(page == .overview ? .leading : .trailing))
        }
        .frame(height: height, alignment: .top)
        // Clip only vertically: the outgoing page overflowing, but leave room at the sides for card shadows.
        .mask { Rectangle().padding(.horizontal, -12).padding(.vertical, -4) }
    }

    @ViewBuilder
    private func pageContent(_ page: StatusPreferences.Page) -> some View {
        switch page {
        case .overview: overview
        case .battery: BatteryDetailView(morph: batteryMorph)
        }
    }

    /// The overview comes and goes from the left, other pages from the right, like turning pages; with Reduce Motion they only fade.
    private func pageTransition(_ edge: Edge) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
        let distance: CGFloat = edge == .leading ? -36 : 36
        // The old page fades fast while the new one slides in with a slight scale, so the two don't overlap for long.
        return .asymmetric(
            insertion: .offset(x: distance).combined(with: .opacity).combined(with: .scale(scale: 0.98, anchor: .top)),
            removal: .offset(x: distance / 2).combined(with: .opacity).animation(Motion.pageExit))
    }

    // MARK: Header / Footer

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 1) {
                Text(SystemInfo.computerName)
                    .font(Typeface.ui(13, .semibold))
                    .lineLimit(1)
                Text("\(SystemInfo.chip) · \(SystemInfo.osVersion) · " + tr("已运行 ", "up ") + Fmt.uptime(monitor.uptime))
                    .font(Typeface.ui(11))
                    .foregroundStyle(Ink.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button { prefs.page == .overview ? onSettings() : (prefs.page = .overview) } label: {
                Image(systemName: prefs.page == .overview ? "slider.horizontal.3" : "chevron.backward")
                    .font(Typeface.ui(12, .medium))
                    .frame(width: 16, height: 16)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(SubtleButtonStyle())
            .hint(prefs.page == .overview ? tr("状态设置", "Status settings") : tr("返回（Esc）", "Back (Esc)"))
        }
        .padding(.horizontal, 2)
        .padding(.bottom, 2)
    }

    private var footer: some View {
        HStack(spacing: 4) {
            Button {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
            } label: {
                Label(tr("活动监视器", "Activity Monitor"), systemImage: "arrow.up.forward.app")
            }
            Spacer()
            Button(action: onSettings) {
                Text(tr("设置…", "Settings…"))
            }
        }
        .font(Typeface.ui(11))
        .foregroundStyle(Ink.secondary)
        .buttonStyle(SubtleButtonStyle())
    }

    // MARK: Overview

    private var overview: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                cpuTile
                memoryTile
            }
            .fixedSize(horizontal: false, vertical: true)
            .panelEntrance(1)

            HStack(spacing: 8) {
                if monitor.gpu != nil { gpuTile }
                diskTile
            }
            .fixedSize(horizontal: false, vertical: true)
            .panelEntrance(2)

            networkCard.panelEntrance(3)
            if let battery = monitor.battery {
                BatterySummaryCard(battery: battery, estimate: monitor.batteryEstimate, morph: batteryMorph) {
                    prefs.page = .battery
                }
                .panelEntrance(4)
            } else if !monitor.peripherals.isEmpty {
                // Desktops have no battery page, so peripheral batteries go straight into the overview.
                PeripheralsCard(devices: monitor.peripherals).panelEntrance(4)
            }
            ProcessCard().panelEntrance(5)
        }
    }

    private var cpuTile: some View {
        Tile(title: "CPU", symbol: "cpu", tint: Palette.cpu) {
            if let t = monitor.temperature, let temp = t.cpu {
                TemperatureBadge(celsius: temp).hint(temperatureHelp(t))
            } else if let load = monitor.loadAverage.first {
                Text(String(format: "%.2f", load)).monospacedDigit().hint(tr("1 分钟平均负载", "1-minute load average"))
            }
        } content: {
            BigNumber(value: Fmt.percent(monitor.cpu.usage), unit: "%")
                .hint(monitor.loadAverage.isEmpty ? "" : tr("平均负载 ", "Load average ") + monitor.loadAverage.map { String(format: "%.2f", $0) }.joined(separator: " / "))
            Sparkline(values: monitor.cpuHistory, maxValue: 100, tint: Palette.cpu,
                      readout: ChartReadout(interval: prefs.interval) { [history = monitor.cpuHistory] in
                          "\(Fmt.percent(history[$0]))%"
                      })
                .frame(minHeight: 24, maxHeight: .infinity)
            CoreBars(cores: monitor.cpu.cores, tint: Palette.cpu)
                .frame(height: 12)
                .hint(tr("每个核心的占用", "Usage of each core"))
            HStack(spacing: 10) {
                Text(tr("用户 ", "User ") + "\(Fmt.percent(monitor.cpu.user))%")
                Text(tr("系统 ", "System ") + "\(Fmt.percent(monitor.cpu.system))%")
            }
            .lineLimit(1)
            .font(Typeface.ui(10.5, .medium))
            .foregroundStyle(Ink.secondary)
            .monospacedDigit()
        }
    }

    private var memoryTile: some View {
        let m = monitor.memory
        let (used, unit) = Fmt.bytesParts(Double(m.used), base: 1024)
        return Tile(title: tr("内存", "Memory"), symbol: "memorychip", tint: Palette.memory) {
            if m.pressureLevel > 1 {
                PressureBadge(level: m.pressureLevel)
            } else {
                Text("\(Fmt.percent(m.usedPercent))%").monospacedDigit()
                    .hint(tr("内存压力正常。macOS 会主动把空闲内存用作缓存并压缩不常用的数据，所以占用高是正常的，只有内存压力升高时才需要关注。", "Memory pressure is normal. macOS uses free memory as cache and compresses data you are not using, so high usage is expected. It only matters when memory pressure rises."))
            }
        } content: {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                BigNumber(value: used, unit: unit)
                Text("/ \(Fmt.memory(m.total))")
                    .font(Typeface.ui(11))
                    .foregroundStyle(Ink.tertiary)
            }
            SegmentBar(segments: [
                (Double(m.app), Palette.memory),
                (Double(m.wired), Palette.memory.opacity(0.6)),
                (Double(m.compressed), Palette.memory.opacity(0.35)),
            ], total: Double(m.total))
            .padding(.vertical, 2)
            VStack(spacing: 2) {
                Legend(color: Palette.memory, label: tr("应用", "App"), value: Fmt.memory(m.app))
                Legend(color: Palette.memory.opacity(0.6), label: tr("联动", "Wired"), value: Fmt.memory(m.wired))
                Legend(color: Palette.memory.opacity(0.35), label: tr("压缩", "Compressed"), value: Fmt.memory(m.compressed))
                Legend(color: Ink.tertiary, label: tr("交换", "Swap"), value: Fmt.memory(m.swapUsed))
            }
        }
    }

    private var gpuTile: some View {
        Tile(title: "GPU", symbol: "square.stack.3d.up", tint: Palette.gpu) {
            if let temp = monitor.temperature?.gpu {
                TemperatureBadge(celsius: temp).hint(tr("GPU 温度", "GPU temperature"))
            }
        } content: {
            BigNumber(value: Fmt.percent(monitor.gpu ?? 0), unit: "%")
            Sparkline(values: monitor.gpuHistory, maxValue: 100, tint: Palette.gpu,
                      readout: ChartReadout(interval: prefs.interval) { [history = monitor.gpuHistory] in
                          "\(Fmt.percent(history[$0]))%"
                      })
                .frame(minHeight: 24, maxHeight: .infinity)
        }
    }

    private var diskTile: some View {
        let d = monitor.disk
        let (free, unit) = Fmt.bytesParts(Double(d.free))
        return Tile(title: d.name, symbol: "internaldrive", tint: Palette.disk) {
            Text("\(Fmt.percent(d.usedPercent))%").monospacedDigit()
        } content: {
            BigNumber(value: free, unit: unit + tr(" 可用", " free"))
            MeterBar(fraction: d.usedPercent / 100, tint: Palette.disk)
                .padding(.vertical, 2)
            VStack(spacing: 2) {
                Legend(color: Palette.disk, label: tr("读取", "Read"), value: Fmt.rate(d.read), symbol: "arrow.down")
                Legend(color: Palette.disk.opacity(0.7), label: tr("写入", "Write"), value: Fmt.rate(d.write), symbol: "arrow.up")
            }
        }
    }

    private var networkCard: some View {
        networkTile(monitor.network)
    }

    private func networkTile(_ n: NetworkSnapshot) -> some View {
        Tile(title: tr("网络", "Network"), symbol: "network", tint: Palette.down) {
            Text(n.address ?? tr("未连接", "Not connected")).monospacedDigit().textSelection(.enabled)
        } content: {
            HStack(alignment: .firstTextBaseline) {
                RateView(symbol: "arrow.down", tint: Palette.down, value: n.down)
                Spacer()
                RateView(symbol: "arrow.up", tint: Palette.up, value: n.up)
            }
            MirrorChart(top: monitor.downHistory, bottom: monitor.upHistory, topTint: Palette.down, bottomTint: Palette.up,
                        readout: ChartReadout(interval: prefs.interval) { [down = monitor.downHistory, up = monitor.upHistory] in
                            "↓ \(Fmt.rate(down[$0]))  ↑ \(Fmt.rate(up.indices.contains($0) ? up[$0] : 0))"
                        })
                .frame(height: 44)
            NetworkQualityRow(wifi: monitor.wifi, latency: monitor.latency)
            HStack {
                Text(tr("开机以来", "Since boot") + "  ↓ \(Fmt.bytes(n.totalDown))  ↑ \(Fmt.bytes(n.totalUp))")
                Spacer(minLength: 8)
                Text(tr("峰值 ", "Peak ") + Fmt.rate(max(monitor.downHistory.max() ?? 0, monitor.upHistory.max() ?? 0)))
            }
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .frame(height: 14)
            .font(Typeface.ui(10.5, .medium))
            .foregroundStyle(Ink.tertiary)
            .monospacedDigit()
        }
    }
}

// MARK: - Pieces

/// Under the network card: Wi-Fi bars with strength and link rate, and latency to the router and the internet on the right.
private struct NetworkQualityRow: View {
    let wifi: WiFiSnapshot?
    let latency: LatencySnapshot?

    var body: some View {
        HStack(spacing: 8) {
            if let wifi {
                HStack(spacing: 4) {
                    Image(systemName: "wifi", variableValue: wifi.strength)
                        .font(Typeface.ui(10, .semibold))
                        .foregroundStyle(Palette.down)
                    Text(verbatim: wifi.rate >= 1000 ? String(format: "%.1f Gbps", wifi.rate / 1000) : String(format: "%.0f Mbps", wifi.rate))
                }
                .hint(help(for: wifi))
            } else {
                Label(tr("有线或未连接 Wi-Fi", "Wired or no Wi-Fi"), systemImage: "cable.connector.horizontal")
                    .labelStyle(.titleAndIcon)
            }
            Spacer(minLength: 4)
            HStack(spacing: 10) {
                if let gateway = latency?.gateway { chip(tr("网关", "Router"), gateway) }
                chip(tr("互联网", "Internet"), latency?.internet)
            }
            .fixedSize()
            .hint(latencyHint)
        }
        .lineLimit(1)
        .font(Typeface.ui(10.5, .medium))
        .foregroundStyle(Ink.secondary)
        .monospacedDigit()
        .frame(height: 14)
    }

    private var latencyHint: String {
        var lines = [tr("往返延迟（越低越好）", "Round-trip latency (lower is better)")]
        if let gateway = latency?.gateway { lines.append(tr("网关（你的路由器）", "Router") + String(format: "：%.0f ms", gateway)) }
        lines.append(tr("互联网取以下任播 DNS 中最快的一个：", "Internet is the fastest of these anycast DNS servers:"))
        for target in latency?.targets ?? [] {
            lines.append("  \(target.name) \(target.host)  " + (target.milliseconds.map { String(format: "%.0f ms", $0) } ?? tr("无响应", "no reply")))
        }
        return lines.joined(separator: "\n")
    }

    /// Returns a String (not a literal) so .help shows it as is, without localizing or grouping digits.
    private func help(for wifi: WiFiSnapshot) -> String {
        let band = wifi.band.isEmpty ? "" : tr("（\(wifi.band)）", " (\(wifi.band))")
        return tr("Wi-Fi 信号 \(wifi.rssi) dBm，噪声 \(wifi.noise) dBm，信噪比 \(wifi.rssi - wifi.noise) dB\n信道 \(wifi.channel)\(band)，当前速率 \(Int(wifi.rate)) Mbps",
                 "Wi-Fi signal \(wifi.rssi) dBm, noise \(wifi.noise) dBm, SNR \(wifi.rssi - wifi.noise) dB\nChannel \(wifi.channel)\(band), link rate \(Int(wifi.rate)) Mbps")
    }

    private func chip(_ label: String, _ milliseconds: Double?) -> some View {
        let color: Color = switch milliseconds {
        case nil: Ink.tertiary
        case let value? where value < 60: Palette.battery
        case let value? where value < 150: Color.orange
        default: Color.red
        }
        return HStack(spacing: 4) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(verbatim: label)
            HStack(alignment: .firstTextBaseline, spacing: 1.5) {
                Text(verbatim: milliseconds.map { String(format: "%.0f", $0) } ?? "—")
                    .foregroundStyle(.primary)
                Text(verbatim: "ms")
                    .font(Typeface.ui(9.5, .medium))
                    .foregroundStyle(Ink.tertiary)
            }
        }
        .fixedSize()
    }
}

private func temperatureHelp(_ t: TemperatureSnapshot) -> String {
    var lines = [tr("CPU 温度：\(t.cpuSensorCount) 个传感器的平均值", "CPU temperature: average of \(t.cpuSensorCount) sensors")]
    if let max = t.cpuMax { lines.append(String(format: tr("其中最高 %.0f°C", "Hottest %.0f°C"), max)) }
    lines.append(tr("来源：", "Source: ") + t.cpuSource)
    return lines.joined(separator: "\n")
}

private struct RateView: View {
    let symbol: String
    let tint: Color
    let value: Double

    var body: some View {
        let (number, unit) = Fmt.bytesParts(value)
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: symbol)
                .font(Typeface.ui(11, .bold))
                .foregroundStyle(tint)
            BigNumber(value: number, unit: "\(unit)/s", size: 20)
        }
    }
}

private struct TemperatureBadge: View {
    let celsius: Double

    var body: some View {
        let color: Color = celsius >= 95 ? .red : celsius >= 80 ? .orange : Ink.secondary
        HStack(spacing: 2) {
            Image(systemName: "thermometer.medium")
            Text(String(format: "%.0f°C", celsius)).monospacedDigit()
        }
        .foregroundStyle(color)
    }
}

private struct PressureBadge: View {
    let level: Int

    var body: some View {
        let (text, color): (String, Color) = level >= 4 ? (tr("压力过高", "Critical"), .red) : (tr("压力偏高", "High"), .orange)
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(text)
        }
        .foregroundStyle(color)
        .hint(tr("系统内存压力升高，可能开始频繁压缩或使用交换空间，可以关闭一些占内存的应用。", "Memory pressure is rising and the system may start compressing or swapping heavily. Quitting some memory-hungry apps will help."))
    }
}

private struct ProcessCard: View {
    @Environment(SystemMonitor.self) private var monitor
    @Environment(StatusPreferences.self) private var prefs

    var body: some View {
        @Bindable var prefs = prefs
        let rows = prefs.processSort == .cpu ? monitor.topByCPU : monitor.topByMemory
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "list.bullet")
                    .font(Typeface.ui(10, .bold))
                    .foregroundStyle(Ink.secondary)
                Text(tr("进程", "Processes"))
                    .font(Typeface.ui(11, .medium))
                    .foregroundStyle(Ink.secondary)
                Spacer()
                GlassSegmentedControl(tr("进程排序", "Sort processes"), selection: $prefs.processSort,
                                      options: [(.cpu, "CPU"), (.memory, tr("内存", "Memory"))], height: 18)
            }
            VStack(spacing: 3) {
                ForEach(rows) { row in
                    ProcessRow(row: row, value: prefs.processSort == .cpu
                               ? String(format: "%.1f%%", row.cpu) : Fmt.memory(row.memory))
                }
            }
            // When the ranking changes the rows slide to their new places instead of the text jumping.
            .animation(.snappy(duration: 0.35), value: rows.map(\.id))
            // Five rows tall from the start, so the card doesn't shrink before the first processes are sampled.
            .frame(height: 5 * 20 + 4 * 3, alignment: .top)
        }
        .padding(10)
        .card()
    }
}

/// A process row: highlighted under the pointer; right-click to show it in Finder or quit the app.
private struct ProcessRow: View {
    let row: ProcessEntry
    let value: String
    @StateObject private var hover = HoverState()

    var body: some View {
        let app = NSRunningApplication(processIdentifier: row.id)
        HStack(spacing: 8) {
            Image(nsImage: row.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 16, height: 16)
            Text(row.name)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text(value)
                .monospacedDigit()
                .foregroundStyle(Ink.secondary)
                .contentTransition(.numericText())
        }
        .font(Typeface.ui(12))
        .frame(height: 20)
        .padding(.horizontal, 5)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(hover.hovering ? 0.06 : 0))
        }
        .padding(.horizontal, -5)
        .contentShape(Rectangle())
        .onHover { hover.hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hover.hovering)
        .hint("\(row.name)\nPID \(row.id) · CPU \(String(format: "%.1f%%", row.cpu)) · " + tr("内存 ", "Memory ") + Fmt.memory(row.memory) + "\n" + tr("右键查看更多操作", "Right-click for more actions"))
        .contextMenu {
            if let url = app?.bundleURL {
                Button(tr("在访达中显示", "Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
            if let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier, app.activationPolicy == .regular {
                Button(tr("切换到 ", "Switch to ") + row.name) { app.activate() }
                Divider()
                Button(tr("退出 ", "Quit ") + row.name) { app.terminate() }
            }
            Button(tr("拷贝 PID ", "Copy PID ") + "\(row.id)") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("\(row.id)", forType: .string)
            }
        }
    }
}

// MARK: - Page height

/// Each page's measured height; switching pages animates the container straight to the new one.
@MainActor
private final class PageHeights: ObservableObject {
    @Published private(set) var values: [StatusPreferences.Page: CGFloat] = [:]

    func update(_ page: StatusPreferences.Page, _ height: CGFloat) {
        guard height > 0, abs((values[page] ?? 0) - height) > 0.5 else { return }
        values[page] = height
    }
}

private struct PageHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct PageHeightReader: View {
    let onChange: (CGFloat) -> Void

    var body: some View {
        GeometryReader { geo in
            Color.clear.preference(key: PageHeightKey.self, value: geo.size.height)
        }
        .onPreferenceChange(PageHeightKey.self) { height in
            MainActor.assumeIsolated { onChange(height) }
        }
    }
}
