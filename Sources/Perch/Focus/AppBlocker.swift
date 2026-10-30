import AppKit
import SwiftUI

/// What was blocked: an app, or a site in a browser.
enum BlockTarget {
    case app(NSRunningApplication)
    case site(BlockedSite, browser: NSRunningApplication)

    /// Key for passes and blocked counts.
    var passKey: String {
        switch self {
        case .app(let app): app.bundleIdentifier ?? ""
        case .site(let site, _): site.passKey
        }
    }

    /// Whether two are the same: one app process, or one site in one browser.
    var identity: String {
        switch self {
        case .app(let app): "app:\(app.processIdentifier)"
        case .site(let site, let browser): "site:\(site.pattern):\(browser.processIdentifier)"
        }
    }

    var name: String {
        switch self {
        case .app(let app): app.localizedName ?? tr("这个 App", "this app")
        case .site(let site, _): site.displayName
        }
    }

    var icon: NSImage {
        switch self {
        case .app(let app): app.icon ?? AppIcons.icon(for: app.bundleIdentifier ?? "")
        case .site(let site, _): SiteIcons.shared.icon(for: site)
        }
    }

    var isSite: Bool {
        if case .site = self { return true }
        return false
    }
}

/// A running pass, as the island and the countdown pill show it.
struct ActivePass: Identifiable, Equatable {
    let key: String
    let end: Date

    var id: String { key }

    var site: BlockedSite? {
        guard key.hasPrefix(BlockedSite.passPrefix) else { return nil }
        return BlockedSite(pattern: String(key.dropFirst(BlockedSite.passPrefix.count)), name: nil)
    }

    var name: String {
        if let site { return site.displayName }
        return NSRunningApplication.runningApplications(withBundleIdentifier: key).first?.localizedName
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: key)
                .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
            ?? "App"
    }

    var icon: NSImage {
        site.map { SiteIcons.shared.icon(for: $0) } ?? AppIcons.icon(for: key)
    }

    static let duration = TimeInterval(ScheduleStore.passMinutes * 60)
}

/// Watches every app and browser: apps a schedule pauses are put away (quit, in a strict one), and
/// when one comes to the front, or a browser sits on a paused site, the shield goes over it.
final class AppBlocker: NSObject {
    private let store = ScheduleStore.shared
    private let access = BrowserAccess.shared
    private let shield = ShieldController()
    private var passTimers: [String: [Timer]] = [:]
    private var timer: Timer?
    private var webTimer: Timer?
    /// The last app in use that isn't paused, to go back to.
    private var lastAllowedApp: NSRunningApplication?
    /// Apps asked to quit and when: force them if they take too long.
    private var quitting: [pid_t: Date] = [:]
    private static let forceQuitAfter: TimeInterval = 15
    /// How often a browser in front is read.
    private static let webInterval: TimeInterval = 0.8

    /// No shield while the focus blur already covers everything.
    var isSuspended: () -> Bool = { false }
    /// Passes started or ended.
    var onPassesChange: () -> Void = {}

