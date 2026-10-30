import AppKit
import SwiftUI

/// Focus in a menu: start a session, or open the schedules.
struct FocusMenuItems: View {
    @Environment(FocusController.self) private var focus

    var body: some View {
        Button(tr("开始专注", "Start Focus")) { focus.startSession(fromMenu: true) }
            .keyboardShortcut("f", modifiers: [.command, .option])
        Button(tr("时段…", "Schedules…")) { SchedulesWindowController.shared.show() }
    }
}

/// Quit, except while a strict schedule runs.
struct QuitMenuItem: View {
    var body: some View {
        let locked = ScheduleStore.shared.hasStrictRuleActive
        Button(locked ? tr("严格时段中，暂不能退出", "Strict Schedule Running") : tr("退出 Perch", "Quit Perch")) {
            NSApp.terminate(nil)
        }
        .disabled(locked)
    }
}
