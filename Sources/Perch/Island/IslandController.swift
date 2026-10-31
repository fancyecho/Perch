import AppKit
import SwiftUI

/// Which parts of the island are switched on (Settings › Notch).
struct IslandPreferences: Equatable {
    var hoverToExpand: Bool
    var levels: Bool
    var nowPlaying: Bool
    var devices: Bool
    var battery: Bool
    var taskStyle: TaskStyle
    var reminders: Bool
    var haptics: Bool

    static var current: IslandPreferences {
        let defaults = UserDefaults.standard
        return IslandPreferences(
            hoverToExpand: defaults.bool(forKey: Pref.islandHoverToExpand),
            levels: defaults.bool(forKey: Pref.islandLevels),
            nowPlaying: defaults.bool(forKey: Pref.islandNowPlaying),
            devices: defaults.bool(forKey: Pref.islandDevices),
            battery: defaults.bool(forKey: Pref.islandBattery),
            taskStyle: TaskStyle.current,
            reminders: defaults.bool(forKey: Pref.islandReminders),
            haptics: defaults.bool(forKey: Pref.islandHaptics)
        )
    }
}

/// Runs the notch island: owns its window and the system monitors, and decides what it shows.
///
/// The window is fixed at the size of the largest form and hangs over the notch; every change of form
/// is a SwiftUI spring inside it. It ignores the mouse except while the pointer is over the island's
/// current outline, so the menu bar beside it stays clickable.
///
/// Today's tasks hang here too. In capsule style a glass capsule sits under the island, shares its
/// springs and opens into the glass task panel; in merged style the tasks live inside the island:
/// beside the notch, in a column when it opens, and as a black list it grows down into.
final class IslandController {
    static let open = Animation.spring(duration: 0.5, bounce: 0.3)
    static let close = Animation.spring(duration: 0.4, bounce: 0.1)
    static let hover = Animation.spring(duration: 0.35, bounce: 0.35)
    /// How long a paused track keeps its place beside the notch.
    static let pauseLinger: TimeInterval = 20

    let model: IslandModel
    let volume = SystemVolume()
    let brightness = DisplayBrightness()
    let keyboardLight = KeyboardBacklight()
    let media = NowPlayingService()
    let bluetooth = BluetoothMonitor()
    let power = PowerMonitor()
    /// Drives the task list the island grows into.
    let taskPanel = PanelModel()
    var onOpenSettings: ((SettingsTab) -> Void)?

    private let store: TaskStore
    private let focus: FocusController
    private let status: StatusController
    private let panel = IslandPanel()
    private let keyTap = MediaKeyTap()
    /// Keeps the window fixed over the notch through Space switches and on the lock screen.
    private var notchSpace: NotchSpace?
    private var lockObservers: [NSObjectProtocol] = []
    /// Perch's own menus (a task's context menu, the panel's ⋯) also announce themselves system-wide;
    /// those must not hide the capsule they belong to.
    private var ownMenuOpen = false
    private var swipeMonitor: Any?
    private var swipeSurface: SwipeSurface?
    private var swipeTravel = CGSize.zero
    private var swipeArmed = false
    /// A mouse wheel sends a burst of events per flick; one turn of the page per burst.
    private var wheelQuietUntil = Date.distantPast
    private var glowTask: Task<Void, Never>?
    private var unlockTask: Task<Void, Never>?
    /// Plays the padlock opening for a moment after the screen unlocks.
    private var isUnlocking = false

    private enum SwipeSurface {
        case island, capsule
    }
    private var preferences = IslandPreferences.current
    private var observers: [NSObjectProtocol] = []
    private var mouseMonitors: [Any] = []
    private var keyMonitor: Any?
    private var dwellTask: Task<Void, Never>?
    private var collapseTask: Task<Void, Never>?
    private var watchTask: Task<Void, Never>?
    private var bannerTask: Task<Void, Never>?
    private var inlineTask: Task<Void, Never>?
    private var routeTask: Task<Void, Never>?
    private var lingerTask: Task<Void, Never>?
    private var trustTask: Task<Void, Never>?
    private var alarmTask: Task<Void, Never>?
    private var clockTask: Task<Void, Never>?
    private var peekTask: Task<Void, Never>?
    private var cardFadeTask: Task<Void, Never>?
    /// Taking the keyboard during the window's first moments (as when a notification click launches
    /// Perch straight into the task list) sent SwiftUI into an endless constraints loop.
    private let keyboardReadyAt = Date.now.addingTimeInterval(1.5)
    /// A reminder that fell due while the island was open; it shows once the island closes.
    private var pendingReminder: IslandBanner?
    private var pausedAt: Date?
    private var feedbackSound: NSSound?

    /// Whether today's tasks live with the island rather than in the floating pill.
    var hostsTasks: Bool { preferences.taskStyle != .floating }

    /// The full task list is open: the black one in merged style or the glass panel in capsule style.
    private var isListOpen: Bool { model.isShowingTasks || model.cardMode == .panel }
    private var isOpen: Bool { model.isExpanded || isListOpen }

