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
}

