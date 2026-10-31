import AppKit
import Darwin
import IOKit
import IOKit.ps
import SystemConfiguration
import UniformTypeIdentifiers

// MARK: - Snapshots

struct CPUSnapshot {
    var usage: Double = 0      // 0–100
    var user: Double = 0
    var system: Double = 0
    var cores: [Double] = []   // each core, 0–100
}

struct MemorySnapshot {
    var total: UInt64 = ProcessInfo.processInfo.physicalMemory
    var app: UInt64 = 0
    var wired: UInt64 = 0
    var compressed: UInt64 = 0
    var cached: UInt64 = 0
    var swapUsed: UInt64 = 0
    var pressureLevel: Int = 1 // 1 normal / 2 warning / 4 critical

    var used: UInt64 { app + wired + compressed }
    var usedPercent: Double { total == 0 ? 0 : Double(used) / Double(total) * 100 }
}

struct NetworkSnapshot {
    var down: Double = 0       // bytes/s
    var up: Double = 0
    var totalDown: UInt64 = 0
    var totalUp: UInt64 = 0
    var address: String?
}

nonisolated struct DiskSnapshot: Sendable {
    var name: String = "Macintosh HD"
    var total: Int64 = 0
    var free: Int64 = 0
    var read: Double = 0       // bytes/s
    var write: Double = 0

    var usedPercent: Double { total == 0 ? 0 : Double(total - free) / Double(total) * 100 }
}

struct BatterySnapshot {
    var percent: Int = 0
    var isCharging = false
    var onAC = false
    var fullyCharged = false
    var lowPowerMode = false
    var minutesRemaining: Int?    // the system's estimate: time to full while charging, time left on battery

    // Health
    var health: Int?              // full charge / design capacity: “Maximum Capacity” in System Settings
    var cycles: Int?
    var designCycles: Int?
    var temperature: Double?      // °C
    var currentCapacity: Int?     // mAh
    var fullCapacity: Int?        // mAh
    var designCapacity: Int?      // mAh

    // Electrical
    var voltage: Double?          // V
    var amperage: Double?         // A, positive charging, negative discharging

    // Power flow (W)
    var adapterPower: Double?     // what the adapter actually delivers
    var systemPower: Double?      // what the Mac itself uses
    var batteryPower: Double?     // in or out of the battery, positive charging, negative discharging

    // Power adapter
    var adapterWatts: Int?        // rated power
    var adapterName: String?
}

struct ProcessEntry: Identifiable {
    let id: pid_t
    let name: String
    let icon: NSImage
    let cpu: Double
    let memory: UInt64
}

// MARK: - CPU

final class CPUSampler {
    private var previous: [[UInt32]] = []

    func sample() -> CPUSnapshot {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return CPUSnapshot() }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }

        var current: [[UInt32]] = []
        for i in 0..<Int(cpuCount) {
            let base = Int(CPU_STATE_MAX) * i
            current.append([
                UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]),
                UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]),
                UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]),
                UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]),
            ])
        }
        defer { previous = current }
        guard previous.count == current.count else { return CPUSnapshot(cores: Array(repeating: 0, count: current.count)) }

        var snapshot = CPUSnapshot()
        var sumUser = 0.0, sumSystem = 0.0, sumTotal = 0.0
        for (cur, prev) in zip(current, previous) {
            let user = Double(cur[0] &- prev[0]) + Double(cur[3] &- prev[3])
            let system = Double(cur[1] &- prev[1])
            let idle = Double(cur[2] &- prev[2])
            let total = user + system + idle
            snapshot.cores.append(total > 0 ? (user + system) / total * 100 : 0)
            sumUser += user; sumSystem += system; sumTotal += total
        }
        if sumTotal > 0 {
            snapshot.user = sumUser / sumTotal * 100
            snapshot.system = sumSystem / sumTotal * 100
            snapshot.usage = snapshot.user + snapshot.system
        }
        return snapshot
    }
}

// MARK: - Memory

