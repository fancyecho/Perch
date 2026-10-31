#if DEBUG
import AppKit
import SwiftUI

/// Lets a script drive Perch while developing, for screenshots of states that otherwise need the
/// pointer: `swift scripts/poke.swift status`. Debug builds only.
extension AppDelegate {
    func installDebugHooks() -> NSObjectProtocol {
        DistributedNotificationCenter.default().addObserver(forName: .init("app.perch.debug"), object: nil, queue: .main) { [weak self] note in
            let command = note.object as? String ?? ""
            MainActor.assumeIsolated { self?.runDebugCommand(command) }
        }
    }

    private func runDebugCommand(_ command: String) {
        let parts = command.split(separator: ":").map(String.init)
        switch parts.first {
        case "expand": island?.expand()
        case "collapse": island?.collapse()
        case "status": island?.openStatus()
        case "close": island?.closeTaskList()
        case "panel": status.showPanel()
        case "tasks": openTasks(focusInput: false)
        case "focustab":
            island?.taskPanel.tab = .focus
            model.tab = .focus
            openTasks(focusInput: false)
        case "page": island?.showPage(parts.dropFirst().first == "status" ? .status : .main)
        case "metric":
            let metric: StatusMetric = switch parts.dropFirst().first {
            case "memory": .memory
            case "temperature": .temperature
            case "network": .network
            case "disk": .disk
            default: .cpu
            }
            island?.model.metricHandler?(metric)
        case "focus": focus.startSession()
        case "unlock": focus.debugUnlock()
        case "schedules": SchedulesWindowController.shared.show()
        case "settings":
            let tab = parts.dropFirst().first.flatMap { name in SettingsTab.allCases.first { "\($0)" == name } } ?? .general
            showSettings(tab)
        case "alert":
            _ = island?.showAlert(SystemAlert(id: "debug", kind: .hot, title: tr("CPU 温度 96°C", "CPU at 96°C"),
                                              detail: tr("已经持续一分钟以上处于高温，可以看看是哪个进程在满负荷运行。", "It has been this hot for over a minute.")))
        case "glow":
            switch parts.dropFirst().first {
            case "celebration": island?.celebrate()
            case "low": island?.debugGlow(.lowBattery)
            case "alert": island?.debugGlow(.alert)
            default: island?.debugGlow(.charging)
            }
        case "snapglow":
            // Frames of the glow's pass over a stand-in island, written next to the given path.
            let out = parts.dropFirst().joined(separator: ":")
            let shape = NotchShape(shoulder: 6, cornerRadius: 13)
            for glow in [IslandGlow.charging, .celebration] {
                for head in [0.35, 0.75, 1.1] {
                    let view = ZStack {
                        Color(white: 0.55)
                        shape.fill(.black).frame(width: 220, height: 38)
                            .overlay { GlowLight(glow: glow, shape: shape, head: head) }
                            .frame(maxHeight: .infinity, alignment: .top)
                    }
                    .frame(width: 280, height: 70)
                    let renderer = ImageRenderer(content: view)
                    renderer.scale = 2
                    if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                       let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: "\(out)-\(glow)-\(head).png"))
                    }
                }
            }
        case "snaplevels":
            // Volume and brightness bars at a few levels, written next to the given path.
            let out = parts.dropFirst().joined(separator: ":")
            let rows = VStack(alignment: .leading, spacing: 4) {
                ForEach([0.3, 0.625, 0.6875, 0.8125, 0.875, 1.0], id: \.self) { value in
                    HStack(spacing: 24) {
                        LevelBar(hud: LevelHUD(kind: .volume, value: value)).frame(width: 74)
                        LevelBar(hud: LevelHUD(kind: .brightness, value: value)).frame(width: 74)
                    }
                }
            }
            .padding(14)
            .background(Color.black)
            .environment(\.colorScheme, .dark)
            let renderer = ImageRenderer(content: rows)
            renderer.scale = 2
            if let tiff = renderer.nsImage?.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: out + "-levels.png"))
            }
        case "pass": focus.debugGrantPass(parts.dropFirst().first ?? "com.apple.Safari")
        case "endpass": focus.passes.forEach { focus.endPass($0.key) }
        case "testrule":
            // A schedule running now that pauses nothing, to see the capsule's halo.
            let now = ScheduleClock.calendar.dateComponents([.hour, .minute], from: .now)
            let minute = (now.hour ?? 0) * 60 + (now.minute ?? 0)
            ScheduleStore.shared.rules.append(BlockRule(name: "Debug", tint: 3, weekdays: Set(1...7),
                                                        windows: [TimeWindow(start: (minute + 1410) % 1440, end: (minute + 60) % 1440)], apps: []))
            island?.tasksChanged()
        case "removetestrule":
            ScheduleStore.shared.rules.removeAll { $0.name == "Debug" }
        case "closewindows":
            NSApp.windows.filter { $0.isVisible && ($0.title == tr("时段", "Schedules") || $0.contentViewController is NSTabViewController) }
                .forEach { $0.close() }
        default: NSLog("Perch debug: unknown command \(command)")
        }
    }
}

extension FocusController {
    /// A five-minute pass for an app, as if a gentle schedule had let it through.
    func debugGrantPass(_ bundleID: String) {
        let rule = BlockRule(name: "Debug", tint: 0, weekdays: Set(1...7), windows: [TimeWindow(start: 0, end: 0)], apps: [])
        schedules.grantPass(for: bundleID, rule: rule)
        onPassesChange?()
        refreshPassesForDebug()
    }
}
#endif
