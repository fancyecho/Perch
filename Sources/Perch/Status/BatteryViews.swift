import SwiftUI

// MARK: - Shared

private enum PowerPalette {
    static let system = Palette.cpu
    static let battery = Palette.battery
    static let adapter = Color(red: 1.0, green: 0.74, blue: 0.25)
}

/// The state for the overview card (no time), such as “Charging paused”.
private func batteryState(_ b: BatterySnapshot, _ e: BatteryEstimate?) -> String {
    let state: String = switch e?.kind {
    case .toFull, .toLimit: tr("充电中", "Charging")
    case .atLimit(let limit): tr("已达充电上限 \(limit)%", "At charge limit \(limit)%")
    case .full: tr("已充满", "Fully charged")
    case .paused: tr("已暂停充电", "Charging paused")
    case .remaining, nil: b.onAC ? tr("已接通电源", "Plugged in") : tr("使用电池", "On battery")
    }
    return b.lowPowerMode ? state + tr(" · 低电量模式", " · Low Power") : state
}

/// The detail page's left side: only where the power comes from, such as “On power adapter · Low Power Mode”.
private func powerSource(_ b: BatterySnapshot) -> String {
    let source = b.onAC ? (b.isCharging ? tr("正在充电", "Charging") : tr("已接通电源", "Plugged in")) : tr("使用电池", "On battery")
    return b.lowPowerMode ? source + tr(" · 低电量模式", " · Low Power") : source
}

/// The overview card's one-line summary, such as “Charging · 90% in 1:12”.
private func batterySummary(_ b: BatterySnapshot, _ e: BatteryEstimate?) -> String {
    guard let e else { return batteryState(b, nil) }
    // Chinese reads “1:12 后充满” / “38 分钟后充满”, with no space after a word ending in a character.
    let time = e.minutes.map { $0 >= 60 && AppSettings.shared.isChinese ? Fmt.minutes($0) + " " : Fmt.minutes($0) }
    let estimating = tr("估算中", "estimating")
    switch e.kind {
    case .toFull: return tr("充电中 · ", "Charging · ") + (time.map { tr("\($0)后充满", "full in \($0)") } ?? estimating)
    case .toLimit(let limit): return tr("充电中 · ", "Charging · ") + (time.map { tr("\($0)后到 \(limit)%", "\(limit)% in \($0)") } ?? estimating)
    case .remaining: return tr("使用电池 · ", "On battery · ") + (time.map { tr("剩余 \($0)", "\($0) left") } ?? estimating)
    default: return batteryState(b, e)
    }
}

private func wattText(_ value: Double?, signed: Bool = false) -> String {
    guard let value else { return "—" }
    let text = String(format: "%.1f W", abs(value))
    guard signed, abs(value) >= 0.05 else { return text }
    return (value > 0 ? "+" : "−") + text
}

struct StatusBatteryGlyph: View {
    let percent: Int
    let charging: Bool
    var lowPower = false
    var width: CGFloat = 34

    var body: some View {
        let height = width * 0.53
        // As the system does: yellow in Low Power Mode, red when low and not charging, green otherwise.
        let tint = lowPower ? Color(red: 1.0, green: 0.8, blue: 0.0)
            : percent <= 20 && !charging ? Color.red : Palette.battery
        ZStack {
            HStack(spacing: 1.5) {
                RoundedRectangle(cornerRadius: height * 0.28, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.35), lineWidth: 1.2)
                    .overlay(alignment: .leading) {
                        GeometryReader { geo in
                            let fill = RoundedRectangle(cornerRadius: height * 0.17, style: .continuous)
                            fill
                                .fill(tint)
                                .overlay { if charging { ChargingSheen().clipShape(fill) } }
                                .frame(width: max(3, (geo.size.width - 5) * CGFloat(percent) / 100))
                                .padding(2.5)
                        }
                    }
                    .frame(width: width, height: height)
                Capsule().fill(Color.primary.opacity(0.35)).frame(width: 2, height: height * 0.33)
            }
            if charging {
                Image(systemName: "bolt.fill")
                    .font(Typeface.ui(height * 0.55, .bold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.3), radius: 1)
                    .offset(x: -2)
            }
        }
    }
}

