import AppKit
import ImageIO
import Observation
import SwiftUI

nonisolated struct MediaTrack: Equatable, Sendable {
    var title: String
    var artist: String
    var album: String
    var duration: Double

    /// Duration often arrives a beat later than the rest; that is still the same track.
    var identity: String { "\(title)\n\(artist)\n\(album)" }
}

/// What is playing anywhere on the Mac (Music, Spotify, a browser tab…), with transport controls.
///
/// MediaRemote no longer answers ordinary apps, so Perch runs its PerchMediaHelper library inside
/// /usr/bin/perl, an Apple-signed binary that MediaRemote still answers, and reads the JSON lines it
/// prints. The helper exits on its own when Perch quits, because its stdin closes.
@Observable
final class NowPlayingService {
    enum Command: String {
        case play, pause, toggle, next, previous
    }

    private(set) var track: MediaTrack?
    private(set) var isPlaying = false
    private(set) var artwork: NSImage?
    /// A vivid color from the artwork, lifted so it reads on black.
    private(set) var accent: Color?
    private(set) var sourceBundleID: String?
    private(set) var elapsed: Double = 0
    private(set) var elapsedAt = Date.now
    private(set) var rate: Double = 1

    /// A new track started; not raised for whatever was already playing when Perch launched.
    @ObservationIgnored var onTrackChange: (() -> Void)?
    @ObservationIgnored var onChange: (() -> Void)?

    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var input: FileHandle?
    @ObservationIgnored private var readTask: Task<Void, Never>?
    @ObservationIgnored private var restartTask: Task<Void, Never>?
    @ObservationIgnored private var restartDelay: Double = 1
    @ObservationIgnored private var launchedAt = Date.distantPast
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var hasReported = false
    @ObservationIgnored private var icons: [String: NSImage] = [:]

    var duration: Double { track?.duration ?? 0 }

    func position(at date: Date) -> Double {
        guard let track else { return 0 }
        let moved = isPlaying ? date.timeIntervalSince(elapsedAt) * (rate > 0 ? rate : 1) : 0
        let position = max(elapsed + moved, 0)
        return track.duration > 0 ? min(position, track.duration) : position
    }

    var sourceAppURL: URL? {
        sourceBundleID.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
    }

    var sourceName: String? {
        guard let url = sourceAppURL else { return nil }
        let name = FileManager.default.displayName(atPath: url.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    var sourceIcon: NSImage? {
        guard let bundleID = sourceBundleID else { return nil }
        if let icon = icons[bundleID] { return icon }
        guard let url = sourceAppURL else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icons[bundleID] = icon
        return icon
    }

    // MARK: - Control

    func send(_ command: Command) {
        write(command.rawValue)
        // Answer the click at once; the helper's next report confirms or corrects it.
        switch command {
        case .toggle: setPlaying(!isPlaying)
        case .play: setPlaying(true)
        case .pause: setPlaying(false)
        case .next, .previous: break
        }
    }

    func seek(to seconds: Double) {
        write("seek \(seconds)")
        elapsed = seconds
        elapsedAt = .now
    }

    func openSourceApp() {
        guard let url = sourceAppURL else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    private func setPlaying(_ playing: Bool) {
        guard track != nil, playing != isPlaying else { return }
        elapsed = position(at: .now)
        elapsedAt = .now
        isPlaying = playing
        onChange?()
    }

    private func write(_ line: String) {
        try? input?.write(contentsOf: Data((line + "\n").utf8))
    }

    // MARK: - Helper process

    func start() {
        guard process == nil, restartTask == nil else { return }
        launch()
    }

    func stop() {
        restartTask?.cancel()
        restartTask = nil
        generation += 1
        readTask?.cancel()
        readTask = nil
        process?.terminate()
        process = nil
        input = nil
        clear()
    }

    private func launch() {
        guard let helper = Self.helperURL else { return }
        // Writing to a helper that just died must fail quietly instead of killing Perch.
        signal(SIGPIPE, SIG_IGN)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = ["-e", Self.loader, helper.path]
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        generation += 1
        let token = generation
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.helperExited(token) }
        }
        do {
            try process.run()
        } catch {
            scheduleRestart()
            return
        }
        self.process = process
        input = stdin.fileHandleForWriting
        launchedAt = .now
        hasReported = false
        let output = stdout.fileHandleForReading
        readTask = Task.detached(priority: .utility) { [weak self] in
            do {
                for try await line in output.bytes.lines {
                    guard let report = NowPlayingReport(line: line) else { continue }
                    await self?.apply(report, token: token)
                }
            } catch {}
        }
    }

    private func helperExited(_ token: Int) {
        guard token == generation else { return }
        process = nil
        input = nil
        readTask?.cancel()
        readTask = nil
        clear()
        scheduleRestart()
    }

    private func scheduleRestart() {
        if Date.now.timeIntervalSince(launchedAt) > 30 { restartDelay = 1 }
        let delay = restartDelay
        restartDelay = min(restartDelay * 2, 60)
        restartTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.restartTask = nil
            self.launch()
        }
    }

