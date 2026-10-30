import Foundation
import IOKit.ps
import Observation

nonisolated struct BatteryState: Equatable, Sendable {
    var level: Int
    var isPluggedIn: Bool
    var isCharging: Bool
    var isCharged: Bool
    var minutesToFull: Int?
    var minutesToEmpty: Int?
}

nonisolated enum PowerEvent: Equatable, Sendable {
    case pluggedIn
    case unplugged
    case low
    case charged
    case lowPowerMode(Bool)

    static let lowThresholds = [20, 10, 5]

    /// What changed between two readings of the internal battery, if it's worth mentioning.
    static func between(_ old: BatteryState, _ new: BatteryState) -> PowerEvent? {
        if new.isPluggedIn != old.isPluggedIn { return new.isPluggedIn ? .pluggedIn : .unplugged }
        if !new.isPluggedIn, lowThresholds.contains(where: { new.level <= $0 && old.level > $0 }) { return .low }
        if new.isPluggedIn, new.isCharged, !old.isCharged { return .charged }
        return nil
    }
}

/// The internal battery and Low Power Mode, with an event for each change worth a banner.
@Observable
final class PowerMonitor {
    private(set) var battery: BatteryState?
    private(set) var isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled

    @ObservationIgnored var onEvent: ((PowerEvent) -> Void)?

    @ObservationIgnored private var source: CFRunLoopSource?
    @ObservationIgnored private var lowPowerObserver: NSObjectProtocol?

    func start() {
        guard source == nil else { return }
        battery = Self.readBattery()
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource(powerSourcesChanged, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            self.source = source
        }
        lowPowerObserver = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.lowPowerModeChanged() }
        }
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        source = nil
        if let lowPowerObserver { NotificationCenter.default.removeObserver(lowPowerObserver) }
        lowPowerObserver = nil
    }

    fileprivate func sourcesChanged() {
        let old = battery
        battery = Self.readBattery()
        guard let old, let new = battery, let event = PowerEvent.between(old, new) else { return }
        onEvent?(event)
    }

    private func lowPowerModeChanged() {
        let enabled = ProcessInfo.processInfo.isLowPowerModeEnabled
        guard enabled != isLowPowerMode else { return }
        isLowPowerMode = enabled
        onEvent?(.lowPowerMode(enabled))
    }

    private static func readBattery() -> BatteryState? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let current = description[kIOPSCurrentCapacityKey] as? Int ?? 0
            let capacity = max(description[kIOPSMaxCapacityKey] as? Int ?? 100, 1)
            // -1 means macOS is still estimating.
            func minutes(_ key: String) -> Int? {
                (description[key] as? Int).flatMap { $0 > 0 ? $0 : nil }
            }
            return BatteryState(
                level: min(max(Int((Double(current) / Double(capacity) * 100).rounded()), 0), 100),
                isPluggedIn: description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue,
                isCharging: description[kIOPSIsChargingKey] as? Bool ?? false,
                isCharged: description[kIOPSIsChargedKey] as? Bool ?? false,
                minutesToFull: minutes(kIOPSTimeToFullChargeKey),
                minutesToEmpty: minutes(kIOPSTimeToEmptyKey)
            )
        }
        return nil
    }
}

nonisolated private func powerSourcesChanged(_ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let monitor = Unmanaged<PowerMonitor>.fromOpaque(context).takeUnretainedValue()
    MainActor.assumeIsolated { monitor.sourcesChanged() }
}
