import AudioToolbox
import CoreAudio
import Observation

/// Where sound is going: the default output device, named and drawn the way the island shows it.
nonisolated struct AudioRoute: Equatable, Sendable {
    var name: String
    var symbol: String
    /// Headphones of some kind, so the volume HUD shows the device instead of a speaker.
    var isPersonal: Bool

    static let speakers = AudioRoute(name: "", symbol: "speaker.wave.2.fill", isPersonal: false)
}

/// A device sound can go to, for picking where it plays.
nonisolated struct AudioOutput: Identifiable, Equatable, Sendable {
    let id: AudioObjectID
    let route: AudioRoute
}

/// Volume levels move in the same steps as the system's keys: sixteenths, or sixty-fourths with ⇧⌥.
nonisolated enum LevelStep {
    static func next(from value: Double, up: Bool, fine: Bool) -> Double {
        let steps: Double = fine ? 64 : 16
        let stepped = (value * steps).rounded() + (up ? 1 : -1)
        return min(max(stepped, 0), steps) / steps
    }
}

/// The default output device's volume and mute state, observed through CoreAudio.
@Observable
final class SystemVolume {
    private(set) var level: Double = 0
    private(set) var isMuted = false
    private(set) var route = AudioRoute.speakers
    private(set) var canSetVolume = false
    /// Every device sound can go to, the current one included.
    private(set) var outputs: [AudioOutput] = []
    private(set) var outputID = AudioObjectID(kAudioObjectUnknown)

    /// Volume or mute changed, whoever changed it.
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored var onRouteChange: ((AudioRoute) -> Void)?

    @ObservationIgnored private var device = AudioObjectID(kAudioObjectUnknown)
    @ObservationIgnored private var defaultDeviceListener: AudioObjectPropertyListenerBlock?
    @ObservationIgnored private var deviceListener: AudioObjectPropertyListenerBlock?
    @ObservationIgnored private var deviceListListener: AudioObjectPropertyListenerBlock?
    /// What mute restores to on devices that have no mute control of their own.
    @ObservationIgnored private var levelBeforeMute: Double = 0.5

    var isSilent: Bool { isMuted || level < 0.001 }