    private func apply(_ report: NowPlayingReport, token: Int) {
        guard token == generation else { return }
        let previous = track
        track = report.track
        isPlaying = report.track != nil && report.isPlaying
        elapsed = report.elapsed
        elapsedAt = report.timestamp
        rate = report.rate
        sourceBundleID = report.bundleID
        switch report.artwork {
        case .unchanged: break
        case .removed:
            artwork = nil
            accent = nil
        case .replaced(let data, let tint):
            artwork = NSImage(data: data)
            accent = tint.map { Color(.sRGB, red: $0.red, green: $0.green, blue: $0.blue) }
        }
        if report.track == nil {
            artwork = nil
            accent = nil
        }
        if hasReported, let track = report.track, track.identity != previous?.identity {
            onTrackChange?()
        }
        hasReported = true
        onChange?()
    }

    private func clear() {
        track = nil
        isPlaying = false
        artwork = nil
        accent = nil
        sourceBundleID = nil
        onChange?()
    }

    private static let loader = """
        use DynaLoader;
        my $h = DynaLoader::dl_load_file($ARGV[0], 0) or die DynaLoader::dl_error();
        my $s = DynaLoader::dl_find_symbol($h, 'perch_media_stream') or die DynaLoader::dl_error();
        DynaLoader::dl_install_xsub('main::perch_media_stream', $s);
        perch_media_stream();
        """

    /// Inside the app bundle, or next to the executable for `swift run`.
    private static var helperURL: URL? {
        let name = "libPerchMediaHelper.dylib"
        return [
            Bundle.main.privateFrameworksURL?.appendingPathComponent(name),
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent(name),
        ]
        .compactMap { $0 }
        .first { FileManager.default.fileExists(atPath: $0.path) }
    }
}

// MARK: - Reports

nonisolated struct RGB: Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
}

/// One line from the helper. Decoded off the main thread, since artwork can be a megabyte of base64.
nonisolated struct NowPlayingReport: Sendable {
    enum Artwork: Sendable {
        case unchanged
        case removed
        case replaced(Data, accent: RGB?)
    }

    var track: MediaTrack?
    var isPlaying: Bool
    var elapsed: Double
    var rate: Double
    var timestamp: Date
    var bundleID: String?
    var artwork: Artwork

    private struct Payload: Decodable {
        var playing: Bool
        var empty: Bool?
        var title: String?
        var artist: String?
        var album: String?
        var duration: Double?
        var elapsed: Double?
        var rate: Double?
        var timestamp: Double?
        var bundle: String?
        var artwork: String?
    }

    init?(line: String) {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: Data(line.utf8)) else { return nil }
        if payload.empty == true {
            track = nil
        } else {
            track = MediaTrack(
                title: payload.title ?? "",
                artist: payload.artist ?? "",
                album: payload.album ?? "",
                duration: payload.duration ?? 0
            )
        }
        isPlaying = payload.playing
        elapsed = payload.elapsed ?? 0
        rate = payload.rate ?? 1
        timestamp = payload.timestamp.map(Date.init(timeIntervalSince1970:)) ?? .now
        bundleID = payload.bundle.flatMap { $0.isEmpty ? nil : $0 }
        switch payload.artwork {
        case nil:
            artwork = .unchanged
        case let encoded? where encoded.isEmpty:
            artwork = .removed
        case let encoded?:
            if let data = Data(base64Encoded: encoded) {
                artwork = .replaced(data, accent: ArtworkPalette.accent(of: data))
            } else {
                artwork = .unchanged
            }
        }
    }
}

nonisolated enum ArtworkPalette {
    /// The artwork's most vivid color: saturated, bright pixels decide it and greys barely count.
    static func accent(of data: Data) -> RGB? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 40,
              ] as CFDictionary),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let side = 20
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                bytesPerRow: side * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }

        var sum = RGB(red: 0, green: 0, blue: 0)
        var total = 0.0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let pixel = RGB(red: Double(pixels[index]) / 255, green: Double(pixels[index + 1]) / 255, blue: Double(pixels[index + 2]) / 255)
            let hsb = pixel.hsb
            let weight = hsb.saturation * hsb.saturation * hsb.brightness + 0.002
            sum.red += pixel.red * weight
            sum.green += pixel.green * weight
            sum.blue += pixel.blue * weight
            total += weight
        }
        let average = RGB(red: sum.red / total, green: sum.green / total, blue: sum.blue / total).hsb
        return RGB(hue: average.hue, saturation: min(average.saturation * 1.15, 0.85), brightness: max(average.brightness, 0.86))
    }
}

nonisolated extension RGB {
    var hsb: (hue: Double, saturation: Double, brightness: Double) {
        let high = max(red, green, blue)
        let delta = high - min(red, green, blue)
        var hue = 0.0
        if delta > 0 {
            if high == red {
                hue = (green - blue) / delta
            } else if high == green {
                hue = (blue - red) / delta + 2
            } else {
                hue = (red - green) / delta + 4
            }
            hue /= 6
            if hue < 0 { hue += 1 }
        }
        return (hue, high > 0 ? delta / high : 0, high)
    }

    init(hue: Double, saturation: Double, brightness: Double) {
        let sector = (hue * 6).truncatingRemainder(dividingBy: 6)
        let fraction = sector - sector.rounded(.down)
        let p = brightness * (1 - saturation)
        let q = brightness * (1 - saturation * fraction)
        let t = brightness * (1 - saturation * (1 - fraction))
        switch Int(sector) {
        case 0: self.init(red: brightness, green: t, blue: p)
        case 1: self.init(red: q, green: brightness, blue: p)
        case 2: self.init(red: p, green: brightness, blue: t)
        case 3: self.init(red: p, green: q, blue: brightness)
        case 4: self.init(red: t, green: p, blue: brightness)
        default: self.init(red: brightness, green: p, blue: q)
        }
    }
}
