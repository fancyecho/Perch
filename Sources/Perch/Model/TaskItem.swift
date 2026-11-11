import Foundation

nonisolated enum Priority: Int, Codable, CaseIterable, Comparable, Sendable {
    case none = 0, low, medium, high

    static func < (lhs: Priority, rhs: Priority) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A calendar day with no time zone attached ("floating"), so a date-only task stays on the
/// same day when the user switches time zones or a DST transition happens.
nonisolated struct Day: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    let year: Int
    let month: Int
    let day: Int

    private static let utc: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()

    init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    init(_ date: Date, in calendar: Calendar) {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: c.year ?? 1970, month: c.month ?? 1, day: c.day ?? 1)
    }

    init(ordinal: Int) {
        let c = Self.utc.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: Double(ordinal) * 86_400))
        self.init(year: c.year ?? 1970, month: c.month ?? 1, day: c.day ?? 1)
    }

    /// Days since 1970-01-01. Counting in UTC keeps day arithmetic free of DST.
    var ordinal: Int {
        let date = Self.utc.date(from: DateComponents(year: year, month: month, day: day)) ?? .distantPast
        return Int((date.timeIntervalSince1970 / 86_400).rounded(.down))
    }

    /// False for impossible dates such as February 30.
    var isValid: Bool { Day(ordinal: ordinal) == self }

    /// 0 = Monday … 6 = Sunday (1970-01-01 was a Thursday).
    var mondayIndex: Int { ((ordinal % 7) + 7 + 3) % 7 }

    func adding(days: Int) -> Day { Day(ordinal: ordinal + days) }

    func days(until other: Day) -> Int { other.ordinal - ordinal }

    /// Wall-clock time on this day. A time skipped by a DST jump resolves forward;
    /// a repeated one resolves to its first occurrence.
    func date(hour: Int, minute: Int, in calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))
            ?? Self.utc.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))
            ?? .distantPast
    }

    func start(in calendar: Calendar) -> Date {
        calendar.startOfDay(for: date(hour: 12, minute: 0, in: calendar))
    }

    static func < (lhs: Day, rhs: Day) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    var description: String { String(format: "%04d-%02d-%02d", year, month, day) }

    init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad day \(text)"))
        }
        self.init(year: parts[0], month: parts[1], day: parts[2])
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

nonisolated enum Schedule: Hashable, Sendable {
    /// Date-only: floats with the calendar day.
    case day(Day)
    /// A specific moment, shown in whatever time zone is selected.
    case time(Date)

    func day(in calendar: Calendar) -> Day {
        switch self {
        case .day(let day): day
        case .time(let date): Day(date, in: calendar)
        }
    }

    var time: Date? {
        if case .time(let date) = self { return date }
        return nil
    }
}

/// How a task comes back once it's done (or skipped): the next one lands on the next matching day,
/// at the same time of day and with the same length.
nonisolated enum Recurrence: Hashable, Sendable {
    case daily
    /// Monday to Friday.
    case weekdays
    /// On these weekdays, 0 = Monday … 6 = Sunday. Never empty.
    case weekly(Set<Int>)
    /// The same day of the month (the last day, in months too short for it).
    case monthly

    func matches(_ day: Day, anchor: Day) -> Bool {
        switch self {
        case .daily: true
        case .weekdays: day.mondayIndex < 5
        case .weekly(let days): days.contains(day.mondayIndex)
        case .monthly: day.day == min(anchor.day, day.lastDayOfMonth)
        }
    }

    /// The first matching day after `day`. `anchor` is the day of the month a monthly task keeps.
    func next(after day: Day, anchor: Day? = nil) -> Day {
        let anchor = anchor ?? day
        if case .monthly = self {
            let (year, month) = day.month == 12 ? (day.year + 1, 1) : (day.year, day.month + 1)
            let last = Day(year: year, month: month, day: 1).lastDayOfMonth
            return Day(year: year, month: month, day: min(anchor.day, last))
        }
        var candidate = day.adding(days: 1)
        while !matches(candidate, anchor: anchor) { candidate = candidate.adding(days: 1) }
        return candidate
    }

    /// The first matching day on or after `day`.
    func first(onOrAfter day: Day) -> Day {
        matches(day, anchor: day) ? day : next(after: day, anchor: day)
    }

    @MainActor var title: String {
        switch self {
        case .daily: return tr("每天", "Every day")
        case .weekdays: return tr("工作日", "Weekdays")
        case .monthly: return tr("每月", "Monthly")
        case .weekly(let days):
            let sorted = days.sorted()
            if sorted == Array(0...6) { return tr("每天", "Every day") }
            if sorted == Array(0...4) { return tr("工作日", "Weekdays") }
            let zh = ["一", "二", "三", "四", "五", "六", "日"]
            let en = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
            return tr("每周" + sorted.map { zh[$0] }.joined(separator: "、"), "Every " + sorted.map { en[$0] }.joined(separator: ", "))
        }
    }

    /// Stored as text: "daily", "weekdays", "weekly:0,2,4", "monthly".
    var storageValue: String {
        switch self {
        case .daily: "daily"
        case .weekdays: "weekdays"
        case .monthly: "monthly"
        case .weekly(let days): "weekly:" + days.sorted().map(String.init).joined(separator: ",")
        }
    }

    init?(storageValue: String) {
        switch storageValue {
        case "daily": self = .daily
        case "weekdays": self = .weekdays
        case "monthly": self = .monthly
        default:
            guard storageValue.hasPrefix("weekly:") else { return nil }
            let days = Set(storageValue.dropFirst(7).split(separator: ",").compactMap { Int($0) }.filter { (0...6).contains($0) })
            guard !days.isEmpty else { return nil }
            self = .weekly(days)
        }
    }
}

