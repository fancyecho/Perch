import AppKit
import Carbon.HIToolbox
import Observation

enum AppLanguage: String, CaseIterable, Identifiable {
    case system, chinese = "zh", english = "en"

    var id: String { rawValue }
}

enum HotKeyStatus: Equatable {
    case disabled, registered, unavailable
}

/// A global shortcut as Carbon understands it: a virtual key code plus Carbon modifier bits.
nonisolated struct HotKeyCombo: Codable, Hashable, Sendable {
    var keyCode: UInt32
    var modifiers: UInt32

    static let standard = HotKeyCombo(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey))
    /// Opens and closes the notch island.
    static let islandStandard = HotKeyCombo(keyCode: UInt32(kVK_ANSI_C), modifiers: UInt32(optionKey))
}

/// Which global shortcut a recorder edits.
enum HotKeySlot {
    case tasks, island
}

/// Language, time zone and shortcut preferences. Views read these through observation,
/// so switching language or zone re-renders everything that formats text or dates.
@Observable
final class AppSettings {
    static let shared = AppSettings()

    var language: AppLanguage {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: Keys.language)
            rebuild()
        }
    }

    /// nil follows the system time zone (and its changes).
    var timeZoneID: String? {
        didSet {
            UserDefaults.standard.set(timeZoneID, forKey: Keys.timeZone)
            rebuild()
        }
    }

    /// nil disables the global shortcut.
    var hotKey: HotKeyCombo? {
        didSet {
            let data = hotKey.flatMap { try? JSONEncoder().encode($0) }
            UserDefaults.standard.set(data ?? Data(), forKey: Keys.hotKey)
            applyHotKey()
        }
    }

    var isRecordingHotKey = false {
        didSet { applyHotKey() }
    }

    private(set) var hotKeyStatus: HotKeyStatus = .disabled

    /// Opens and closes the island; nil turns the shortcut off.
    var islandHotKey: HotKeyCombo? {
        didSet {
            let data = islandHotKey.flatMap { try? JSONEncoder().encode($0) }
            UserDefaults.standard.set(data ?? Data(), forKey: Keys.islandHotKey)
            applyIslandHotKey()
        }
    }

    var isRecordingIslandHotKey = false {
        didSet { applyIslandHotKey() }
    }

    private(set) var islandHotKeyStatus: HotKeyStatus = .disabled
    private(set) var calendar: Calendar
    private(set) var isChinese: Bool

    var locale: Locale { Locale(identifier: isChinese ? "zh_CN" : "en_US") }
    var timeZone: TimeZone { calendar.timeZone }

    /// Registers the shortcut with the system and reports whether that worked.
    @ObservationIgnored var hotKeyRegistrar: ((HotKeyCombo?) -> HotKeyStatus)? {
        didSet { applyHotKey() }
    }
    @ObservationIgnored var islandHotKeyRegistrar: ((HotKeyCombo?) -> HotKeyStatus)? {
        didSet { applyIslandHotKey() }
    }
    @ObservationIgnored private var timeFormatter = DateFormatter()
    @ObservationIgnored private var systemZoneObserver: NSObjectProtocol?

    private enum Keys {
        static let language = "language"
        static let timeZone = "timeZone"
        static let hotKey = "hotKey"
        static let islandHotKey = "islandHotKey"
    }

    private init() {
        let defaults = UserDefaults.standard
        language = defaults.string(forKey: Keys.language).flatMap(AppLanguage.init(rawValue:)) ?? .system
        timeZoneID = defaults.string(forKey: Keys.timeZone).flatMap { TimeZone(identifier: $0)?.identifier }
        if let data = defaults.data(forKey: Keys.hotKey) {
            hotKey = data.isEmpty ? nil : (try? JSONDecoder().decode(HotKeyCombo.self, from: data)) ?? .standard
        } else {
            hotKey = .standard
        }
        if let data = defaults.data(forKey: Keys.islandHotKey) {
            islandHotKey = data.isEmpty ? nil : (try? JSONDecoder().decode(HotKeyCombo.self, from: data)) ?? .islandStandard
        } else {
            islandHotKey = .islandStandard
        }
        calendar = Calendar(identifier: .gregorian)
        isChinese = true
        rebuild()

        systemZoneObserver = NotificationCenter.default.addObserver(
            forName: .NSSystemTimeZoneDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                NSTimeZone.resetSystemTimeZone()
                self?.rebuild()
            }
        }
    }

    func formatTime(_ date: Date) -> String {
        timeFormatter.string(from: date)
    }

    private func rebuild() {
        switch language {
        case .chinese: isChinese = true
        case .english: isChinese = false
        case .system: isChinese = Locale.preferredLanguages.first?.hasPrefix("zh") ?? false
        }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZoneID.flatMap(TimeZone.init(identifier:)) ?? .current
        cal.locale = locale
        cal.firstWeekday = 2
        calendar = cal

        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = cal.timeZone
        formatter.setLocalizedDateFormatFromTemplate(isChinese ? "HHmm" : "jmm")
        timeFormatter = formatter
    }

    private func applyIslandHotKey() {
        guard let islandHotKeyRegistrar else { return }
        islandHotKeyStatus = islandHotKeyRegistrar(isRecordingIslandHotKey ? nil : islandHotKey)
    }

    // MARK: Shortcuts by slot, for the recorder

    func hotKey(_ slot: HotKeySlot) -> HotKeyCombo? {
        slot == .tasks ? hotKey : islandHotKey
    }

    func setHotKey(_ combo: HotKeyCombo?, for slot: HotKeySlot) {
        if slot == .tasks { hotKey = combo } else { islandHotKey = combo }
    }

    func isRecording(_ slot: HotKeySlot) -> Bool {
        slot == .tasks ? isRecordingHotKey : isRecordingIslandHotKey
    }

    func setRecording(_ recording: Bool, for slot: HotKeySlot) {
        if slot == .tasks { isRecordingHotKey = recording } else { isRecordingIslandHotKey = recording }
    }

    func hotKeyStatus(_ slot: HotKeySlot) -> HotKeyStatus {
        slot == .tasks ? hotKeyStatus : islandHotKeyStatus
    }

    private func applyHotKey() {
        guard let hotKeyRegistrar else { return }
        if isRecordingHotKey {
            _ = hotKeyRegistrar(nil)
        } else {
            hotKeyStatus = hotKeyRegistrar(hotKey)
        }
    }
}

/// Picks the string for the current UI language.
func tr(_ chinese: String, _ english: String) -> String {
    AppSettings.shared.isChinese ? chinese : english
}
