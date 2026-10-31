import AppKit
import Observation
import SwiftUI

/// A stretch of a day in wall-clock time, as minutes from midnight. `end <= start` crosses midnight
/// and ends the next day.
struct TimeWindow: Codable, Hashable, Identifiable {
    var id = UUID()
    var start: Int
    var end: Int

    var crossesMidnight: Bool { end <= start }

    var durationMinutes: Int {
        let minutes = (end - start + 1440) % 1440
        return minutes == 0 ? 1440 : minutes
    }
}

struct BlockedApp: Codable, Hashable, Identifiable {
    var bundleID: String
    var name: String
    var id: String { bundleID }
}

/// A schedule: on which days, in which stretches of the day, which apps and sites are paused.
struct BlockRule: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var tint: Int
    var isEnabled = true
    /// Calendar weekdays: 1 is Sunday … 7 is Saturday.
    var weekdays: Set<Int>
    var windows: [TimeWindow]
    var apps: [BlockedApp]
    /// While it runs it can't be skipped, edited, turned off or deleted.
    var isStrict = false
    var sites: [BlockedSite] = []

    /// Every schedule keeps the app's time zone, the one today's tasks use too.
    var timeZone: TimeZone { ScheduleClock.timeZone }
    var calendar: Calendar { ScheduleClock.calendar }

    func blocks(_ bundleID: String) -> Bool {
        apps.contains { $0.bundleID == bundleID }
    }

    func blockedSite(for url: URL) -> BlockedSite? {
        sites.first { $0.matches(url) }
    }

    var hasNoTargets: Bool { apps.isEmpty && sites.isEmpty }
}

/// Decoded by hand so schedules saved by older versions of Focus (no sites, no tint) still load
/// instead of being dropped whole.
extension BlockRule {
    private enum CodingKeys: String, CodingKey {
        case id, name, tint, isEnabled, weekdays, windows, apps, isStrict, sites
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        tint = try container.decodeIfPresent(Int.self, forKey: .tint) ?? 0
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        weekdays = try container.decode(Set<Int>.self, forKey: .weekdays)
        windows = try container.decode([TimeWindow].self, forKey: .windows)
        apps = try container.decodeIfPresent([BlockedApp].self, forKey: .apps) ?? []
        isStrict = try container.decodeIfPresent(Bool.self, forKey: .isStrict) ?? false
        sites = try container.decodeIfPresent([BlockedSite].self, forKey: .sites) ?? []
    }
}

/// One schedule's stretch on a particular day.
struct Occurrence: Equatable {
    let rule: BlockRule
    let start: Date
    let end: Date

    func progress(at date: Date) -> Double {
        let total = end.timeIntervalSince(start)
        return total > 0 ? min(max(date.timeIntervalSince(start) / total, 0), 1) : 1
    }
}

// MARK: - Time

extension BlockRule {
    /// Puts `window` on the given day.
    ///
    /// Daylight saving: a time skipped when clocks spring forward moves to the first moment after
    /// the switch; when they fall back, the start takes the first of the repeated hour and the end
    /// the second, so the schedule covers every moment the clock shows a time inside it.
    func occurrence(of window: TimeWindow, onDayOf day: Date) -> Occurrence? {
        let calendar = calendar
        guard weekdays.contains(calendar.component(.weekday, from: day)),
              let start = calendar.date(bySettingHour: window.start / 60, minute: window.start % 60, second: 0, of: day,
                                        matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward),
              let endDay = calendar.date(byAdding: .day, value: window.crossesMidnight ? 1 : 0, to: day),
              let end = calendar.date(bySettingHour: window.end / 60, minute: window.end % 60, second: 0, of: endDay,
                                      matchingPolicy: .nextTime, repeatedTimePolicy: .last, direction: .forward),
              end > start
        else { return nil }
        return Occurrence(rule: self, start: start, end: end)
    }

    /// The stretch running now; where stretches overlap, the one that ends last.
    func activeOccurrence(at now: Date) -> Occurrence? {
        guard isEnabled else { return nil }
        return occurrences(around: now, dayOffsets: -1...0)
            .filter { $0.start <= now && now < $0.end }
            .max { $0.end < $1.end }
    }