// MARK: - 24-hour history

/// The last 24 hours of charge: charging shaded in light green, a dashed line at 20%; hover to read any moment.
private struct BatteryHistoryCard: View {
    let points: [BatteryHistory.Point]
    @StateObject private var hover = HoverLocation()

    var body: some View {
        Tile(title: tr("最近 24 小时", "Last 24 Hours"), symbol: "chart.xyaxis.line", tint: Palette.battery) {
            if points.count >= 2, let low = points.map(\.percent).min(), let high = points.map(\.percent).max() {
                Text("\(low)% – \(high)%").monospacedDigit()
            }
        } content: {
            if points.count < 2 {
                Text(tr("电量记录从现在开始积累，每 5 分钟记一次，退出应用也不会丢失。", "Battery level is recorded every 5 minutes from now on, and kept when you quit the app."))
                    .font(Typeface.ui(10.5))
                    .foregroundStyle(Ink.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                chart.frame(height: 64)
                HStack {
                    Text(tr("24 小时前", "24h ago"))
                    Spacer()
                    Text(tr("12 小时前", "12h ago"))
                    Spacer()
                    Text(tr("现在", "Now"))
                }
                .font(Typeface.ui(9.5, .medium))
                .foregroundStyle(Ink.tertiary)
            }
        }
    }

    private var chart: some View {
        GeometryReader { geo in
            let size = geo.size
            let now = Date()
            let x = { (time: Date) -> CGFloat in
                size.width * CGFloat(1 - now.timeIntervalSince(time) / BatteryHistory.window)
            }
            let y = { (percent: Int) -> CGFloat in size.height - 1 - (size.height - 2) * CGFloat(percent) / 100 }
            let segments = segments()
            ZStack(alignment: .topLeading) {
                // Charging stretches
                ForEach(chargingSpans(), id: \.0) { span in
                    Rectangle()
                        .fill(Palette.battery.opacity(0.13))
                        .frame(width: max(1, x(span.1) - x(span.0)), height: size.height)
                        .offset(x: x(span.0))
                }
                Path { path in
                    path.move(to: CGPoint(x: 0, y: y(20)))
                    path.addLine(to: CGPoint(x: size.width, y: y(20)))
                }
                .stroke(Color.red.opacity(0.35), style: StrokeStyle(lineWidth: 0.8, dash: [2, 3]))
                ForEach(segments.indices, id: \.self) { index in
                    let segment = segments[index]
                    let line = Path { path in
                        for (offset, point) in segment.enumerated() {
                            let p = CGPoint(x: x(point.time), y: y(point.percent))
                            if offset == 0 { path.move(to: p) } else { path.addLine(to: p) }
                        }
                    }
                    closedArea(line, from: x(segment[0].time), to: x(segment[segment.count - 1].time), bottom: size.height)
                        .fill(LinearGradient(colors: [Palette.battery.opacity(0.28), Palette.battery.opacity(0)],
                                             startPoint: .top, endPoint: .bottom))
                    line.stroke(Palette.battery, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                }
                Color.clear
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location): hover.x = location.x
                        case .ended: hover.x = nil
                        }
                    }
                if let hoverX = hover.x, let point = nearest(to: hoverX, width: size.width, now: now) {
                    let px = x(point.time)
                    Group {
                        ReadoutGuide().frame(height: size.height).offset(x: px - 0.5)
                        ReadoutDot(tint: Palette.battery).offset(x: px - 6.5, y: y(point.percent) - 6.5)
                        ReadoutBubble(value: "\(point.percent)%",
                                      detail: point.time.formatted(date: .omitted, time: .shortened) + (point.charging ? tr(" · 充电中", " · charging") : ""))
                            .alignmentGuide(.leading) { d in -min(max(px - d.width / 2, 0), size.width - d.width) }
                            .offset(y: -6)
                    }
                    .allowsHitTesting(false)
                }
            }
            .animation(.interactiveSpring(response: 0.2, dampingFraction: 0.9), value: hover.x.map { Int($0 / 3) })
        }
    }

    private func closedArea(_ line: Path, from start: CGFloat, to end: CGFloat, bottom: CGFloat) -> Path {
        var area = line
        area.addLine(to: CGPoint(x: end, y: bottom))
        area.addLine(to: CGPoint(x: start, y: bottom))
        area.closeSubpath()
        return area
    }

    /// Splits the record into runs at long gaps such as sleep.
    private func segments() -> [[BatteryHistory.Point]] {
        var result: [[BatteryHistory.Point]] = []
        for point in points {
            if let last = result.last?.last, point.time.timeIntervalSince(last.time) <= BatteryHistory.gap {
                result[result.count - 1].append(point)
            } else {
                result.append([point])
            }
        }
        return result
    }

    private func chargingSpans() -> [(Date, Date)] {
        var spans: [(Date, Date)] = []
        for (current, next) in zip(points, points.dropFirst())
        where current.charging && next.time.timeIntervalSince(current.time) <= BatteryHistory.gap {
            if let last = spans.last, last.1 == current.time {
                spans[spans.count - 1].1 = next.time
            } else {
                spans.append((current.time, next.time))
            }
        }
        return spans
    }

    private func nearest(to x: CGFloat, width: CGFloat, now: Date) -> BatteryHistory.Point? {
        let time = now.addingTimeInterval(-BatteryHistory.window * Double(1 - x / width))
        return points.min { abs($0.time.timeIntervalSince(time)) < abs($1.time.timeIntervalSince(time)) }
    }
}

