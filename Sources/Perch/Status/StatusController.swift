import AppKit
import SwiftUI
import UserNotifications

/// Status inside Perch: samples the Mac, hands its alerts to the island (or Notification Center
/// without one), and draws the optional menu bar readout, which opens the dashboard beneath it.
@Observable
final class StatusController {
    let prefs = StatusPreferences.shared
    let monitor: SystemMonitor

    /// Shows an alert on the island; false when there's no island to show it.
    @ObservationIgnored var onAlert: ((SystemAlert) -> Bool)?
    @ObservationIgnored var onOpenSettings: (() -> Void)?

    @ObservationIgnored private var statusItem: NSStatusItem?
    @ObservationIgnored private var panel: StatusPanel?
    @ObservationIgnored private var appearanceObservation: NSKeyValueObservation?
    @ObservationIgnored private var lastIconKey: IconKey?
    @ObservationIgnored private var darkMenuBar = true
    /// Who is showing the Mac's details right now (the island's status page, the panel).
    @ObservationIgnored private var watchers: Set<String> = []

    init() {
        monitor = SystemMonitor(prefs: prefs)
    }

    func start() {
        monitor.alerts.onAlert = { [weak self] alert in self?.deliver(alert) }
        followReadout()
    }

    /// Opens the dashboard under the readout, or under the menu bar's right end without one.
    func showPanel() {
        let panel = panel ?? makePanel()
        if let button = statusItem?.button {
            panel.toggle(below: button)
        } else if let screen = NSScreen.main {
            let corner = NSRect(x: screen.frame.maxX - 220, y: screen.visibleFrame.maxY, width: 1, height: 1)
            panel.isShown ? panel.close() : panel.show(anchor: corner, on: screen)
        }
    }

    /// Full sampling (processes, disk, Wi-Fi, latency) runs while anything shows it.
    func watch(_ watcher: String, _ watching: Bool) {
        if watching { watchers.insert(watcher) } else { watchers.remove(watcher) }
        monitor.panelVisible = !watchers.isEmpty
    }

    // MARK: Alerts

    private func deliver(_ alert: SystemAlert) {
        if onAlert?(alert) == true { return }
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.detail
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: alert.id, content: content, trigger: nil))
    }

    // MARK: Menu bar readout

    /// Redraws the readout whenever its numbers or settings change, and adds or removes it.
    private func followReadout() {
        withObservationTracking {
            updateReadout()
        } onChange: { [weak self] in
            Task { @MainActor in self?.followReadout() }
        }
    }

    private struct IconKey: Equatable {
        let values: MenuBarModel.Values
        let toggles: [Bool]
        let dark: Bool
    }

    private func updateReadout() {
        guard prefs.menuBarReadout else {
            if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
            statusItem = nil
            appearanceObservation = nil
            lastIconKey = nil
            return
        }
        let item = statusItem ?? makeStatusItem()
        // Only what's shown counts: a hidden number changing needn't redraw anything.
        var shown = monitor.menuBar.values
        if !prefs.showCPU { shown.cpu = 0 }
        if !prefs.showMemory { shown.memory = 0 }
        if !prefs.showGPU { shown.gpu = nil }
        if !prefs.showNetwork { shown.up = ""; shown.down = "" }
        if !prefs.showTemperature { shown.temperature = nil }
        if !prefs.showBattery { shown.battery = nil; shown.charging = false; shown.lowPower = false }
        let key = IconKey(values: shown,
                          toggles: [prefs.showCPU, prefs.showMemory, prefs.showGPU, prefs.showNetwork, prefs.showBattery, prefs.showTemperature],
                          dark: darkMenuBar)
        guard key != lastIconKey else { return }
        lastIconKey = key
        // In Low Power Mode the battery is yellow, which a template image can't be, so then it's
        // drawn in the menu bar's own ink.
        let colored = prefs.showBattery && shown.battery != nil && shown.lowPower
        let ink: NSColor = colored && darkMenuBar ? .white : .black
        let fill: NSColor = colored ? NSColor(red: 1.0, green: 0.8, blue: 0.0, alpha: 1) : ink
        let image = MenuBarRenderer.render(values: shown, prefs: prefs, ink: ink, batteryFill: fill)
        image.isTemplate = !colored
        item.button?.image = image
    }

    private func makeStatusItem() -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.imagePosition = .imageOnly
        item.button?.target = self
        item.button?.action = #selector(readoutClicked)
        item.button?.setAccessibilityLabel(tr("系统状态", "System Status"))
        // Setting the image fires the appearance observation too, so only a real switch between
        // light and dark redraws.
        appearanceObservation = item.button?.observe(\.effectiveAppearance) { [weak self] button, _ in
            MainActor.assumeIsolated {
                let dark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                guard let self, dark != self.darkMenuBar else { return }
                self.darkMenuBar = dark
                self.updateReadout()
            }
        }
        statusItem = item
        return item
    }

    @objc private func readoutClicked() {
        showPanel()
    }

    private func makePanel() -> StatusPanel {
        let panel = StatusPanel(rootView: StatusDashboard { [weak self] in
            self?.panel?.close()
            self?.onOpenSettings?()
        }
        .environment(monitor)
        .environment(prefs)
        .environment(AppSettings.shared))
        panel.onVisibilityChange = { [weak self] visible in
            guard let self else { return }
            statusItem?.button?.highlight(visible)
            if visible {
                // Sample at full rate once the unfolding has mostly finished, so it doesn't stutter.
                Task {
                    try? await Task.sleep(for: .milliseconds(350))
                    if self.panel?.isShown == true { self.watch("panel", true) }
                }
            } else {
                watch("panel", false)
                Task {
                    try? await Task.sleep(for: .milliseconds(200))
                    if self.panel?.isShown != true { self.prefs.page = .overview }
                }
            }
        }
        panel.onEscape = { [weak self] in
            guard let self, prefs.page != .overview else { return false }
            prefs.page = .overview
            return true
        }
        self.panel = panel
        return panel
    }
}
