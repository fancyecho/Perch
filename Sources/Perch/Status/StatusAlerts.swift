import Foundation
import UserNotifications

/// Something about the Mac worth interrupting for.
struct SystemAlert: Equatable {
    enum Kind: Equatable {
        case battery, hot, memory, disk
        /// A process holding a whole core for minutes; it can be quit from the alert.
        case runaway(pid_t)
    }

    let id: String
    let kind: Kind
    let title: String
    let detail: String

    var symbol: String {
        switch kind {
        case .battery: "battery.25percent"
        case .hot: "thermometer.high"
        case .memory: "memorychip"
        case .disk: "internaldrive"
        case .runaway: "flame"
        }
    }
}

/// Raises an alert when a threshold is crossed: low battery, a hot CPU, critical memory pressure,
/// a nearly full disk, or a process holding a full core. Each has a cooldown, so the same thing
/// doesn't keep interrupting. The island shows them; without it they become notifications.
final class AlertMonitor {
    private let prefs: StatusPreferences
    var onAlert: ((SystemAlert) -> Void)?
    private var lastFired: [String: Date] = [:]
    private var hotSince: Date?
    /// Which battery level (20%, 10%) was last alerted; reset by plugging in or the level recovering.
    private var batteryNotified: Int?
    private var busySince: [pid_t: Date] = [:]
    private var authorizationRequested = false

    static let lowBatteryLevels = [20, 10]
    static let hotCelsius = 95.0
    static let hotDuration: TimeInterval = 60
    static let lowDiskBytes: Int64 = 10 * 1_000_000_000
    static let busyPercent = 90.0
    static let busyDuration: TimeInterval = 5 * 60

    /// Notification Center exists only when running as an .app; a bare executable from swift build would crash.
    private static let available = Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app")

    init(prefs: StatusPreferences) {
        self.prefs = prefs
    }

    /// Called when any alert is on: the first time it brings up the system's notification permission prompt.
    func requestAuthorizationIfNeeded() {
        guard Self.available, !authorizationRequested, prefs.anyAlertEnabled, onAlert == nil else { return }
        authorizationRequested = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func evaluate(battery: BatterySnapshot?, temperature: Double?, memoryPressure: Int,
                  disk: DiskSnapshot, processes: [ProcessEntry]?, now: Date = Date()) {
        if let battery { checkBattery(battery) }
        checkTemperature(temperature, now: now)
        if prefs.alertMemory, memoryPressure >= 4 {
            fire("memory", kind: .memory, cooldown: 30 * 60, now: now, title: tr("内存压力过高", "Memory pressure is critical"),
                 body: tr("系统开始频繁压缩内存或使用交换空间，可以关闭一些占内存的应用。",
                         "macOS is compressing and swapping heavily. Quitting some memory-hungry apps will help."))
        }
        if prefs.alertDisk, disk.total > 0, disk.free < Self.lowDiskBytes {
            fire("disk", kind: .disk, cooldown: 12 * 3600, now: now, title: tr("磁盘空间不足", "Low disk space"),
                 body: tr("\(disk.name) 只剩 \(Fmt.bytes(Double(disk.free)))，空间太少会影响系统更新和虚拟内存。",
                         "\(disk.name) has only \(Fmt.bytes(Double(disk.free))) left, which can block system updates and virtual memory."))
        }
        if let processes { checkBusyProcesses(processes, now: now) }
    }

    private func checkBattery(_ battery: BatterySnapshot) {
        if battery.onAC || battery.percent >= 30 {
            batteryNotified = nil
            return
        }
        guard prefs.alertLowBattery,
              let level = Self.lowBatteryLevels.last(where: { battery.percent <= $0 }),
              batteryNotified.map({ level < $0 }) ?? true else { return }
        batteryNotified = level
        post(id: "battery", kind: .battery, title: tr("电量只剩 \(battery.percent)%", "Battery at \(battery.percent)%"),
             body: level <= 10 ? tr("请尽快接上电源。", "Plug in soon.")
                 : tr("可以接上电源，或打开低电量模式延长使用时间。", "Plug in, or turn on Low Power Mode to last longer."))
    }

    private func checkTemperature(_ celsius: Double?, now: Date) {
        guard prefs.alertHot, let celsius, celsius >= Self.hotCelsius else {
            hotSince = nil
            return
        }
        let since = hotSince ?? now
        hotSince = since
        guard now.timeIntervalSince(since) >= Self.hotDuration else { return }
        fire("hot", kind: .hot, cooldown: 30 * 60, now: now, title: String(format: tr("CPU 温度 %.0f°C", "CPU at %.0f°C"), celsius),
             body: tr("已经持续一分钟以上处于高温，可以看看是哪个进程在满负荷运行。",
                     "It has been this hot for over a minute. Check which process is running flat out."))
    }

    /// A process holding more than 90% of a core for 5 minutes straight.
    private func checkBusyProcesses(_ processes: [ProcessEntry], now: Date) {
        guard prefs.alertRunaway else {
            busySince.removeAll()
            return
        }
        let busy = processes.filter { $0.cpu >= Self.busyPercent }
        busySince = busySince.filter { pid, _ in busy.contains { $0.id == pid } }
        for process in busy {
            let since = busySince[process.id] ?? now
            busySince[process.id] = since
            guard now.timeIntervalSince(since) >= Self.busyDuration else { continue }
            fire("busy-\(process.id)", kind: .runaway(process.id), cooldown: 3600, now: now, title: tr("\(process.name) 持续占用 CPU", "\(process.name) is maxing out the CPU"),
                 body: String(format: tr("已经连续 %d 分钟占用约 %.0f%% CPU，如果它不该这么忙，可以退出它。",
                                        "It has used about %2$.0f%% CPU for %1$d minutes. If it shouldn't be this busy, quit it."),
                              Int(now.timeIntervalSince(since) / 60), process.cpu))
        }
    }

    private func fire(_ id: String, kind: SystemAlert.Kind, cooldown: TimeInterval, now: Date, title: String, body: String) {
        if let last = lastFired[id], now.timeIntervalSince(last) < cooldown { return }
        lastFired[id] = now
        post(id: id, kind: kind, title: title, body: body)
    }

    private func post(id: String, kind: SystemAlert.Kind, title: String, body: String) {
        if let onAlert {
            onAlert(SystemAlert(id: id, kind: kind, title: title, detail: body))
            return
        }
        guard Self.available else { return }
        requestAuthorizationIfNeeded()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
}