enum MemorySampler {
    static func sample() -> MemorySnapshot {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        var snapshot = MemorySnapshot()
        guard result == KERN_SUCCESS else { return snapshot }

        var kernelPage: vm_size_t = 0
        host_page_size(mach_host_self(), &kernelPage)
        let page = UInt64(kernelPage)
        let internalPages = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)
        snapshot.app = (internalPages > purgeable ? internalPages - purgeable : 0) * page
        snapshot.wired = UInt64(stats.wire_count) * page
        snapshot.compressed = UInt64(stats.compressor_page_count) * page
        snapshot.cached = (purgeable + UInt64(stats.external_page_count)) * page

        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 {
            snapshot.swapUsed = swap.xsu_used
        }
        snapshot.pressureLevel = Int(SystemInfo.sysctlInt32("kern.memorystatus_vm_pressure_level") ?? 1)
        return snapshot
    }
}

// MARK: - GPU

enum GPUSampler {
    /// 0–100, or nil when it can't be read (in a virtual machine, say).
    static func sample() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        var best: Double?
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard let stats = IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [String: Any],
                  let value = (stats["Device Utilization %"] as? NSNumber)?.doubleValue else { continue }
            best = max(best ?? 0, value)
        }
        return best
    }
}

// MARK: - Network

final class NetworkSampler {
    private var last: (rx: UInt64, tx: UInt64, time: TimeInterval)?
    private var names: [UInt16: String] = [:]

    func sample() -> NetworkSnapshot {
        let (rx, tx) = counters()
        let now = ProcessInfo.processInfo.systemUptime
        var snapshot = NetworkSnapshot(totalDown: rx, totalUp: tx, address: Self.primaryIPv4())
        if let last, now > last.time {
            let dt = now - last.time
            snapshot.down = rx >= last.rx ? Double(rx - last.rx) / dt : 0
            snapshot.up = tx >= last.tx ? Double(tx - last.tx) / dt : 0
        }
        last = (rx, tx, now)
        return snapshot
    }

    private func interfaceName(_ index: UInt16) -> String {
        if let cached = names[index] { return cached }
        var buffer = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
        let name = if_indextoname(UInt32(index), &buffer) != nil ? String(nulTerminated: buffer) : ""
        names[index] = name
        return name
    }

    /// Physical interfaces (en*) only, so VPN tunnels aren't counted twice.
    private func counters() -> (UInt64, UInt64) {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return (0, 0) }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &length, nil, 0) == 0 else { return (0, 0) }

        var rx: UInt64 = 0, tx: UInt64 = 0
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                guard header.ifm_msglen > 0 else { break }
                if Int32(header.ifm_type) == RTM_IFINFO2,
                   offset + MemoryLayout<if_msghdr2>.size <= length {
                    let message = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    if interfaceName(message.ifm_index).hasPrefix("en") {
                        rx += message.ifm_data.ifi_ibytes
                        tx += message.ifm_data.ifi_obytes
                    }
                }
                offset += Int(header.ifm_msglen)
            }
        }
        return (rx, tx)
    }

    static func primaryIPv4() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let head else { return nil }
        defer { freeifaddrs(head) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = head
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let flags = Int32(entry.pointee.ifa_flags)
            guard let address = entry.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0,
                  String(cString: entry.pointee.ifa_name).hasPrefix("en") else { continue }
            var addr = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            if inet_ntop(AF_INET, &addr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil {
                return String(nulTerminated: buffer)
            }
        }
        return nil
    }
}

// MARK: - Disk

final class DiskSampler {
    private var last: (read: UInt64, write: UInt64, time: TimeInterval)?

    private var capacity = DiskSnapshot()
    private var capacityTime: TimeInterval = -.infinity
    private var capacityLoading = false

