import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = AppSettings.shared
    let store = TaskStore()
    let model = PanelModel()
    let swipe = SwipeTracker()
    private(set) var controller: PanelController?
    private(set) var island: IslandController?
    private var hotKey: GlobalHotKey?
    private let reminders = ReminderScheduler()
    private var settingsWindow: NSWindow?
    private var settingsTabs: NSTabViewController?
    private var defaultsObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Pref.register()

        let controller = PanelController(store: store, model: model, swipe: swipe, settings: settings)
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

        model.settingsHandler = { [weak self] in self?.showSettings(.tasks) }

        applyIslandPreference()
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyIslandPreference() }
        }

        let updater = Updater.shared
        updater.onUpdateFound = { [weak self] release in
            self?.store.announce(tr("Perch \(release.version) 可以更新了，在 ⋯ 菜单中安装", "Perch \(release.version) is available. Install it from the ⋯ menu"), undo: nil)
        }
        updater.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.saveNow()
    }

    /// Settings is a window of pages under a toolbar of tabs, each page as tall as its content.
    func showSettings(_ tab: SettingsTab = .general) {
        if settingsWindow == nil {
            let tabs = NSTabViewController()
            tabs.tabStyle = .toolbar
            for page in SettingsTab.allCases {
                let hosting = NSHostingController(rootView: SettingsPane(tab: page).environment(settings).environment(Updater.shared))
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
            let island = IslandController(store: store, swipe: swipe)
            island.onOpenSettings = { [weak self] tab in self?.showSettings(tab) }
            self.island = island
        } else if !enabled, let island {
            island.shutdown()
            self.island = nil
        }
        controller?.setSuspended(island != nil && TaskStyle.current != .floating)
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
