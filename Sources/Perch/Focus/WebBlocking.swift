import AppKit
import Carbon
import Observation

// MARK: - Sites

/// A site to pause. `pattern` is a normalized "domain[/path]" such as bilibili.com or
/// youtube.com/shorts. A domain takes its subdomains with it: bilibili.com also pauses www., m. and
/// live.bilibili.com.
nonisolated struct BlockedSite: Codable, Hashable, Identifiable, Sendable {
    var pattern: String
    /// The name it was picked under from the common sites; typed-in sites have none.
    var name: String?

    var id: String { pattern }
    /// Common sites go by their name in the current language.
    @MainActor var displayName: String { Self.knownName(for: pattern) ?? name ?? pattern }
    /// Key for passes and blocked counts; never collides with an app's bundle id.
    var passKey: String { Self.passPrefix + pattern }

    static let passPrefix = "web:"

    private var parts: (host: String, path: String?) {
        let pieces = pattern.split(separator: "/", maxSplits: 1).map(String.init)
        return (pieces.first ?? pattern, pieces.count > 1 ? pieces[1] : nil)
    }

    var host: String { parts.host }

    func matches(_ url: URL) -> Bool {
        guard var host = url.host?.lowercased() else { return false }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        let (patternHost, path) = parts
        guard host == patternHost || host.hasSuffix("." + patternHost) else { return false }
        guard let path else { return true }
        return url.path.lowercased().hasPrefix("/" + path)
    }

    /// Turns what was typed into a pattern: no scheme, www., query or trailing slash. Nil when it
    /// doesn't look like an address.
    static func normalize(_ input: String) -> String? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for scheme in ["https://", "http://"] where text.hasPrefix(scheme) { text.removeFirst(scheme.count) }
        if let cut = text.firstIndex(where: { $0 == "?" || $0 == "#" }) { text = String(text[..<cut]) }
        if text.hasPrefix("www.") { text.removeFirst(4) }
        while text.hasSuffix("/") { text.removeLast() }
        let host = text.split(separator: "/").first.map(String.init) ?? ""
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-.")
        guard host.contains("."), !host.hasPrefix("."), !host.hasSuffix("."),
              host.unicodeScalars.allSatisfy(allowed.contains), !text.contains(" ")
        else { return nil }
        return text
    }

    private static let knownNames: [String: (String, String)] = [
        "bilibili.com": ("哔哩哔哩", "Bilibili"),
        "douyin.com": ("抖音", "Douyin"),
        "weibo.com": ("微博", "Weibo"),
        "zhihu.com": ("知乎", "Zhihu"),
        "xiaohongshu.com": ("小红书", "Xiaohongshu"),
        "youtube.com": ("YouTube", "YouTube"),
        "x.com": ("X", "X"),
        "reddit.com": ("Reddit", "Reddit"),
        "taobao.com": ("淘宝", "Taobao"),
    ]

    @MainActor static func knownName(for pattern: String) -> String? {
        knownNames[pattern].map { tr($0.0, $0.1) }
    }

    /// Common distractions, one click to add.
    @MainActor static var suggestions: [BlockedSite] {
        ["bilibili.com", "douyin.com", "weibo.com", "zhihu.com", "xiaohongshu.com", "youtube.com", "x.com", "reddit.com", "taobao.com"]
            .map { BlockedSite(pattern: $0, name: knownName(for: $0)) }
    }
}

// MARK: - Browsers

/// Browsers whose current tab can be read (all speak AppleScript). Firefox can't be read.
nonisolated enum Browser: CaseIterable, Sendable {
    case safari, chrome, arc, edge, brave, vivaldi

    var bundleID: String {
        switch self {
        case .safari: "com.apple.Safari"
        case .chrome: "com.google.Chrome"
        case .arc: "company.thebrowser.Browser"
        case .edge: "com.microsoft.edgemac"
        case .brave: "com.brave.Browser"
        case .vivaldi: "com.vivaldi.Vivaldi"
        }
    }

    var name: String {
        switch self {
        case .safari: "Safari"
        case .chrome: "Chrome"
        case .arc: "Arc"
        case .edge: "Edge"
        case .brave: "Brave"
        case .vivaldi: "Vivaldi"
        }
    }

    static func from(bundleID: String?) -> Browser? {
        allCases.first { $0.bundleID == bundleID }
    }

    var isInstalled: Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil }
    var isRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty }

    /// Safari calls it the current tab; Chrome and its family (Arc too) the active tab.
    private var currentTab: String { self == .safari ? "current tab" : "active tab" }

    // MARK: Reading addresses, closing tabs
    // Each runs under a timeout of a second or two, so a hung browser can't hang Perch, and only
    // once access is known to be granted: asking from here would block the main thread on the prompt.

    /// The address in the front window's current tab.
    func frontURL() -> URL? {
        let source = """
        with timeout of 1 second
            tell application id "\(bundleID)"
                if (count of windows) is 0 then return ""
                return URL of \(currentTab) of front window
            end tell
        end timeout
        """
        guard let text = run(source)?.stringValue, !text.isEmpty else { return nil }
        return URL(string: text)
    }

    func closeFrontTab() {
        _ = run("""
        with timeout of 2 seconds
            tell application id "\(bundleID)"
                if (count of windows) > 0 then close \(currentTab) of front window
            end tell
        end timeout
        """)
    }

    /// Closes every tab whose address matches (strict schedules). `keepFront` spares the front
    /// window's current tab.
    func closeTabs(where shouldClose: (URL) -> Bool, keepFront: Bool) {
        guard let windows = run("""
        with timeout of 2 seconds
            tell application id "\(bundleID)" to return URL of every tab of every window
        end timeout
        """) else { return }
        let front = keepFront ? frontURL() : nil
        var targets: [(window: Int, tab: Int)] = []
        for w in stride(from: windows.numberOfItems, through: 1, by: -1) {
            guard let tabs = windows.atIndex(w) else { continue }
            for t in stride(from: tabs.numberOfItems, through: 1, by: -1) {
                guard let text = tabs.atIndex(t)?.stringValue, let url = URL(string: text), shouldClose(url) else { continue }
                if w == 1, url == front { continue }
                targets.append((w, t))
            }
        }
        guard !targets.isEmpty else { return }
        // Back to front, so the earlier indexes stay put.
        let lines = targets.map { "close tab \($0.tab) of window \($0.window)" }.joined(separator: "\n")
        _ = run("""
        with timeout of 3 seconds
            tell application id "\(bundleID)"
                \(lines)
            end tell
        end timeout
        """)
    }

    private func run(_ source: String) -> NSAppleEventDescriptor? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        return error == nil ? result : nil
    }

    // MARK: Permission

    enum Permission: Sendable {
        case granted, notDetermined, denied, notRunning
    }

    /// `ask` shows the system prompt and waits for an answer, so never ask on the main thread.
    func permission(ask: Bool) -> Permission {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        guard let desc = target.aeDesc else { return .denied }
        let status = AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, ask)
        switch Int(status) {
        case Int(noErr): return .granted
        case errAEEventWouldRequireUserConsent: return .notDetermined
        case procNotFound: return .notRunning
        default: return .denied
        }
    }

    static func openAutomationSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
    }
}