    var activePasses: [ActivePass] {
        store.passes.filter { $0.value > .now }.map { ActivePass(key: $0.key, end: $0.value) }.sorted { $0.end < $1.end }
    }

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(appActivated(_:)), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(evaluate), name: NSWorkspace.didWakeNotification, object: nil)
        center.addObserver(self, selector: #selector(evaluate), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        // The clock or time zone changed: work it out again right away.
        NotificationCenter.default.addObserver(self, selector: #selector(evaluate), name: .NSSystemClockDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(evaluate), name: .NSSystemTimeZoneDidChange, object: nil)
        timer = Timer.scheduledTimer(timeInterval: 5, target: self, selector: #selector(evaluate), userInfo: nil, repeats: true)
        webTimer = Timer.scheduledTimer(timeInterval: Self.webInterval, target: self, selector: #selector(checkBrowser), userInfo: nil, repeats: true)

        shield.onBack = { [weak self] in self?.backToWork() }
        shield.onPass = { [weak self] target, rule in self?.grantPass(to: target, rule: rule) }
        evaluate()
    }

    /// The blur is coming: put the shield and what it covers away first.
    func yieldToOverlay() {
        guard let target = shield.target else { return }
        putAway(target)
        shield.dismiss(playSound: false)
    }

    @objc private func appActivated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        check(app)
    }

    @objc func evaluate() {
        store.pinStrictSessions()
        let passCount = store.passes.count
        store.dropExpiredPasses()
        if store.passes.count != passCount { onPassesChange() }
        // The schedule ended or a pass came through: lift the shield, leave the app or page up front.
        if let shown = shield.target, !isStillBlocked(shown) {
            shield.dismiss(playSound: false)
        }
        sweepBackgroundApps()
        sweepStrictTabs()
        if let front = NSWorkspace.shared.frontmostApplication { check(front) }
    }

    private func isStillBlocked(_ target: BlockTarget) -> Bool {
        switch target {
        case .app(let app): store.blockingOccurrence(for: app.bundleIdentifier ?? "") != nil
        case .site(let site, _): store.isBlocking(site: site)
        }
    }

    // MARK: Apps

    private func check(_ app: NSRunningApplication) {
        guard let bundleID = app.bundleIdentifier, bundleID != Bundle.main.bundleIdentifier else { return }
        guard let occurrence = store.blockingOccurrence(for: bundleID) else {
            lastAllowedApp = app
            if let shown = shield.target, shield.isShowing {
                // Back to the same browser while it shows a blocked site: look at the address again.
                if case .site(_, let browser) = shown, browser.processIdentifier == app.processIdentifier {
                    checkBrowser()
                    return
                }
                // ⌘Tab to another app: what was blocked goes away too, not left behind to peek at.
                putAway(shown)
                shield.dismiss(playSound: false)
            }
            return
        }
        if isSuspended() {
            putAway(.app(app))
            return
        }
        present(.app(app), occurrence: occurrence)
    }

    private func present(_ target: BlockTarget, occurrence: Occurrence) {
        // The same thing coming to the front again isn't another attempt.
        let isNewAttempt = !(shield.isShowing && shield.target?.identity == target.identity)
        let attempt = isNewAttempt ? store.recordAttempt(for: target.passKey) : nil
        shield.show(target, occurrence: occurrence, passesLeft: store.passesLeft(for: occurrence.rule), attempt: attempt)
    }

    /// Paused apps in the background can still be scrolled through behind other windows, so they're
    /// all put away.
    private func sweepBackgroundApps() {
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        quitting = quitting.filter { pid, _ in NSRunningApplication(processIdentifier: pid) != nil }
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let bundleID = app.bundleIdentifier, bundleID != Bundle.main.bundleIdentifier,
                  app.processIdentifier != front, shield.target?.identity != "app:\(app.processIdentifier)",
                  store.blockingOccurrence(for: bundleID) != nil
            else { continue }
            putAway(.app(app))
        }
    }

    /// Gentle: the app is hidden, the site's tab closed. Strict: the app quits (music playing in the
    /// background and incoming messages stop too).
    private func putAway(_ target: BlockTarget) {
        switch target {
        case .site(_, let browser):
            Browser.from(bundleID: browser.bundleIdentifier)?.closeFrontTab()
        case .app(let app):
            guard let bundleID = app.bundleIdentifier, let occurrence = store.blockingOccurrence(for: bundleID) else {
                app.hide()
                return
            }
            guard occurrence.rule.isStrict else {
                if !app.isHidden { app.hide() }
                return
            }
            if let asked = quitting[app.processIdentifier] {
                if Date.now.timeIntervalSince(asked) > Self.forceQuitAfter { app.forceTerminate() }
            } else {
                quitting[app.processIdentifier] = .now
                app.hide()
                app.terminate()
            }
        }
    }

    // MARK: Sites

    /// With a browser in front and a schedule with sites running, reads the current tab's address.
    @objc private func checkBrowser() {
        guard !isSuspended(), !store.activeSiteOccurrences().isEmpty,
              let front = NSWorkspace.shared.frontmostApplication,
              let browser = Browser.from(bundleID: front.bundleIdentifier),
              access.isGranted(browser),
              let url = browser.frontURL()
        else { return }
        guard let (occurrence, site) = store.blockingSite(for: url) else { return }
        present(.site(site, browser: front), occurrence: occurrence)
    }

    /// Strict schedules close matching tabs in every browser, background video included. The tab
    /// under the shield stays until "back to work".
    private func sweepStrictTabs() {
        let strictSites = store.activeSiteOccurrences().filter(\.rule.isStrict).flatMap(\.rule.sites)
        guard !strictSites.isEmpty else { return }
        let shownBrowser: pid_t? = {
            if case .site(_, let browser) = shield.target { return browser.processIdentifier }
            return nil
        }()
        for browser in Browser.allCases where browser.isRunning && access.isGranted(browser) {
            let pid = NSRunningApplication.runningApplications(withBundleIdentifier: browser.bundleID).first?.processIdentifier
            browser.closeTabs(where: { url in strictSites.contains { $0.matches(url) } },
                              keepFront: pid != nil && pid == shownBrowser)
        }
    }

    // MARK: Back to work, passes

    private func backToWork() {
        guard let target = shield.target else { return }
        putAway(target)
        shield.dismiss(playSound: true)
        switch target {
        case .app:
            if let lastAllowedApp, !lastAllowedApp.isTerminated { lastAllowedApp.activate() }
        case .site(_, let browser):
            // The tab is gone; stay in the browser (most likely looking something up).
            browser.activate()
        }
    }

    private func grantPass(to target: BlockTarget, rule: BlockRule) {
        store.grantPass(for: target.passKey, rule: rule)
        shield.dismiss(playSound: false)
        switch target {
        case .app(let app): app.activate()
        case .site(_, let browser): browser.activate()
        }
        schedulePassTimers(for: target.passKey)
        onPassesChange()
    }

    /// A soft note a minute before the end, and a check right on time (not waiting for the next poll).
    private func schedulePassTimers(for key: String) {
        passTimers[key]?.forEach { $0.invalidate() }
        guard let end = store.passes[key] else { return }
        let chime = Timer(fire: end.addingTimeInterval(-60), interval: 0, repeats: false) { _ in
            MainActor.assumeIsolated { SoundPlayer.shared.playNote(2) }
        }
        let expiry = Timer(fire: end.addingTimeInterval(0.2), interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.passTimers[key] = nil
                self?.evaluate()
                self?.checkBrowser()
            }
        }
        [chime, expiry].forEach { RunLoop.main.add($0, forMode: .common) }
        passTimers[key] = [chime, expiry]
    }

    /// "End" on a pass: take it back; the app is hidden, or the site's tab closed.
    func endPassEarly(_ key: String) {
        passTimers[key]?.forEach { $0.invalidate() }
        passTimers[key] = nil
        store.revokePass(for: key)
        // A background app can't take another app's front window away; borrow this click to come forward.
        NSApp.activate()
        if key.hasPrefix(BlockedSite.passPrefix) {
            let site = BlockedSite(pattern: String(key.dropFirst(BlockedSite.passPrefix.count)), name: nil)
            for browser in Browser.allCases where browser.isRunning && access.isGranted(browser) {
                if let url = browser.frontURL(), site.matches(url) { browser.closeFrontTab() }
            }
        } else {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: key) { app.hide() }
        }
        SoundPlayer.shared.playNote(5)
        if let lastAllowedApp, !lastAllowedApp.isTerminated { lastAllowedApp.activate() }
        onPassesChange()
    }
}