// MARK: - Peripherals

/// Bluetooth peripherals' batteries: a row per device, a small ring per battery.
struct PeripheralsCard: View {
    let devices: [PeripheralBattery]

    var body: some View {
        Tile(title: tr("外设电量", "Peripherals"), symbol: "dot.radiowaves.left.and.right", tint: Palette.down) {
            EmptyView()
        } content: {
            VStack(spacing: 7) {
                ForEach(devices) { device in
                    HStack(spacing: 8) {
                        Image(systemName: device.symbol)
                            .font(Typeface.ui(13, .medium))
                            .foregroundStyle(Ink.secondary)
                            .frame(width: 20)
                        Text(device.name)
                            .font(Typeface.ui(12))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        HStack(spacing: 10) {
                            ForEach(device.levels.indices, id: \.self) { index in
                                LevelRing(level: device.levels[index])
                            }
                        }
                    }
                    .frame(height: 20)
                }
            }
        }
    }
}

private struct LevelRing: View {
    let level: PeripheralBattery.Level

    var body: some View {
        let tint = level.percent <= 20 ? Color.red : Palette.battery
        HStack(spacing: 4) {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.1), lineWidth: 2.2)
                Circle()
                    .trim(from: 0, to: CGFloat(level.percent) / 100)
                    .stroke(tint, style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 13, height: 13)
            Text((level.part.map { $0.label + " " } ?? "") + "\(level.percent)%")
                .font(Typeface.ui(11, .medium))
                .monospacedDigit()
        }
    }
}

// MARK: - Flow line

/// The line between two icons: with current flowing, a string of dots runs in its direction, faster at higher power; without, a faint dashed line.
struct FlowLine: View {
    enum Flow: Equatable {
        case idle
        case forward(watts: Double)
        case backward(watts: Double)
    }