    func sample() -> DiskSnapshot {
        let now = ProcessInfo.processInfo.systemUptime
        // Asking for free space is slow (up to a few hundred milliseconds), so it runs off the main thread every 30 s;
        // the result lands with the next sample, so opening the panel never stalls its animation.
        if now - capacityTime > 30, !capacityLoading {
            capacityLoading = true
            let first = capacityTime == -.infinity
            capacityTime = now
            if first {
                // The first time reads right away, so there's data from the start.
                if let result = Self.loadCapacity() { capacity = result }
                capacityLoading = false
            } else {
                Task { [weak self] in
                    let result = await Task.detached(priority: .utility) { Self.loadCapacity() }.value
                    guard let self else { return }
                    if let result { capacity = result }
                    capacityLoading = false
                }
            }
        }

        var snapshot = capacity
        let (read, write) = Self.ioCounters()
        if let last, now > last.time {
            let dt = now - last.time
            snapshot.read = read >= last.read ? Double(read - last.read) / dt : 0
            snapshot.write = write >= last.write ? Double(write - last.write) / dt : 0
        }
        last = (read, write, now)
        return snapshot
    }

    /// Asking for free space can take a few hundred milliseconds.
    nonisolated private static func loadCapacity() -> DiskSnapshot? {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeLocalizedNameKey]
        guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys) else { return nil }
        var result = DiskSnapshot()
        result.total = Int64(values.volumeTotalCapacity ?? 0)
        result.free = values.volumeAvailableCapacityForImportantUsage ?? 0
        result.name = values.volumeLocalizedName ?? result.name
        return result
    }

    private static func ioCounters() -> (UInt64, UInt64) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else { return (0, 0) }
        defer { IOObjectRelease(iterator) }

        var read: UInt64 = 0, write: UInt64 = 0
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard let stats = IORegistryEntryCreateCFProperty(entry, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [String: Any] else { continue }
            read += (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            write += (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
        }
        return (read, write)
    }
}

// MARK: - Battery

