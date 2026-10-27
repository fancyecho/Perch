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
        ])
    }
}