    let flow: Flow
    let tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let dotCount = 3

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: flow == .idle || reduceMotion)) { timeline in
            Canvas { context, size in
                let y = size.height / 2
                var track = Path()
                track.move(to: CGPoint(x: 0, y: y))
                track.addLine(to: CGPoint(x: size.width, y: y))
                guard let (direction, watts) = parameters else {
                    context.stroke(track, with: .color(.primary.opacity(0.12)),
                                   style: StrokeStyle(lineWidth: 1.2, lineCap: .round, dash: [2, 3]))
                    return
                }
                context.stroke(track, with: .color(tint.opacity(0.22)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                if reduceMotion {
                    // Without animation a small arrow shows the direction.
                    let tip = CGPoint(x: direction > 0 ? size.width : 0, y: y)
                    var arrow = Path()
                    arrow.move(to: CGPoint(x: tip.x - direction * 4, y: y - 3.5))
                    arrow.addLine(to: tip)
                    arrow.addLine(to: CGPoint(x: tip.x - direction * 4, y: y + 3.5))
                    context.stroke(arrow, with: .color(tint), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                    return
                }
                // Laps per second: 0.35 (a trickle) up to about 1.25 (60 W and more).
                let speed = 0.35 + min(watts, 60) / 60 * 0.9
                let phase = timeline.date.timeIntervalSinceReferenceDate * speed
                for k in 0..<Self.dotCount {
                    var t = (phase + Double(k) / Double(Self.dotCount)).truncatingRemainder(dividingBy: 1)
                    if direction < 0 { t = 1 - t }
                    // Fading in and out at the ends, as if flowing out of one icon and into the other.
                    let fade = sin(t * .pi)
                    let x = size.width * t
                    let dot = CGRect(x: x - 2.25, y: y - 2.25, width: 4.5, height: 4.5)
                    context.fill(Path(ellipseIn: dot.insetBy(dx: -2, dy: -2)), with: .color(tint.opacity(0.18 * fade)))
                    context.fill(Path(ellipseIn: dot), with: .color(tint.opacity(fade)))
                }
            }
        }
        .accessibilityHidden(true)
    }

    /// Direction (+1 rightward, -1 leftward) and power; nil with no current.
    private var parameters: (Double, Double)? {
        switch flow {
        case .idle: nil
        case .forward(let watts): (1, watts)
        case .backward(let watts): (-1, watts)
        }
    }
}

/// While charging, a soft sheen sweeps across the level from left to right, about every 2.4 seconds.
private struct ChargingSheen: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if !reduceMotion {
            TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
                GeometryReader { geo in
                    let cycle = 2.4
                    let t = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: cycle) / cycle
                    // Sweep through in the first 60% of the time, then rest.
                    let progress = min(t / 0.6, 1)
                    let band = geo.size.width * 0.6
                    LinearGradient(colors: [.white.opacity(0), .white.opacity(0.45), .white.opacity(0)],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: band)
                        .offset(x: -band + (geo.size.width + band) * progress)
                        .opacity(t < 0.6 ? 1 : 0)
                }
            }
            .allowsHitTesting(false)
        }
    }
}

// MARK: - Overview card

/// Elements that share a place between the overview card and the detail page.
private enum BatteryMorph: Hashable {
    case glyph, percent
}

private extension View {
    /// With a namespace they take part in matchedGeometryEffect; without one (static snapshots) they show as they are.
    @ViewBuilder
    func matchedGeometry(_ id: BatteryMorph, in namespace: Namespace.ID?) -> some View {
        if let namespace {
            matchedGeometryEffect(id: id, in: namespace, properties: .position)
        } else {
            self
        }
    }
}

/// The battery summary in the overview; click for the battery details.
struct BatterySummaryCard: View {
    let battery: BatterySnapshot
    let estimate: BatteryEstimate?
    var morph: Namespace.ID?
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                StatusBatteryGlyph(percent: battery.percent, charging: battery.isCharging, lowPower: battery.lowPowerMode)
                    .matchedGeometry(BatteryMorph.glyph, in: morph)
                VStack(alignment: .leading, spacing: 1) {
                    BigNumber(value: "\(battery.percent)", unit: "%", size: 20)
                        .matchedGeometry(BatteryMorph.percent, in: morph)
                    Text(batterySummary(battery, estimate))
                        .font(Typeface.ui(11))
                        .foregroundStyle(Ink.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.9)
                        .frame(height: 14)
                }
                Spacer(minLength: 4)
                VStack(spacing: 2) {
                    Legend(color: PowerPalette.system, label: tr("系统", "System"), value: wattText(battery.systemPower))
                    Legend(color: PowerPalette.battery, label: tr("电池", "Battery"), value: wattText(battery.batteryPower, signed: true))
                }
                .frame(width: AppSettings.shared.isChinese ? 96 : 108)
                DisclosureChevron()
            }
            .padding(11)
            .contentShape(Rectangle())
        }
        .buttonStyle(CardButtonStyle())
        .card()
        .hint(tr("查看电池详情", "Open battery details"))
    }
}

// MARK: - Detail page

struct BatteryDetailView: View {
    @Environment(SystemMonitor.self) private var monitor
    var morph: Namespace.ID?