enum BatterySampler {
    static func sample() -> BatterySnapshot? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }

        for source in sources {
            guard let info = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  info[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }

            var snapshot = BatterySnapshot()
            let current = info[kIOPSCurrentCapacityKey] as? Int ?? 0
            let maximum = max(info[kIOPSMaxCapacityKey] as? Int ?? 100, 1)
            snapshot.percent = Int((Double(current) / Double(maximum) * 100).rounded())
            snapshot.isCharging = info[kIOPSIsChargingKey] as? Bool ?? false
            snapshot.onAC = info[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            snapshot.fullyCharged = info[kIOPSIsChargedKey] as? Bool ?? false
            snapshot.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
            let minutes = snapshot.isCharging ? info[kIOPSTimeToFullChargeKey] as? Int : info[kIOPSTimeToEmptyKey] as? Int
            if let minutes, minutes > 0 { snapshot.minutesRemaining = minutes }
            if let registry = smartBatteryProperties() {
                apply(registry, to: &snapshot)
            }
            return snapshot
        }
        return nil
    }

    static func smartBatteryProperties() -> [String: Any]? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS else { return nil }
        return properties?.takeRetainedValue() as? [String: Any]
    }

    /// Fields sit in different places across models and system versions, at the top level or in BatteryData, so each tries several sources in turn.
    private static func apply(_ dict: [String: Any], to s: inout BatterySnapshot) {
        let batteryData = dict["BatteryData"] as? [String: Any] ?? [:]
        let telemetry = dict["PowerTelemetryData"] as? [String: Any] ?? [:]
        let adapter = dict["AdapterDetails"] as? [String: Any] ?? [:]

        /// Negative numbers are stored unsigned in the IORegistry; int64Value restores them bit for bit.
        func number(_ sources: [([String: Any], String)]) -> Int64? {
            for (d, key) in sources {
                if let n = d[key] as? NSNumber { return n.int64Value }
                // Some fields are arrays (Qmax per cell, say); take the average.
                if let list = d[key] as? [NSNumber], !list.isEmpty {
                    return list.map(\.int64Value).reduce(0, +) / Int64(list.count)
                }
            }
            return nil
        }
        func positive(_ value: Int64?) -> Int? { value.flatMap { $0 > 0 ? Int($0) : nil } }

        // Capacity and health
        s.cycles = positive(number([(dict, "CycleCount"), (batteryData, "CycleCount")]))
        s.designCycles = positive(number([(dict, "DesignCycleCount9C"), (batteryData, "DesignCycleCount9C")]))
        s.designCapacity = positive(number([(dict, "DesignCapacity"), (batteryData, "DesignCapacity")]))
        s.fullCapacity = positive(number([(dict, "NominalChargeCapacity"), (dict, "AppleRawMaxCapacity"),
                                          (batteryData, "NominalChargeCapacity"), (batteryData, "Qmax")]))
        s.currentCapacity = positive(number([(dict, "AppleRawCurrentCapacity"), (batteryData, "RemainingCapacity")]))
        if let design = s.designCapacity, let full = s.fullCapacity {
            let ratio = Double(full) / Double(design) * 100
            if ratio > 30 && ratio < 130 { s.health = min(100, Int(ratio.rounded())) }
        }

        // Temperature: 0.01 °C at the top level; a few models only have it in BatteryData, possibly in 0.1 K, so judge by a plausible range.
        for raw in [number([(dict, "Temperature")]), number([(dict, "VirtualTemperature")]),
                    number([(batteryData, "Temperature")])].compactMap({ $0 }) {
            let celsius = Double(raw) / 100
            let fromKelvin = Double(raw) / 10 - 273.15
            if (5...80).contains(celsius) { s.temperature = celsius; break }
            if (5...80).contains(fromKelvin) { s.temperature = fromKelvin; break }
        }

        // Voltage and current
        if let mv = number([(dict, "Voltage"), (dict, "AppleRawBatteryVoltage"), (batteryData, "Voltage")]), mv > 0 {
            s.voltage = Double(mv) / 1000
        }
        if let ma = number([(dict, "InstantAmperage"), (dict, "Amperage")]) {
            s.amperage = Double(Int32(truncatingIfNeeded: ma)) / 1000
        }
        if let v = s.voltage, let a = s.amperage {
            s.batteryPower = v * a
        }

        // Power telemetry (Apple silicon), in mW
        func watts(_ key: String) -> Double? {
            guard let mw = number([(telemetry, key)]) else { return nil }
            let w = Double(mw) / 1000
            return abs(w) < 500 ? w : nil
        }
        let onAC = s.onAC || (dict["ExternalConnected"] as? Bool ?? false)
        s.onAC = onAC
        if let load = watts("SystemLoad"), load > 0 { s.systemPower = load }
        if onAC, let input = watts("SystemPowerIn"), input > 0 { s.adapterPower = input }

        // Without telemetry, work it out from conservation of energy: input = system use + power into the battery.
        let charging = max(s.batteryPower ?? 0, 0)
        if s.systemPower == nil {
            if onAC, let input = s.adapterPower {
                s.systemPower = max(input - charging, 0)
            } else if !onAC, let battery = s.batteryPower {
                s.systemPower = abs(battery)
            }
        }
        if onAC, s.adapterPower == nil, let system = s.systemPower {
            s.adapterPower = system + charging
        }

        // Adapter
        s.adapterWatts = positive(number([(adapter, "Watts")]))
        if let name = adapter["Name"] as? String, !name.isEmpty {
            s.adapterName = name
        } else if let description = adapter["Description"] as? String, !description.isEmpty {
            s.adapterName = description.lowercased().contains("pd") ? tr("USB-C 电源适配器", "USB-C Power Adapter") : description
        }
    }

}

// MARK: - Processes

struct ProcessSample {
    var byCPU: [ProcessEntry] = []
    var byMemory: [ProcessEntry] = []
}

final class ProcessSampler {
    private var previous: [pid_t: UInt64] = [:]
    private var lastTime: UInt64 = 0
    private var identities: [pid_t: (name: String, icon: NSImage)] = [:]
    private var paths: [pid_t: String] = [:]
    private static let genericIcon = NSWorkspace.shared.icon(for: .unixExecutable)

