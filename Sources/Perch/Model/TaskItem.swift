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

nonisolated struct TaskItem: Identifiable, Hashable, Sendable {
    var id = UUID()
    var title: String
    var schedule: Schedule?
    var priority: Priority = .none
    var tags: [String] = []
    var createdAt = Date()
    var completedAt: Date?

    var isDone: Bool { completedAt != nil }
    var hasTime: Bool { schedule?.time != nil }

    func day(in calendar: Calendar) -> Day? { schedule?.day(in: calendar) }
}

extension TaskItem: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, title, day, at, priority, tags, createdAt, completedAt
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
    }
}

nonisolated struct FocusSession: Codable, Hashable, Sendable {
    var taskID: UUID
    var startedAt: Date
}
