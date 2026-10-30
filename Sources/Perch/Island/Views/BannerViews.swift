import SwiftUI

/// A short-lived message. Status reaches out sideways at the notch's height (like Alcove's HUDs);
/// a new track or a due task drops down below the notch, where there's room to say more.
struct BannerView: View {
    let banner: IslandBanner
    @Environment(IslandModel.self) private var model

    var body: some View {
        Group {
            if banner.dropsDown {
                VStack(spacing: 0) {
                    Color.clear.frame(height: model.geometry.notchSize.height)
                    dropContent
                        .frame(height: IslandModel.bannerDrop - 4)
                        .padding(.horizontal, 16)
                    Spacer(minLength: 0)
                }
            } else {
                wingContent
            }
        }
        .foregroundStyle(.white)
    }

    @ViewBuilder
    private var wingContent: some View {
        switch banner {
        case .level(let hud): LevelWings(hud: hud)
        case .device(let device, let connected): DeviceWings(device: device, connected: connected)
        case .power(let event): PowerWings(event: event)
        case .route(let route): RouteWings(route: route)
        case .track, .reminder, .alert: EmptyView()
        }
    }

    @ViewBuilder
    private var dropContent: some View {
        switch banner {
        case .track: TrackBanner()
        case .reminder(let task, let alsoDue): ReminderBanner(task: task, alsoDue: alsoDue)
        case .alert(let alert): AlertBanner(alert: alert)
        case .level, .device, .power, .route: EmptyView()
        }
    }
}

// MARK: - Status in the wings

/// Icon and name on the left of the notch, a draggable level bar on the right.
struct LevelWings: View {
    let hud: LevelHUD
    @Environment(IslandModel.self) private var model
    @AppStorage(Pref.hudShowsValue) private var showsValue = false

    var body: some View {
        WingsLayout {
            HStack(spacing: 6) {
                LevelIcon(hud: hud)
                Text(label)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
            }
        } trailing: {
            HStack(spacing: 6) {
                LevelBar(hud: hud) { value in model.levelHandler?(hud.kind, value) }
                    .frame(width: showsValue ? 50 : 74)
                if showsValue {
                    Text(hud.isSilent ? "0" : "\(Int((hud.value * 100).rounded()))")
                        .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.85))
                        .contentTransition(.numericText(value: hud.value))
                        .animation(.snappy, value: hud.value)
                        .frame(width: 22, alignment: .trailing)
                }
            }
        }
    }

    private var label: String {
        switch hud.kind {
        case .volume:
            if hud.isSilent { return tr("静音", "Muted") }
            if let route = hud.route, route.isPersonal, !route.name.isEmpty { return route.name }
            return tr("声音", "Sound")
        case .brightness:
            return tr("亮度", "Display")
        case .keyboard:
            return tr("键盘", "Keyboard")
        }
    }
}

private struct DeviceWings: View {
    let device: BluetoothDevice
    let connected: Bool
    @Environment(BluetoothMonitor.self) private var bluetooth

    var body: some View {
        // Batteries often report a few seconds after connecting; show them as they arrive.
        let battery = bluetooth.devices.first { $0.id == device.id }?.battery ?? device.battery
        WingsLayout {
            HStack(spacing: 6) {
                Image(systemName: device.symbol)
                    .font(.system(size: 14, weight: .medium))
                Text(device.name)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
            }
        } trailing: {
            if !connected {
                Text(tr("已断开", "Disconnected"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            } else if battery.isEmpty {
                Text(tr("已连接", "Connected"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.green)
            } else {
                BatteryReadout(battery: battery)
            }
        }
    }
}

struct BatteryReadout: View {
    let battery: BluetoothBattery

    var body: some View {
        HStack(spacing: 8) {
            if let main = battery.main {
                HStack(spacing: 4) {
                    BatteryRing(level: main, size: 13, lineWidth: 2.5)
                    Text("\(main)%")
                }
            }
            if let caseLevel = battery.caseLevel {
                HStack(spacing: 3) {
                    Image(systemName: "airpods.chargingcase")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.6))
                    Text("\(caseLevel)%")
                }
            }
        }
        .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
        .fixedSize()
    }
}

private struct PowerWings: View {
    let event: PowerEvent
    @Environment(PowerMonitor.self) private var power

