import Foundation

enum Pref {
    static let pinned = "pinned"
    static let peekOnHover = "peekOnHover"
    static let fadeWhenIdle = "fadeWhenIdle"
    static let idleOpacity = "idleOpacity"
    static let pillOrigin = "pillOrigin"

    static func register() {
        UserDefaults.standard.register(defaults: [
            pinned: true,
            peekOnHover: true,
            fadeWhenIdle: true,
            idleOpacity: 0.6,
        ])
    }
}