    /// The next stretch to start, within a week.
    func nextOccurrence(after now: Date) -> Occurrence? {
        guard isEnabled else { return nil }
        return occurrences(around: now, dayOffsets: 0...7)
            .filter { $0.start > now }
            .min { $0.start < $1.start }
    }

    private func occurrences(around now: Date, dayOffsets: ClosedRange<Int>) -> [Occurrence] {
        let calendar = calendar
        let today = calendar.startOfDay(for: now)
        return dayOffsets.flatMap { offset -> [Occurrence] in
            guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { return [] }
            return windows.compactMap { occurrence(of: $0, onDayOf: day) }
        }
    }
}

/// Schedules follow the app's time zone (Settings › General), the same one today's tasks use.
enum ScheduleClock {
    static var timeZone: TimeZone { AppSettings.shared.timeZone }

    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }
}

// MARK: - Pinning strict schedules

/// When a strict schedule starts it is copied, and its end is also kept on a monotonic clock.
/// Changing the system clock or time zone, or deleting the schedule's settings, then can't end it
/// early.
struct StrictPin: Codable {
    var rule: BlockRule
    var start: Date
    var end: Date
    /// The end on the monotonic clock, in nanoseconds (it runs through sleep and ignores clock changes).
    var monotonicEnd: UInt64
    /// The monotonic clock restarts at boot; after a restart only the wall clock is left to go by.
    var bootSession: String

    func isValid(at now: Date) -> Bool {
        bootSession == SystemClock.bootSession ? SystemClock.monotonic < monotonicEnd : now < end
    }
}

enum SystemClock {
    static var monotonic: UInt64 { clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) }

    static let bootSession: String = {
        var size = 0
        sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0)
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }()
}

// MARK: - Store

/// The schedules, plus "five more minutes" passes and how often something was blocked today.
@Observable
final class ScheduleStore {
    static let shared = ScheduleStore()
    static let passMinutes = 5
    static let passesPerDay = 3

    enum Keys {
        static let rules = "focus.rules"
        static let passCounts = "focus.passCounts"
        static let pins = "focus.strictPins"
        static let attempts = "focus.attempts"
    }

    var rules: [BlockRule] {
        didSet { save() }
    }

    /// Pass key (a bundle id, or "web:" + site) → when its pass runs out.
    private(set) var passes: [String: Date] = [:]
    /// "rule id|day" → passes used that day.
    private var passCounts: [String: Int]
    /// Rule id → the copy kept while a strict schedule runs.
    private(set) var pins: [UUID: StrictPin]
    /// "pass key|day" → times it was blocked that day.
    private var attempts: [String: Int]

    private init() {
        let defaults = UserDefaults.standard
        rules = defaults.data(forKey: Keys.rules).flatMap { try? JSONDecoder().decode([BlockRule].self, from: $0) } ?? []
        passCounts = defaults.dictionary(forKey: Keys.passCounts) as? [String: Int] ?? [:]
        attempts = defaults.dictionary(forKey: Keys.attempts) as? [String: Int] ?? [:]
        pins = defaults.data(forKey: Keys.pins).flatMap { try? JSONDecoder().decode([UUID: StrictPin].self, from: $0) } ?? [:]
    }

    /// Re-reads everything saved, after an import.
    func reload() {
        let defaults = UserDefaults.standard
        rules = defaults.data(forKey: Keys.rules).flatMap { try? JSONDecoder().decode([BlockRule].self, from: $0) } ?? []
        passCounts = defaults.dictionary(forKey: Keys.passCounts) as? [String: Int] ?? [:]
        attempts = defaults.dictionary(forKey: Keys.attempts) as? [String: Int] ?? [:]
    }

    /// Every schedule running now: by the clock, plus pinned strict ones (the later end wins).
    func activeOccurrences(at now: Date = .now) -> [Occurrence] {
        var byRule: [UUID: Occurrence] = [:]
        let scheduled = rules.compactMap { $0.activeOccurrence(at: now) }
        let pinned = pins.values.filter { $0.isValid(at: now) }.map { Occurrence(rule: $0.rule, start: $0.start, end: $0.end) }
        for occurrence in scheduled + pinned {
            if let existing = byRule[occurrence.rule.id], existing.end >= occurrence.end { continue }
            byRule[occurrence.rule.id] = occurrence
        }
        return byRule.values.sorted { $0.end < $1.end }
    }

