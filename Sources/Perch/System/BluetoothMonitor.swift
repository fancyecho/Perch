import CoreBluetooth
import Foundation
import IOBluetooth
import IOKit
import Observation
import Synchronization

nonisolated struct BluetoothBattery: Equatable, Sendable {
    var single: Int?
    var left: Int?
    var right: Int?
    var caseLevel: Int?

    /// Both earbuds, or the device itself: whichever is lower, since that is what runs out first.
    var main: Int? {
        if let single { return single }
        switch (left, right) {
        case let (left?, right?): return min(left, right)
        case let (left?, nil): return left
        case let (nil, right?): return right
        case (nil, nil): return nil
        }
    }

    var isEmpty: Bool { main == nil && caseLevel == nil }
}

nonisolated struct BluetoothDevice: Identifiable, Equatable, Sendable {
    let id: String
    var name: String
    var symbol: String
    var battery: BluetoothBattery
}

/// Connected Bluetooth devices with their battery levels, and word of every connect and disconnect.
/// IOBluetooth asks for Bluetooth permission the first time this starts.
@Observable
final class BluetoothMonitor: NSObject {
    private(set) var devices: [BluetoothDevice] = []

    @ObservationIgnored var onConnect: ((BluetoothDevice) -> Void)?
    @ObservationIgnored var onDisconnect: ((BluetoothDevice) -> Void)?

    @ObservationIgnored private var connectNotification: IOBluetoothUserNotification?
    @ObservationIgnored private var disconnectNotifications: [String: IOBluetoothUserNotification] = [:]
    @ObservationIgnored private var startedAt = Date.distantPast
    @ObservationIgnored private var batteryTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var modelTask: Task<Void, Never>?
    @ObservationIgnored private var startTask: Task<Void, Never>?

    /// Without a usage description macOS kills the process on first use, as with a bare `swift run`.
    static var isUsable: Bool {
        Bundle.main.object(forInfoDictionaryKey: "NSBluetoothAlwaysUsageDescription") != nil
    }

