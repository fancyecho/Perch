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
    private(set) var calendar: Calendar
    private(set) var isChinese: Bool

    var locale: Locale { Locale(identifier: isChinese ? "zh_CN" : "en_US") }
    var timeZone: TimeZone { calendar.timeZone }

    /// Registers the shortcut with the system and reports whether that worked.
    @ObservationIgnored var hotKeyRegistrar: ((HotKeyCombo?) -> HotKeyStatus)? {
        didSet { applyHotKey() }
    }
    @ObservationIgnored private var timeFormatter = DateFormatter()
    @ObservationIgnored private var systemZoneObserver: NSObjectProtocol?

    private enum Keys {
        static let language = "language"
        static let timeZone = "timeZone"
        static let hotKey = "hotKey"
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
