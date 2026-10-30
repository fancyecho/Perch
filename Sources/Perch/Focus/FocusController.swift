import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Focus inside Perch. ⌥⌘F, or leaving the Mac for a while, blurs every screen until the unlock
/// phrase is typed or the shortcut held down; schedules pause distracting apps and sites at set
/// times. The island steps aside while the blur is up and shows a pass's countdown beside the notch.
@Observable
final class FocusController {
    static let shortcut = HotKeyCombo(keyCode: UInt32(kVK_ANSI_F), modifiers: UInt32(cmdKey | optionKey))

    let store = FocusStore.shared
    let schedules = ScheduleStore.shared

    private(set) var hotKeyStatus: HotKeyStatus = .disabled
    /// The blur is up.
    private(set) var isCurtained = false
    private(set) var passes: [ActivePass] = []
    /// The island shows passes beside the notch; without it the countdown pill does.
    var islandShowsPasses = false {
        didSet {
            if islandShowsPasses != oldValue { refreshPasses() }
        }
    }

    /// The task being focused on in Perch, if any; the blur shows it and offers to tick it off.
    @ObservationIgnored var focusedTask: (() -> TaskItem?)?
    @ObservationIgnored var onCompleteTask: ((UUID) -> Void)?
    @ObservationIgnored var onCurtainChange: ((Bool) -> Void)?
    @ObservationIgnored var onPassesChange: (() -> Void)?

    @ObservationIgnored private let overlay = FocusOverlay()
    @ObservationIgnored private let blocker = AppBlocker()
    @ObservationIgnored private let countdown = PassCountdownController()
    @ObservationIgnored private var hotKey: GlobalHotKey?
    @ObservationIgnored private var hotKeyDown = false
    @ObservationIgnored private var idleTimer: Timer?
    @ObservationIgnored private var lastIdleCheck = Date.now
    /// Launch or the last wake; time away never counts from before it.
    @ObservationIgnored private var lastWake = Date.now
    /// Blur time already recorded during a task's focus, which the task's own count leaves out.
    @ObservationIgnored private var overlapCredit: TimeInterval = 0

    var shortcutText: String { Self.shortcut.displayString.replacingOccurrences(of: " ", with: "") }

    /// A running strict schedule keeps Perch from quitting, except to install an update.
    var blocksQuit: Bool { schedules.hasStrictRuleActive && !Updater.shared.isRelaunching }

    func start() {
        overlay.shortcutText = shortcutText
        overlay.onCurtainChange = { [weak self] up in
            guard let self else { return }
            isCurtained = up
            onCurtainChange?(up)
        }
        overlay.onSessionRecorded = { [weak self] seconds in
            guard let self, focusedTask?() != nil else { return }
            overlapCredit += seconds
        }
        overlay.onCompleteTask = { [weak self] id in self?.onCompleteTask?(id) }

        blocker.isSuspended = { [weak self] in self?.overlay.isShowing ?? false }
        blocker.onPassesChange = { [weak self] in self?.refreshPasses() }
        blocker.start()
        countdown.onEndEarly = { [weak self] key in self?.endPass(key) }

        // Pressed once it starts a session; while the blur is up, holding it lifts the blur.
        let hotKey = GlobalHotKey(id: 2, action: { [weak self] in self?.hotKeyPressed() },
                                  release: { [weak self] in self?.hotKeyReleased() })
        hotKeyStatus = hotKey.register(Self.shortcut)
        self.hotKey = hotKey

        idleTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIdle() }
        }
        refreshPasses()
    }

    func shutdown() {
        overlay.saveProgress()
    }

    /// Starts a session now. From a menu it waits for the menu to close first.
    func startSession(fromMenu: Bool = false) {
        guard !overlay.isShowing else { return }
        guard fromMenu else { return showOverlay(playSound: true) }
        Task {
            try? await Task.sleep(for: .milliseconds(250))
            showOverlay(playSound: true)
        }
    }

    func endPass(_ key: String) {
        blocker.endPassEarly(key)
    }

    /// A task's focus in Perch ended: it counts toward today, less what the blur already counted.
    func taskFocusEnded(_ session: FocusSession, at end: Date = .now) {
        let desk = end.timeIntervalSince(session.startedAt) - overlapCredit
        overlapCredit = 0
        store.record(max(0, desk), on: end)
    }

    // MARK: The shortcut

    private func hotKeyPressed() {
        guard !hotKeyDown else { return } // ignore key repeat while held
        hotKeyDown = true
        if overlay.isShowing {
            overlay.beginHold()
        } else {
            showOverlay(playSound: true)
        }
    }

    private func hotKeyReleased() {
        hotKeyDown = false
        overlay.endHold()
    }

    // MARK: Leaving the Mac

    private func checkIdle() {
        // With the lid closed the Mac keeps half-waking in the dark without any notification; that
        // must not start a session in a dark room, or count the time before it.
        let now = Date.now
        if now.timeIntervalSince(lastIdleCheck) > FocusOverlay.sleepGap { lastWake = now }
        lastIdleCheck = now
        if Displays.areAsleep { lastWake = now }

        guard store.idleMinutes > 0, !overlay.isShowing, now > lastWake else { return }
        // Watching a lecture or sitting in a call means long stretches without touching anything.
        let keeper = MediaActivity.appKeepingDisplayAwake()
        if store.autoPausedBy != keeper { store.autoPausedBy = keeper }
        guard keeper == nil else { return }

        let anyInput = CGEventType(rawValue: ~0)!
        let threshold = TimeInterval(store.idleMinutes * 60)
        let idle = min(CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput),
                       now.timeIntervalSince(lastWake))
        if idle >= threshold {
            // The time away counts (working at the desk), back at most one threshold's worth.
            showOverlay(since: now.addingTimeInterval(-min(idle, threshold + 10)), playSound: false)
        }
    }

    /// The blur covers everything, so the shield steps aside first.
    private func showOverlay(since start: Date = .now, playSound: Bool) {
        blocker.yieldToOverlay()
        overlay.show(since: start, task: focusedTask?(), playSound: playSound)
    }

    #if DEBUG
    func refreshPassesForDebug() { refreshPasses() }
    func debugUnlock() { overlay.debugUnlock() }
    #endif

    private func refreshPasses() {
        let live = blocker.activePasses
        if live != passes { passes = live }
        countdown.refresh(enabled: !islandShowsPasses)
        onPassesChange?()
    }
}
