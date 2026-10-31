import SwiftUI

/// When the capsule shows the time instead of the task.
enum CapsuleClockMode: String, CaseIterable {
    case off
    /// The last seconds of every minute: the time rises in, its minute rolls over, then the task
    /// comes back. The time only appears at the moment it changes.
    case onTheMinute
    /// Taking turns: ten seconds of the task, five of the time.
    case alternate
    /// The capsule is a clock; pointing at it brings the task.
    case always

    /// Whether the time has the capsule at this moment, all else being equal.
    func showsClock(at date: Date) -> Bool {
        switch self {
        case .off:
            return false
        case .onTheMinute:
            let second = Calendar.current.component(.second, from: date)
            return second >= 57 || second < 5
        case .alternate:
            return Int(date.timeIntervalSinceReferenceDate) % 15 < 5
        case .always:
            return true
        }
    }

    /// The same, with a task that's late or nearly due: it takes turns even in a capsule that's
    /// always the clock, so it isn't hidden until hovered. Other modes keep their rhythm.
    func showsClock(at date: Date, urgentTask: Bool) -> Bool {
        self == .always && urgentTask ? Self.alternate.showsClock(at: date) : showsClock(at: date)
    }
}

/// Dayline's line of time: the date and weekday, then the time, in the app's time zone.
struct ClockLineStyle: Equatable {
    var showsDate = true
    var showsWeekday = true
    var uses24Hour = true
    /// Wider letter spacing, English in capitals.
    var wideTracking = true
    /// The date and weekday step back, the time is bold.
    var emphasizesTime = false
    /// The changing digits roll as the minute turns.
    var rollsDigits = true
    var english = false

    /// `M月d日 EEE` + `HH:mm` in Chinese; `EEE MMM d` + `HH:mm` in English, as the system clock orders it.
    func parts(at date: Date, in timeZone: TimeZone) -> (leading: String?, time: String) {
        let weekday = showsWeekday ? "EEE" : nil
        let leadingPattern = (english ? [weekday, showsDate ? "MMM d" : nil] : [showsDate ? "M月d日" : nil, weekday])
            .compactMap { $0 }.joined(separator: " ")
        let timePattern = english ? (uses24Hour ? "HH:mm" : "h:mm a") : (uses24Hour ? "HH:mm" : "ah:mm")
        let leading = leadingPattern.isEmpty ? nil : Self.formatter(leadingPattern, timeZone, english).string(from: date)
        return (leading.map { wideTracking && english ? $0.uppercased() : $0 },
                Self.formatter(timePattern, timeZone, english).string(from: date))
    }

    private static var formatters: [String: DateFormatter] = [:]

    private static func formatter(_ pattern: String, _ timeZone: TimeZone, _ english: Bool) -> DateFormatter {
        let key = "\(pattern)|\(timeZone.identifier)|\(english)"
        if let cached = formatters[key] { return cached }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: english ? "en_US" : "zh_CN")
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        formatter.dateFormat = pattern
        formatters[key] = formatter
        return formatter
    }
}

/// The time as Dayline draws it, here in the capsule.
struct ClockLine: View {
    let now: Date
    var fontSize: CGFloat = 12.5
    @Environment(AppSettings.self) private var settings
    @AppStorage(Pref.clockShowsDate) private var showsDate = true
    @AppStorage(Pref.clockShowsWeekday) private var showsWeekday = true
    @AppStorage(Pref.clockUses24Hour) private var uses24Hour = true
    @AppStorage(Pref.clockWideTracking) private var wideTracking = true
    @AppStorage(Pref.clockEmphasizesTime) private var emphasizesTime = false
    @AppStorage(Pref.clockRollsDigits) private var rollsDigits = true
    @AppStorage(Pref.clockLanguage) private var language = "system"

    var body: some View {
        let style = ClockLineStyle(showsDate: showsDate, showsWeekday: showsWeekday, uses24Hour: uses24Hour,
                                   wideTracking: wideTracking, emphasizesTime: emphasizesTime, rollsDigits: rollsDigits,
                                   english: language == "en" || (language == "system" && !settings.isChinese))
        let parts = style.parts(at: now, in: settings.timeZone)
        let tracking: CGFloat = wideTracking ? fontSize * 0.1 : 0
        HStack(spacing: fontSize * 0.3 + tracking) {
            if let leading = parts.leading {
                Text(leading)
                    .fontWeight(wideTracking ? .light : .regular)
                    .foregroundStyle(emphasizesTime ? .secondary : .primary)
            }
            Text(parts.time)
                .fontWeight(emphasizesTime ? .semibold : wideTracking ? .medium : .regular)
                .contentTransition(rollsDigits ? .numericText() : .identity)
                .animation(rollsDigits ? .smooth(duration: 0.45) : nil, value: parts.time)
        }
        .font(.system(size: fontSize).monospacedDigit())
        .tracking(tracking)
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

/// Takes over the standalone Dayline's choices once, so the capsule's time looks like the menu
/// bar's did.
enum DaylineImport {
    private static let doneKey = "clock.importedFromDayline"

    static func runOnce() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey) else { return }
        defaults.set(true, forKey: doneKey)
        guard let dayline = UserDefaults(suiteName: "com.dayline.Dayline"), dayline.object(forKey: "showsDate") != nil
                || dayline.object(forKey: "menuBar.usesWideTracking") != nil else { return }
        let pairs = [("showsDate", Pref.clockShowsDate), ("showsWeekday", Pref.clockShowsWeekday),
                     ("uses24HourClock", Pref.clockUses24Hour), ("menuBar.usesWideTracking", Pref.clockWideTracking),
                     ("menuBar.emphasizesTime", Pref.clockEmphasizesTime), ("menuBar.rollsDigits", Pref.clockRollsDigits)]
        for (old, new) in pairs {
            if let value = dayline.object(forKey: old) as? Bool { defaults.set(value, forKey: new) }
        }
        if let language = dayline.string(forKey: "language"), ["zh", "en"].contains(language) {
            defaults.set(language, forKey: Pref.clockLanguage)
        }
    }
}