/// Which browsers allow Perch to read their tabs, cached for a few seconds for the views and the poll.
@Observable
final class BrowserAccess {
    static let shared = BrowserAccess()

    private(set) var states: [Browser: Browser.Permission] = [:]
    private var checkedAt: [Browser: Date] = [:]

    func isGranted(_ browser: Browser) -> Bool {
        if let at = checkedAt[browser], Date.now.timeIntervalSince(at) < 10, let state = states[browser] {
            return state == .granted
        }
        return refresh(browser) == .granted
    }

    @discardableResult
    func refresh(_ browser: Browser) -> Browser.Permission {
        let state = browser.permission(ask: false)
        if states[browser] != state { states[browser] = state }
        checkedAt[browser] = .now
        return state
    }

    func refreshAll() {
        Browser.allCases.filter(\.isInstalled).forEach { refresh($0) }
    }

    /// Shows the system prompt, waiting for the answer off the main thread.
    func request(_ browser: Browser) {
        Task {
            let state = await Task.detached(priority: .userInitiated) { browser.permission(ask: true) }.value
            states[browser] = state
            checkedAt[browser] = .now
        }
    }
}

// MARK: - Site icons

/// A site's icon: a lettered tile at first, then the site's own apple-touch-icon or favicon, fetched
/// from the site itself (no third party) and cached.
@Observable
final class SiteIcons {
    static let shared = SiteIcons()

    private var icons: [String: NSImage] = [:]
    private var loading: Set<String> = []

    nonisolated private static let cacheDirectory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appending(path: "app.perch.Perch/SiteIcons")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    func icon(for site: BlockedSite) -> NSImage {
        if let icon = icons[site.host] { return icon }
        if let cached = NSImage(contentsOf: Self.cacheDirectory.appending(path: "\(site.host).png")) {
            icons[site.host] = cached
            return cached
        }
        load(site.host)
        return Self.monogram(for: site)
    }

    private func load(_ host: String) {
        guard !loading.contains(host) else { return }
        loading.insert(host)
        Task {
            guard let png = await Self.fetchIcon(host), let image = NSImage(data: png) else { return }
            icons[host] = image
        }
    }

    @concurrent
    nonisolated private static func fetchIcon(_ host: String) async -> Data? {
        let candidates = ["https://\(host)/apple-touch-icon.png", "https://www.\(host)/apple-touch-icon.png",
                          "https://\(host)/favicon.ico", "https://www.\(host)/favicon.ico"].compactMap(URL.init(string:))
        for url in candidates {
            var request = URLRequest(url: url)
            request.timeoutInterval = 6
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let image = NSImage(data: data), image.size.width >= 16,
                  let png = image.tiffRepresentation.flatMap({ NSBitmapImageRep(data: $0) })?
                    .representation(using: .png, properties: [:])
            else { continue }
            try? png.write(to: cacheDirectory.appending(path: "\(host).png"))
            return png
        }
        return nil
    }

    /// Without an icon: the first letter on a warm gradient tile.
    static func monogram(for site: BlockedSite) -> NSImage {
        let letter = String(site.displayName.first ?? "·").uppercased()
        let tint = RuleTint.all[abs(site.host.hashValue) % RuleTint.all.count]
        let start = NSColor(tint.0), end = NSColor(tint.1)
        return NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 2), xRadius: 14, yRadius: 14)
            NSGradient(starting: start, ending: end)?.draw(in: path, angle: -60)
            let font = NSFont.systemFont(ofSize: 30, weight: .bold)
            let text = NSAttributedString(string: letter, attributes: [.font: font, .foregroundColor: NSColor.white])
            let size = text.size()
            text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
            return true
        }
    }
}
