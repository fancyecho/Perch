import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = AppSettings.shared
    let store = TaskStore()
    let model = PanelModel()
    let swipe = SwipeTracker()
    let focus = FocusController()
    let status = StatusController()
    private(set) var controller: PanelController?
    private(set) var island: IslandController?
    private var hotKey: GlobalHotKey?
    private let reminders = ReminderScheduler()
    private var settingsWindow: NSWindow?
    private var settingsTabs: NSTabViewController?
    private var defaultsObserver: NSObjectProtocol?
    private var debugObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // With keep-alive on, only the instance launchd started stays.
        BackgroundAgent.settleInstances()
        Pref.register()
        FocusImport.runOnce()
        DaylineImport.runOnce()

        let controller = PanelController(store: store, model: model, swipe: swipe, settings: settings, focus: focus)
        self.controller = controller

        swipe.install(in: controller.panel) { [weak self] id, direction in
            guard let store = self?.store else { return }
            Haptics.confirm()
            withAnimation(.snappy) {
                switch direction {
                case .complete: store.complete(id)
                case .postpone: store.postponeToTomorrow(id)
                }
            }
        }

        let hotKey = GlobalHotKey { [weak self] in self?.toggleTasks() }
        self.hotKey = hotKey
        settings.hotKeyRegistrar = { [weak hotKey] combo in hotKey?.register(combo) ?? .unavailable }

        reminders.activate()
        reminders.onOpen = { [weak self] in self?.openTasks(focusInput: false) }
        reminders.sync(store.tasks)
        store.onChange = { [weak self] in
            guard let self else { return }
            reminders.sync(store.tasks)
            island?.tasksChanged()
        }
        resyncRemindersOnLocaleChange()

        store.onComplete = { [weak self] clearedToday, playsSound in
            if playsSound { Feedback.shared.taskChecked() }
            if clearedToday {
                Feedback.shared.todayCleared()
                self?.island?.celebrate()
            }
        }

        model.settingsHandler = { [weak self] tab in self?.showSettings(tab) }

        focus.focusedTask = { [weak self] in
            guard let store = self?.store, let session = store.focus else { return nil }
            return store.task(session.taskID)
        }
        focus.onCompleteTask = { [weak self] id in
            withAnimation(.snappy) { self?.store.complete(id) }
        }
        focus.onCurtainChange = { [weak self] up in self?.island?.setCurtained(up) }
        focus.onPassesChange = { [weak self] in self?.island?.focusChanged() }
        store.onFocusEnded = { [weak self] session in self?.focus.taskFocusEnded(session) }
        focus.start()

        status.onAlert = { [weak self] alert in self?.island?.showAlert(alert) ?? false }
        status.onOpenSettings = { [weak self] in self?.showSettings(.status) }
        status.start()

        applyIslandPreference()
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyIslandPreference() }
        }

        #if DEBUG
        debugObserver = installDebugHooks()
        #endif

        let updater = Updater.shared
        updater.onUpdateFound = { [weak self] release in
            self?.store.announce(tr("Perch \(release.version) 可以更新了，在 ⋯ 菜单中安装", "Perch \(release.version) is available. Install it from the ⋯ menu"), undo: nil)
        }
        updater.start()
    }

    /// A running strict schedule can't be escaped by quitting (an update still gets through).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard focus.blocksQuit else { return .terminateNow }
        NSSound.beep()
        return .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        focus.shutdown()
        store.saveNow()
    }

    /// Settings is a window of pages under a toolbar of tabs, each page as tall as its content.
    func showSettings(_ tab: SettingsTab = .general) {
        if settingsWindow == nil {
            let tabs = NSTabViewController()
            tabs.tabStyle = .toolbar
            for page in SettingsTab.allCases {
                let hosting = NSHostingController(rootView: SettingsPane(tab: page)
                    .environment(settings)
                    .environment(Updater.shared)
                    .environment(focus))
                hosting.sizingOptions = .preferredContentSize
                hosting.title = page.title
                let item = NSTabViewItem(viewController: hosting)
                item.label = page.title
                item.image = NSImage(systemSymbolName: page.symbol, accessibilityDescription: page.title)
                tabs.addTabViewItem(item)
            }
            tabs.selectedTabViewItemIndex = tab.rawValue
            let window = NSWindow(contentViewController: tabs)
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            // Come to whichever Space is in front, even over a full-screen app.
            window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            window.center()
            settingsTabs = tabs
            settingsWindow = window
        }
        settingsTabs?.selectedTabViewItemIndex = tab.rawValue
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    /// Opens today's tasks wherever they live: in the notch island, or the floating panel.
    func openTasks(focusInput: Bool) {
        if let island, island.hostsTasks {
            island.openTaskList(focusInput: focusInput)
        } else {
            controller?.go(.panel, focusInput: focusInput)
        }
    }

    /// The Mac's status: the island's status page, or the panel under the menu bar without the island.
    func openStatus() {
        if let island {
            island.openStatus()
        } else {
            status.showPanel()
        }
    }

    func toggleTasks() {
        if let island, island.hostsTasks {
            island.toggleTaskList()
        } else {
            controller?.toggle()
        }
    }

    /// The notch island comes and goes with its setting. While it holds today's tasks (as a capsule
    /// or inside itself) the floating pill steps aside, and while it shows reminders itself, the
    /// system notifications go quietly to Notification Center.
    private func applyIslandPreference() {
        let enabled = UserDefaults.standard.bool(forKey: Pref.islandEnabled)
        if enabled, island == nil {
            let island = IslandController(store: store, swipe: swipe, focus: focus, status: status)
            island.onOpenSettings = { [weak self] tab in self?.showSettings(tab) }
            island.setCurtained(focus.isCurtained)
            self.island = island
        } else if !enabled, let island {
            island.shutdown()
            self.island = nil
        }
        controller?.setSuspended(island != nil && TaskStyle.current != .floating)
        focus.islandShowsPasses = island != nil
        let quiet = island != nil && UserDefaults.standard.bool(forKey: Pref.islandReminders)
        if reminders.deliversQuietly != quiet {
            reminders.deliversQuietly = quiet
            reminders.sync(store.tasks)
        }
    }

    /// Notification text is localized and shows times in the selected zone, so rebuild it on change.
    private func resyncRemindersOnLocaleChange() {
        withObservationTracking {
            _ = settings.isChinese
            _ = settings.calendar
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.reminders.sync(self.store.tasks)
                for (index, item) in (self.settingsTabs?.tabViewItems ?? []).enumerated() {
                    item.label = SettingsTab(rawValue: index)?.title ?? item.label
                    item.viewController?.title = item.label
                }
                self.resyncRemindersOnLocaleChange()
            }
        }
    }
}
