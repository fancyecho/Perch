import Foundation

struct ParsedInput: Equatable {
    var title: String
    var schedule: Schedule?
    var priority: Priority = .none
    var tags: [String] = []
    /// True when the date or time came from the text rather than the default day.
    var hasExplicitDate = false
}

/// Turns a single line like `明天下午3点 写周报 !! #工作` into a task.
/// Understands common Chinese and English date, time, priority and tag phrasing.
/// Days are counted in the given calendar and times are built from wall-clock components,
/// so results stay correct across DST transitions.
enum QuickParser {
    private enum Period {
        case dawn, morning, noon, afternoon, evening

        init?(_ word: String?) {
            switch word?.lowercased() {
            case "凌晨": self = .dawn
            case "早上", "早晨", "清晨", "上午", "早", "morning", "am": self = .morning
            case "中午", "noon": self = .noon
            case "下午", "afternoon", "pm": self = .afternoon
            case "傍晚", "晚上", "夜里", "晚", "evening", "tonight": self = .evening
            default: return nil
            }
        }

        var defaultHour: Int {
            switch self {
            case .dawn: 6
            case .morning: 9
            case .noon: 12
            case .afternoon: 15
            case .evening: 20
            }
        }

        func adjust(_ hour: Int) -> Int {
            switch self {
            case .dawn, .morning: hour == 12 ? 0 : hour
            case .noon: hour < 11 ? hour + 12 : hour
            case .afternoon, .evening: hour < 12 ? hour + 12 : hour
            }
        }
    }

    private static let periodWords = "凌晨|早上|早晨|清晨|上午|中午|下午|傍晚|晚上|夜里|晚|早"
    private static let minuteSuffix = #"(?:(半)|(一刻)|(三刻)|(\d{1,2})\s*分?)?"#

