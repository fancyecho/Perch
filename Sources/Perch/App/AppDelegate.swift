import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = AppSettings.shared
    let store = TaskStore()
    let model = PanelModel()
    let swipe = SwipeTracker()
    private(set) var controller: PanelController?
    private var hotKey: GlobalHotKey?
    private let reminders = ReminderScheduler()
    private var settingsWindow: NSWindow?

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

        let hotKey = GlobalHotKey { [weak controller] in controller?.toggle() }
        self.hotKey = hotKey
        settings.hotKeyRegistrar = { [weak hotKey] combo in hotKey?.register(combo) ?? .unavailable }

        reminders.activate()
        reminders.onOpen = { [weak controller] in controller?.go(.panel) }
        reminders.sync(store.tasks)
        store.onChange = { [weak self] in
            guard let self else { return }
            reminders.sync(store.tasks)
        }
        resyncRemindersOnLocaleChange()

        store.onComplete = { clearedToday, playsSound in
            if playsSound { Feedback.shared.taskChecked() }
            if clearedToday { Feedback.shared.todayCleared() }
        }

        model.settingsHandler = { [weak self] in self?.showSettings() }

        let updater = Updater.shared
        updater.onUpdateFound = { [weak self] release in
            self?.store.announce(tr("Perch \(release.version) 可以更新了，在 ⋯ 菜单中安装", "Perch \(release.version) is available. Install it from the ⋯ menu"), undo: nil)
        }
        updater.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.saveNow()
    }

    func showSettings() {
        if settingsWindow == nil {
            let hosting = NSHostingController(rootView: SettingsView().environment(settings).environment(Updater.shared))
            let window = NSWindow(contentViewController: hosting)
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
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
                self.resyncRemindersOnLocaleChange()
            }
        }
    }
}
