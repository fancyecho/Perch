import SwiftUI

@main
struct PerchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Perch", systemImage: "bird") {
            MenuBarContent(app: appDelegate)
                .environment(AppSettings.shared)
                .environment(Updater.shared)
        }
    }
}

private struct MenuBarContent: View {
    let app: AppDelegate
    @Environment(AppSettings.self) private var settings
    @Environment(Updater.self) private var updater
    @AppStorage(Pref.pinned) private var pinned = true

    var body: some View {
        Button(tr("打开面板", "Open Panel")) { app.controller?.go(.panel, focusInput: true) }
            .keyboardShortcut(settings.hotKey?.keyboardShortcut)
        Toggle(tr("始终置顶", "Always on Top"), isOn: $pinned)
        Divider()
        Button(tr("设置…", "Settings…")) { app.showSettings() }
            .keyboardShortcut(",")
        if let release = updater.availableRelease {
            Button(tr("安装更新 \(release.version)…", "Install Update \(release.version)…")) {
                Task { await updater.install(release) }
            }
        } else {
            Button(tr("检查更新…", "Check for Updates…")) {
                app.showSettings()
                Task { await updater.check(userInitiated: true) }
            }
        }
        Button(tr("退出 Perch", "Quit Perch")) { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
