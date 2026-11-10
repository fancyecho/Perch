import AppKit
import CryptoKit
import Observation

nonisolated struct AppRelease: Equatable, Sendable {
    let version: String
    let notes: String
    let pageURL: URL
    let archiveURL: URL
    let signatureURL: URL
    /// The same two files through GitHub's API, used when the download links fail.
    var archiveAPIURL: URL?
    var signatureAPIURL: URL?
}

/// Self-updates from GitHub Releases.
///
/// A release carries `Perch-<version>.zip` and `Perch-<version>.zip.sig`, an Ed25519 signature
/// made with a key that never leaves the maintainer's machine. The archive is only installed when
/// that signature matches the public key embedded in this app, and the unpacked bundle has the
/// expected identifier, version and an intact code signature.
@Observable
final class Updater {
    enum State: Equatable {
        case idle, checking, upToDate, available(AppRelease), installing, failed(String)
    }

    static let shared = Updater()

    private(set) var state: State = .idle
    private(set) var lastChecked: Date?

    var checksAutomatically: Bool {
        didSet { UserDefaults.standard.set(checksAutomatically, forKey: Keys.autoCheck) }
    }

    let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

    var availableRelease: AppRelease? {
        if case .available(let release) = state { return release }
        return nil
    }

    @ObservationIgnored var onUpdateFound: ((AppRelease) -> Void)?
    /// Quitting to install an update; a strict Focus schedule lets this one quit through.
    @ObservationIgnored private(set) var isRelaunching = false
    @ObservationIgnored private var scheduleTask: Task<Void, Never>?

    private enum Keys {
        static let autoCheck = "checksForUpdatesAutomatically"
        /// Points the updater at another feed (same JSON shape as GitHub's) for testing.
        static let feedOverride = "updateFeedURL"
    }

    private init() {
        checksAutomatically = UserDefaults.standard.object(forKey: Keys.autoCheck) as? Bool ?? true
    }

