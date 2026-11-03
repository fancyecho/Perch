import AppKit
import ServiceManagement

/// What the status page and the menu bar readout show, how often the Mac is sampled, and which
/// alerts come (Settings › Island).
@Observable
final class StatusPreferences {
    static let shared = StatusPreferences()

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
    var alertLowBattery: Bool { didSet { save(alertLowBattery, "alertLowBattery") } }
    var alertHot: Bool { didSet { save(alertHot, "alertHot") } }
    var alertMemory: Bool { didSet { save(alertMemory, "alertMemory") } }
    var alertDisk: Bool { didSet { save(alertDisk, "alertDisk") } }
    var alertRunaway: Bool { didSet { save(alertRunaway, "alertRunaway") } }

    var anyAlertEnabled: Bool { alertLowBattery || alertHot || alertMemory || alertDisk || alertRunaway }

    private static let prefix = "status."
    private static let legacyDomain = "com.helian.Status"
    private static let importedKey = "status.importedFromStatusApp"
    private static let defaults: [String: Any] = [
        "menuBarReadout": false, "islandGauges": true,
        "showCPU": true, "showMemory": true, "showGPU": false, "showNetwork": true, "showBattery": false,
        "showTemperature": true, "interval": 2.0,
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

/// Samples the Mac. The cheap numbers always, for the island's charts, the menu bar readout and the
/// alerts; Wi-Fi, latency and the disk only while the island's status page is open; processes only
/// now and then, for the runaway alert.
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
    private(set) var wifi: WiFiSnapshot?
    private(set) var latency: LatencySnapshot?

    /// The island's charts: the last two minutes or so.
    private(set) var cpuHistory: [Double] = []
    private(set) var memoryHistory: [Double] = []
    private(set) var downHistory: [Double] = []
    private(set) var upHistory: [Double] = []

    let alerts: AlertMonitor

    /// Something shows the details (the island's status page), so they're sampled too.
    var isWatched = false {
        didSet {
            guard isWatched != oldValue, isWatched else { return }
            tick(full: true)
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
    private var lastLatencySample: TimeInterval = -.infinity
    private var latencyLoading = false

    init(prefs: StatusPreferences) {
        self.prefs = prefs
        alerts = AlertMonitor(prefs: prefs)
        alerts.requestAuthorizationIfNeeded()
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
                try? await Task.sleep(for: .seconds(interval), tolerance: .seconds(interval * 0.2))
            }
        }
    }

    /// `full` samples right away for whatever just came on screen, without adding to the charts.
    private func tick(full: Bool = false) {
        let first = tickCount == 0
        // CPU, memory and network are cheap and their charts need continuous data, so they're always sampled.
        cpu = cpuSampler.sample()
        memory = MemorySampler.sample()
        network = networkSampler.sample()

        let readout = prefs.menuBarReadout
        if readout && prefs.showGPU { gpu = GPUSampler.sample() }
        // The rest only as often as what shows it needs: the disk about every minute for its alert,
        // processes about every 30 s for theirs, the battery every 10 s, temperature every 4 s.
        let alertTicks = max(1, Int((30 / prefs.interval).rounded()))
        if isWatched || (prefs.alertDisk && tickCount % (alertTicks * 2) == 0) {
            disk = diskSampler.sample()
        }
        var processes: [ProcessEntry]?
        if prefs.alertRunaway && tickCount % alertTicks == 0 {
            processes = processSampler.sample().byCPU
        }
        if isWatched {
            wifi = WiFiSampler.sample()
            refreshLatency()
        }
        if (readout && prefs.showBattery) || prefs.alertLowBattery, tickCount % 5 == 0 || full {
            battery = BatterySampler.sample()
        }
        if isWatched || ((readout && prefs.showTemperature) || prefs.alertHot) && tickCount % 2 == 0 {
            temperature = temperatureSampler.sample()
        }
        if !first {
            alerts.evaluate(battery: battery, temperature: temperature?.cpu, memoryPressure: memory.pressureLevel,
                            disk: disk, processes: processes)
        }

        // The first sample has no difference yet and extra refreshes would bunch up, so neither goes into the history.
        if !first && !full {
            Self.push(cpu.usage, to: &cpuHistory)
            Self.push(memory.usedPercent, to: &memoryHistory)
            Self.push(network.down, to: &downHistory)
            Self.push(network.up, to: &upHistory)
        }
        if !full { tickCount += 1 }

        guard readout else { return }
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

    /// Latency blocks, so it runs in the background, about every 4 s while it's shown.
    private func refreshLatency() {
        let now = ProcessInfo.processInfo.systemUptime
        guard !latencyLoading, now - lastLatencySample >= 4 else { return }
        latencyLoading = true
        lastLatencySample = now
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) { LatencySampler.sample() }.value
            self?.latency = result
            self?.latencyLoading = false
        }
    }

    private static func push(_ value: Double, to history: inout [Double]) {
        history.append(value)
        if history.count > historyLength { history.removeFirst(history.count - historyLength) }
    }
}
