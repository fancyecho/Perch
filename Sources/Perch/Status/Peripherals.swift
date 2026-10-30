import CoreAudio
import Foundation
import IOKit

/// A Bluetooth peripheral's batteries (AirPods, Magic Mouse / Keyboard / Trackpad and so on).
nonisolated struct PeripheralBattery: Identifiable, Equatable, Sendable {
    struct Level: Equatable, Sendable {
        /// Which part of AirPods; single-battery devices have none.
        enum Part: Sendable {
            case left, right, `case`

            @MainActor var label: String {
                switch self {
                case .left: tr("左", "L")
                case .right: tr("右", "R")
                case .case: tr("盒", "Case")
                }
            }
        }

        var part: Part?
        var percent: Int
    }

    var id: String { name }
    var name: String
    var symbol: String
    var levels: [Level]
}

/// Two sources: BatteryPercent on Apple HID peripherals in the IORegistry (the Magic family), and
/// system_profiler's Bluetooth report (AirPods' left, right and case). Both block, so they run off the main thread.
nonisolated enum PeripheralSampler {
    static func sample() -> [PeripheralBattery] {
        var result = hidDevices()
        for device in bluetoothDevices() where !result.contains(where: { $0.name == device.name }) {
            result.append(device)
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func hidDevices() -> [PeripheralBattery] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleDeviceManagementHIDEventService"),
                                           &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var devices: [PeripheralBattery] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            func property(_ key: String) -> Any? {
                IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            guard let percent = property("BatteryPercent") as? Int, let name = property("Product") as? String else { continue }
            devices.append(PeripheralBattery(name: name, symbol: symbol(name: name, type: nil),
                                             levels: [.init(part: nil, percent: percent)]))
        }
        return devices
    }

    private static func bluetoothDevices() -> [PeripheralBattery] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json", "-detailLevel", "basic"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let controllers = json["SPBluetoothDataType"] as? [[String: Any]] else { return [] }

        var devices: [PeripheralBattery] = []
        for controller in controllers {
            for entry in controller["device_connected"] as? [[String: Any]] ?? [] {
                for (name, value) in entry {
                    guard let info = value as? [String: Any] else { continue }
                    let parts: [(String, PeripheralBattery.Level.Part?)] = [("device_batteryLevelMain", nil), ("device_batteryLevelLeft", .left),
                                                                            ("device_batteryLevelRight", .right), ("device_batteryLevelCase", .case)]
                    let levels = parts.compactMap { key, part -> PeripheralBattery.Level? in
                        guard let text = info[key] as? String, let percent = Int(text.trimmingCharacters(in: CharacterSet(charactersIn: "% "))) else { return nil }
                        return .init(part: part, percent: percent)
                    }
                    guard !levels.isEmpty else { continue }
                    devices.append(PeripheralBattery(name: name, symbol: symbol(name: name, type: info["device_minorType"] as? String),
                                                     levels: levels))
                }
            }
        }
        return devices
    }

    private static func symbol(name: String, type: String?) -> String {
        let lower = name.lowercased()
        if lower.contains("airpods max") { return "airpodsmax" }
        if lower.contains("airpods pro") { return "airpodspro" }
        if lower.contains("airpods") { return "airpods" }
        if lower.contains("mouse") || type == "Mouse" { return "magicmouse" }
        if lower.contains("trackpad") { return "rectangle.and.hand.point.up.left" }
        if lower.contains("keyboard") || type == "Keyboard" { return "keyboard" }
        if lower.contains("pencil") { return "applepencil" }
        if type == "Headphones" || type == "Headset" { return "headphones" }
        if type == "Gamepad" || type == "Joystick" { return "gamecontroller" }
        return "dot.radiowaves.left.and.right"
    }
}

/// Called as peripherals connect and disconnect. A Bluetooth headset shows up among the audio devices, a Magic
/// peripheral as a new HID service; neither needs Bluetooth permission, and both beat polling.
@MainActor
final class PeripheralWatcher {
    private let onChange: () -> Void
    private var port: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        var devices = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &devices, .main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.onChange() }
        }

        port = IONotificationPortCreate(kIOMainPortDefault)
        IONotificationPortSetDispatchQueue(port, .main)
        let context = Unmanaged.passUnretained(self).toOpaque()
        for type in [kIOFirstMatchNotification, kIOTerminatedNotification] {
            var iterator: io_iterator_t = 0
            IOServiceAddMatchingNotification(port, type, IOServiceMatching("AppleDeviceManagementHIDEventService"), { context, iterator in
                PeripheralWatcher.drain(iterator)
                guard let context else { return }
                let watcher = Unmanaged<PeripheralWatcher>.fromOpaque(context).takeUnretainedValue()
                MainActor.assumeIsolated { watcher.onChange() }
            }, context, &iterator)
            // The notifications only start once the existing devices have been drained.
            Self.drain(iterator)
            iterators.append(iterator)
        }
    }

    private nonisolated static func drain(_ iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 { IOObjectRelease(service) }
    }
}