    static func parse(
        _ raw: String,
        now: Date = .now,
        defaultDay: Day? = nil,
        calendar cal: Calendar = AppSettings.shared.calendar
    ) -> ParsedInput {
        var text = " \(raw) "
        var result = ParsedInput(title: "")

        for groups in takeAll(#"[#＃]([^\s#＃]+)"#, from: &text) {
            if let tag = groups[1], !result.tags.contains(tag) { result.tags.append(tag) }
        }
        result.priority = takePriority(from: &text)

        let today = Day(now, in: cal)
        var dayOffset: Int?
        var explicitDay: Day?
        var absolute: Date?
        var period: Period?
        var hour: Int?
        var minute = 0
        /// "9:30" style is read as 24-hour time, so it never gets the afternoon guess.
        var isClockNotation = false

        // Relative durations: "2小时后", "in 30 min"
        if let g = take(#"(\d{1,3})\s*个?\s*(分钟|小时|钟头)后"#, from: &text), let n = g.int(1) {
            absolute = now.addingTimeInterval(Double(n) * (g[2] == "分钟" ? 60 : 3600))
        } else if let g = take(#"\bin\s+(\d{1,3})\s*(minutes?|mins?|m|hours?|hrs?|h)\b"#, from: &text), let n = g.int(1) {
            absolute = now.addingTimeInterval(Double(n) * ((g[2] ?? "").hasPrefix("m") ? 60 : 3600))
        }

        // Day
        if let g = take(#"(\d{1,3})\s*天后"#, from: &text) ?? take(#"\bin\s+(\d{1,3})\s*days?\b"#, from: &text) {
            dayOffset = g.int(1)
        } else if let g = take(#"(大后天|后天|明早|明晚|明天|明日|今早|今晚|今夜|今天|今日)"#, from: &text)
                    ?? take(#"\b(tomorrow|tmr|today|tonight)\b"#, from: &text) {
            switch g[1]?.lowercased() {
            case "大后天": dayOffset = 3
            case "后天": dayOffset = 2
            case "明早": dayOffset = 1; period = .morning
            case "明晚": dayOffset = 1; period = .evening
            case "明天", "明日", "tomorrow", "tmr": dayOffset = 1
            case "今早": dayOffset = 0; period = .morning
            case "今晚", "今夜", "tonight": dayOffset = 0; period = .evening
            default: dayOffset = 0
            }
        } else if let g = take(#"(下下|下个|下|这个|这|本)?(?:周|星期|礼拜)([一二三四五六日天1-7])"#, from: &text),
                  let target = weekdayIndex(g[2]) {
            dayOffset = weekdayOffset(target: target, prefix: g[1], today: today)
        } else if let g = take(#"\b(next\s+)?(monday|tuesday|wednesday|thursday|friday|saturday|sunday|mon|tues|tue|wed|thurs|thur|thu|fri|sat|sun)\b"#, from: &text),
                  let target = weekdayIndex(g[2]) {
            dayOffset = weekdayOffset(target: target, prefix: g[1] == nil ? nil : "下", today: today)
        } else if take(#"(下周|下个星期|下星期|下个礼拜|下礼拜)"#, from: &text) != nil || take(#"\bnext\s+week\b"#, from: &text) != nil {
            dayOffset = weekdayOffset(target: 0, prefix: "下", today: today)
        } else if take(#"(周末)"#, from: &text) != nil || take(#"\b(weekend)\b"#, from: &text) != nil {
            dayOffset = weekdayOffset(target: 5, prefix: nil, today: today)
        } else if let g = take(#"(\d{1,2})\s*月\s*(\d{1,2})\s*[日号]?"#, from: &text)
                    ?? take(#"(?<![\d/])(\d{1,2})/(\d{1,2})(?![\d/])"#, from: &text),
                  let month = g.int(1), let day = g.int(2) {
            explicitDay = nextDay(month: month, day: day, today: today)
        } else if let g = take(#"(?<![\d月])(\d{1,2})\s*[日号](?!后)"#, from: &text), let day = g.int(1) {
            explicitDay = nextDay(month: nil, day: day, today: today)
        }

        // Time
        if let g = take("(\(periodWords))?\\s*(\\d{1,2})\\s*[:：]\\s*(\\d{2})", from: &text) {
            period = Period(g[1]) ?? period
            hour = g.int(2)
            minute = g.int(3) ?? 0
            isClockNotation = true
        } else if let g = take("(\(periodWords))?\\s*(\\d{1,2})\\s*点\\s*\(minuteSuffix)", from: &text)
                    ?? take("(\(periodWords))\\s*([零一二两三四五六七八九十]{1,3})\\s*点\\s*\(minuteSuffix)", from: &text) {
            period = Period(g[1]) ?? period
            hour = number(g[2])
            minute = g[3] != nil ? 30 : g[4] != nil ? 15 : g[5] != nil ? 45 : (g.int(6) ?? 0)
        } else if let g = take(#"\b(\d{1,2})(?:[:.](\d{2}))?\s*(am|pm)\b"#, from: &text) {
            period = Period(g[3])
            hour = g.int(1)
            minute = g.int(2) ?? 0
        } else if let g = take(#"\bat\s+(\d{1,2})(?::(\d{2}))?\b"#, from: &text) {
            hour = g.int(1)
            minute = g.int(2) ?? 0
        } else if let g = take("(凌晨|早上|早晨|清晨|上午|中午|下午|傍晚|晚上|夜里)", from: &text)
                    ?? take(#"\b(morning|noon|afternoon|evening)\b"#, from: &text) {
            period = Period(g[1])
        }

        if let absolute {
            result.schedule = .time(absolute)
        } else {
            let day = explicitDay ?? dayOffset.map { today.adding(days: $0) }
            if hour == nil, let period { hour = period.defaultHour }
            if var h = hour, h <= 24, minute < 60 {
                if let period {
                    h = period.adjust(h)
                } else if isClockNotation {
                    // keep as written
                } else if h >= 1 && h <= 6 {
                    h += 12
                } else if h < 12, day == nil,
                          today.date(hour: h, minute: minute, in: cal) < now,
                          today.date(hour: h + 12, minute: minute, in: cal) > now {
                    h += 12
                }
                h = min(h, 23)
                var date = (day ?? today).date(hour: h, minute: minute, in: cal)
                if day == nil, date < now {
                    date = today.adding(days: 1).date(hour: h, minute: minute, in: cal)
                }
                result.schedule = .time(date)
            } else if let day {
                result.schedule = .day(day)
            }
        }

        result.hasExplicitDate = result.schedule != nil
        if result.schedule == nil, let defaultDay { result.schedule = .day(defaultDay) }
        result.title = cleanTitle(text)
        return result
    }

    // MARK: - Pieces

    private static func takePriority(from text: inout String) -> Priority {
        if let g = take(#"(?<=\s)[pP]([1-3])(?=\s)"#, from: &text) {
            switch g[1] {
            case "1": return .high
            case "2": return .medium
            default: return .low
            }
        }
        if let g = take(#"[!！]{1,3}(?=\s)"#, from: &text), let marks = g[0] {
            return Priority(rawValue: min(marks.count, 3)) ?? .none
        }
        return .none
    }

    /// Monday = 0 … Sunday = 6
    private static func weekdayIndex(_ token: String?) -> Int? {
        guard let token = token?.lowercased() else { return nil }
        let chinese: [String: Int] = ["一": 0, "二": 1, "三": 2, "四": 3, "五": 4, "六": 5, "日": 6, "天": 6]
        if let v = chinese[token] { return v }
        if let n = Int(token), (1...7).contains(n) { return n - 1 }
        let english = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]
        return english.firstIndex { token.hasPrefix($0) }
    }

    private static func weekdayOffset(target: Int, prefix: String?, today: Day) -> Int {
        let current = today.mondayIndex
        switch prefix {
        case "下", "下个": return 7 - current + target
        case "下下": return 14 - current + target
        case "这", "这个", "本":
            let delta = target - current
            return delta < 0 ? delta + 7 : delta
        default: return (target - current + 7) % 7
        }
    }

    /// The next occurrence of month/day (or day of month) on or after today.
    private static func nextDay(month: Int?, day: Int, today: Day) -> Day? {
        let candidate = Day(year: today.year, month: month ?? today.month, day: day)
        if candidate.isValid && candidate >= today { return candidate }
        if month == nil {
            let nextMonth = today.month == 12 ? Day(year: today.year + 1, month: 1, day: day) : Day(year: today.year, month: today.month + 1, day: day)
            return nextMonth.isValid ? nextMonth : nil
        }
        let nextYear = Day(year: today.year + 1, month: candidate.month, day: day)
        return nextYear.isValid ? nextYear : nil
    }

    private static func number(_ token: String?) -> Int? {
        guard let token else { return nil }
        if let n = Int(token) { return n }
        let digits: [Character: Int] = ["零": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
        if token == "十" { return 10 }
        if token.hasPrefix("十"), let last = token.last, let v = digits[last] { return 10 + v }
        if token.count == 1, let first = token.first { return digits[first] }
        return nil
    }

    private static func cleanTitle(_ text: String) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.trimmingCharacters(in: CharacterSet(charactersIn: " ,，。.、:：;；-—"))
    }

    // MARK: - Regex helpers

    private static var cache: [String: NSRegularExpression] = [:]

    private static func regex(_ pattern: String) -> NSRegularExpression? {
        if let cached = cache[pattern] { return cached }
        let compiled = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        cache[pattern] = compiled
        return compiled
    }

    /// Finds the first match, removes it from `text` and returns its capture groups.
    private static func take(_ pattern: String, from text: inout String) -> Groups? {
        guard let re = regex(pattern) else { return nil }
        let ns = text as NSString
        guard let match = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let values = (0..<match.numberOfRanges).map { i -> String? in
            let r = match.range(at: i)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
        text = ns.replacingCharacters(in: match.range, with: " ")
        return Groups(values: values)
    }

    private static func takeAll(_ pattern: String, from text: inout String) -> [Groups] {
        var all: [Groups] = []
        while let g = take(pattern, from: &text) { all.append(g) }
        return all
    }

    private struct Groups {
        let values: [String?]
        subscript(_ i: Int) -> String? { i < values.count ? values[i] : nil }
        func int(_ i: Int) -> Int? { self[i].flatMap { Int($0) } }
    }
}
