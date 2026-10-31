import AppKit
import IOKit.pwr_mgt
import SwiftUI

/// The blur over every screen. It never lifts on its own: typing the unlock phrase or holding the
/// Focus shortcut lifts it.
final class FocusOverlay: NSObject {
    static let holdSeconds: TimeInterval = 4
    private static let blurInDuration: TimeInterval = 1.2
    private static let blurOutDuration: TimeInterval = 0.9
    private static let summaryDuration: TimeInterval = 2.6
    /// With a task to tick off, the summary waits a little longer for the answer.
    private static let taskSummaryDuration: TimeInterval = 7
    /// Untouched this long, the blur goes ambient.
    private static let ambientDelay: TimeInterval = 8
    /// A new quote this often while ambient (never while someone is looking).
    private static let quoteInterval: TimeInterval = 15 * 60
    /// How far the blur lifts at the end of a hold or a typed phrase.
    private static let revealedBlur: CGFloat = 0.4
    /// After sleeping (lid closed, display off) this long, waking starts a new session.
    private static let newSessionAfterSleep: TimeInterval = 30 * 60
    /// The once-a-second tick missing for this long means the Mac slept in between.
    static let sleepGap: TimeInterval = 30

    /// The phrase that lifts the blur, typed out.
    static var unlockPhrase: String { tr("我现在要用电脑做正事", "I need the computer for real work") }

    private let store = FocusStore.shared
    private let sound = SoundPlayer.shared
    private var model = OverlayModel()
    private var windows: [(window: CurtainWindow, blur: BackdropBlurView)] = []
    private var ticker: Timer?
    private var holdTask: Task<Void, Never>?
    private var summaryTask: Task<Void, Never>?
    private var eventMonitor: Any?
    private var sleepAssertion: IOPMAssertionID = 0
    private var keepAwakeTimer: Timer?
    private var pausedAt: Date?
    private var lastTick = Date.now
    private var lastActivity = Date.now
    private var lastQuoteChange = Date.now
    private var lastMatched = 0

    private(set) var isShowing = false
    private var isExiting = false

