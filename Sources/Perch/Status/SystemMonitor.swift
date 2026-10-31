import AppKit
import ServiceManagement

/// What Status shows and how often it samples (Settings › Status).
@Observable
final class StatusPreferences {
    static let shared = StatusPreferences()

    enum ProcessSort: String, CaseIterable { case cpu, memory }
    enum Page { case overview, battery }

    /// CPU, memory and friends drawn in the menu bar beside Perch's bird.
    var menuBarReadout: Bool { didSet { save(menuBarReadout, "menuBarReadout") } }
    /// Small gauges in the open island.
    var islandGauges: Bool { didSet { save(islandGauges, "islandGauges") } }
    var showCPU: Bool { didSet { save(showCPU, "showCPU") } }
    var showMemory: Bool { didSet { save(showMemory, "showMemory") } }
    var showGPU: Bool { didSet { save(showGPU, "showGPU") } }
    var showNetwork: Bool { didSet { save(showNetwork, "showNetwork") } }
    var showBattery: Bool { didSet { save(showBattery, "showBattery") } }
    var showTemperature: Bool { didSet { save(showTemperature, "showTemperature") } }
    var interval: Double { didSet { save(interval, "interval") } }
    /// 0 follows the system's estimate; 80–100 only shapes the time-to-charge estimate, it never
    /// changes how the Mac charges.
    var chargeLimit: Int { didSet { save(chargeLimit, "chargeLimit") } }
    var processSort: ProcessSort { didSet { save(processSort.rawValue, "processSort") } }
    var alertLowBattery: Bool { didSet { save(alertLowBattery, "alertLowBattery") } }
    var alertHot: Bool { didSet { save(alertHot, "alertHot") } }
    var alertMemory: Bool { didSet { save(alertMemory, "alertMemory") } }
    var alertDisk: Bool { didSet { save(alertDisk, "alertDisk") } }
    var alertRunaway: Bool { didSet { save(alertRunaway, "alertRunaway") } }

    var anyAlertEnabled: Bool { alertLowBattery || alertHot || alertMemory || alertDisk || alertRunaway }

    /// The dashboard's page (not saved).
    var page: Page = .overview

    private static let prefix = "status."
    private static let legacyDomain = "com.helian.Status"
    private static let importedKey = "status.importedFromStatusApp"
    private static let defaults: [String: Any] = [
        "menuBarReadout": false, "islandGauges": true,
        "showCPU": true, "showMemory": true, "showGPU": false, "showNetwork": true, "showBattery": false,
        "showTemperature": true, "interval": 2.0, "chargeLimit": 0, "processSort": ProcessSort.cpu.rawValue,
        "alertLowBattery": true, "alertHot": true, "alertMemory": true, "alertDisk": true, "alertRunaway": true,
    ]

    private init() {
        let store = UserDefaults.standard
        store.register(defaults: Dictionary(uniqueKeysWithValues: Self.defaults.map { (Self.prefix + $0.key, $0.value) }))
        Self.importOnce(into: store)
        func bool(_ key: String) -> Bool { store.bool(forKey: Self.prefix + key) }
        menuBarReadout = bool("menuBarReadout")
        islandGauges = bool("islandGauges")
        showCPU = bool("showCPU")
        showMemory = bool("showMemory")
        showGPU = bool("showGPU")
        showNetwork = bool("showNetwork")
        showBattery = bool("showBattery")
        showTemperature = bool("showTemperature")
        interval = store.double(forKey: Self.prefix + "interval")
        chargeLimit = store.integer(forKey: Self.prefix + "chargeLimit")
        processSort = ProcessSort(rawValue: store.string(forKey: Self.prefix + "processSort") ?? "") ?? .cpu
        alertLowBattery = bool("alertLowBattery")
        alertHot = bool("alertHot")
        alertMemory = bool("alertMemory")
        alertDisk = bool("alertDisk")
        alertRunaway = bool("alertRunaway")
    }

    private func save(_ value: Any, _ key: String) {
        UserDefaults.standard.set(value, forKey: Self.prefix + key)
    }

