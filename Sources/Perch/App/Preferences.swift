import Foundation

enum Pref {
    static let pinned = "pinned"
    static let peekOnHover = "peekOnHover"
    static let fadeWhenIdle = "fadeWhenIdle"
    static let idleOpacity = "idleOpacity"
    static let pillOrigin = "pillOrigin"
    static let completionSound = "completionSound"
    static let celebrations = "celebrations"
    static let todayTimeline = "todayTimeline"
    static let chimeStyle = "chimeStyle"
    static let islandEnabled = "islandEnabled"
    static let islandHoverToExpand = "islandHoverToExpand"
    static let islandLevels = "islandLevels"
    static let islandNowPlaying = "islandNowPlaying"
    static let islandDevices = "islandDevices"
    static let islandBattery = "islandBattery"
    static let islandReminders = "islandReminders"
    /// Where today's tasks show while the island is on (see TaskStyle).
    static let islandTaskStyle = "islandTaskStyle"
    static let islandHaptics = "islandHaptics"
    static let islandAskedAccessibility = "islandAskedAccessibility"
    /// Volume and brightness bars take the level's color (green to orange) instead of plain white.
    static let hudColorful = "hudColorful"
    static let hudShowsValue = "hudShowsValue"
    /// Seconds a volume or brightness HUD stays after the last change.
    static let hudDuration = "hudDuration"

    static func register() {
        UserDefaults.standard.register(defaults: [
            pinned: true,
            peekOnHover: true,
            fadeWhenIdle: true,
            idleOpacity: 0.6,
            completionSound: true,
            celebrations: true,
            todayTimeline: true,
            chimeStyle: ChimeStyle.perch.rawValue,
            islandEnabled: true,
            islandHoverToExpand: true,
            islandLevels: true,
            islandNowPlaying: true,
            islandDevices: true,
            islandBattery: true,
            islandReminders: true,
            islandTaskStyle: TaskStyle.capsule.rawValue,
            islandHaptics: true,
            hudColorful: true,
            hudShowsValue: false,
            hudDuration: 1.6,
        ])
    }
}
