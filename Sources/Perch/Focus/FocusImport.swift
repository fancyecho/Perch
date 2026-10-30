import Foundation

/// Brings over, once, what the standalone Focus app saved: its schedules, the days of focus, how
/// often things were blocked, and its preferences. Its time zone already matches Perch's setting.
enum FocusImport {
    private static let doneKey = "focus.importedFromFocusApp"
    private static let legacyDomain = "com.helian.focus"

    static func runOnce() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey) else { return }
        defaults.set(true, forKey: doneKey)
        guard let legacy = UserDefaults(suiteName: legacyDomain), legacy.object(forKey: "blockRules") != nil
                || legacy.object(forKey: "dailyFocusSeconds") != nil else { return }

        if defaults.data(forKey: ScheduleStore.Keys.rules) == nil, let rules = legacy.data(forKey: "blockRules") {
            defaults.set(rules, forKey: ScheduleStore.Keys.rules)
        }
        if defaults.object(forKey: ScheduleStore.Keys.passCounts) == nil, let counts = legacy.dictionary(forKey: "blockPassCounts") {
            defaults.set(counts, forKey: ScheduleStore.Keys.passCounts)
        }
        if defaults.object(forKey: ScheduleStore.Keys.attempts) == nil, let attempts = legacy.dictionary(forKey: "blockAttempts") {
            defaults.set(attempts, forKey: ScheduleStore.Keys.attempts)
        }
        if let days = legacy.dictionary(forKey: "dailyFocusSeconds") as? [String: Double] {
            var merged = defaults.dictionary(forKey: FocusStore.Keys.daily) as? [String: Double] ?? [:]
            for (day, seconds) in days { merged[day, default: 0] += seconds }
            defaults.set(merged, forKey: FocusStore.Keys.daily)
        }
        for (old, new) in [("idleMinutes", FocusStore.Keys.idleMinutes), ("keepAwakeMinutes", FocusStore.Keys.keepAwakeMinutes),
                           ("soundEnabled", FocusStore.Keys.soundEnabled)] where defaults.object(forKey: new) == nil {
            if let value = legacy.object(forKey: old) { defaults.set(value, forKey: new) }
        }
        ScheduleStore.shared.reload()
        FocusStore.shared.reload()
    }
}
