import Foundation

/// The last 24 hours of battery level: a point every 5 minutes (or when charging starts or stops), saved
/// in Application Support so the curve survives a relaunch.
@MainActor
final class BatteryHistory {
    struct Point: Codable, Equatable {
        var time: Date
        var percent: Int
        var charging: Bool
    }

    static let window: TimeInterval = 24 * 3600
    static let spacing: TimeInterval = 5 * 60
    /// Points further apart than this (sleep, say) break the curve.
    static let gap: TimeInterval = 20 * 60

    private(set) var points: [Point] = []
    private let url: URL?

    init(url: URL? = BatteryHistory.defaultURL) {
        self.url = url
        if let url, let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode([Point].self, from: data) {
            points = saved.filter { Date().timeIntervalSince($0.time) <= Self.window }
        }
    }

    /// Made-up history for STATUS_DEMO: discharging by day, one charge at noon, a gap for sleep at night; never touches the file.
    static func demo(now: Date = Date()) -> BatteryHistory {
        let history = BatteryHistory(url: nil)
        var percent = 92.0
        for step in stride(from: 288, through: 0, by: -1) {
            let time = now.addingTimeInterval(-Double(step) * spacing)
            let hour = Double(288 - step) / 12
            if (6.5...9).contains(hour) { continue }   // Asleep
            let charging = (13.0...14.5).contains(hour)
            percent = charging ? min(percent + 3.2, 100) : max(percent - 0.55, 8)
            history.points.append(Point(time: time, percent: Int(percent), charging: charging))
        }
        return history
    }

    /// Beside the tasks; the first time, the standalone Status app's record comes along.
    nonisolated private static var defaultURL: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let url = base.appending(path: "Perch/battery-history.json")
        let legacy = base.appending(path: "Status/battery-history.json")
        if !FileManager.default.fileExists(atPath: url.path), FileManager.default.fileExists(atPath: legacy.path) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.copyItem(at: legacy, to: url)
        }
        return url
    }

    func record(percent: Int, charging: Bool, at now: Date = Date()) {
        if let last = points.last, now.timeIntervalSince(last.time) < Self.spacing,
           last.charging == charging, abs(last.percent - percent) < 3 {
            return
        }
        points.append(Point(time: now, percent: percent, charging: charging))
        points.removeAll { now.timeIntervalSince($0.time) > Self.window }
        save()
    }

    private func save() {
        guard let url else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(points) { try? data.write(to: url, options: .atomic) }
    }
}