    func start() {
        guard connectNotification == nil, startTask == nil, Self.isUsable else { return }
        startTask = Task { [weak self] in
            let allowed = await Self.prepare()
            guard let self, !Task.isCancelled else { return }
            self.startTask = nil
            guard allowed else { return }
            self.startedAt = .now
            self.connectNotification = IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(self.deviceConnected(_:device:)))
        }
    }

    /// IOBluetooth sets itself up on first use and blocks until the Bluetooth permission prompt is
    /// answered, so make that first use here, off the main thread.
    @concurrent
    nonisolated private static func prepare() async -> Bool {
        if CBManager.authorization == .denied || CBManager.authorization == .restricted { return false }
        let selector = NSSelectorFromString("sharedInstance")
        if let coordinator = NSClassFromString("IOBluetoothCoreBluetoothCoordinator") as? NSObject.Type,
           coordinator.responds(to: selector) {
            _ = coordinator.perform(selector)
        }
        return CBManager.authorization == .allowedAlways
    }

    func stop() {
        startTask?.cancel()
        startTask = nil
        connectNotification?.unregister()
        connectNotification = nil
        disconnectNotifications.values.forEach { $0.unregister() }
        disconnectNotifications = [:]
        batteryTasks.values.forEach { $0.cancel() }
        batteryTasks = [:]
        devices = []
    }

    /// An audio output that is one of these devices takes the device's own symbol: CoreAudio only
    /// knows the name, which draws AirPods 3 as the generic AirPods.
    func refine(_ route: AudioRoute) -> AudioRoute {
        guard let device = devices.first(where: { $0.name.caseInsensitiveCompare(route.name) == .orderedSame }) else { return route }
        var refined = route
        refined.symbol = device.symbol
        return refined
    }

    /// Re-reads every battery, for when the levels are about to be on screen.
    func refreshBatteries() {
        for device in devices {
            guard let bluetooth = IOBluetoothDevice(addressString: device.id) else { continue }
            update(Self.describe(bluetooth, id: device.id))
        }
    }

    // IOBluetooth calls these on CoreBluetooth's own queue, not the main thread: read what's needed
    // there, then carry on on the main actor.
    @objc nonisolated private func deviceConnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        guard let address = device.addressString else { return }
        let info = Self.describe(device, id: address)
        Task { @MainActor [weak self] in self?.connected(info) }
    }

    @objc nonisolated private func deviceDisconnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        guard let address = device.addressString else { return }
        let fallback = Self.describe(device, id: address)
        Task { @MainActor [weak self] in self?.disconnected(address, fallback: fallback) }
    }

    private func connected(_ info: BluetoothDevice) {
        guard connectNotification != nil, let device = IOBluetoothDevice(addressString: info.id) else { return }
        disconnectNotifications[info.id]?.unregister()
        disconnectNotifications[info.id] = device.register(forDisconnectNotification: self, selector: #selector(deviceDisconnected(_:device:)))
        update(info)
        lookUpModels()
        // Registering reports the devices that were already connected; those aren't news.
        if Date.now.timeIntervalSince(startedAt) > 2 { onConnect?(info) }
        followBattery(of: info.id)
    }

    private func disconnected(_ address: String, fallback: BluetoothDevice) {
        disconnectNotifications.removeValue(forKey: address)?.unregister()
        batteryTasks.removeValue(forKey: address)?.cancel()
        let info = devices.first { $0.id == address } ?? fallback
        devices.removeAll { $0.id == address }
        onDisconnect?(info)
    }

    private func update(_ device: BluetoothDevice) {
        if let index = devices.firstIndex(where: { $0.id == device.id }) {
            if devices[index] != device { devices[index] = device }
        } else {
            devices.append(device)
        }
    }

    /// IOBluetooth often won't say which model a device is, so ask system_profiler (no permission
    /// needed) and redraw with the right symbol, AirPods 3 rather than the generic AirPods.
    private func lookUpModels() {
        guard modelTask == nil else { return }
        modelTask = Task { [weak self] in
            await Self.loadAppleModels()
            guard let self else { return }
            modelTask = nil
            for device in devices {
                guard let bluetooth = IOBluetoothDevice(addressString: device.id) else { continue }
                update(Self.describe(bluetooth, id: device.id))
            }
        }
    }

    /// Headphones report their batteries a few seconds after connecting, so look again a few times.
    private func followBattery(of address: String) {
        batteryTasks[address]?.cancel()
        batteryTasks[address] = Task { [weak self] in
            for delay in [1.5, 3, 6, 15] {
                try? await Task.sleep(for: .seconds(delay))
                guard let self, !Task.isCancelled, let device = IOBluetoothDevice(addressString: address), device.isConnected() else { return }
                self.update(Self.describe(device, id: address))
            }
        }
    }

    // MARK: - Describing devices

    nonisolated private static func describe(_ device: IOBluetoothDevice, id: String) -> BluetoothDevice {
        BluetoothDevice(
            id: id,
            name: device.name ?? device.nameOrAddress ?? id,
            symbol: symbol(for: device),
            battery: battery(of: device, address: id)
        )
    }

    nonisolated private static func battery(of device: IOBluetoothDevice, address: String) -> BluetoothBattery {
        // Undocumented IOBluetoothDevice properties; 0 means "not reported".
        func percent(_ key: String) -> Int? {
            guard device.responds(to: NSSelectorFromString(key)),
                  let value = (device.value(forKey: key) as? NSNumber)?.intValue,
                  (1...100).contains(value) else { return nil }
            return value
        }
        var battery = BluetoothBattery(
            single: percent("batteryPercentSingle"),
            left: percent("batteryPercentLeft"),
            right: percent("batteryPercentRight"),
            caseLevel: percent("batteryPercentCase")
        )
        if battery.main == nil {
            battery.single = percent("batteryPercentCombined") ?? percent("headsetBattery") ?? hidBatteryPercent(address: address)
        }
        return battery
    }

    /// Apple's keyboards, mice and trackpads publish their battery in the I/O Registry instead.
    nonisolated private static func hidBatteryPercent(address: String) -> Int? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleDeviceManagementHIDEventService"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        let wanted = address.lowercased().replacingOccurrences(of: ":", with: "-")
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            let deviceAddress = IORegistryEntryCreateCFProperty(service, "DeviceAddress" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
            guard deviceAddress?.lowercased().replacingOccurrences(of: ":", with: "-") == wanted else { continue }
            return (IORegistryEntryCreateCFProperty(service, "BatteryPercent" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.intValue
        }
        return nil
    }


    /// Address ("40-da-5c-…") → product ID of Apple devices, as system_profiler reports them.
    nonisolated private static let appleModels = Mutex<[String: Int]>([:])

    nonisolated private static func addressKey(_ address: String) -> String {
        address.lowercased().replacingOccurrences(of: ":", with: "-")
    }

    @concurrent
    nonisolated private static func loadAppleModels() async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json", "-detailLevel", "basic"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let controllers = json["SPBluetoothDataType"] as? [[String: Any]] else { return }
        var models: [String: Int] = [:]
        for controller in controllers {
            let entries = (controller["device_connected"] as? [[String: Any]] ?? []) + (controller["device_not_connected"] as? [[String: Any]] ?? [])
            for entry in entries {
                for case let info as [String: Any] in entry.values {
                    guard (info["device_vendorID"] as? String)?.lowercased() == "0x004c",
                          let address = info["device_address"] as? String,
                          let product = (info["device_productID"] as? String).flatMap({ Int($0.dropFirst(2), radix: 16) })
                    else { continue }
                    models[addressKey(address)] = product
                }
            }
        }
        appleModels.withLock { $0.merge(models) { _, new in new } }
    }

    nonisolated private static func symbol(for device: IOBluetoothDevice) -> String {
        // system_profiler knows the model for sure; IOBluetooth's undocumented properties can report
        // the generic AirPods for any of them.
        if let address = device.addressString,
           let product = appleModels.withLock({ $0[addressKey(address)] }), let symbol = AppleAudioModel.symbol(for: product) { return symbol }
        let vendor = (device.value(forKey: "vendorID") as? NSNumber)?.intValue
        let product = (device.value(forKey: "productID") as? NSNumber)?.intValue
        if vendor == 0x004C, let product, let symbol = AppleAudioModel.symbol(for: product) { return symbol }

        if let symbol = SystemVolume.symbol(forName: device.name ?? "") { return symbol.name }
        let name = (device.name ?? "").lowercased()
        if name.contains("trackpad") { return "rectangle.and.hand.point.up.left.fill" }
        if name.contains("magic mouse") { return "magicmouse.fill" }

        // Bluetooth class of device: the major class says what it is, the minor class narrows it.
        let minor = Int(device.deviceClassMinor)
        switch Int(device.deviceClassMajor) {
        case 0x01: return "laptopcomputer"
        case 0x02: return "iphone"
        case 0x04: return minor == 0x05 || minor == 0x07 ? "hifispeaker.fill" : "headphones"
        case 0x05:
            if minor & 0x0F == 0x01 || minor & 0x0F == 0x02 { return "gamecontroller.fill" }
            if minor & 0x30 == 0x20 { return "computermouse.fill" }
            return "keyboard.fill"
        case 0x07: return "applewatch"
        default: return "wave.3.right"
        }
    }
}

/// Apple and Beats headphones by Bluetooth product ID, as SF Symbols draw them.
nonisolated enum AppleAudioModel {
    private static let symbols: [Int: String] = [
        0x2002: "airpods", 0x200F: "airpods", 0x2013: "airpods.gen3", 0x2019: "airpods.gen4", 0x201B: "airpods.gen4",
        0x200E: "airpods.pro", 0x2014: "airpods.pro", 0x2024: "airpods.pro", 0x2027: "airpods.pro",
        0x200A: "airpods.max", 0x201F: "airpods.max",
        0x200B: "beats.powerbeats.pro", 0x2011: "beats.studiobuds", 0x2016: "beats.studiobuds", 0x2012: "beats.fitpro",
    ]

    static func symbol(for product: Int) -> String? { symbols[product] }

    /// The charging case that goes with the earbuds' symbol.
    static func caseSymbol(for symbol: String) -> String {
        switch symbol {
        case "airpods.gen3": "airpods.gen3.chargingcase.wireless"
        case "airpods.gen4": "airpods.gen4.chargingcase.wireless"
        case "airpods.pro", "airpodspro": "airpods.pro.chargingcase.wireless"
        default: "airpods.chargingcase"
        }
    }
}
