import Foundation

/// Localized date and time labels, always in the selected time zone.
enum DateText {
    private static var settings: AppSettings { .shared }
    private static var calendar: Calendar { settings.calendar }

    private static let chineseWeekdays = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]
    private static let englishWeekdays = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    private static let englishWeekdaysLong = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
    private static let englishMonths = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    static func today(_ now: Date) -> Day { Day(now, in: calendar) }

    static func weekday(_ day: Day) -> String {
        (settings.isChinese ? chineseWeekdays : englishWeekdays)[day.mondayIndex]
    }

    static func weekdayLong(_ day: Day) -> String {
        settings.isChinese ? chineseWeekdays[day.mondayIndex] : englishWeekdaysLong[day.mondayIndex]
    }

    static func monthDay(_ day: Day) -> String {
        settings.isChinese ? "\(day.month)月\(day.day)日" : "\(englishMonths[day.month - 1]) \(day.day)"
    }

    static func time(_ date: Date) -> String { settings.formatTime(date) }

    static func relativeDay(_ day: Day, now: Date) -> String {
        let distance = today(now).days(until: day)
        switch distance {
        case 0: return tr("今天", "Today")
        case 1: return tr("明天", "Tomorrow")
        case -1: return tr("昨天", "Yesterday")
        case 2 where settings.isChinese: return "后天"
        default:
            let daysLeftThisWeek = 6 - today(now).mondayIndex
            if distance > 0 && distance <= daysLeftThisWeek { return weekday(day) }
            if distance > daysLeftThisWeek && distance <= daysLeftThisWeek + 7 {
                return tr("下", "Next ") + weekday(day)
            }
            return monthDay(day)
        }
    }

    static func dueLabel(_ schedule: Schedule?, now: Date) -> String? {
        switch schedule {
        case nil: return nil
        case .day(let day): return relativeDay(day, now: now)
        case .time(let date):
            let day = relativeDay(Day(date, in: calendar), now: now)
            return Day(date, in: calendar) == today(now) ? time(date) : "\(day) \(time(date))"
        }
    }

    static func dueLabel(_ task: TaskItem, now: Date) -> String? {
        dueLabel(task.schedule, now: now)
    }

    static func isOverdue(_ task: TaskItem, now: Date) -> Bool {
        guard !task.isDone, let schedule = task.schedule else { return false }
        switch schedule {
        case .time(let date): return date < now
        case .day(let day): return day < today(now)
        }
    }

    static func isDueToday(_ task: TaskItem, now: Date) -> Bool {
        task.day(in: calendar) == today(now)
    }

    static func dayHeader(_ day: Day, now: Date) -> String {
        switch today(now).days(until: day) {
        case 1: tr("明天 · \(weekday(day))", "Tomorrow · \(weekday(day))")
        case 2 where settings.isChinese: "后天 · \(weekday(day))"
        default: "\(weekday(day)) · \(monthDay(day))"
        }
    }

    static func elapsed(since start: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    /// e.g. "UTC+08:00" / "UTC−04:00"
    static func utcOffset(_ zone: TimeZone, at date: Date) -> String {
        let seconds = zone.secondsFromGMT(for: date)
        let sign = seconds < 0 ? "−" : "+"
        let minutes = abs(seconds) / 60
        return String(format: "UTC%@%02d:%02d", sign, minutes / 60, minutes % 60)
    }
}
