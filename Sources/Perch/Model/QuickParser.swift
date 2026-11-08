import Foundation

struct ParsedInput: Equatable {
    var title: String
    var schedule: Schedule?
    var priority: Priority = .none
    var tags: [String] = []
    /// True when the date or time came from the text rather than the default day.
    var hasExplicitDate = false
    /// Minutes, from a range ("3-5pm") or a length ("1小时", "45 min").
    var duration: Int?
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
    private static let rangeSeparator = #"\s*(?:-|–|—|~|～|到|至)\s*"#
    private static let hourNumber = #"(\d{1,2}|[零一二两三四五六七八九十]{1,3})"#

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

        // Time ranges: "9:00-10:30", "下午3点到5点半", "3-5pm"
        var end: (period: Period?, hour: Int, minute: Int)?
        if let g = take("(\(periodWords))?\\s*(\\d{1,2})\\s*[:：]\\s*(\\d{2})\(rangeSeparator)(\(periodWords))?\\s*(\\d{1,2})\\s*[:：]\\s*(\\d{2})", from: &text),
           let h1 = g.int(2), let h2 = g.int(5) {
            period = Period(g[1]) ?? period
            hour = h1
            minute = g.int(3) ?? 0
            isClockNotation = true
            end = (Period(g[4]), h2, g.int(6) ?? 0)
        } else if let g = take("(\(periodWords))?\\s*\(hourNumber)\\s*(?:点\\s*\(minuteSuffix))?\(rangeSeparator)(\(periodWords))?\\s*\(hourNumber)\\s*点\\s*\(minuteSuffix)", from: &text),
                  let h1 = number(g[2]), let h2 = number(g[8]) {
            period = Period(g[1]) ?? period
            hour = h1
            minute = minutes(g, from: 3)
            end = (Period(g[7]), h2, minutes(g, from: 9))
        } else if let g = take(#"(?:\bfrom\s+)?\b(\d{1,2})(?:[:.](\d{2}))?\s*(am|pm)?\s*(?:-|–|—|~|to)\s*(\d{1,2})(?:[:.](\d{2}))?\s*(am|pm)\b"#, from: &text),
                  let h1 = g.int(1), let h2 = g.int(4) {
            let endPeriod = Period(g[6])
            // "3-5pm" shares the pm, unless that would put the start after the end ("11-1pm").
            if let own = Period(g[3]) {
                period = own
            } else if let endPeriod, endPeriod.adjust(h1) <= endPeriod.adjust(h2) {
                period = endPeriod
            } else {
                period = .morning
            }
            hour = h1
            minute = g.int(2) ?? 0
            end = (endPeriod, h2, g.int(5) ?? 0)
        }

        // Time
        if hour != nil {
            // already read as a range
        } else if let g = take("(\(periodWords))?\\s*(\\d{1,2})\\s*[:：]\\s*(\\d{2})", from: &text) {
            period = Period(g[1]) ?? period
            hour = g.int(2)
            minute = g.int(3) ?? 0
            isClockNotation = true
        } else if let g = take("(\(periodWords))?\\s*(\\d{1,2})\\s*点\\s*\(minuteSuffix)", from: &text)
                    ?? take("(\(periodWords))\\s*([零一二两三四五六七八九十]{1,3})\\s*点\\s*\(minuteSuffix)", from: &text) {
            period = Period(g[1]) ?? period
            hour = number(g[2])
            minute = minutes(g, from: 3)
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
                if let end {
                    result.duration = rangeLength(startHour: h, startMinute: minute, end: end, sharedPeriod: period)
                }
            } else if let day {
                result.schedule = .day(day)
            }
        }

        if result.duration == nil { result.duration = takeDuration(from: &text) }

        result.hasExplicitDate = result.schedule != nil
        if result.schedule == nil, let defaultDay { result.schedule = .day(defaultDay) }
        result.title = cleanTitle(text)
        return result
    }

    // MARK: - Pieces

    /// The minute part after 点: 半 / 一刻 / 三刻 / digits, in four groups starting at `index`.
    private static func minutes(_ g: Groups, from index: Int) -> Int {
        g[index] != nil ? 30 : g[index + 1] != nil ? 15 : g[index + 2] != nil ? 45 : (g.int(index + 3) ?? 0)
    }

    /// Length of "start–end" in minutes. An end without its own period follows the start's;
    /// an end that still lands before the start is read as later the same day ("11-1点").
    private static func rangeLength(startHour: Int, startMinute: Int, end: (period: Period?, hour: Int, minute: Int), sharedPeriod: Period?) -> Int? {
        guard end.hour <= 24, end.minute < 60 else { return nil }
        let start = startHour * 60 + startMinute
        var endHour = end.hour
        if let period = end.period ?? sharedPeriod { endHour = period.adjust(endHour) }
        var finish = endHour * 60 + end.minute
        while finish <= start, finish + 12 * 60 <= start + 24 * 60 { finish += 12 * 60 }
        let length = finish - start
        return TaskItem.durationRange.contains(length) ? length : nil
    }

    /// A length on its own: "1小时", "一个半小时", "半小时", "45分钟", "for 1h30m", "90 min".
    private static func takeDuration(from text: inout String) -> Int? {
        var total: Double?
        if let g = take(#"(\d+(?:\.\d+)?|[一两二三四五六七八九十]{1,3})\s*个?\s*(半)?\s*(?:小时|钟头)(?:\s*(\d{1,2})\s*分钟?)?(?!\s*[后以])"#, from: &text),
           let hours = g[1].flatMap({ Double($0) ?? number($0).map(Double.init) }) {
            total = hours * 60 + (g[2] != nil ? 30 : 0) + Double(g.int(3) ?? 0)
        } else if take(#"半\s*个?\s*(?:小时|钟头)(?!\s*[后以])"#, from: &text) != nil {
            total = 30
        } else if let g = take(#"(\d{1,3})\s*分钟(?!\s*[后以])"#, from: &text), let m = g.int(1) {
            total = Double(m)
        } else if let g = take(#"\b(?:for\s+)?(\d+(?:\.\d+)?)\s*(?:h|hrs?|hours?)(?:\s*(\d{1,2})\s*(?:m|mins?|minutes?))?\b"#, from: &text),
                  let hours = g[1].flatMap(Double.init) {
            total = hours * 60 + Double(g.int(2) ?? 0)
        } else if let g = take(#"\b(?:for\s+)?(\d{1,3})\s*(?:m|mins?|minutes?)\b"#, from: &text), let m = g.int(1) {
            total = Double(m)
        }
        guard let total else { return nil }
        let minutes = Int(total.rounded())
        return TaskItem.durationRange.contains(minutes) ? minutes : nil
    }

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