    /// Checks shortly after launch, then once a day.
    func start() {
        scheduleTask?.cancel()
        scheduleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            while !Task.isCancelled {
                if let self, self.checksAutomatically { await self.check(userInitiated: false) }
                try? await Task.sleep(for: .seconds(24 * 3600))
            }
        }
    }

    func check(userInitiated: Bool) async {
        guard state != .checking, state != .installing else { return }
        state = .checking
        do {
            let release = try await fetchLatestRelease()
            lastChecked = .now
            if Self.isVersion(release.version, newerThan: currentVersion) {
                state = .available(release)
                if !userInitiated { onUpdateFound?(release) }
            } else {
                state = .upToDate
            }
        } catch {
            state = userInitiated ? .failed(Self.message(for: error)) : .idle
        }
    }

    func install(_ release: AppRelease) async {
        guard state != .installing else { return }
        state = .installing
        let work = FileManager.default.temporaryDirectory.appending(path: "PerchUpdate-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

            let archive = work.appending(path: "update.zip")
            try FileManager.default.moveItem(at: try await Self.download(release.archiveURL, fallback: release.archiveAPIURL), to: archive)
            let signature = try await Self.fetch(release.signatureURL, fallback: release.signatureAPIURL)
            try Self.verify(archive: archive, signature: signature)

            let unpacked = work.appending(path: "unpacked")
            try await Self.run("/usr/bin/ditto", "-x", "-k", archive.path, unpacked.path)
            let newApp = try Self.validatedBundle(in: unpacked, expectedVersion: release.version)
            try await Self.run("/usr/bin/codesign", "--verify", "--deep", "--strict", newApp.path)

            let destination = Bundle.main.bundleURL
            guard FileManager.default.isWritableFile(atPath: destination.deletingLastPathComponent().path) else {
                throw UpdateError.notWritable(destination.deletingLastPathComponent().path)
            }
            try Self.launchInstaller(newApp: newApp, destination: destination, work: work)
            isRelaunching = true
            NSApp.terminate(nil)
        } catch {
            try? FileManager.default.removeItem(at: work)
            state = .failed(Self.message(for: error))
        }
    }

    private static func message(for error: Error) -> String {
        (error as? UpdateError)?.message ?? error.localizedDescription
    }

    // MARK: - Feed

    private var feedURL: URL {
        if let override = UserDefaults.standard.string(forKey: Keys.feedOverride), let url = URL(string: override) {
            return url
        }
        let repository = Bundle.main.object(forInfoDictionaryKey: "PerchUpdateRepository") as? String ?? "fancyecho/Perch"
        return URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    }

    private func fetchLatestRelease() async throws -> AppRelease {
        var request = URLRequest(url: feedURL, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Perch/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw http.statusCode == 404 ? UpdateError.noRelease : UpdateError.server(http.statusCode)
        }
        let payload = try JSONDecoder().decode(GitHubRelease.self, from: data)
        let version = payload.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        guard let archive = payload.assets.first(where: { $0.name.hasSuffix(".zip") }),
              let signature = payload.assets.first(where: { $0.name == archive.name + ".sig" }) else {
            throw UpdateError.missingAssets
        }
        return AppRelease(
            version: version,
            notes: payload.body ?? "",
            pageURL: payload.htmlURL,
            archiveURL: archive.downloadURL,
            signatureURL: signature.downloadURL,
            archiveAPIURL: archive.apiURL,
            signatureAPIURL: signature.apiURL
        )
    }

    private struct GitHubRelease: Decodable {
        struct Asset: Decodable {
            let name: String
            let downloadURL: URL
            let apiURL: URL?

            enum CodingKeys: String, CodingKey {
                case name
                case downloadURL = "browser_download_url"
                case apiURL = "url"
            }
        }

        let tagName: String
        let body: String?
        let htmlURL: URL
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case body
            case htmlURL = "html_url"
            case assets
        }
    }

    // MARK: - Verification & install

    nonisolated static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: - Downloads

    /// GitHub's download servers sometimes answer with an error page (a 504, say) instead of the
    /// file; that page must never be taken for the update. Server hiccups get two more tries.
    /// When the download link keeps failing, the same file comes through GitHub's API, which is
    /// served from elsewhere and has stayed up through outages of the download servers.
    nonisolated static func download(_ url: URL, fallback: URL? = nil) async throws -> URL {
        try await withFallback(fallback) {
            try await retrying {
                let (file, response) = try await URLSession.shared.download(for: request(url))
                try requireSuccess(response)
                return file
            }
        } viaAPI: { api in
            let (file, response) = try await URLSession.shared.download(for: request(api, asAsset: true))
            try requireSuccess(response)
            return file
        }
    }

    nonisolated static func fetch(_ url: URL, fallback: URL? = nil) async throws -> Data {
        try await withFallback(fallback) {
            try await retrying {
                let (data, response) = try await URLSession.shared.data(for: request(url))
                try requireSuccess(response)
                return data
            }
        } viaAPI: { api in
            let (data, response) = try await URLSession.shared.data(for: request(api, asAsset: true))
            try requireSuccess(response)
            return data
        }
    }

    private nonisolated static func request(_ url: URL, asAsset: Bool = false) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 60)
        // Never a stale copy: a cached error page would fail every retry.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if asAsset { request.setValue("application/octet-stream", forHTTPHeaderField: "Accept") }
        return request
    }

    private nonisolated static func withFallback<T: Sendable>(
        _ api: URL?,
        _ primary: @Sendable () async throws -> T,
        viaAPI: @Sendable (URL) async throws -> T
    ) async throws -> T {
        do {
            return try await primary()
        } catch {
            guard let api else { throw error }
            return try await viaAPI(api)
        }
    }

    /// Anything but a 2xx from a web server is an error. Local files (a test feed) have no status.
    nonisolated static func requireSuccess(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else { throw UpdateError.download(http.statusCode) }
    }

    private nonisolated static func retrying<T: Sendable>(_ attempt: @Sendable () async throws -> T) async throws -> T {
        var delay = Duration.seconds(2)
        for _ in 0..<2 {
            do {
                return try await attempt()
            } catch UpdateError.download(let code) where code >= 500 || code == 429 {
                try await Task.sleep(for: delay)
                delay *= 2
            }
        }
        return try await attempt()
    }

    nonisolated static func verify(archive: URL, signature: Data) throws {
        guard let keyText = Bundle.main.object(forInfoDictionaryKey: "PerchUpdatePublicKey") as? String,
              let keyData = Data(base64Encoded: keyText),
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else {
            throw UpdateError.noPublicKey
        }
        let text = String(decoding: signature, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let signatureBytes = Data(base64Encoded: text),
              publicKey.isValidSignature(signatureBytes, for: try Data(contentsOf: archive)) else {
            throw UpdateError.badSignature
        }
    }

    private static func validatedBundle(in folder: URL, expectedVersion: String) throws -> URL {
        let contents = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        guard let app = contents.first(where: { $0.pathExtension == "app" }),
              let bundle = Bundle(url: app),
              bundle.bundleIdentifier == Bundle.main.bundleIdentifier,
              bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == expectedVersion else {
            throw UpdateError.unexpectedBundle
        }
        return app
    }

    /// Waits for this process to quit, swaps the bundles (restoring the old one if the copy
    /// fails), then relaunches. It runs on after Perch exits.
    private static func launchInstaller(newApp: URL, destination: URL, work: URL) throws {
        let script = """
        #!/bin/sh
        PID="$1"; NEW="$2"; DEST="$3"; WORK="$4"
        while kill -0 "$PID" 2>/dev/null; do sleep 0.2; done
        BACKUP="$WORK/previous.app"
        if mv "$DEST" "$BACKUP"; then
          if ditto "$NEW" "$DEST"; then rm -rf "$BACKUP"; else rm -rf "$DEST"; mv "$BACKUP" "$DEST"; fi
        fi
        xattr -dr com.apple.quarantine "$DEST" 2>/dev/null
        open "$DEST"
        rm -rf "$WORK"
        """
        let scriptURL = work.appending(path: "install.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [scriptURL.path, String(ProcessInfo.processInfo.processIdentifier), newApp.path, destination.path, work.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    nonisolated private static func run(_ tool: String, _ arguments: String...) async throws {
        let status = try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }.value
        guard status == 0 else { throw UpdateError.toolFailed((tool as NSString).lastPathComponent) }
    }
}