    /// Takes over the standalone Status app's choices once. Using it meant wanting its menu bar
    /// readout, so that comes on too.
    private static func importOnce(into store: UserDefaults) {
        guard !store.bool(forKey: importedKey) else { return }
        store.set(true, forKey: importedKey)
        guard let legacy = UserDefaults(suiteName: legacyDomain), legacy.object(forKey: "interval") != nil else { return }
        for key in defaults.keys where key != "menuBarReadout" && key != "islandGauges" {
            if let value = legacy.object(forKey: key) { store.set(value, forKey: prefix + key) }
        }
        store.set(true, forKey: prefix + "menuBarReadout")
    }
}

struct BatteryEstimate: Equatable {
    enum Kind: Equatable {
        case toFull            // charging, to 100%
        case toLimit(Int)      // charging, to the set charge limit
        case remaining         // on battery: how long it should last
        case atLimit(Int)      // at the charge limit, charging stopped
        case full              // full
        case paused            // on power but not charging (the system's optimized charging paused it, say)
    }

    var kind: Kind
    var minutes: Int?
    var fromSystem = false
}

/// The few numbers the menu bar shows; set only when they really change.
@Observable
final class MenuBarModel {
    struct Values: Equatable {
        var cpu = 0
        var memory = 0
        var gpu: Int?
        var up = "0B"
        var down = "0B"
        var battery: Int?
        var lowPower = false
        var temperature: Int?
        var charging = false
    }

    private(set) var values = Values()

    func update(_ new: Values) {
        if new != values { values = new }
    }
}

/// Samples the Mac. The cheap numbers always (for the menu bar, the island and alerts); processes,
/// disk, Wi-Fi and latency only while the dashboard is open.
@Observable
final class SystemMonitor {
    static let historyLength = 60

    let menuBar = MenuBarModel()

    private(set) var cpu = CPUSnapshot()
    private(set) var memory = MemorySnapshot()
    private(set) var gpu: Double?
    private(set) var network = NetworkSnapshot()
    private(set) var disk = DiskSnapshot()
    private(set) var battery: BatterySnapshot?
    private(set) var temperature: TemperatureSnapshot?
    private(set) var topByCPU: [ProcessEntry] = []
    private(set) var topByMemory: [ProcessEntry] = []
    private(set) var uptime: TimeInterval = 0
    private(set) var loadAverage: [Double] = []

    private(set) var cpuHistory: [Double] = []
    private(set) var gpuHistory: [Double] = []
    private(set) var downHistory: [Double] = []
    private(set) var upHistory: [Double] = []
    /// Memory in use (%) and CPU temperature (°C), for the island's charts.
    private(set) var memoryHistory: [Double] = []
    private(set) var temperatureHistory: [Double] = []
    private(set) var batteryEstimate: BatteryEstimate?
    private(set) var systemPowerHistory: [Double] = []
    /// Recent battery power for estimating charge and remaining time (timestamped, recorded with the panel closed too).
    private var powerSamples: [(time: TimeInterval, watts: Double)] = []
    private var lastPowerPush: TimeInterval = 0
    private var lastGPUPush: TimeInterval = 0
    private(set) var batteryPowerHistory: [Double] = []

    /// The last 24 hours of charge (saved).
    let batteryHistory = BatteryHistory()
    private(set) var peripherals: [PeripheralBattery] = []
    private(set) var wifi: WiFiSnapshot?
    private(set) var latency: LatencySnapshot?
    let alerts: AlertMonitor
    private var lastLatencySample: TimeInterval = -.infinity
    private var lastPeripheralSample: TimeInterval = -.infinity
    private var lastFullTick: TimeInterval = -.infinity
    private var peripheralWatcher: PeripheralWatcher?
    private var latencyLoading = false
    private var peripheralsLoading = false