    init(store: TaskStore, swipe: SwipeTracker, focus: FocusController, status: StatusController) {
        self.store = store
        self.focus = focus
        self.status = status
        model = IslandModel(geometry: NotchGeometry(screen: NotchGeometry.preferredScreen()))
        taskPanel.mode = .panel
        taskPanel.isInIsland = true
        let root = IslandView()
            .environment(model)
            .environment(media)
            .environment(volume)
            .environment(bluetooth)
            .environment(power)
            .environment(store)
            .environment(swipe)
            .environment(taskPanel)
            .environment(AppSettings.shared)
            .environment(Updater.shared)
            .environment(Feedback.shared)
            .environment(focus)
            .environment(ScheduleStore.shared)
            .environment(status.monitor)
            .environment(status.prefs)
        let hosting = IslandHostingView(rootView: root)
        hosting.sizingOptions = []
        // The window sits right over the camera housing, so its safe area flips around as it gains
        // and loses the keyboard; following it sent SwiftUI into an endless layout loop.
        hosting.safeAreaRegions = []
        panel.contentView = hosting
        panel.onCancel = { [weak self] in self?.closeTaskList() }
        swipe.track(panel)

        model.expandHandler = { [weak self] in self?.expand() }
        model.levelHandler = { [weak self] kind, value in self?.setLevel(kind, to: value) }
        model.reminderHandler = { [weak self] id, action in self?.handleReminder(id, action) }
        model.tasksHandler = { [weak self] focusInput in self?.openTaskList(focusInput: focusInput) }
        taskPanel.router = { [weak self] mode, focusInput in
            if mode == .panel { self?.openTaskList(focusInput: focusInput) } else { self?.closeTaskList() }
        }
        taskPanel.settingsHandler = { [weak self] tab in self?.onOpenSettings?(tab) }
        model.settingsHandler = { [weak self] tab in self?.onOpenSettings?(tab) }
        model.statusHandler = { [weak self] in self?.openStatus() }
        model.metricHandler = { [weak self] metric in
            guard let self, self.model.statusMetric != metric else { return }
            if self.preferences.haptics { Haptics.tick() }
            withAnimation(.snappy(duration: 0.3)) { self.model.statusMetric = metric }
        }
        model.pageHandler = { [weak self] page in self?.showPage(page) }
        model.alertHandler = { [weak self] alert in self?.handleAlert(alert) }
        volume.onChange = { [weak self] in self?.showLevel(.volume) }
        volume.onRouteChange = { [weak self] route in self?.routeChanged(route) }
        brightness.onChange = { [weak self] in self?.brightnessChanged() }
        media.onChange = { [weak self] in self?.updateLiveActivity() }
        media.onTrackChange = { [weak self] in self?.trackChanged() }
        bluetooth.onConnect = { [weak self] device in self?.deviceChanged(device, connected: true) }
        bluetooth.onDisconnect = { [weak self] device in self?.deviceChanged(device, connected: false) }
        power.onEvent = { [weak self] event in self?.powerChanged(event) }
        keyTap.handler = { [weak self] press in self?.handleKey(press) ?? false }

        placeWindow()
        panel.orderFrontRegardless()
        notchSpace = NotchSpace()
        notchSpace?.add(panel)
        volume.start()
        power.start()
        applyPreferences(force: true)
        startPointerTracking()
        startSwipeTracking()
        startClock()
        scheduleCardFade(after: 2)

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyPreferences() }
        })
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        })
        // Alarms count down on a monotonic clock, so re-aim them when the wall clock is changed.
        observers.append(center.addObserver(forName: .NSSystemClockDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleNextReminder() }
        })
        let distributed = DistributedNotificationCenter.default()
        for (name, locked) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            lockObservers.append(distributed.addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.lockChanged(locked) }
            })
        }
        for (name, open) in [("com.apple.HIToolbox.beginMenuTrackingNotification", true), ("com.apple.HIToolbox.endMenuTrackingNotification", false)] {
            lockObservers.append(distributed.addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.menuTrackingChanged(open) }
            })
        }
        observers.append(center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.ownMenuOpen = true }
        })
        observers.append(center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.ownMenuOpen = false }
        })
    }

    func shutdown() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        lockObservers.forEach { DistributedNotificationCenter.default().removeObserver($0) }
        lockObservers = []
        mouseMonitors.forEach { NSEvent.removeMonitor($0) }
        mouseMonitors = []
        if let swipeMonitor { NSEvent.removeMonitor(swipeMonitor) }
        swipeMonitor = nil
        removeKeyMonitor()
        keyTap.stop()
        for task in [dwellTask, collapseTask, watchTask, bannerTask, inlineTask, routeTask, lingerTask, trustTask, alarmTask, clockTask, peekTask, cardFadeTask] {
            task?.cancel()
        }
        volume.stop()
        media.stop()
        bluetooth.stop()
        power.stop()
        status.watch("island", false)
        notchSpace?.remove(panel)
        notchSpace = nil
        panel.orderOut(nil)
    }

    // MARK: - Open & close

    func expand() {
        dwellTask?.cancel()
        collapseTask?.cancel()
        guard !isOpen, !model.isCurtained else { return }
        bannerTask?.cancel()
        bluetooth.refreshBatteries()
        if preferences.haptics { Haptics.tick() }
        let pages = islandPages
        if !pages.contains(model.page) { model.page = pages[0] }
        withAnimation(Self.open) {
            model.isExpanded = true
            model.banner = nil
        }
        refreshPointer()
        startWatching()
        updateStatusWatch()
    }

    /// Processes, disk, Wi-Fi and latency are only sampled while the status page is on screen.
    private func updateStatusWatch() {
        status.watch("island", model.isExpanded && model.page == .status && focus.passes.isEmpty)
    }

    func collapse() {
        guard model.isExpanded else { return }
        withAnimation(Self.close) {
            model.isExpanded = false
            model.inlineLevel = nil
        } completion: { [weak self] in
            // It opens on the first page again next time.
            guard let self, !self.model.isExpanded else { return }
            self.model.page = .main
        }
        updateStatusWatch()
        refreshPointer()
        showPendingReminder()
    }

    /// Opens the full task list: the glass panel the capsule grows into, or the black list the island
    /// grows into in merged style. Either takes the keyboard.
    func openTaskList(focusInput: Bool = false) {
        guard hostsTasks, !model.isLocked, !model.isCurtained else { return }
        let wait = keyboardReadyAt.timeIntervalSinceNow
        guard wait <= 0 else {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                self?.openTaskList(focusInput: focusInput)
            }
            return
        }
        dwellTask?.cancel()
        collapseTask?.cancel()
        peekTask?.cancel()
        cardFadeTask?.cancel()
        if preferences.taskStyle == .merged, !model.isLocked {
            if !model.isShowingTasks {
                bannerTask?.cancel()
                withAnimation(Self.open) {
                    model.isShowingTasks = true
                    model.isExpanded = false
                    model.banner = nil
                    model.inlineLevel = nil
                }
            }
        } else if model.cardMode != .panel {
            if model.isExpanded {
                withAnimation(Self.close) {
                    model.isExpanded = false
                    model.inlineLevel = nil
                }
            }
            let top = model.cardTop
            withAnimation(PanelController.morph) {
                model.pinnedCardTop = top
                model.cardMode = .panel
                model.isCardFaded = false
            }
        }
        if preferences.haptics { Haptics.tick() }
        panel.acceptsKey = true
        panel.makeKeyAndOrderFront(nil)
        notchSpace?.add(panel)
        if focusInput { taskPanel.inputFocusRequest += 1 }
        refreshPointer()
        startWatching()
    }

    func closeTaskList() {
        guard isListOpen else { return }
        // Hand keyboard focus back to whatever app the user was in.
        let handBackFocus: () -> Void = { [weak self] in
            guard let self, !self.isListOpen, self.panel.isKeyWindow else { return }
            self.panel.orderOut(nil)
            self.panel.orderFrontRegardless()
            self.notchSpace?.add(self.panel)
        }
        if model.isShowingTasks {
            withAnimation(Self.close) { model.isShowingTasks = false } completion: { handBackFocus() }
        }
        if model.cardMode == .panel {
            withAnimation(PanelController.morph) {
                model.cardMode = .capsule
                model.pinnedCardTop = nil
            } completion: { handBackFocus() }
        }
        panel.acceptsKey = false
        refreshPointer()
        showPendingReminder()
        scheduleCardFade()
    }

    func toggleTaskList() {
        isListOpen ? closeTaskList() : openTaskList(focusInput: true)
    }

    // MARK: - Status

    /// Opens the island on its status page, with one of the details showing. When the island has
    /// no status page (its gauges are off), the full panel opens under the menu bar instead.
    func openStatus(_ metric: StatusMetric? = nil) {
        guard !model.isLocked, !model.isCurtained else { return }
        if let metric { model.statusMetric = metric }
        guard islandPages.contains(.status) else { return status.showPanel() }
        if model.isExpanded {
            showPage(.status)
        } else {
            model.page = .status
            expand()
        }
    }

    /// Shows a Mac alert; false when it should go to Notification Center instead (on the lock screen).
    func showAlert(_ alert: SystemAlert) -> Bool {
        guard !model.isLocked else { return false }
        // The island already says low battery its own way.
        if alert.kind == .battery, preferences.battery { return true }
        present(.alert(alert), for: .seconds(10))
        if model.banner?.kind == .alert { flash(.alert) }
        return true
    }

    private func handleAlert(_ alert: SystemAlert) {
        bannerTask?.cancel()
        withAnimation(Self.close) { model.banner = nil }
        refreshPointer()
        switch alert.kind {
        case .runaway(let pid): NSRunningApplication(processIdentifier: pid)?.terminate()
        case .hot: openStatus(.temperature)
        case .memory: openStatus(.memory)
        case .disk: status.showPanel()
        case .battery: openStatus()
        }
    }

    // MARK: - The capsule

    /// The capsule swells under the pointer straight away; held there a moment longer it peeks at
    /// the next few tasks.
    private func cardHoverChanged(_ hovering: Bool) {
        peekTask?.cancel()
        cardFadeTask?.cancel()
        guard model.cardMode != .panel else {
            model.isCardHovering = hovering
            return
        }
        withAnimation(Self.hover) {
            model.isCardHovering = hovering
            if hovering { model.isCardFaded = false }
        }
        if hovering {
            startWatching()
            guard model.cardMode == .capsule, UserDefaults.standard.bool(forKey: Pref.peekOnHover) else { return }
            peekTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(480))
                guard let self, !Task.isCancelled, self.model.isCardHovering, self.model.cardMode == .capsule,
                      NSEvent.pressedMouseButtons == 0 else { return }
                withAnimation(PanelController.morph) {
                    self.model.peekRows = self.peekRows
                    self.model.cardMode = .peek
                }
                self.refreshPointer()
            }
        } else {
            if model.cardMode == .peek {
                peekTask = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(260))
                    guard let self, !Task.isCancelled, !self.model.isCardHovering, self.model.cardMode == .peek else { return }
                    withAnimation(PanelController.morph) { self.model.cardMode = .capsule }
                    self.refreshPointer()
                }
            }
            scheduleCardFade()
        }
    }

    private var peekRows: Int {
        max(min(store.peekTasks(now: .now).count, PanelController.peekMaxRows), 1)
    }

    /// The capsule settles back to see-through when nobody is looking at it.
    private func scheduleCardFade(after delay: Double = 1.2) {
        cardFadeTask?.cancel()
        guard preferences.taskStyle == .capsule else { return }
        cardFadeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled, !self.model.isCardHovering, self.model.cardMode == .capsule,
                  UserDefaults.standard.bool(forKey: Pref.fadeWhenIdle) else { return }
            withAnimation(.easeInOut(duration: 0.6)) { self.model.isCardFaded = true }
        }
    }

    // MARK: - Banners

    private func present(_ banner: IslandBanner, for duration: Duration) {
        // Status still shows beside the notch over an open glass panel; nothing drops onto it.
        guard !model.isExpanded, !model.isShowingTasks, !(banner.dropsDown && model.cardMode == .panel),
              !model.isCurtained || banner.passesCurtain else { return }
        if model.banner?.kind == banner.kind {
            model.banner = banner
        } else {
            dwellTask?.cancel()
            withAnimation(Self.open) { model.banner = banner }
        }
        bannerTask?.cancel()
        bannerTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            // Stay while the pointer rests on it, e.g. to drag the level.
            while let self, !Task.isCancelled, self.model.isHovering {
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard let self, !Task.isCancelled else { return }
            withAnimation(Self.close) { self.model.banner = nil }
            self.refreshPointer()
        }
        refreshPointer()
    }

    private func showLevel(_ kind: LevelKind) {
        guard preferences.levels, !model.isShowingTasks else { return }
        let hud = level(kind)
        guard model.isExpanded else {
            let duration = UserDefaults.standard.double(forKey: Pref.hudDuration)
            present(.level(hud), for: .seconds(duration > 0 ? duration : 1.6))
            return
        }
        // Inside the open island the level takes over the row beside the notch for a moment.
        if model.inlineLevel == nil {
            withAnimation(.smooth(duration: 0.25)) { model.inlineLevel = hud }
        } else {
            model.inlineLevel = hud
        }
        inlineTask?.cancel()
        inlineTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            guard let self, !Task.isCancelled else { return }
            withAnimation(.smooth(duration: 0.3)) { self.model.inlineLevel = nil }
        }
    }

    private func level(_ kind: LevelKind) -> LevelHUD {
        switch kind {
        case .volume: LevelHUD(kind: .volume, value: volume.level, isMuted: volume.isMuted, route: bluetooth.refine(volume.route))
        case .brightness: LevelHUD(kind: .brightness, value: brightness.level)
        case .keyboard: LevelHUD(kind: .keyboard, value: keyboardLight.level)
        }
    }

    private func setLevel(_ kind: LevelKind, to value: Double) {
        switch kind {
        case .volume: volume.setLevel(value)
        case .brightness: brightness.setLevel(value)
        case .keyboard: keyboardLight.setLevel(value)
        }
        showLevel(kind)
    }

    // MARK: - System events

    /// Keeps a brightness HUD in step while the system animates toward the new level.
    private func brightnessChanged() {
        if case .level(let hud)? = model.banner, hud.kind == .brightness {
            model.banner = .level(level(.brightness))
        }
        if model.inlineLevel?.kind == .brightness {
            model.inlineLevel = level(.brightness)
        }
    }

    private func routeChanged(_ route: AudioRoute) {
        guard preferences.devices, !route.name.isEmpty else { return }
        routeTask?.cancel()
        // A Bluetooth headset announces itself with its own banner; let that one win.
        routeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard let self, !Task.isCancelled, self.model.banner?.kind != .device else { return }
            self.present(.route(self.bluetooth.refine(route)), for: .seconds(2.6))
        }
    }

    private func deviceChanged(_ device: BluetoothDevice, connected: Bool) {
        guard preferences.devices else { return }
        present(.device(device, connected: connected), for: .seconds(connected ? 4 : 2.6))
    }

    private func powerChanged(_ event: PowerEvent) {
        guard preferences.battery else { return }
        present(.power(event), for: .seconds(3.2))
        switch event {
        case .pluggedIn: flash(.charging)
        case .low: flash(.lowBattery)
        case .unplugged, .charged, .lowPowerMode: break
        }
    }

    /// Today's list was just cleared.
    func celebrate() {
        flash(.celebration)
    }

    private func flash(_ glow: IslandGlow) {
        glowTask?.cancel()
        withAnimation(.easeIn(duration: 0.2)) { model.glow = glow }
        glowTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.8))
            guard let self, !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.5)) { self.model.glow = nil }
        }
    }

    private func trackChanged() {
        guard preferences.nowPlaying, media.isPlaying, !isOpen else { return }
        present(.track, for: .seconds(3.2))
    }

    /// What sits beside the notch: the artwork of whatever plays (lingering a little after a pause),
    /// and today's tasks as a progress ring and the next due time, or the focus timer.
    private func updateLiveActivity() {
        if media.track == nil || media.isPlaying {
            pausedAt = nil
        } else if pausedAt == nil {
            pausedAt = .now
        }
        let lingering = pausedAt.map { Date.now.timeIntervalSince($0) < Self.pauseLinger } ?? false
        let playing = preferences.nowPlaying && media.track != nil && (media.isPlaying || lingering)

        var live = LiveActivity()
        if playing { live.leading = .artwork }
        // On the lock screen the padlock takes the left wing, and it springs open on the way out.
        if model.isLocked || isUnlocking {
            live.leading = isUnlocking ? .unlocked : .locked
        }
        // In capsule style the capsule tells the tasks; only in merged style do they sit by the notch.
        if preferences.taskStyle == .merged {
            let now = Date.now
            let headline = store.headline(now: now)
            if let focus = store.focus, headline?.id == focus.taskID {
                live.trailing = .focus
            } else if let headline, headline.hasTime || DateText.isOverdue(headline, now: now) {
                live.trailing = .due
            }
            let progress = store.progress(now: now)
            if live.leading == nil, progress.done < progress.total { live.leading = .progress }
        }
        if live.trailing == nil, playing { live.trailing = .equalizer }
        // A pass running out matters more than what's playing.
        if !focus.passes.isEmpty, !model.isLocked {
            live.leading = .pass
            live.trailing = .countdown
        }
        let next = live.leading == nil && live.trailing == nil || model.isCurtained ? nil : live
        if next != model.live {
            withAnimation(next == nil ? Self.close : Self.open) { model.live = next }
            refreshPointer()
        }

        lingerTask?.cancel()
        if playing, let pausedAt {
            let remaining = Self.pauseLinger - Date.now.timeIntervalSince(pausedAt)
            lingerTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(max(remaining, 0) + 0.1))
                guard !Task.isCancelled else { return }
                self?.updateLiveActivity()
            }
        }
    }

    /// Due times and "today" move with the clock, so look at the tasks again every minute.
    private func startClock() {
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                let second = Double(Calendar.current.component(.second, from: .now))
                try? await Task.sleep(for: .seconds(61 - second))
                guard let self else { return }
                self.updateLiveActivity()
            }
        }
    }

    // MARK: - Tasks & reminders

    /// The store changed: refresh the wings, re-aim the alarm, and drop a reminder whose task is done
    /// or has moved.
    func tasksChanged() {
        updateLiveActivity()
        scheduleNextReminder()
        if model.cardMode == .peek, model.peekRows != peekRows {
            withAnimation(PanelController.morph) { model.peekRows = peekRows }
        }
        if case .reminder(let task, _)? = model.banner,
           store.task(task.id).map({ $0.isDone || $0.schedule != task.schedule }) ?? true {
            bannerTask?.cancel()
            withAnimation(Self.close) { model.banner = nil }
            refreshPointer()
        }
    }

    private func scheduleNextReminder(after date: Date = .now) {
        alarmTask?.cancel()
        guard preferences.reminders, let next = ReminderClock.next(after: date, in: store.tasks) else { return }
        alarmTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(next.time.timeIntervalSinceNow, 0)))
            guard let self, !Task.isCancelled else { return }
            self.remind(dueAt: next.time)
            self.scheduleNextReminder(after: max(.now, next.time))
        }
    }

    private func remind(dueAt time: Date) {
        let due = store.tasks.filter { !$0.isDone && $0.schedule?.time == time }
        guard let task = due.first else { return }
        let banner = IslandBanner.reminder(task, alsoDue: due.count - 1)
        NSSound(named: "Glass")?.play()
        // A task's title waits for the screen to unlock rather than showing on the lock screen.
        if isOpen || model.isLocked {
            pendingReminder = banner
        } else {
            present(banner, for: .seconds(12))
        }
    }

    private func showPendingReminder() {
        guard let pendingReminder, !isOpen else { return }
        self.pendingReminder = nil
        present(pendingReminder, for: .seconds(12))
    }

    private func handleReminder(_ id: UUID, _ action: ReminderAction) {
        switch action {
        case .complete:
            store.complete(id)
        case .snooze:
            store.reschedule(id, to: .time(Date.now.addingTimeInterval(10 * 60)))
        }
        bannerTask?.cancel()
        withAnimation(Self.close) { model.banner = nil }
        refreshPointer()
    }

    // MARK: - Keys

    /// Takes the volume and brightness keys over once Accessibility allows it. Until then the system
    /// keeps its own HUD and the island mirrors what it can observe.
    private func takeOverKeys() {
        if keyTap.start() {
            removeKeyMonitor()
            return
        }
        installKeyMonitor()
        if !UserDefaults.standard.bool(forKey: Pref.islandAskedAccessibility) {
            UserDefaults.standard.set(true, forKey: Pref.islandAskedAccessibility)
            Accessibility.requestAccess()
        }
        trustTask?.cancel()
        trustTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                if Accessibility.isTrusted, self.keyTap.start() {
                    self.removeKeyMonitor()
                    return
                }
            }
        }
    }

    private func releaseKeys() {
        trustTask?.cancel()
        trustTask = nil
        keyTap.stop()
        removeKeyMonitor()
    }

    private func handleKey(_ press: MediaKeyPress) -> Bool {
        // ⌥ with these keys opens Sound or Displays settings; leave that to the system.
        if press.modifiers.contains(.option) && !press.modifiers.contains(.shift) { return false }
        let fine = press.modifiers.contains([.shift, .option])
        switch press.key {
        case .volumeUp, .volumeDown:
            guard volume.canSetVolume else { return false }
            if press.isDown {
                volume.step(up: press.key == .volumeUp, fine: fine)
                showLevel(.volume)
            } else {
                playVolumeFeedback(inverted: press.modifiers.contains(.shift))
            }
        case .mute:
            guard volume.canSetVolume else { return false }
            if press.isDown, !press.isRepeat {
                volume.toggleMute()
                showLevel(.volume)
            }
        case .brightnessUp, .brightnessDown:
            guard brightness.isAvailable else { return false }
            if press.isDown {
                brightness.step(up: press.key == .brightnessUp, fine: fine)
                showLevel(.brightness)
            }
        case .illuminationUp, .illuminationDown:
            guard keyboardLight.isAvailable else { return false }
            if press.isDown {
                keyboardLight.step(up: press.key == .illuminationUp, fine: fine)
                showLevel(.keyboard)
            }
        }
        return true
    }

    /// The system's "play feedback when volume is changed" click; ⇧ inverts the setting.
    private func playVolumeFeedback(inverted: Bool) {
        let enabled = UserDefaults.standard.integer(forKey: "com.apple.sound.beep.feedback") == 1
        guard enabled != inverted, !volume.isSilent else { return }
        feedbackSound?.stop()
        feedbackSound = NSSound(contentsOfFile: "/System/Library/LoginPlugins/BezelServices.loginPlugin/Contents/Resources/volume.aiff", byReference: true)
        feedbackSound?.play()
    }

    /// Without the event tap the keys still reach the system; watch them so brightness gets a HUD too
    /// (volume already shows through CoreAudio).
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .systemDefined) { [weak self] event in
            guard let press = MediaKeyPress(event), press.isDown else { return }
            MainActor.assumeIsolated { self?.observedKey(press) }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private func observedKey(_ press: MediaKeyPress) {
        let kind: LevelKind
        switch press.key {
        case .brightnessUp, .brightnessDown: kind = .brightness
        case .illuminationUp, .illuminationDown: kind = .keyboard
        case .volumeUp, .volumeDown, .mute: return
        }
        // The system applies the step itself; read the result once it has.
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self else { return }
            if kind == .brightness { self.brightness.refresh() } else { self.keyboardLight.refresh() }
            self.showLevel(kind)
        }
    }

    // MARK: - Pointer

    private func startPointerTracking() {
        let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPointer(byMoving: true) }
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            MainActor.assumeIsolated { self?.refreshPointer(byMoving: true) }
            return event
        }
        mouseMonitors = [global, local].compactMap { $0 }
    }

    /// Lets the mouse through everywhere except over the island and the capsule. `byMoving` tells a
    /// real pointer movement from the island changing shape under a pointer that is standing still.
    private func refreshPointer(byMoving: Bool = false) {
        let mouse = NSEvent.mouseLocation
        // Over the focus blur the island only answers while it has something to answer, like a reminder.
        let overIsland = hitRect.contains(mouse) && (!model.isCurtained || model.banner != nil)
        let overCard = cardHitRect?.contains(mouse) ?? false
        let interactive = overIsland || overCard
        if panel.ignoresMouseEvents == interactive { panel.ignoresMouseEvents = !interactive }
        if overCard != model.isCardHovering { cardHoverChanged(overCard) }
        guard overIsland != model.isHovering else { return }
        withAnimation(Self.hover) { model.isHovering = overIsland }
        if overIsland { pointerEntered(byMoving: byMoving) } else { pointerExited() }
    }

    private var cardHitRect: NSRect? {
        guard model.taskStyle == .capsule, !model.isLocked, !model.isCurtained, !(model.isMenuOpen && model.cardMode != .panel) else { return nil }
        let size = model.cardSize
        let frame = panel.frame
        return NSRect(x: frame.midX - size.width / 2, y: frame.maxY - model.cardTop - size.height, width: size.width, height: size.height)
    }

    private var hitRect: NSRect {
        let layout = model.layout
        let screen = model.geometry.screenFrame
        // Reaches a little past the top edge, where the pointer stops.
        let rect = NSRect(x: screen.midX - layout.width / 2, y: screen.maxY - layout.height, width: layout.width, height: layout.height + 2)
        guard model.isExpanded else { return rect }
        // Some slack while open, so brushing an edge doesn't snap it shut.
        return rect.insetBy(dx: -8, dy: -6)
    }

    private func pointerEntered(byMoving: Bool) {
        collapseTask?.cancel()
        startWatching()
        // Only a pointer that moves in opens the island: not one the island grew under. A level HUD
        // stays put under the pointer so its bar can be dragged, and a reminder so it can be answered.
        guard byMoving, preferences.hoverToExpand, !isOpen, !model.isCurtained,
              model.banner?.kind != .level, model.banner?.kind != .reminder else { return }
        dwellTask?.cancel()
        dwellTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard let self, !Task.isCancelled, self.model.isHovering, NSEvent.pressedMouseButtons == 0 else { return }
            self.expand()
        }
    }

    private func pointerExited() {
        dwellTask?.cancel()
        // The task list stays until it's dismissed; only the hover view closes on its own.
        guard model.isExpanded else { return }
        collapseTask?.cancel()
        collapseTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(220))
            // Moving down onto the capsule keeps the island open; otherwise the capsule would spring
            // back up and slip out from under the pointer.
            // So does one of its own menus (such as the output picker) hanging below it.
            while let self, !Task.isCancelled, self.model.isCardHovering || self.ownMenuOpen {
                try? await Task.sleep(for: .milliseconds(150))
            }
            guard let self, !Task.isCancelled, !self.model.isHovering else { return }
            self.collapse()
        }
    }

    /// Mouse-moved events can go missing while the island reshapes under a still pointer, so keep
    /// checking where the pointer really is until it has left. Also closes the task list once the
    /// keyboard has gone elsewhere, as when the user clicks into another app.
    private func startWatching() {
        guard watchTask == nil else { return }
        watchTask = Task { [weak self] in
            while let self, !Task.isCancelled, self.model.isHovering || self.model.isCardHovering || self.isOpen {
                try? await Task.sleep(for: .milliseconds(150))
                self.refreshPointer()
                let popoverOpen = self.panel.childWindows?.contains(where: \.isVisible) ?? false
                if self.isListOpen, !self.panel.isKeyWindow, !popoverOpen {
                    self.closeTaskList()
                }
            }
            self?.watchTask = nil
        }
    }

    // MARK: - Swipes

    /// Two-finger swipes, read from the trackpad's scroll events over the island and the capsule.
    private func startSwipeTracking() {
        swipeMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            return self.handleSwipe(event)
        }
    }

    private func handleSwipe(_ event: NSEvent) -> NSEvent? {
        guard event.window === panel else { return event }
        guard event.hasPreciseScrollingDeltas else { return handleWheel(event) }
        if event.phase.contains(.began) {
            swipeTravel = .zero
            swipeArmed = false
            if isPointerOnCapsuleRow {
                swipeSurface = .capsule
            } else if model.isHovering {
                swipeSurface = .island
            } else {
                swipeSurface = nil
            }
        }
        guard let surface = swipeSurface else { return event }
        // Measured the way the fingers move, whatever the scrolling direction setting.
        let inverted = event.isDirectionInvertedFromDevice
        swipeTravel.width += inverted ? event.scrollingDeltaX : -event.scrollingDeltaX
        swipeTravel.height += inverted ? event.scrollingDeltaY : -event.scrollingDeltaY
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            swipeSurface = nil
            switch surface {
            case .island: finishIslandSwipe()
            case .capsule: finishCapsuleSwipe(cancelled: event.phase.contains(.cancelled))
            }
        } else if surface == .capsule {
            followCapsuleSwipe()
        }
        return nil
    }

    /// A mouse wheel over the island does what a two-finger swipe does: down opens it and moves to
    /// the page below, up to the page above (closing it from the first), sideways (a tilting wheel)
    /// changes the track. It's left alone over the capsule, where a stray roll shouldn't complete
    /// a task.
    private func handleWheel(_ event: NSEvent) -> NSEvent? {
        guard model.isHovering else { return event }
        // Measured the way the wheel turns, whatever the scrolling direction setting.
        let inverted = event.isDirectionInvertedFromDevice
        let dx = inverted ? event.scrollingDeltaX : -event.scrollingDeltaX
        let dy = inverted ? event.scrollingDeltaY : -event.scrollingDeltaY
        guard max(abs(dx), abs(dy)) >= 0.5, Date.now >= wheelQuietUntil else { return nil }
        wheelQuietUntil = Date.now.addingTimeInterval(0.45)
        // Scale a notch up to the distance a swipe has to travel.
        swipeTravel = CGSize(width: dx * 100, height: dy * 100)
        finishIslandSwipe()
        return nil
    }

    /// The capsule's own row, not the peek list under it, whose rows have swipes of their own.
    private var isPointerOnCapsuleRow: Bool {
        guard model.isCardHovering, model.cardMode != .panel, let card = cardHitRect else { return false }
        let row = NSRect(x: card.minX, y: card.maxY - IslandModel.capsuleHoverHeight, width: card.width, height: IslandModel.capsuleHoverHeight)
        return row.contains(NSEvent.mouseLocation)
    }

    /// The pages the open island has right now (see IslandPage).
    private var islandPages: [IslandPage] {
        let hasMain = media.track != nil || (preferences.taskStyle == .merged && !model.isLocked)
        return IslandPage.available(hasMain: hasMain, gauges: status.prefs.islandGauges, locked: model.isLocked)
    }

    /// Moves the open island to the page below (`forward`) or above. Up from the first page, the
    /// island closes, as swiping up always did.
    func turnPage(forward: Bool) {
        let pages = islandPages
        let index = pages.firstIndex(of: model.page) ?? 0
        let next = index + (forward ? 1 : -1)
        guard pages.indices.contains(next) else {
            if !forward { collapse() }
            return
        }
        showPage(pages[next])
    }

    func showPage(_ page: IslandPage) {
        let pages = islandPages
        guard page != model.page, let target = pages.firstIndex(of: page) else { return }
        // The direction lands first, so the page leaving already carries it.
        model.pageMovesForward = target > (pages.firstIndex(of: model.page) ?? 0)
        if preferences.haptics { Haptics.tick() }
        Task { [weak self] in
            guard let self else { return }
            withAnimation(.spring(duration: 0.45, bounce: 0.12)) { self.model.page = page }
            self.updateStatusWatch()
        }
    }

    /// Sideways changes the track (to the left for the next one, like turning a page). Down opens
    /// the island; once open, up and down move between its pages.
    private func finishIslandSwipe() {
        let dx = swipeTravel.width
        let dy = swipeTravel.height
        if abs(dx) > 60, abs(dx) > abs(dy) * 1.4, media.track != nil {
            media.send(dx < 0 ? .next : .previous)
            if preferences.haptics { Haptics.tick() }
            let direction: CGFloat = dx < 0 ? -1 : 1
            withAnimation(.snappy(duration: 0.14)) { model.mediaNudge = direction }
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(140))
                withAnimation(.spring(duration: 0.45, bounce: 0.45)) { self?.model.mediaNudge = 0 }
            }
        } else if abs(dy) > 40, abs(dy) > abs(dx) {
            if model.isExpanded {
                // Fingers moving down go down to the next page.
                turnPage(forward: dy > 0)
            } else if dy > 0 {
                expand()
            }
        }
    }

    private func followCapsuleSwipe() {
        // A mostly vertical gesture is a scroll that wandered by; leave it alone.
        guard model.capsuleSwipe != 0 || abs(swipeTravel.width) > abs(swipeTravel.height) * 1.2 else { return }
        model.capsuleSwipe = SwipeTracker.rubberBand(swipeTravel.width)
        let armed = abs(model.capsuleSwipe) >= SwipeTracker.threshold
        if armed != swipeArmed {
            swipeArmed = armed
            if armed { Haptics.tick() }
        }
    }

    /// Past the threshold, right completes the capsule's task and left moves it to tomorrow.
    private func finishCapsuleSwipe(cancelled: Bool) {
        let offset = model.capsuleSwipe
        if !cancelled, abs(offset) >= SwipeTracker.threshold, let task = store.headline(now: .now) {
            Haptics.confirm()
            if offset > 0 {
                Feedback.shared.taskChecked()
                withAnimation(.snappy) { store.complete(task.id, playsSound: false) }
            } else {
                withAnimation(.snappy) { store.postponeToTomorrow(task.id) }
            }
        }
        withAnimation(.spring(duration: 0.35, bounce: 0.25)) { model.capsuleSwipe = 0 }
    }

    // MARK: - Focus

    /// The focus blur is up: the island stays a plain notch above it, and only a task falling due or
    /// a level the user changed shows on it.
    func setCurtained(_ curtained: Bool) {
        guard curtained != model.isCurtained else { return }
        if curtained {
            closeTaskList()
            collapse()
            peekTask?.cancel()
            bannerTask?.cancel()
            withAnimation(Self.close) {
                model.cardMode = .capsule
                model.isCardHovering = false
                model.isHovering = false
                if let banner = model.banner, !banner.passesCurtain { model.banner = nil }
            }
        }
        withAnimation(.smooth(duration: 0.4)) { model.isCurtained = curtained }
        updateLiveActivity()
        refreshPointer()
        if !curtained { scheduleCardFade() }
    }

    /// A pass started or ended.
    func focusChanged() {
        updateLiveActivity()
    }

    // MARK: - Window & preferences

    private func menuTrackingChanged(_ open: Bool) {
        let hides = open && !ownMenuOpen
        guard hides != model.isMenuOpen else { return }
        withAnimation(.easeOut(duration: hides ? 0.12 : 0.25)) { model.isMenuOpen = hides }
        refreshPointer()
    }

    /// The island stays on the notch over the lock screen (it lives in its own space), so close
    /// everything that shows tasks or takes input, and let the capsule step out of sight meanwhile.
    private func lockChanged(_ locked: Bool) {
        guard locked != model.isLocked else { return }
        if locked {
            closeTaskList()
            collapse()
            peekTask?.cancel()
            withAnimation(Self.close) {
                model.cardMode = .capsule
                model.isCardHovering = false
                model.isHovering = false
            }
        }
        model.isLocked = locked
        unlockTask?.cancel()
        if !locked {
            isUnlocking = true
            unlockTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1.1))
                guard let self, !Task.isCancelled else { return }
                self.isUnlocking = false
                self.updateLiveActivity()
            }
            showPendingReminder()
        }
        updateLiveActivity()
        refreshPointer()
    }

    private func placeWindow() {
        let size = model.windowSize
        let screen = model.geometry.screenFrame
        panel.setFrame(
            NSRect(x: screen.midX - size.width / 2, y: screen.maxY - size.height, width: size.width, height: size.height),
            display: true
        )
    }

    private func screensChanged() {
        brightness.updateDisplay()
        let geometry = NotchGeometry(screen: NotchGeometry.preferredScreen())
        guard geometry != model.geometry else { return }
        withoutAnimation { model.geometry = geometry }
        placeWindow()
    }

    private func applyPreferences(force: Bool = false) {
        if model.showsStatusDetail != status.prefs.islandGauges {
            withAnimation(Self.open) { model.showsStatusDetail = status.prefs.islandGauges }
        }
        let new = IslandPreferences.current
        let old = preferences
        guard force || new != old else { return }
        preferences = new
        if force || new.nowPlaying != old.nowPlaying {
            new.nowPlaying ? media.start() : media.stop()
        }
        if force || new.devices != old.devices {
            new.devices ? bluetooth.start() : bluetooth.stop()
        }
        if force || new.levels != old.levels {
            new.levels ? takeOverKeys() : releaseKeys()
        }
        if force || new.reminders != old.reminders {
            scheduleNextReminder()
        }
        if force || new.taskStyle != old.taskStyle {
            closeTaskList()
            model.taskStyle = new.taskStyle
            model.cardMode = .capsule
            // The glass capsule and panel follow the system look; the merged list is dark like the island.
            panel.appearance = new.taskStyle == .merged ? NSAppearance(named: .darkAqua) : nil
            scheduleCardFade()
        }
        updateLiveActivity()
    }
}
