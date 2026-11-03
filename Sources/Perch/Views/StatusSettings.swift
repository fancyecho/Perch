import SwiftUI

/// The island page's system status sections: the status page and the menu bar readout, how often
/// the Mac is sampled, and the alerts.
struct StatusSections: View {
    let islandEnabled: Bool
    @Bindable private var prefs = StatusPreferences.shared

    var body: some View {
        Section {
            Toggle(isOn: $prefs.islandGauges) {
                SettingLabel(tr("灵动岛的系统状态页", "Status page in the island"),
                             tr("展开灵动岛后上下滑或点左边的圆点切换", "In the open island, swipe up or down, or click the dots on its left"))
            }
            .disabled(!islandEnabled)
            Toggle(isOn: $prefs.menuBarReadout) {
                SettingLabel(tr("在菜单栏显示读数", "Readout in the menu bar"),
                             tr("点它打开灵动岛的系统状态页", "Click it to open the island's status page"))
            }
            if prefs.menuBarReadout {
                readoutItem(tr("CPU", "CPU"), "cpu", $prefs.showCPU)
                readoutItem(tr("CPU 温度", "CPU temperature"), "thermometer.medium", $prefs.showTemperature)
                readoutItem(tr("内存", "Memory"), "memorychip", $prefs.showMemory)
                readoutItem("GPU", "square.stack.3d.up", $prefs.showGPU)
                readoutItem(tr("网速", "Network speed"), "network", $prefs.showNetwork)
                readoutItem(tr("电池", "Battery"), "battery.75percent", $prefs.showBattery)
            }
            Picker(tr("刷新间隔", "Refresh every"), selection: $prefs.interval) {
                ForEach([1.0, 2.0, 3.0, 5.0], id: \.self) { seconds in
                    Text(tr("\(Int(seconds)) 秒", "\(Int(seconds)) s")).tag(seconds)
                }
            }
        } header: {
            Text(tr("系统状态", "System Status"))
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
