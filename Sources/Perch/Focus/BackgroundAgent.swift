import AppKit
import ServiceManagement

/// Keep alive: launchd watches Perch and relaunches it within seconds after Activity Monitor,
/// Force Quit or `killall` ends it. Quitting from the menu (exit code 0) stays quit.
///
/// Only one Perch may run at a time (or two sets of everything would appear):
/// - with the agent on, the instance launchd started is the one, and closes any others;
/// - an instance started otherwise (from Finder, after an update) asks the agent to restart and
///   take over, then quits.
enum BackgroundAgent {
    static let label = "app.perch.Perch.agent"
    /// For tests and hand-overs: don't hand off on this launch.
    static let skipHandOffArgument = "--skip-handoff"

    private static var service: SMAppService { .agent(plistName: "\(label).plist") }

    static var isEnabled: Bool { service.status == .enabled }
    static var needsApproval: Bool { service.status == .requiresApproval }

    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// Whether launchd started this instance.
    static var launchedByAgent: Bool {
        ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == label
    }

    private static var otherInstances: [NSRunningApplication] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != ownPID }
    }

    // MARK: At launch

    /// Makes sure exactly one instance is left running.
    static func settleInstances() {
        if launchedByAgent {
            closeOtherInstances()
        } else {
            handOffIfNeeded()
        }
    }

    /// The agent is on but this launch came from Finder or an update: have the agent restart (so the
    /// new build is the one running) and quit, but only once the other instance is really up.
    private static func handOffIfNeeded() {
        guard isEnabled, !CommandLine.arguments.contains(skipHandOffArgument) else { return }
        launchctl(["kickstart", "-k", "gui/\(getuid())/\(label)"])
        let deadline = Date.now.addingTimeInterval(4)
        while Date.now < deadline {
            if !otherInstances.isEmpty { exit(0) }
            Thread.sleep(forTimeInterval: 0.2)
        }
    }

    /// Others refuse to quit during a strict schedule, so they're forced after two seconds (they
    /// aren't the agent's, so nothing brings them back).
    private static func closeOtherInstances() {
        let others = otherInstances
        guard !others.isEmpty else { return }
        others.forEach { $0.terminate() }
        Task {
            try? await Task.sleep(for: .seconds(2))
            others.filter { !$0.isTerminated }.forEach { $0.forceTerminate() }
        }
    }

    // MARK: Switching

    /// launchd starts the agent's instance right away and it closes this one. The agent also starts
    /// Perch at login, so the plain login item goes, or Perch would start twice.
    static func enable() throws {
        try service.register()
        if SMAppService.mainApp.status == .enabled { try? SMAppService.mainApp.unregister() }
    }

    /// Unregistering ends the instance the agent started, so a plain one starts first to take over.
    /// The login item the agent replaced comes back.
    static func disable() {
        try? SMAppService.mainApp.register()
        guard launchedByAgent else {
            try? service.unregister()
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = false
        configuration.arguments = [skipHandOffArgument]
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            Task { @MainActor in
                try? await service.unregister()
                // launchd usually ends this instance on unregistering; if not, leave.
                try? await Task.sleep(for: .seconds(1.5))
                exit(0)
            }
        }
    }

    @discardableResult
    private static func launchctl(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