enum UpdateError: Error {
    case noRelease, server(Int), download(Int), missingAssets, noPublicKey, badSignature, unexpectedBundle, notWritable(String), toolFailed(String)
}

extension UpdateError {
    @MainActor var message: String {
        switch self {
        case .noRelease: tr("还没有发布的版本", "No release has been published yet")
        case .server(let code): tr("服务器返回 \(code)", "Server responded with \(code)")
        case .download(let code) where code >= 500:
            tr("GitHub 暂时没有响应（\(code)），稍后再试", "GitHub isn't responding right now (\(code)). Try again in a bit")
        case .download(let code): tr("下载更新失败（\(code)）", "Couldn't download the update (\(code))")
        case .missingAssets: tr("发布中缺少安装包或签名", "The release is missing its archive or signature")
        case .noPublicKey: tr("应用中缺少更新公钥", "This build has no update public key")
        case .badSignature: tr("安装包签名校验失败，已拒绝安装", "The update's signature didn't verify, so it wasn't installed")
        case .unexpectedBundle: tr("安装包内容与预期不符", "The update archive didn't contain the expected app")
        case .notWritable(let path): tr("没有写入 \(path) 的权限", "No permission to write to \(path)")
        case .toolFailed(let tool): tr("\(tool) 执行失败", "\(tool) failed")
        }
    }
}