    /// The schedule blocking this app right now. A pass only gets past gentle schedules.
    func blockingOccurrence(for bundleID: String, at now: Date = .now) -> Occurrence? {
        let hasPass = (passes[bundleID] ?? .distantPast) > now
        return activeOccurrences(at: now)
            .filter { $0.rule.blocks(bundleID) && ($0.rule.isStrict || !hasPass) }
            .max { a, b in a.rule.isStrict != b.rule.isStrict ? b.rule.isStrict : a.end < b.end }
    }

    /// The schedule and site rule blocking this address right now. A pass only gets past gentle schedules.
    func blockingSite(for url: URL, at now: Date = .now) -> (occurrence: Occurrence, site: BlockedSite)? {
        let candidates = activeOccurrences(at: now).compactMap { occurrence -> (occurrence: Occurrence, site: BlockedSite)? in
            guard let site = occurrence.rule.blockedSite(for: url) else { return nil }
            if !occurrence.rule.isStrict, (passes[site.passKey] ?? .distantPast) > now { return nil }
            return (occurrence, site)
        }
        return candidates.max { a, b in
            a.occurrence.rule.isStrict != b.occurrence.rule.isStrict ? b.occurrence.rule.isStrict : a.occurrence.end < b.occurrence.end
        }
    }

    /// Whether a site is still blocked (the shield checks before it goes).
    func isBlocking(site: BlockedSite, at now: Date = .now) -> Bool {
        activeOccurrences(at: now).contains { occurrence in
            occurrence.rule.sites.contains(site)
                && (occurrence.rule.isStrict || (passes[site.passKey] ?? .distantPast) <= now)
        }
    }

    /// Running schedules with sites in them; without any, there's no need to look at browsers.
    func activeSiteOccurrences(at now: Date = .now) -> [Occurrence] {
        activeOccurrences(at: now).filter { !$0.rule.sites.isEmpty }
    }

    /// Pins strict schedules as they start, and pulls out pins that have run out.
    func pinStrictSessions(at now: Date = .now) {
        var updated = pins.filter { $0.value.isValid(at: now) }
        for rule in rules where rule.isStrict && updated[rule.id] == nil {
            guard let occurrence = rule.activeOccurrence(at: now) else { continue }
            let remaining = UInt64(max(0, occurrence.end.timeIntervalSince(now)) * 1_000_000_000)
            updated[rule.id] = StrictPin(rule: rule, start: occurrence.start, end: occurrence.end,
                                         monotonicEnd: SystemClock.monotonic + remaining,
                                         bootSession: SystemClock.bootSession)
        }
        guard Set(updated.keys) != Set(pins.keys) else { return }
        pins = updated
        if let data = try? JSONEncoder().encode(pins) { UserDefaults.standard.set(data, forKey: Keys.pins) }
    }

    func nextOccurrence(after now: Date = .now) -> Occurrence? {
        rules.compactMap { $0.nextOccurrence(after: now) }.min { $0.start < $1.start }
    }

    /// A strict schedule that is running can't be edited, turned off or deleted.
    func isLocked(_ rule: BlockRule, at now: Date = .now) -> Bool {
        (pins[rule.id]?.isValid(at: now) ?? false) || (rule.isStrict && rule.activeOccurrence(at: now) != nil)
    }

    var hasStrictRuleActive: Bool {
        activeOccurrences().contains { $0.rule.isStrict }
    }

    func passesLeft(for rule: BlockRule, at now: Date = .now) -> Int {
        guard !rule.isStrict else { return 0 }
        return max(0, Self.passesPerDay - (passCounts[passKey(rule, now)] ?? 0))
    }

    func grantPass(for key: String, rule: BlockRule, at now: Date = .now) {
        guard passesLeft(for: rule, at: now) > 0 else { return }
        passCounts[passKey(rule, now), default: 0] += 1
        passes[key] = now.addingTimeInterval(TimeInterval(Self.passMinutes * 60))
        // Only the last few days of counts are worth keeping.
        let recent = Set((0..<3).map { passKey(rule, now.addingTimeInterval(-Double($0) * 86400)) })
        passCounts = passCounts.filter { key, _ in !key.hasPrefix(rule.id.uuidString) || recent.contains(key) }
        UserDefaults.standard.set(passCounts, forKey: Keys.passCounts)
    }