    func start() {
        guard defaultDeviceListener == nil else { return }
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.defaultDeviceChanged() }
        }
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
        defaultDeviceListener = listener
        // Headphones and displays come and go; keep the list of outputs current.
        var devices = Self.address(kAudioHardwarePropertyDevices, scope: kAudioObjectPropertyScopeGlobal)
        let listListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.outputs = Self.availableOutputs() }
        }
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &devices, .main, listListener)
        deviceListListener = listListener
        outputs = Self.availableOutputs()
        attach(to: Self.defaultOutputDevice())
    }

    func stop() {
        detach()
        if let defaultDeviceListener {
            var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, defaultDeviceListener)
        }
        defaultDeviceListener = nil
        if let deviceListListener {
            var devices = Self.address(kAudioHardwarePropertyDevices, scope: kAudioObjectPropertyScopeGlobal)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &devices, .main, deviceListListener)
        }
        deviceListListener = nil
    }

    // MARK: - Changing

    func step(up: Bool, fine: Bool) {
        if isMuted {
            // Like the system: volume up unmutes, volume down leaves it muted.
            guard up else { return }
            setMuted(false)
        }
        setLevel(LevelStep.next(from: level, up: up, fine: fine))
    }

    /// Sends sound to another device, as picking it in Control Center does.
    func selectOutput(_ id: AudioObjectID) {
        guard id != outputID else { return }
        var device = id
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &device)
    }

    func toggleMute() {
        setMuted(!isMuted)
    }

    func setLevel(_ value: Double) {
        var volume = Float32(min(max(value, 0), 1))
        var address = Self.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &volume)
        if volume > 0, isMuted { setMuted(false) }
        refresh()
    }

    func setMuted(_ muted: Bool) {
        var address = Self.address(kAudioDevicePropertyMute)
        if Self.isSettable(device, &address) {
            var value: UInt32 = muted ? 1 : 0
            AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
            refresh()
        } else if muted {
            levelBeforeMute = max(level, 1.0 / 16)
            setLevel(0)
        } else if level < 0.001 {
            setLevel(levelBeforeMute)
        }
    }

    // MARK: - Observing

    private func defaultDeviceChanged() {
        let newDevice = Self.defaultOutputDevice()
        guard newDevice != device else { return }
        attach(to: newDevice)
        onRouteChange?(route)
    }

    private func attach(to newDevice: AudioObjectID) {
        detach()
        device = newDevice
        outputID = newDevice
        route = Self.route(of: newDevice)
        var volume = Self.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        canSetVolume = Self.isSettable(newDevice, &volume)
        readLevels()

        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        var mute = Self.address(kAudioDevicePropertyMute)
        AudioObjectAddPropertyListenerBlock(newDevice, &volume, .main, listener)
        AudioObjectAddPropertyListenerBlock(newDevice, &mute, .main, listener)
        deviceListener = listener
    }

    private func detach() {
        guard let deviceListener else { return }
        var volume = Self.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        var mute = Self.address(kAudioDevicePropertyMute)
        AudioObjectRemovePropertyListenerBlock(device, &volume, .main, deviceListener)
        AudioObjectRemovePropertyListenerBlock(device, &mute, .main, deviceListener)
        self.deviceListener = nil
    }

    private func refresh() {
        let before = (level, isMuted)
        readLevels()
        if before != (level, isMuted) { onChange?() }
    }

    private func readLevels() {
        var volume: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        var address = Self.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume) == noErr {
            level = Double(volume)
        }
        var muted: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        address = Self.address(kAudioDevicePropertyMute)
        isMuted = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &muted) == noErr && muted != 0
    }

    // MARK: - CoreAudio plumbing

    private static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioDevicePropertyScopeOutput
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func isSettable(_ device: AudioObjectID, _ address: inout AudioObjectPropertyAddress) -> Bool {
        guard AudioObjectHasProperty(device, &address) else { return false }
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(device, &address, &settable) == noErr && settable.boolValue
    }

    private static func defaultOutputDevice() -> AudioObjectID {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = address(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return device
    }

    /// Visible devices with output streams.
    private static func availableOutputs() -> [AudioOutput] {
        var address = address(kAudioHardwarePropertyDevices, scope: kAudioObjectPropertyScopeGlobal)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            var streams = Self.address(kAudioDevicePropertyStreams)
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &streamSize) == noErr, streamSize > 0 else { return nil }
            var hidden: UInt32 = 0
            var hiddenSize = UInt32(MemoryLayout<UInt32>.size)
            var isHidden = Self.address(kAudioDevicePropertyIsHidden, scope: kAudioObjectPropertyScopeGlobal)
            if AudioObjectGetPropertyData(id, &isHidden, 0, nil, &hiddenSize, &hidden) == noErr, hidden != 0 { return nil }
            let route = route(of: id)
            return route.name.isEmpty ? nil : AudioOutput(id: id, route: route)
        }
    }

    private static func route(of device: AudioObjectID) -> AudioRoute {
        var address = address(kAudioObjectPropertyName, scope: kAudioObjectPropertyScopeGlobal)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &name) { AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0) }
        let deviceName = status == noErr ? (name?.takeRetainedValue() as String?) ?? "" : ""

        var transport: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        address = Self.address(kAudioDevicePropertyTransportType, scope: kAudioObjectPropertyScopeGlobal)
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport)

        var source: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        address = Self.address(kAudioDevicePropertyDataSource)
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, &source)

        let lowered = deviceName.lowercased()
        let personal = { (symbol: String) in AudioRoute(name: deviceName, symbol: symbol, isPersonal: true) }
        if lowered.contains("airpods max") { return personal("airpods.max") }
        if lowered.contains("airpods pro") { return personal("airpods.pro") }
        if lowered.contains("airpods") { return personal("airpods") }
        if lowered.contains("beats") { return personal("beats.headphones") }
        switch transport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return personal("headphones")
        case kAudioDeviceTransportTypeBuiltIn where source == 0x6864_706E: // 'hdpn': the headphone jack
            return personal("headphones")
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort:
            return AudioRoute(name: deviceName, symbol: "tv.fill", isPersonal: false)
        case kAudioDeviceTransportTypeAirPlay:
            return AudioRoute(name: deviceName, symbol: "airplay.audio", isPersonal: false)
        case kAudioDeviceTransportTypeBuiltIn:
            return AudioRoute(name: deviceName, symbol: "speaker.wave.2.fill", isPersonal: false)
        default:
            return AudioRoute(name: deviceName, symbol: "hifispeaker.fill", isPersonal: false)
        }
    }
}