extension Day {
    nonisolated var lastDayOfMonth: Int {
        var day = 31
        while day > 28, !Day(year: year, month: month, day: day).isValid { day -= 1 }
        return day
    }
}

nonisolated struct TaskItem: Identifiable, Hashable, Sendable {
    var id = UUID()
    var title: String
    var schedule: Schedule?
    var priority: Priority = .none
    var tags: [String] = []
    var createdAt = Date()
    var completedAt: Date?
    /// How long a timed task lasts, in minutes. Nil means the default length.
    var duration: Int?
    /// A color picked by hand. Nil derives one from the first tag.
    var color: TaskColor?
    /// Comes back on a schedule once done or skipped.
    var recurrence: Recurrence?
    /// Free-form details. Nil (never empty) when there are none.
    var notes: String?
    /// A checklist of smaller steps.
    var subtasks: [Subtask] = []

    static let defaultDuration = 30
    static let durationRange = 5...(24 * 60)

    var isDone: Bool { completedAt != nil }
    var hasTime: Bool { schedule?.time != nil }
    var minutes: Int { duration ?? Self.defaultDuration }
    /// When a timed task is over.
    var end: Date? { schedule?.time.map { $0.addingTimeInterval(Double(minutes) * 60) } }

    func day(in calendar: Calendar) -> Day? { schedule?.day(in: calendar) }

    var hasNotes: Bool { notes.map { !$0.isEmpty } ?? false }
    /// Has a checklist or notes to show when the task is opened up.
    var hasDetails: Bool { !subtasks.isEmpty || hasNotes }
    /// Checked-off steps and all steps, counting only ones with a title.
    var checklist: (done: Int, total: Int) {
        let named = subtasks.filter { !$0.title.isEmpty }
        return (named.filter(\.isDone).count, named.count)
    }
}

/// One step of a task's checklist.
nonisolated struct Subtask: Identifiable, Hashable, Sendable, Codable {
    var id = UUID()
    var title: String
    var isDone = false

    private enum CodingKeys: String, CodingKey {
        case id, title, done
    }

    init(id: UUID = UUID(), title: String, isDone: Bool = false) {
        self.id = id
        self.title = title
        self.isDone = isDone
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        isDone = try c.decodeIfPresent(Bool.self, forKey: .done) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        if isDone { try c.encode(true, forKey: .done) }
    }
}

extension TaskItem: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, title, day, at, priority, tags, createdAt, completedAt, duration, color, repeats, notes, subtasks
        // Format used before floating days existed.
        case due, hasTime
    }

    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        priority = try c.decodeIfPresent(Priority.self, forKey: .priority) ?? .none
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
        completedAt = try c.decodeIfPresent(Date.self, forKey: .completedAt)
        duration = try c.decodeIfPresent(Int.self, forKey: .duration)
        color = try? c.decodeIfPresent(TaskColor.self, forKey: .color)
        recurrence = (try? c.decodeIfPresent(String.self, forKey: .repeats)).flatMap { $0.flatMap(Recurrence.init(storageValue:)) }
        notes = (try? c.decodeIfPresent(String.self, forKey: .notes)).flatMap { $0 }.flatMap { $0.isEmpty ? nil : $0 }
        // A step left blank when the app quit mid-edit isn't worth keeping.
        subtasks = ((try? c.decodeIfPresent([Subtask].self, forKey: .subtasks)) ?? nil ?? []).filter { !$0.title.isEmpty }

        if let at = try c.decodeIfPresent(Date.self, forKey: .at) {
            schedule = .time(at)
        } else if let day = try c.decodeIfPresent(Day.self, forKey: .day) {
            schedule = .day(day)
        } else if let due = try c.decodeIfPresent(Date.self, forKey: .due) {
            // Legacy date-only tasks were saved as local midnight of the system time zone.
            let timed = try c.decodeIfPresent(Bool.self, forKey: .hasTime) ?? false
            schedule = timed ? .time(due) : .day(Day(due, in: .current))
        }
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        switch schedule {
        case .day(let day): try c.encode(day, forKey: .day)
        case .time(let date): try c.encode(date, forKey: .at)
        case nil: break
        }
        try c.encode(priority, forKey: .priority)
        try c.encode(tags, forKey: .tags)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(completedAt, forKey: .completedAt)
        try c.encodeIfPresent(duration, forKey: .duration)
        try c.encodeIfPresent(color, forKey: .color)
        try c.encodeIfPresent(recurrence?.storageValue, forKey: .repeats)
        // Left out when empty, so files of tasks without details read as they always have.
        if let notes, !notes.isEmpty { try c.encode(notes, forKey: .notes) }
        if !subtasks.isEmpty { try c.encode(subtasks, forKey: .subtasks) }
    }
}

/// The timeline's palette: soft, slightly muted tones that read on light and dark glass.
nonisolated enum TaskColor: String, Codable, CaseIterable, Sendable {
    case coral, amber, sage, teal, sky, indigo, lavender, rose
}

nonisolated struct FocusSession: Codable, Hashable, Sendable {
    var taskID: UUID
    var startedAt: Date
}
