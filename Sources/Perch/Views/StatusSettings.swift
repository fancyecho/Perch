import SwiftUI

/// Settings › Status: the island's gauges, the menu bar readout, sampling, and alerts.
struct StatusPane: View {
    @Bindable private var prefs = StatusPreferences.shared
    @AppStorage(Pref.islandEnabled) private var islandEnabled = true

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $prefs.islandGauges) {
                    SettingLabel(tr("灵动岛的系统状态页", "Status page in the island"),
                                 tr("展开灵动岛后双指上下滑或点边上的圆点切换；点读数打开完整的系统状态",
                                    "In the open island, swipe up or down or click the dots at its edge; click the gauges for the full status"))
                }
                .disabled(!islandEnabled)
                Toggle(isOn: $prefs.menuBarReadout) {
                    SettingLabel(tr("在菜单栏显示读数", "Readout in the menu bar"),
                                 tr("点它打开系统状态面板", "Click it for the status panel"))
                }
                if prefs.menuBarReadout {
                    readoutItem(tr("CPU", "CPU"), "cpu", $prefs.showCPU)
                    readoutItem(tr("CPU 温度", "CPU temperature"), "thermometer.medium", $prefs.showTemperature)
                    readoutItem(tr("内存", "Memory"), "memorychip", $prefs.showMemory)
                    readoutItem("GPU", "square.stack.3d.up", $prefs.showGPU)
                    readoutItem(tr("网速", "Network speed"), "network", $prefs.showNetwork)
                    readoutItem(tr("电池", "Battery"), "battery.75percent", $prefs.showBattery)
                }
            } header: {
                Text(tr("显示", "Show"))
            }

            Section(tr("采样", "Sampling")) {
                Picker(tr("刷新间隔", "Refresh every"), selection: $prefs.interval) {
                    ForEach([1.0, 2.0, 3.0, 5.0], id: \.self) { seconds in
                        Text(tr("\(Int(seconds)) 秒", "\(Int(seconds)) s")).tag(seconds)
                    }
                }
                Picker(selection: $prefs.chargeLimit) {
                    Text(tr("自动", "Auto")).tag(0)
                    ForEach([80, 85, 90, 95, 100], id: \.self) { limit in
                        Text("\(limit)%").tag(limit)
                    }
                } label: {
                    SettingLabel(tr("充电上限", "Charge limit"),
                                 tr("只用来估算充满时间，不改变实际充电；“自动”跟随系统的估计",
                                    "Only for the time-to-full estimate; it doesn't change charging. Auto follows the system"))
                }
            }

            Section {
                alertItem(tr("电量低于 20%", "Battery below 20%"), "battery.25percent", $prefs.alertLowBattery)
                alertItem(tr("CPU 持续过热", "CPU running hot"), "thermometer.high", $prefs.alertHot)
                alertItem(tr("内存压力过高", "Memory pressure critical"), "memorychip", $prefs.alertMemory)
                alertItem(tr("磁盘空间不足 10 GB", "Less than 10 GB of disk"), "internaldrive", $prefs.alertDisk)
                alertItem(tr("进程持续占满 CPU 5 分钟", "A process maxing a core for 5 min"), "flame", $prefs.alertRunaway)
            } header: {
                Text(tr("提醒", "Alerts"))
            } footer: {
                Text(islandEnabled
                     ? tr("在灵动岛上提醒，同一件事有冷却时间，不会反复打扰。", "Shown on the island, each with a cooldown so it doesn't keep interrupting.")
                     : tr("灵动岛关闭时改用系统通知。", "With the island off, these arrive as notifications."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func readoutItem(_ title: String, _ symbol: String, _ isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) { IconLabel(title: title, symbol: symbol) }
            .padding(.leading, 12)
    }

    private func alertItem(_ title: String, _ symbol: String, _ isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) { IconLabel(title: title, symbol: symbol) }
    }
}

/// A label whose icons share one width, so the titles line up.
private struct IconLabel: View {
    let title: String
    let symbol: String

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: symbol).frame(width: 20)
        }
    }
}