    /// Blocked once more; returns how many times today (a week of counts is kept).
    @discardableResult
    func recordAttempt(for key: String, at now: Date = .now) -> Int {
        let entry = "\(key)|\(Self.dayKey(now))"
        attempts[entry, default: 0] += 1
        let recent = Set((0..<7).map { Self.dayKey(now.addingTimeInterval(-Double($0) * 86400)) })
        attempts = attempts.filter { key, _ in recent.contains(String(key.split(separator: "|").last ?? "")) }
        UserDefaults.standard.set(attempts, forKey: Keys.attempts)
        return attempts[entry] ?? 1
    }

    /// How many times anything was blocked on a day.
    func blockedCount(on date: Date = .now) -> Int {
        let day = Self.dayKey(date)
        return attempts.reduce(0) { $0 + ($1.key.hasSuffix("|\(day)") ? $1.value : 0) }
    }

    static func dayKey(_ date: Date) -> String {
        let parts = ScheduleClock.calendar.dateComponents([.year, .month, .day], from: date)
        return "\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)"
    }

    func revokePass(for key: String) {
        passes[key] = nil
    }

    func dropExpiredPasses(at now: Date = .now) {
        let live = passes.filter { $0.value > now }
        if live.count != passes.count { passes = live }
    }

    func newRule(name: String? = nil, start: Int = 19 * 60, end: Int = 22 * 60, weekdays: Set<Int> = Set(1...7)) -> BlockRule {
        BlockRule(name: name ?? tr("新时段", "New Schedule"), tint: rules.count % RuleTint.all.count, weekdays: weekdays,
                  windows: [TimeWindow(start: start, end: end)], apps: [])
    }

    private func passKey(_ rule: BlockRule, _ date: Date) -> String {
        let parts = rule.calendar.dateComponents([.year, .month, .day], from: date)
        return "\(rule.id.uuidString)|\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)"
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(rules) else { return }
        UserDefaults.standard.set(data, forKey: Keys.rules)
    }
}

// MARK: - Display

/// Schedule colors, in the warm family of the lamp.
enum RuleTint {
    static let all: [(Color, Color)] = [
        (Color(red: 0.96, green: 0.60, blue: 0.24), Color(red: 0.89, green: 0.37, blue: 0.22)), // lamplight
        (Color(red: 0.93, green: 0.42, blue: 0.45), Color(red: 0.80, green: 0.28, blue: 0.43)), // rouge
        (Color(red: 0.62, green: 0.48, blue: 0.95), Color(red: 0.45, green: 0.34, blue: 0.86)), // violet
        (Color(red: 0.36, green: 0.58, blue: 0.96), Color(red: 0.25, green: 0.42, blue: 0.86)), // indigo
        (Color(red: 0.25, green: 0.74, blue: 0.70), Color(red: 0.15, green: 0.56, blue: 0.58)), // celadon
        (Color(red: 0.55, green: 0.76, blue: 0.36), Color(red: 0.38, green: 0.60, blue: 0.27)), // bamboo
    ]

    static func gradient(_ index: Int) -> LinearGradient {
        let pair = all[index % all.count]
        return LinearGradient(colors: [pair.0, pair.1], startPoint: .leading, endPoint: .trailing)
    }

    static func color(_ index: Int) -> Color { all[index % all.count].0 }
}

/// The lamp's own colors: amber to vermilion.
enum Brand {
    static let gradient = LinearGradient(
        colors: [Color(red: 0.96, green: 0.60, blue: 0.24), Color(red: 0.89, green: 0.37, blue: 0.22)],
        startPoint: .leading, endPoint: .trailing)
    static let glow = Color(red: 1.0, green: 0.55, blue: 0.24)
}

enum AppIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(for bundleID: String) -> NSImage {
        if let cached = cache[bundleID] { return cached }
        let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil) ?? NSImage()
        cache[bundleID] = icon
        return icon
    }
}

enum ScheduleText {
    static func clock(_ minutes: Int) -> String {
        String(format: "%02d:%02d", (minutes / 60) % 24, minutes % 60)
    }

