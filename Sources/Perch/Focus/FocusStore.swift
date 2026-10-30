import Foundation
import Observation
import ServiceManagement

/// Focus's preferences, and how long was spent focused each day.
@Observable
final class FocusStore {
    static let shared = FocusStore()
    /// Minutes away before the screen blurs on its own; 0 is off.
    static let idleOptions = [0, 1, 2, 3, 5, 10, 15, 30]
    /// How long the blur keeps the display awake with nobody at the Mac; 0 follows the system.
    static let keepAwakeOptions = [0, 30, 60, 90, 120]
    private static let minCountedSeconds: TimeInterval = 60

    enum Keys {
        static let idleMinutes = "focus.idleMinutes"
        static let keepAwakeMinutes = "focus.keepAwakeMinutes"
        static let soundEnabled = "focus.soundEnabled"
        static let daily = "focus.dailySeconds"
    }

    var idleMinutes: Int {
        didSet { UserDefaults.standard.set(idleMinutes, forKey: Keys.idleMinutes) }
    }

    var keepAwakeMinutes: Int {
        didSet { UserDefaults.standard.set(keepAwakeMinutes, forKey: Keys.keepAwakeMinutes) }
    }

    var soundEnabled: Bool {
        didSet { UserDefaults.standard.set(soundEnabled, forKey: Keys.soundEnabled) }
    }

    /// The app playing video or holding a call, which holds off the automatic blur meanwhile.
    var autoPausedBy: String?

    /// "yyyy-MM-dd" in the app's time zone → seconds focused that day.
    private(set) var daily: [String: Double]

    private init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [Keys.idleMinutes: 0, Keys.keepAwakeMinutes: 90, Keys.soundEnabled: true])
        idleMinutes = defaults.integer(forKey: Keys.idleMinutes)
        keepAwakeMinutes = defaults.integer(forKey: Keys.keepAwakeMinutes)
        soundEnabled = defaults.bool(forKey: Keys.soundEnabled)
        daily = defaults.dictionary(forKey: Keys.daily) as? [String: Double] ?? [:]
    }

    /// Re-reads everything saved, after an import.
    func reload() {
        let defaults = UserDefaults.standard
        idleMinutes = defaults.integer(forKey: Keys.idleMinutes)
        keepAwakeMinutes = defaults.integer(forKey: Keys.keepAwakeMinutes)
        soundEnabled = defaults.bool(forKey: Keys.soundEnabled)
        daily = defaults.dictionary(forKey: Keys.daily) as? [String: Double] ?? [:]
    }

    func record(_ seconds: TimeInterval, on date: Date = .now) {
        guard seconds > 0 else { return }
        daily[Self.key(for: date), default: 0] += seconds
        UserDefaults.standard.set(daily, forKey: Keys.daily)
    }

    func seconds(on date: Date) -> TimeInterval {
        daily[Self.key(for: date)] ?? 0
    }

    var todaySeconds: TimeInterval { seconds(on: .now) }

    /// Days in a row with some focus, counting back from yesterday until today has some.
    var streakDays: Int {
        let calendar = ScheduleClock.calendar
        var day = Date.now
        if seconds(on: day) < Self.minCountedSeconds {
            day = calendar.date(byAdding: .day, value: -1, to: day) ?? day
        }
        var streak = 0
        while seconds(on: day) >= Self.minCountedSeconds {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return streak
    }

    /// The last seven days, oldest first.
    var lastWeek: [(date: Date, seconds: TimeInterval)] {
        let calendar = ScheduleClock.calendar
        return (0..<7).reversed().compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: .now).map { ($0, seconds(on: $0)) }
        }
    }

    // MARK: Keep alive

    /// launchd relaunches Perch when it is killed (this also starts it at login).
    var keepAlive = BackgroundAgent.isEnabled || BackgroundAgent.needsApproval {
        didSet {
            guard keepAlive != oldValue, !isRefreshing else { return }
            if keepAlive {
                do { try BackgroundAgent.enable() } catch {
                    NSLog("Perch: couldn't register the keep-alive agent: \(error.localizedDescription)")
                }
            } else {
                BackgroundAgent.disable()
            }
            refreshBackgroundStatus()
        }
    }

    /// Registered, but still waiting for approval in System Settings › Login Items.
    private(set) var keepAliveNeedsApproval = BackgroundAgent.needsApproval

    /// Reading the system's state mustn't register or unregister anything in turn.
    @ObservationIgnored private var isRefreshing = false

    /// The user may have changed it in System Settings; read it again whenever it's shown.
    func refreshBackgroundStatus() {
        isRefreshing = true
        defer { isRefreshing = false }
        // Waiting for approval still counts as on, so the switch doesn't flip back.
        let enabled = BackgroundAgent.isEnabled || BackgroundAgent.needsApproval
        if keepAlive != enabled { keepAlive = enabled }
        keepAliveNeedsApproval = BackgroundAgent.needsApproval
    }

    private static func key(for date: Date) -> String {
        let parts = ScheduleClock.calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

enum DurationText {
    /// 42 min / 2 h 5 min
    static func long(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 60 { return tr("\(minutes) 分钟", "\(minutes) min") }
        let rest = minutes % 60
        return rest == 0
            ? tr("\(minutes / 60) 小时", "\(minutes / 60) h")
            : tr("\(minutes / 60) 小时 \(rest) 分钟", "\(minutes / 60) h \(rest) min")
    }

    /// 12:05 / 1:02:05
    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let h = total / 3600, m = total / 60 % 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}