    func sample(limit: Int = 5) -> ProcessSample {
        let capacity = Int(proc_listallpids(nil, 0)) + 32
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size)))
        guard count > 0 else { return ProcessSample() }

        let now = mach_absolute_time()
        let elapsed = lastTime == 0 ? 0 : Double(now - lastTime)
        var current: [pid_t: UInt64] = [:]
        var rows: [(pid: pid_t, cpu: Double, memory: UInt64)] = []

        for pid in pids.prefix(count) where pid > 0 {
            var info = rusage_info_v6()
            let ok = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V6, $0)
                }
            }
            guard ok == 0 else { continue }
            // CPU time and mach_absolute_time share mach time units, so they divide directly.
            let cpuTime = info.ri_user_time + info.ri_system_time
            current[pid] = cpuTime
            var cpu = 0.0
            if elapsed > 0, let prev = previous[pid], cpuTime >= prev {
                cpu = Double(cpuTime - prev) / elapsed * 100
            }
            rows.append((pid, cpu, info.ri_phys_footprint))
        }
        previous = current
        lastTime = now
        identities = identities.filter { current[$0.key] != nil }
        paths = paths.filter { current[$0.key] != nil }

        func entries(_ sorted: some Sequence<(pid: pid_t, cpu: Double, memory: UInt64)>) -> [ProcessEntry] {
            sorted.prefix(limit).map { row in
                let identity = identity(for: row.pid)
                return ProcessEntry(id: row.pid, name: identity.name, icon: identity.icon, cpu: row.cpu, memory: row.memory)
            }
        }
        return ProcessSample(byCPU: entries(rows.sorted { $0.cpu > $1.cpu }),
                             byMemory: entries(rows.sorted { $0.memory > $1.memory }))
    }

    private func path(for pid: pid_t) -> String {
        if let cached = paths[pid] { return cached }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let path = proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 ? String(nulTerminated: buffer) : ""
        paths[pid] = path
        return path
    }

    private func identity(for pid: pid_t) -> (name: String, icon: NSImage) {
        if let cached = identities[pid] { return cached }

        let path = path(for: pid)
        let app = NSRunningApplication(processIdentifier: pid)

        var name = app?.localizedName ?? (path as NSString).lastPathComponent
        if name.isEmpty {
            var short = [CChar](repeating: 0, count: 64)
            proc_name(pid, &short, UInt32(short.count))
            name = String(nulTerminated: short)
        }

        var icon = app?.icon
        if icon == nil, let range = path.range(of: ".app/") {
            icon = NSWorkspace.shared.icon(forFile: String(path[..<range.lowerBound]) + ".app")
        }
        let identity = (name, icon ?? Self.genericIcon)
        identities[pid] = identity
        return identity
    }
}

// MARK: - System info

enum SystemInfo {
    static func sysctlInt32(_ name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? value : nil
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(nulTerminated: buffer)
    }

    static let chip: String = {
        let brand = sysctlString("machdep.cpu.brand_string") ?? "Mac"
        return brand.replacingOccurrences(of: " (Virtual)", with: "")
    }()

    static let computerName: String = {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Mac"
    }()

    static let osVersion: String = {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return v.patchVersion > 0 ? "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)" : "macOS \(v.majorVersion).\(v.minorVersion)"
    }()

    static var uptime: TimeInterval {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &boot, &size, nil, 0) == 0 else { return ProcessInfo.processInfo.systemUptime }
        return Date().timeIntervalSince1970 - Double(boot.tv_sec)
    }

    static var loadAverage: [Double] {
        var loads = [Double](repeating: 0, count: 3)
        return getloadavg(&loads, 3) == 3 ? loads : []
    }
}

// MARK: - Temperature

struct TemperatureSnapshot: Equatable {
    var cpu: Double?          // average of the chosen sensors
    var cpuMax: Double?       // the hottest of them
    var cpuSensorCount = 0
    var cpuSource = ""
    var gpu: Double?
}

