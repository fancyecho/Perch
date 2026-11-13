import PerchLine
import SwiftUI

@main
struct PerchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Perch", systemImage: "bird") {
            MenuBarContent(app: appDelegate)
                .environment(AppSettings.shared)
                .environment(Updater.shared)
                .environment(appDelegate.focus)
        }
    }
}

private struct MenuBarContent: View {
    let app: AppDelegate
    @Environment(AppSettings.self) private var settings
    @Environment(Updater.self) private var updater
    @AppStorage(Pref.pinned) private var pinned = true
    @AppStorage(Pref.islandEnabled) private var islandEnabled = true

    var body: some View {
        Button(tr("打开面板", "Open Panel")) { app.openTasks(focusInput: true) }
            .keyboardShortcut(settings.hotKey?.keyboardShortcut)
        Toggle(tr("始终置顶", "Always on Top"), isOn: $pinned)
        Toggle(tr("刘海灵动岛", "Notch Island"), isOn: $islandEnabled)
        Divider()
        FocusMenuItems()
        if let line = app.line {
            Menu(tr("晾衣绳", "Line")) {
                Button(tr("显示 / 隐藏", "Show / Hide")) { line.toggleLine() }
                Picker(tr("新截图挂到", "New Screenshots Hang On"), selection: Binding(get: { line.targetSide }, set: { line.targetSide = $0 })) {
                    Text(tr("左边 ·「\(line.name(of: .left))」", "Left · \(line.name(of: .left))")).tag(LineSide.left)
                    Text(tr("右边 ·「\(line.name(of: .right))」", "Right · \(line.name(of: .right))")).tag(LineSide.right)
                }
                Button(tr("全部取下", "Take Everything Down")) { line.takeEverythingDown() }
                    .disabled(line.isEmpty)
                Button(tr("挂回刚取下的", "Put Back")) { line.putBackLast() }
                    .disabled(!line.canPutBack)
                if line.holdsAny {
                    Button(tr("全部放回绳上", "Hang Everything Back")) { line.hangEverythingBack() }
                }
                Divider()
                Button(tr("晾衣绳设置…", "Line Settings…")) { app.showSettings(.line) }
            }
        }
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
        QuitMenuItem()
            .keyboardShortcut("q")
    }
}