    var body: some View {
        if let battery = monitor.battery {
            VStack(spacing: 8) {
                hero(battery, monitor.batteryEstimate)
                PowerFlowCard(battery: battery, estimate: monitor.batteryEstimate,
                              systemHistory: monitor.systemPowerHistory,
                              batteryHistory: monitor.batteryPowerHistory)
                BatteryHistoryCard(points: monitor.batteryHistory.points)
                if !monitor.peripherals.isEmpty {
                    PeripheralsCard(devices: monitor.peripherals)
                }
                HealthCard(battery: battery)
            }
        } else {
            Text(tr("没有检测到内置电池", "No internal battery found"))
                .font(Typeface.ui(12))
                .foregroundStyle(Ink.secondary)
                .frame(maxWidth: .infinity, minHeight: 120)
                .card()
        }
    }

    private func hero(_ b: BatterySnapshot, _ e: BatteryEstimate?) -> some View {
        HStack(spacing: 14) {
            StatusBatteryGlyph(percent: b.percent, charging: b.isCharging, lowPower: b.lowPowerMode, width: 46)
                .matchedGeometry(BatteryMorph.glyph, in: morph)
            VStack(alignment: .leading, spacing: 2) {
                BigNumber(value: "\(b.percent)", unit: "%", size: 28)
                    .matchedGeometry(BatteryMorph.percent, in: morph)
                Text(powerSource(b))
                    .font(Typeface.ui(11.5))
                    .foregroundStyle(b.lowPowerMode ? Color(red: 0.85, green: 0.62, blue: 0.0) : Ink.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .frame(height: 15)
            }
            Spacer(minLength: 0)
            TimeEstimateView(estimate: e)
        }
        .padding(12)
        .card()
    }
}

/// The charging progress on the right: a time (large figures and a caption), or paused / at limit / full.
private struct TimeEstimateView: View {
    let estimate: BatteryEstimate?

    var body: some View {
        if let e = estimate {
            VStack(alignment: .trailing, spacing: 2) {
                headline(e)
                Text(caption(e.kind))
                    .font(Typeface.ui(10.5, .medium))
                    .foregroundStyle(Ink.tertiary)
                    .lineLimit(1)
            }
            .hint(help(e))
        }
    }

    @ViewBuilder
    private func headline(_ e: BatteryEstimate) -> some View {
        switch e.kind {
        case .toFull, .toLimit, .remaining:
            if let minutes = e.minutes {
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    ForEach(Array(Fmt.durationParts(minutes).enumerated()), id: \.offset) { _, part in
                        Text(part.0)
                            .font(Typeface.number(20))
                            .tracking(Typeface.tracking(20))
                            .monospacedDigit()
                        Text(part.1)
                            .font(Typeface.ui(11, .medium))
                            .foregroundStyle(Ink.secondary)
                            .padding(.trailing, 2)
                    }
                }
            } else {
                status(tr("估算中…", "Estimating…"), symbol: "hourglass")
            }
        case .paused: status(tr("已暂停充电", "Paused"), symbol: "pause.circle.fill")
        case .atLimit: status(tr("已达上限", "At limit"), symbol: "checkmark.circle.fill")
        case .full: status(tr("已充满", "Full"), symbol: "checkmark.circle.fill")
        }
    }

    private func status(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(Typeface.ui(14, .semibold))
            .foregroundStyle(symbol == "hourglass" ? Ink.secondary : .primary)
            .frame(height: 24)
    }

    private func caption(_ kind: BatteryEstimate.Kind) -> String {
        switch kind {
        case .toFull: tr("充满还需", "until full")
        case .toLimit(let limit): tr("充到 \(limit)% 还需", "until \(limit)%")
        case .remaining: tr("预计还能使用", "remaining")
        case .paused: tr("可能已达系统充电上限", "system charge limit reached?")
        case .atLimit(let limit): tr("充电上限 \(limit)%", "charge limit \(limit)%")
        case .full: tr("电源直接为电脑供电", "running on adapter power")
        }
    }