    static func window(_ window: TimeWindow) -> String {
        "\(clock(window.start))–\(window.crossesMidnight ? tr("次日 ", "next day ") : "")\(clock(window.end))"
    }

    private static var weekdayOrder: [Int] { [2, 3, 4, 5, 6, 7, 1] }

    static func shortWeekday(_ day: Int) -> String {
        let chinese = [1: "日", 2: "一", 3: "二", 4: "三", 5: "四", 6: "五", 7: "六"]
        let english = [1: "Sun", 2: "Mon", 3: "Tue", 4: "Wed", 5: "Thu", 6: "Fri", 7: "Sat"]
        return tr(chinese[day] ?? "", english[day] ?? "")
    }

    static func weekdays(_ days: Set<Int>) -> String {
        switch days {
        case Set(1...7): return tr("每天", "Every day")
        case [2, 3, 4, 5, 6]: return tr("工作日", "Weekdays")
        case [1, 7]: return tr("周末", "Weekends")
        case []: return tr("不重复", "Never")
        default:
            let picked = weekdayOrder.filter(days.contains).map(shortWeekday)
            return tr("周" + picked.joined(separator: "、"), picked.joined(separator: ", "))
        }
    }

    static func summary(_ rule: BlockRule) -> String {
        ([weekdays(rule.weekdays)] + rule.windows.map(window)).joined(separator: " · ")
    }

    static func duration(_ minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        if h == 0 { return tr("\(m) 分钟", "\(m) min") }
        return m == 0 ? tr("\(h) 小时", "\(h) h") : tr("\(h) 小时 \(m) 分", "\(h) h \(m) min")
    }

    static func remaining(until end: Date, from now: Date) -> String {
        duration(max(1, Int((end.timeIntervalSince(now) / 60).rounded(.up))))
    }

    /// Hours and minutes on a 24-hour clock in the app's time zone, whatever the system language.
    static func time(_ date: Date) -> String {
        timeFormatter.timeZone = ScheduleClock.timeZone
        return timeFormatter.string(from: date)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    /// A moment in the app's time zone, with "tomorrow" or the weekday when it isn't today.
    static func moment(_ date: Date, from now: Date = .now) -> String {
        let calendar = ScheduleClock.calendar
        let time = time(date)
        if calendar.isDate(date, inSameDayAs: now) { return time }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return tr("明天 \(time)", "tomorrow \(time)")
        }
        let day = shortWeekday(calendar.component(.weekday, from: date))
        return tr("周\(day) \(time)", "\(day) \(time)")
    }

    static func span(_ start: Date, _ end: Date, from now: Date = .now) -> String {
        let sameDay = ScheduleClock.calendar.isDate(start, inSameDayAs: end)
        return "\(moment(start, from: now))–\(sameDay ? time(end) : moment(end, from: now))"
    }

    /// The apps and sites a schedule pauses, in one phrase.
    static func targetList(_ rule: BlockRule) -> String {
        let names = rule.apps.map(\.name) + rule.sites.map(\.displayName)
        switch names.count {
        case 0: return tr("还没有选 App 或网站", "No apps or sites yet")
        case 1...2: return names.joined(separator: tr("、", ", "))
        default:
            let first = names.prefix(2).joined(separator: tr("、", ", "))
            return tr("\(first) 等 \(names.count) 项", "\(first) and \(names.count - 2) more")
        }
    }
}

enum TimeZoneText {
    /// UTC+8 / UTC−4 / UTC+5:30
    static func offset(_ zone: TimeZone, at date: Date = .now) -> String {
        let seconds = zone.secondsFromGMT(for: date)
        let sign = seconds >= 0 ? "+" : "−"
        let h = abs(seconds) / 3600, m = abs(seconds) % 3600 / 60
        return m == 0 ? "UTC\(sign)\(h)" : String(format: "UTC%@%d:%02d", sign, h, m)
    }

    static func name(_ zone: TimeZone) -> String {
        zone.localizedName(for: .generic, locale: AppSettings.shared.locale) ?? zone.identifier
    }

    static func city(_ zone: TimeZone) -> String {
        (zone.identifier.split(separator: "/").last.map(String.init) ?? zone.identifier)
            .replacingOccurrences(of: "_", with: " ")
    }

}