/// Apple silicon's temperatures can only be read from IOKit's HID sensors, whose functions have no public headers, so they're looked up with dlsym.
/// Without them (Intel, a virtual machine, a system that changed the interface) it returns nil and the temperature hides itself.
final class TemperatureSampler {
    private typealias CreateFn = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    private typealias SetMatchingFn = @convention(c) (AnyObject, CFDictionary) -> Int32
    private typealias CopyServicesFn = @convention(c) (AnyObject) -> Unmanaged<CFArray>?
    private typealias CopyPropertyFn = @convention(c) (AnyObject, CFString) -> Unmanaged<AnyObject>?
    private typealias CopyEventFn = @convention(c) (AnyObject, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
    private typealias GetFloatFn = @convention(c) (AnyObject, Int32) -> Double

    private static let temperatureEvent: Int64 = 15

    private var copyEvent: CopyEventFn?
    private var getFloat: GetFloatFn?
    private var client: AnyObject?
    private var cpuSensors: [AnyObject] = []
    private var gpuSensors: [AnyObject] = []
    private var cpuSource = ""

    init() {
        guard let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW),
              let create = dlsym(iokit, "IOHIDEventSystemClientCreate"),
              let setMatching = dlsym(iokit, "IOHIDEventSystemClientSetMatching"),
              let copyServices = dlsym(iokit, "IOHIDEventSystemClientCopyServices"),
              let copyProperty = dlsym(iokit, "IOHIDServiceClientCopyProperty"),
              let copyEvent = dlsym(iokit, "IOHIDServiceClientCopyEvent"),
              let getFloat = dlsym(iokit, "IOHIDEventGetFloatValue") else { return }

        self.copyEvent = unsafeBitCast(copyEvent, to: CopyEventFn.self)
        self.getFloat = unsafeBitCast(getFloat, to: GetFloatFn.self)

        guard let client = unsafeBitCast(create, to: CreateFn.self)(kCFAllocatorDefault)?.takeRetainedValue() else { return }
        self.client = client
        // 0xff00 / 5: Apple's vendor-defined temperature sensors
        _ = unsafeBitCast(setMatching, to: SetMatchingFn.self)(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        let services = (unsafeBitCast(copyServices, to: CopyServicesFn.self)(client)?.takeRetainedValue() as? [AnyObject]) ?? []

        let property = unsafeBitCast(copyProperty, to: CopyPropertyFn.self)
        var accSensors: [AnyObject] = [], dieSensors: [AnyObject] = []
        for service in services {
            guard let name = property(service, "Product" as CFString)?.takeRetainedValue() as? String else { continue }
            if name.contains("pACC") || name.contains("eACC") { accSensors.append(service) }
            else if name.hasPrefix("PMU") && name.contains("tdie") { dieSensors.append(service) }
            else if name.contains("GPU") { gpuSensors.append(service) }
        }
        // M1/M2 have pACC/eACC sensors per core cluster; newer chips fall back to the die temperature (tdie).
        cpuSensors = accSensors.isEmpty ? dieSensors : accSensors
        cpuSource = accSensors.isEmpty ? tr("芯片 die 温度传感器 (PMU tdie)", "chip die sensors (PMU tdie)")
                : tr("CPU 核心簇传感器 (pACC/eACC)", "CPU cluster sensors (pACC/eACC)")
    }

    var isAvailable: Bool { !cpuSensors.isEmpty }

    func sample() -> TemperatureSnapshot? {
        guard isAvailable else { return nil }
        let cpu = readings(cpuSensors)
        let gpu = readings(gpuSensors)
        return TemperatureSnapshot(cpu: Self.average(cpu), cpuMax: cpu.max(), cpuSensorCount: cpu.count,
                                   cpuSource: cpuSource, gpu: Self.average(gpu))
    }

    private func readings(_ sensors: [AnyObject]) -> [Double] {
        guard let copyEvent, let getFloat else { return [] }
        return sensors.compactMap { sensor -> Double? in
            guard let event = copyEvent(sensor, Self.temperatureEvent, 0, 0)?.takeRetainedValue() else { return nil }
            let value = getFloat(event, Int32(Self.temperatureEvent << 16))
            return value > 0 && value < 150 ? value : nil
        }
    }

    private static func average(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }
}

extension String {
    /// The text in a NUL-terminated C buffer.
    nonisolated init(nulTerminated buffer: [CChar]) {
        self.init(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