    private func help(_ e: BatteryEstimate) -> String {
        switch e.kind {
        case .paused:
            tr("接着电源但没有充电。通常是达到了 系统设置 › 电池 里的充电上限，或者系统的「优化电池充电」暂时停在了 80%。",
              "Plugged in but not charging. Usually the charge limit in System Settings › Battery was reached, or Optimized Battery Charging is holding at 80%.")
        case .toFull, .toLimit, .remaining:
            e.fromSystem ? tr("系统给出的估计", "Estimate from macOS")
                : tr("按最近约一分钟的平均功率估算，接近充满时充电会变慢，实际可能稍长",
                    "Based on the average power over the last minute. Charging slows near full, so it may take a little longer.")
        default:
            ""
        }
    }
}

/// In = system + battery: three columns of figures and a segmented bar for where power comes from and goes.
private struct PowerFlowCard: View {
    @Environment(StatusPreferences.self) private var prefs
    let battery: BatterySnapshot
    let estimate: BatteryEstimate?
    let systemHistory: [Double]
    let batteryHistory: [Double]

    var body: some View {
        let b = battery
        Tile(title: tr("电源流向", "Power Flow"), symbol: "bolt.fill", tint: PowerPalette.adapter) {
            if b.onAC {
                Text(verbatim: [b.adapterWatts.map { "\($0) W" }, b.adapterName].compactMap { $0 }.joined(separator: " "))
                    .lineLimit(1)
                    .hint(tr("电源适配器额定功率", "Adapter rated power"))
            }
        } content: {
            VStack(spacing: 5) {
                // Dots flowing between the icons show which way the power goes, faster at higher power.
                ZStack {
                    GeometryReader { geo in
                        let third = geo.size.width / 3
                        let gap: CGFloat = 19
                        FlowLine(flow: inputFlow, tint: PowerPalette.adapter)
                            .frame(width: third - gap * 2, height: 8)
                            .position(x: third, y: geo.size.height / 2)
                        FlowLine(flow: batteryFlow, tint: PowerPalette.battery)
                            .frame(width: third - gap * 2, height: 8)
                            .position(x: third * 2, y: geo.size.height / 2)
                    }
                    HStack(spacing: 0) {
                        badge("powerplug.fill", PowerPalette.adapter, active: b.onAC)
                        badge("laptopcomputer", PowerPalette.system, active: true)
                        badge("battery.75percent", PowerPalette.battery, active: true)
                    }
                }
                .frame(height: 30)
                HStack(alignment: .top, spacing: 0) {
                    column(tr("电源输入", "Adapter"), b.onAC ? wattText(b.adapterPower) : tr("未接电源", "Unplugged"))
                    column(tr("电脑消耗", "System"), wattText(b.systemPower))
                    column(batteryColumnTitle, wattText(b.batteryPower.map(abs)))
                }
            }
            flowBar
                .frame(height: 8)
                .padding(.vertical, 2)
            VStack(alignment: .leading, spacing: 3) {
                Legend(color: PowerPalette.system, label: tr("电脑消耗 · 最近 \(historyMinutes) 分钟", "System · last \(historyMinutes) min"),
                       value: systemHistory.max().map { String(format: tr("峰值 %.1f W", "Peak %.1f W"), $0) } ?? "")
                Sparkline(values: systemHistory, tint: PowerPalette.system,
                          readout: ChartReadout(interval: interval) { [history = systemHistory] in
                              String(format: "%.1f W", history[$0])
                          })
                    .frame(height: 40)
            }
            .padding(.top, 2)
        }
    }

    private var interval: Double { prefs.interval }

    private var batteryColumnTitle: String {
        guard let power = battery.batteryPower, abs(power) >= 0.05 else { return tr("电池", "Battery") }
        return power > 0 ? tr("充入电池", "Charging") : tr("电池放电", "Discharging")
    }

    private var historyMinutes: Int { max(1, Int((Double(systemHistory.count) * interval / 60).rounded())) }

    /// On power: the whole bar is the input, split into the Mac's use and what goes into the battery. On battery: all of it is the Mac's use.
    private var flowBar: some View {
        let b = battery
        let system = max(b.systemPower ?? 0, 0)
        let charge = max(b.batteryPower ?? 0, 0)
        let total = max(system + charge, 0.001)
        return GeometryReader { geo in
            HStack(spacing: 2) {
                Capsule().fill(PowerPalette.system)
                    .frame(width: max(4, (geo.size.width - 2) * system / total))
                if charge >= 0.05 {
                    Capsule().fill(PowerPalette.battery)
                }
            }
        }
        .animation(.easeOut(duration: 0.4), value: system)
        .animation(.easeOut(duration: 0.4), value: charge)
    }