    var body: some View {
        let battery = power.battery
        WingsLayout {
            HStack(spacing: 7) {
                if let battery {
                    BatteryGlyph(level: battery.level, isCharging: battery.isPluggedIn && battery.isCharging, tint: tint(battery))
                        .frame(width: 24, height: 11)
                } else {
                    Image(systemName: "leaf.fill").foregroundStyle(.yellow)
                }
                Text(title(battery))
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
            }
        } trailing: {
            if let battery {
                Text("\(battery.level)%")
                    .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(tint(battery))
            }
        }
    }

    private func tint(_ battery: BatteryState) -> Color {
        if case .lowPowerMode(true) = event { return .yellow }
        return battery.tint
    }

    private func title(_ battery: BatteryState?) -> String {
        switch event {
        case .pluggedIn: battery?.isCharging == true ? tr("充电中", "Charging") : tr("已接电源", "Plugged in")
        case .unplugged: tr("使用电池", "On battery")
        case .low: tr("电量不足", "Low battery")
        case .charged: tr("已充满", "Charged")
        case .lowPowerMode(let on): on ? tr("低电量模式", "Low Power") : tr("低电量模式关闭", "Low Power off")
        }
    }
}

private struct RouteWings: View {
    let route: AudioRoute

    var body: some View {
        WingsLayout {
            HStack(spacing: 6) {
                Image(systemName: route.symbol)
                    .font(.system(size: 14, weight: .medium))
                Text(route.name)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
            }
        } trailing: {
            Text(tr("音频输出", "Output"))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
        }
    }
}

// MARK: - Dropping below the notch

private struct TrackBanner: View {
    @Environment(NowPlayingService.self) private var media

    var body: some View {
        HStack(spacing: 10) {
            ArtworkView(size: 30, cornerRadius: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(media.track?.title ?? "")
                    .font(.system(size: 12.5, weight: .semibold))
                Text(media.track?.artist ?? "")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .lineLimit(1)
            Spacer(minLength: 8)
            EqualizerBars(isPlaying: media.isPlaying, tint: media.accent ?? .white, maxHeight: 16)
        }
    }
}

/// A task falling due: complete it or push it back ten minutes without leaving what you're doing.
private struct ReminderBanner: View {
    let task: TaskItem
    let alsoDue: Int
    @Environment(IslandModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @State private var ring = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "bell.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.orange)
                .symbolEffect(.wiggle, options: .repeat(3), value: ring)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(task.title)
                    .font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .lineLimit(1)
            Spacer(minLength: 4)
            ReminderButton(title: tr("稍后", "Later"), isProminent: false) { model.reminderHandler?(task.id, .snooze) }
                .help(tr("10 分钟后再提醒", "Remind me in 10 minutes"))
            ReminderButton(title: tr("完成", "Done"), isProminent: true) { model.reminderHandler?(task.id, .complete) }
        }
        .onAppear { ring.toggle() }
    }

    private var detail: String {
        let time = task.schedule?.time.map(settings.formatTime) ?? ""
        let due = tr("\(time) · 到时间了", "\(time) · Due now")
        return alsoDue > 0 ? due + tr(" · 另有 \(alsoDue) 项", " · \(alsoDue) more") : due
    }
}

/// Something about the Mac worth a look, with the one thing to do about it.
private struct AlertBanner: View {
    let alert: SystemAlert
    @Environment(IslandModel.self) private var model
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: alert.symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(tint)
                .symbolEffect(.pulse, options: .repeat(2), value: pulse)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(alert.title)
                    .font(.system(size: 13, weight: .semibold))
                Text(alert.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .lineLimit(1)
            .help(alert.detail)
            Spacer(minLength: 4)
            ReminderButton(title: actionTitle, isProminent: true) { model.alertHandler?(alert) }
        }
        .onAppear { pulse.toggle() }
    }

    private var tint: Color {
        switch alert.kind {
        case .hot, .runaway: .orange
        case .memory, .disk: .yellow
        case .battery: .red
        }
    }

    private var actionTitle: String {
        if case .runaway = alert.kind { return tr("退出它", "Quit It") }
        return tr("查看", "View")
    }
}

private struct ReminderButton: View {
    let title: String
    let isProminent: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(isProminent ? Color.black : .white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.white.opacity(isProminent ? (hovering ? 1 : 0.9) : (hovering ? 0.22 : 0.14))))
                .contentShape(.capsule)
        }
        .buttonStyle(PressScaleStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}