    /// The curtain goes up and comes down; the island steps out of the way meanwhile.
    var onCurtainChange: ((Bool) -> Void)?
    /// "Done" in the summary, for the task the session was about.
    var onCompleteTask: ((UUID) -> Void)?
    /// How the Focus shortcut reads, for the hint to hold it.
    var shortcutText = "⌥⌘F"

    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        let workspace = NSWorkspace.shared.notificationCenter
        // Display sleep and system sleep (a closed lid too) pause the count until waking.
        workspace.addObserver(self, selector: #selector(pauseCounting), name: NSWorkspace.screensDidSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(pauseCounting), name: NSWorkspace.willSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(resumeCounting), name: NSWorkspace.screensDidWakeNotification, object: nil)
        workspace.addObserver(self, selector: #selector(resumeCounting), name: NSWorkspace.didWakeNotification, object: nil)
    }

    /// - Parameters:
    ///   - start: When the session began; leaving the Mac counts back to the last input.
    ///   - task: The task the session is about, shown under the quote and offered to tick off.
    ///   - playSound: Starting it by hand chimes; blurring after the Mac was left stays quiet.
    func show(since start: Date = .now, task: TaskItem?, playSound: Bool) {
        guard !isShowing else { return }
        isShowing = true
        isExiting = false
        summaryTask?.cancel()
        lastActivity = .now
        lastQuoteChange = .now
        lastMatched = 0
        pausedAt = nil
        lastTick = .now

        model = OverlayModel()
        model.segmentStart = start
        model.task = task.map { OverlayModel.TaskLine(id: $0.id, title: $0.title) }
        model.shortcutText = shortcutText
        model.onSubmit = { [weak self] in self?.submitTyped() }
        model.onTypedChange = { [weak self] in self?.typedChanged() }
        model.onCompleteTask = { [weak self] in self?.completeTask() }
        model.onDismissSummary = { [weak self] in self?.fadeOut() }

        onCurtainChange?(true)
        buildWindows()
        NSApp.activate()
        NSApp.presentationOptions = [.hideDock, .hideMenuBar, .disableProcessSwitching, .disableHideApplication, .disableAppleMenu]
        primaryWindow?.makeKeyAndOrderFront(nil)

        if playSound { sound.play(.enter) }
        windows.forEach { $0.blur.setBlurred(true, duration: Self.blurInDuration) }
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            model.appeared = true
        }

        ticker = Timer.scheduledTimer(timeInterval: 1, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        installEventMonitor()
        keepScreenAwake(true)
    }

    // MARK: Holding the shortcut

    func beginHold() {
        guard isShowing, !isExiting, holdTask == nil, model.summary == nil else { return }
        noteActivity()
        model.holding = true
        withAnimation(.linear(duration: Self.holdSeconds)) { model.holdProgress = 1 }
        setBlur(Self.revealedBlur, duration: Self.holdSeconds, timing: CAMediaTimingFunction(name: .linear))
        sound.play(.hold)
        holdTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.holdSeconds))
            guard !Task.isCancelled else { return }
            self?.unlock()
        }
    }

    func endHold() {
        holdTask?.cancel()
        holdTask = nil
        guard model.holding, !isExiting else { return }
        model.holding = false
        withAnimation(.spring(duration: 0.5, bounce: 0.25)) { model.holdProgress = 0 }
        setBlur(typingBlur, duration: 0.5)
        sound.stop(.hold, fade: 0.25)
    }

    // MARK: Typing the phrase

    /// While an input method is composing (pinyin not yet committed) the ghost text steps aside, or
    /// the two would overlap.
    private func updateComposing() {
        let editor = primaryWindow?.firstResponder as? NSTextView
        let composing = editor?.hasMarkedText() ?? false
        if model.composing != composing { model.composing = composing }
    }

    /// Every correct character plays a note and lifts the blur a little more.
    private func typedChanged() {
        guard isShowing, !isExiting else { return }
        updateComposing()
        let matched = model.matchedCount
        if matched > lastMatched {
            for (step, index) in (lastMatched..<matched).enumerated() {
                sound.playNote(index, delay: Double(step) * 0.07)
            }
        }
        if matched != lastMatched, !model.holding {
            setBlur(blur(forMatched: matched), duration: 0.45)
        }
        lastMatched = matched

        // The whole phrase unlocks without needing Return.
        if model.isComplete {
            Task {
                try? await Task.sleep(for: .milliseconds(250))
                unlock()
            }
        }
    }

    private func submitTyped() {
        guard !model.isComplete else { return }
        model.wrongAttempts += 1
        sound.play(.wrong)
        withAnimation(.smooth) { model.typed = "" }
    }

    private var typingBlur: CGFloat { blur(forMatched: model.matchedCount) }

    private func blur(forMatched matched: Int) -> CGFloat {
        let fraction = CGFloat(matched) / CGFloat(max(OverlayModel.normalize(Self.unlockPhrase).count, 1))
        return 1 - (1 - Self.revealedBlur) * fraction
    }

    // MARK: Ambient

    private func installEventMonitor() {
        let mask: NSEvent.EventTypeMask = [.keyDown, .mouseMoved, .leftMouseDown, .rightMouseDown, .scrollWheel]
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self, self.isShowing, !self.isExiting else { return event }
            self.noteActivity()
            guard event.type == .keyDown else { return event }

            if event.keyCode == 53 { // Esc folds the field away again.
                withAnimation(.smooth) {
                    self.model.typingRevealed = false
                    self.model.typed = ""
                }
                return nil
            }
            // The field always has focus; it only folds away while nothing is being typed.
            if !self.model.typingRevealed {
                withAnimation(.smooth(duration: 0.55)) { self.model.typingRevealed = true }
            }
            Task { self.updateComposing() }
            return event
        }
    }

    func noteActivity() {
        lastActivity = .now
        if isShowing, !isExiting { extendKeepAwake() }
        guard model.ambient else { return }
        withAnimation(.smooth(duration: 0.7)) { model.ambient = false }
    }

    @objc private func tick() {
        guard isShowing, !isExiting else { return }

        // Sleep notifications aren't enough: with the lid closed the Mac keeps waking briefly in the
        // dark without sending any. The timer doesn't run while asleep, so a long gap between ticks
        // means it slept, and that stretch doesn't count.
        let now = Date.now
        let gap = now.timeIntervalSince(lastTick)
        lastTick = now
        if gap > Self.sleepGap { pause(at: now.addingTimeInterval(-gap)) }
        if Displays.areAsleep {
            pause(at: now)
            return
        }
        if model.segmentStart == nil { resumeCounting() }

        if !model.ambient, !model.holding, model.summary == nil, now.timeIntervalSince(lastActivity) >= Self.ambientDelay {
            // Left halfway through the phrase: clear it and let the blur settle back.
            withAnimation(.easeInOut(duration: 1.8)) {
                model.ambient = true
                model.typingRevealed = false
                model.typed = ""
            }
            NSCursor.setHiddenUntilMouseMoves(true)
        }

        if model.ambient, now.timeIntervalSince(lastQuoteChange) >= Self.quoteInterval {
            lastQuoteChange = now
            withAnimation(.easeInOut(duration: 2.5)) { model.quote = Quotes.random(excluding: model.quote) }
        }
    }

    // MARK: Ending

    private func unlock() {
        guard isShowing, !isExiting, model.summary == nil else { return }
        holdTask?.cancel()
        holdTask = nil
        ticker?.invalidate()
        ticker = nil
        removeEventMonitor()

        let session = model.elapsed()
        model.segmentStart = nil
        model.accumulated = session

        sound.play(.unlock)
        setBlur(Self.revealedBlur, duration: 0.6)
        withAnimation(.smooth(duration: 0.7)) {
            model.ambient = false
            model.holding = false
            model.holdProgress = 0
            model.typingRevealed = false
            model.summary = .init(session: session, today: store.todaySeconds, streak: store.streakDays)
        }
        let wait = model.task == nil ? Self.summaryDuration : Self.taskSummaryDuration
        summaryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            self?.fadeOut()
        }
    }

    private func completeTask() {
        guard let task = model.task else { return }
        onCompleteTask?(task.id)
        withAnimation(.snappy) { model.taskCompleted = true }
        summaryTask?.cancel()
        summaryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            self?.fadeOut()
        }
    }

    private func fadeOut() {
        guard isShowing, !isExiting else { return }
        isExiting = true
        summaryTask?.cancel()
        model.appeared = false
        windows.forEach { $0.blur.setBlurred(false, duration: Self.blurOutDuration) }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.blurOutDuration
            windows.forEach { $0.window.animator().alphaValue = 0 }
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.tearDown() }
        })
    }

    private func tearDown() {
        NSApp.presentationOptions = []
        windows.forEach { $0.window.orderOut(nil) }
        windows.removeAll()
        keepScreenAwake(false)
        isShowing = false
        isExiting = false
        onCurtainChange?(false)
    }

    #if DEBUG
    func debugUnlock() { unlock() }
    #endif

    /// The blur is up and counting (not paused while the display sleeps); FocusController adds
    /// the time to today while it is.
    var isCounting: Bool { isShowing && !isExiting && model.summary == nil && model.segmentStart != nil }

    // MARK: Windows

    private var primaryWindow: CurtainWindow? { windows.first?.window }

    private func setBlur(_ amount: CGFloat, duration: TimeInterval, timing: CAMediaTimingFunction = CAMediaTimingFunction(name: .easeOut)) {
        windows.forEach { $0.blur.setBlur(amount, duration: duration, timing: timing) }
    }

    private func buildWindows() {
        windows.forEach { $0.window.orderOut(nil) }
        windows.removeAll()

        // The main screen first: its window takes the keyboard.
        let mainScreen = NSScreen.main ?? NSScreen.screens.first
        let screens = NSScreen.screens.filter { $0 == mainScreen } + NSScreen.screens.filter { $0 != mainScreen }
        for screen in screens {
            let window = CurtainWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.setFrame(screen.frame, display: false)
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.isReleasedWhenClosed = false
            window.acceptsMouseMovedEvents = true
            window.appearance = NSAppearance(named: .darkAqua)

            let container = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
            let blur = BackdropBlurView(frame: container.bounds)
            container.addSubview(blur)

            let content = NSHostingView(rootView: OverlayView(model: model, showsControls: screen == mainScreen)
                .environment(AppSettings.shared))
            content.frame = container.bounds
            content.autoresizingMask = [.width, .height]
            container.addSubview(content)

            window.contentView = container
            window.orderFrontRegardless()
            windows.append((window, blur))
        }
    }

    @objc private func screensChanged() {
        guard isShowing, !isExiting else { return }
        buildWindows()
        setBlur(typingBlur, duration: 0.01)
        primaryWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: Sleep

    @objc private func pauseCounting() {
        pause(at: .now)
    }

    /// Counts up to `date` (sleep is noticed after the fact, so it can reach back).
    private func pause(at date: Date) {
        guard isShowing, !isExiting else { return }
        keepScreenAwake(false)
        guard let start = model.segmentStart else { return }
        model.accumulated += max(0, date.timeIntervalSince(start))
        model.segmentStart = nil
        pausedAt = date
    }

    /// Counts on after waking. After a long sleep (the lid closed overnight) a new session starts,
    /// rather than waking to "focused for 9 hours".
    @objc private func resumeCounting() {
        guard isShowing, !isExiting, model.segmentStart == nil, !Displays.areAsleep else { return }
        lastTick = .now
        if let pausedAt, Date.now.timeIntervalSince(pausedAt) >= Self.newSessionAfterSleep {
            model.accumulated = 0
        }
        pausedAt = nil
        model.segmentStart = .now
        lastActivity = .now
        keepScreenAwake(true)
    }

    /// Keeps the display on while someone may be looking: from the last touch of the Mac, for the
    /// time set, then hands back to the system to dim and sleep as usual. Never on a low battery.
    private func keepScreenAwake(_ awake: Bool) {
        keepAwakeTimer?.invalidate()
        keepAwakeTimer = nil
        if sleepAssertion != 0 {
            IOPMAssertionRelease(sleepAssertion)
            sleepAssertion = 0
        }
        let limit = TimeInterval(store.keepAwakeMinutes * 60)
        guard awake, limit > 0, !BatteryCheck.isLow else { return }
        IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleDisplaySleep as CFString,
                                    IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                    "Perch is showing the focus screen" as CFString, &sleepAssertion)
        keepAwakeTimer = Timer.scheduledTimer(withTimeInterval: limit, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.keepScreenAwake(false) }
        }
    }

    /// Touched again: the time starts over (taking over again if it had already handed back).
    private func extendKeepAwake() {
        if let keepAwakeTimer, sleepAssertion != 0 {
            keepAwakeTimer.fireDate = Date.now.addingTimeInterval(TimeInterval(store.keepAwakeMinutes * 60))
        } else {
            keepScreenAwake(true)
        }
    }

    private func removeEventMonitor() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
    }
}
