import Foundation

enum Fmt {
    /// Returns (number, unit) in decimal units, as Finder and Activity Monitor count.
    static func bytesParts(_ value: Double, base: Double = 1000) -> (String, String) {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var v = max(value, 0)
        var index = 0
        while v >= base && index < units.count - 1 { v /= base; index += 1 }
        let number: String
        if index == 0 { number = String(format: "%.0f", v) }
        else if v >= 100 { number = String(format: "%.0f", v) }
        else if v >= 10 { number = String(format: "%.1f", v) }
        else { number = String(format: "%.2f", v) }
        return (number, units[index])
    }

    static func bytes(_ value: Double) -> String {
        let (n, u) = bytesParts(value)
        return "\(n) \(u)"
    }

    static func bytes<T: BinaryInteger>(_ value: T) -> String { bytes(Double(value)) }

    /// Memory counts in 1024s, so 8 GB of RAM reads “8.00 GB”.
    static func memory<T: BinaryInteger>(_ value: T) -> String {
        let (n, u) = bytesParts(Double(value), base: 1024)
        return "\(n) \(u)"
    }

    static func rate(_ value: Double) -> String { bytes(value) + "/s" }

    /// The compact form for the menu bar, such as “1.2M”.
    static func compactRate(_ value: Double) -> String {
        let units = ["B", "K", "M", "G"]
        var v = max(value, 0)
        var index = 0
        while v >= 1000 && index < units.count - 1 { v /= 1000; index += 1 }
        let number = (v >= 10 || index == 0) ? String(format: "%.0f", v) : String(format: "%.1f", v)
        return number + units[index]
    }

    static func percent(_ value: Double) -> String { String(format: "%.0f", min(max(value, 0), 100)) }

    static func uptime(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds) / 60
        let days = minutes / 1440, hours = (minutes % 1440) / 60, mins = minutes % 60
        if days > 0 { return tr("\(days) 天 \(hours) 小时", "\(days)d \(hours)h") }
        if hours > 0 { return tr("\(hours) 小时 \(mins) 分", "\(hours)h \(mins)m") }
        return tr("\(mins) 分钟", "\(mins) min")
    }

    /// Split into (number, unit) for mixed type sizes, such as [("1", "h"), ("12", "m")].
    static func durationParts(_ total: Int) -> [(String, String)] {
        let hours = total / 60, mins = total % 60
        if hours == 0 { return [("\(mins)", tr("分钟", "min"))] }
        return mins == 0 ? [("\(hours)", tr("小时", "h"))] : [("\(hours)", tr("小时", "h")), ("\(mins)", tr("分", "m"))]
    }

    static func minutes(_ total: Int) -> String {
        total >= 60 ? "\(total / 60):\(String(format: "%02d", total % 60))" : tr("\(total) 分钟", "\(total) min")
    }
}