    /// Adapter → Mac: flows while plugged in with power coming in.
    private var inputFlow: FlowLine.Flow {
        guard battery.onAC, let input = battery.adapterPower, input >= 0.05 else { return .idle }
        return .forward(watts: input)
    }

    /// Mac ↔ battery: toward the battery while charging, from it while discharging.
    private var batteryFlow: FlowLine.Flow {
        guard let power = battery.batteryPower, abs(power) >= 0.05 else { return .idle }
        return power > 0 ? .forward(watts: power) : .backward(watts: -power)
    }

    private func badge(_ symbol: String, _ tint: Color, active: Bool) -> some View {
        Image(systemName: symbol)
            .font(Typeface.ui(12.5, .semibold))
            .foregroundStyle(active ? tint : Ink.tertiary)
            .frame(width: 30, height: 30)
            .background { Circle().fill((active ? tint : Color.primary).opacity(active ? 0.15 : 0.06)) }
            .frame(maxWidth: .infinity)
    }

    private func column(_ title: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(Typeface.number(14))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(height: 18)
                .contentTransition(.numericText())
            Text(title)
                .font(Typeface.ui(10.5, .medium))
                .foregroundStyle(Ink.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .animation(.snappy(duration: 0.3), value: value)
    }
}

private struct HealthCard: View {
    let battery: BatterySnapshot

    var body: some View {
        let b = battery
        Tile(title: tr("电池健康", "Battery Health"), symbol: "heart.fill", tint: Color(red: 1.0, green: 0.42, blue: 0.5)) {
            if let full = b.fullCapacity, let design = b.designCapacity {
                Text(verbatim: "\(full) / \(design) mAh").monospacedDigit()
            }
        } content: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                BigNumber(value: b.health.map(String.init) ?? "—", unit: b.health == nil ? "" : "%")
                Text(tr("最大容量", "max capacity"))
                    .font(Typeface.ui(11))
                    .foregroundStyle(Ink.secondary)
                Spacer()
                Text(healthComment)
                    .font(Typeface.ui(11, .medium))
                    .foregroundStyle(healthColor)
            }
            .hint(tr("满充容量与设计容量之比，对应 系统设置 › 电池 › 电池健康 里的\"最大容量\"", "Full-charge capacity compared with design capacity, the same as Maximum Capacity in System Settings › Battery › Battery Health"))
            MeterBar(fraction: Double(b.health ?? 0) / 100, tint: healthColor)
                .padding(.bottom, 4)
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    chip(tr("循环次数", "Cycles"), b.cycles.map { cycles in b.designCycles.map { "\(cycles) / \($0)" } ?? "\(cycles)" })
                    chip(tr("温度", "Temperature"), b.temperature.map { String(format: "%.1f°C", $0) })
                    chip(tr("当前电量", "Charge"), b.currentCapacity.map { "\($0) mAh" })
                }
                GridRow {
                    chip(tr("电压", "Voltage"), b.voltage.map { String(format: "%.2f V", $0) })
                    chip(tr("电流", "Current"), b.amperage.map { String(format: "%@%.2f A", $0 > 0.005 ? "+" : $0 < -0.005 ? "−" : "", abs($0)) })
                    chip(tr("设计容量", "Design capacity"), b.designCapacity.map { "\($0) mAh" })
                }
            }
        }
    }

    private var healthComment: String {
        guard let health = battery.health else { return "" }
        return health >= 80 ? tr("状态良好", "Normal") : tr("建议检查", "Service recommended")
    }

    private var healthColor: Color {
        guard let health = battery.health else { return Palette.battery }
        return health >= 80 ? Palette.battery : .orange
    }

    private func chip(_ label: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(Typeface.ui(10.5, .medium))
                .foregroundStyle(Ink.secondary)
            Text(value ?? "—")
                .font(Typeface.ui(12.5, .semibold))
                .monospacedDigit()
                .foregroundStyle(value == nil ? Ink.tertiary : .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(height: 16)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
