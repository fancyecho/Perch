import AppKit
import ServiceManagement

/// Keep alive: launchd watches Perch and relaunches it within seconds after Activity Monitor,
/// Force Quit or `killall` ends it. Quitting from the menu (exit code 0) stays quit.
///
/// Only one Perch may run at a time (or two sets of everything would appear):
/// - with the agent on, the instance launchd started is the one, and closes any others;
/// - an instance started otherwise (from Finder, after an update) asks the agent to restart and
///   take over, and carries on meanwhile; the agent's instance closes it once it's up.
enum BackgroundAgent {
    nonisolated static let label = "app.perch.Perch.agent"
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

    /// The agent is on but this launch came from Finder or an update: have the agent restart, so the
    /// new build is the one running. Nothing waits for it: this instance starts up as usual and the
    /// agent's closes it once it's up, and if the agent can't start, this one simply stays. (It used
    /// to wait on the main thread for the hand-over, which froze every launch for seconds whenever
    /// the agent couldn't start.)
    private static func handOffIfNeeded() {
        guard isEnabled, !CommandLine.arguments.contains(skipHandOffArgument) else { return }
        let stale = UserDefaults.standard.string(forKey: registeredBuildKey) != buildFingerprint
        Task.detached(priority: .utility) {
            if stale {
                // launchd checks the agent against the app it was registered from; after an update
                // (a new signature) it refuses to start it until it's registered again. Registering
                // starts it, so there's nothing to kick.
                await reregister()
            } else {
                launchctl(["kickstart", "-k", "gui/\(getuid())/\(label)"])
            }
        }
    }

    private static let registeredBuildKey = "focus.agentRegisteredBuild"

    /// Changes with every build, signed differently or not.
    nonisolated private static var buildFingerprint: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        let modified = Bundle.main.executableURL
            .flatMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
        return "\(version)-\(Int(modified?.timeIntervalSince1970 ?? 0))"
    }

    nonisolated private static func reregister() async {
        let service = SMAppService.agent(plistName: "\(label).plist")
        try? await service.unregister()
        do {
            try service.register()
            await MainActor.run { UserDefaults.standard.set(buildFingerprint, forKey: registeredBuildKey) }
        } catch {
            NSLog("Perch: re-registering the keep-alive agent failed: \(error)")
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
        UserDefaults.standard.set(buildFingerprint, forKey: registeredBuildKey)
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
    nonisolated private static func launchctl(_ arguments: [String]) -> Int32 {
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