    var panelVisible = false {
        didSet {
            guard panelVisible != oldValue else { return }
            if panelVisible {
                // With the panel closed, processes and disk aren't sampled. Opening it samples right away,
                // and again a second later, so process use and disk rates reflect now rather than the closed stretch's average,
                // unless a sample was just taken ahead of time.
                if ProcessInfo.processInfo.systemUptime - lastFullTick > 1.5 {
                    tick(full: true)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.panelVisible else { return }
                        self.tick(full: true)
                    }
                }
            }
        }
    }

    private let prefs: StatusPreferences
    private let cpuSampler = CPUSampler()
    private let networkSampler = NetworkSampler()
    private let diskSampler = DiskSampler()
    private let processSampler = ProcessSampler()
    private let temperatureSampler = TemperatureSampler()
    private var loop: Task<Void, Never>?
    private var tickCount = 0

    init(prefs: StatusPreferences) {
        self.prefs = prefs
        alerts = AlertMonitor(prefs: prefs)
        alerts.requestAuthorizationIfNeeded()
        peripheralWatcher = PeripheralWatcher { [weak self] in self?.peripheralsChanged() }
        start()
    }

    func start() {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.tick()
                // Let the system coalesce this wake-up with other timers, so the CPU wakes less on its own.
                let interval = self.prefs.interval
                try? await Task.sleep(for: .seconds(interval), tolerance: .seconds(interval * 0.15))
            }
        }
    }

    private func tick(full: Bool = false) {
        if full { lastFullTick = ProcessInfo.processInfo.systemUptime }
        let first = tickCount == 0
        let active = full || panelVisible
        // CPU, memory and network are cheap and their charts need continuous data, so they're always sampled.
        cpu = cpuSampler.sample()
        memory = MemorySampler.sample()
        network = networkSampler.sample()

        // These read the IORegistry or walk every process, which costs more: with the panel closed only what's shown elsewhere is sampled.
        if active || prefs.showGPU {
            gpu = GPUSampler.sample()
        }
        // With the panel closed, alerts still get their data now and then: disk about every minute, processes about every 30 s.
        let alertTicks = max(1, Int((30 / prefs.interval).rounded()))
        if active || (prefs.alertDisk && tickCount % (alertTicks * 2) == 0) {
            disk = diskSampler.sample()
        }
        var sampledProcesses: [ProcessEntry]?
        if active || (prefs.alertRunaway && tickCount % alertTicks == 0) {
            let processes = processSampler.sample()
            topByCPU = processes.byCPU
            topByMemory = processes.byMemory
            sampledProcesses = processes.byCPU
        }
        if active {
            wifi = WiFiSampler.sample()
            refreshSlowSamplers(force: full)
        }
        // Battery: every tick with the panel open (the detail page shows live power), every 5th otherwise (menu bar level, estimates).
        if active || tickCount % 5 == 0 {
            battery = BatterySampler.sample()
            if let battery {
                recordPower(battery, chart: active && !full)
                batteryHistory.record(percent: battery.percent, charging: battery.isCharging)
            }
            batteryEstimate = battery.map(estimate)
        }
        // Temperature: every other tick is enough for the menu bar or the heat alert.
        if active || ((prefs.showTemperature || prefs.alertHot) && tickCount % 2 == 0) {
            temperature = temperatureSampler.sample()
        }
        uptime = SystemInfo.uptime
        loadAverage = SystemInfo.loadAverage
        if !first {
            alerts.evaluate(battery: battery, temperature: temperature?.cpu, memoryPressure: memory.pressureLevel,
                            disk: disk, processes: sampledProcesses)
        }

        // The first sample has no difference yet and extra refreshes would bunch up, so neither goes into the history.
        if !first && !full {
            Self.push(cpu.usage, to: &cpuHistory)
            if let gpu {
                // When the GPU went unsampled while the panel was closed, don't join the old curve to new data.
                let now = ProcessInfo.processInfo.systemUptime
                if now - lastGPUPush > prefs.interval * 3 { gpuHistory.removeAll() }
                lastGPUPush = now
                Self.push(gpu, to: &gpuHistory)
            }
            Self.push(network.down, to: &downHistory)
            Self.push(network.up, to: &upHistory)
            Self.push(memory.usedPercent, to: &memoryHistory)
            if let celsius = temperature?.cpu { Self.push(celsius, to: &temperatureHistory) }
        }
        if !full { tickCount += 1 }

        menuBar.update(.init(
            cpu: Int(cpu.usage.rounded()),
            memory: Int(memory.usedPercent.rounded()),
            gpu: gpu.map { Int($0.rounded()) },
            up: Fmt.compactRate(network.up),
            down: Fmt.compactRate(network.down),
            battery: battery?.percent,
            lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
            temperature: temperature?.cpu.map { Int($0.rounded()) },
            charging: battery?.isCharging ?? false
        ))
    }

    /// Latency and peripheral batteries block, so they run in the background: latency about every 4 s, peripherals about every minute (right away on opening).
    private func refreshSlowSamplers(force: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        if !latencyLoading, force || now - lastLatencySample >= 4 {
            latencyLoading = true
            lastLatencySample = now
            Task { [weak self] in
                let result = await Task.detached(priority: .utility) { LatencySampler.sample() }.value
                self?.latency = result
                self?.latencyLoading = false
            }
        }
        // Every 10 s with the panel open; PeripheralWatcher triggers on connecting and disconnecting.
        if force || now - lastPeripheralSample >= 10 { refreshPeripherals() }
    }

    /// A peripheral connected or disconnected: the system may take a second or two to report its battery, so read a few times.
    private func peripheralsChanged() {
        for delay in [0.5, 2.5, 6.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated { self?.refreshPeripherals() }
            }
        }
    }

    private func refreshPeripherals() {
        guard !peripheralsLoading else { return }
        peripheralsLoading = true
        lastPeripheralSample = ProcessInfo.processInfo.systemUptime
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) { PeripheralSampler.sample() }.value
            guard let self else { return }
            peripheralsLoading = false
            if result != peripherals { peripherals = result }
        }
    }


    /// The system's estimate first; while it's still calculating, or with a charge limit set, use the average power of the last minute or so:
    /// time = energy still to go in (or left) in Wh ÷ average power in W.
    private func estimate(_ b: BatterySnapshot) -> BatteryEstimate {
        // 0 = Auto, following the system (whose estimate already allows for its own limit).
        let manualLimit = prefs.chargeLimit > 0 ? prefs.chargeLimit : nil
        let recent = powerSamples.map(\.watts)
        func minutes(_ wattHours: Double, _ rates: [Double]) -> Int? {
            guard !rates.isEmpty else { return nil }
            let rate = rates.reduce(0, +) / Double(rates.count)
            let value = wattHours / rate * 60
            return value.isFinite && value > 0 && value < 24 * 60 ? Int(value.rounded()) : nil
        }

        if b.onAC {
            if b.fullyCharged || b.percent >= 100 { return BatteryEstimate(kind: .full) }
            if let limit = manualLimit, limit < 100, b.percent >= limit, !b.isCharging {
                return BatteryEstimate(kind: .atLimit(limit))
            }
            // On power but not charging: most likely the system's limit or optimized charging paused it.
            guard b.isCharging else { return BatteryEstimate(kind: .paused) }
            // Past the manual limit yet still charging (the two settings disagree): estimate to full, rather than “calculating” forever.
            let target = manualLimit.map { b.percent < $0 ? $0 : 100 } ?? 100
            let kind: BatteryEstimate.Kind = target < 100 ? .toLimit(target) : .toFull
            if target >= 100, let system = b.minutesRemaining {
                return BatteryEstimate(kind: kind, minutes: system, fromSystem: true)
            }
            guard let full = b.fullCapacity, let volts = b.voltage else {
                return BatteryEstimate(kind: kind, minutes: target >= 100 ? b.minutesRemaining : nil)
            }
            let needed = Double(max(target - b.percent, 0)) / 100 * Double(full) * volts / 1000
            return BatteryEstimate(kind: kind, minutes: minutes(needed, recent.filter { $0 > 0.3 }))
        }

        if let system = b.minutesRemaining {
            return BatteryEstimate(kind: .remaining, minutes: system, fromSystem: true)
        }
        guard let volts = b.voltage else { return BatteryEstimate(kind: .remaining) }
        let mAh = Double(b.currentCapacity ?? (b.fullCapacity ?? 0) * b.percent / 100)
        return BatteryEstimate(kind: .remaining, minutes: minutes(mAh * volts / 1000, recent.filter { $0 < -0.3 }.map(abs)))
    }

    /// Charts only record while the panel is open, so points are evenly spaced; too long since the last (the panel was closed) starts over,
    /// so old data isn't joined to new. Recent power for estimates is kept separately by time window.
    private func recordPower(_ b: BatterySnapshot, chart: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        if let watts = b.batteryPower {
            powerSamples.append((now, watts))
            powerSamples.removeAll { now - $0.time > 90 }
        }
        guard chart else { return }
        if now - lastPowerPush > prefs.interval * 3 {
            systemPowerHistory.removeAll()
            batteryPowerHistory.removeAll()
        }
        lastPowerPush = now
        Self.push(b.systemPower ?? 0, to: &systemPowerHistory)
        Self.push(b.batteryPower ?? 0, to: &batteryPowerHistory)
    }

    private static func push(_ value: Double, to history: inout [Double]) {
        history.append(value)
        if history.count > historyLength { history.removeFirst(history.count - historyLength) }
    }
}
