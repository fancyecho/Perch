import AppKit

/// A private window-server space that sits above every desktop, as the menu bar does. Windows in it
/// stay put while Spaces slide past and stay over the lock screen, so the island never slides off
/// the camera housing and shows up beside it. SkyLight's calls are looked up at runtime; when one is
/// missing the island stays an ordinary all-Spaces window.
final class NotchSpace {
    private typealias ConnectionFunction = @convention(c) () -> Int32
    private typealias CreateFunction = @convention(c) (Int32, Int, CFDictionary?) -> UInt64
    private typealias LevelFunction = @convention(c) (Int32, UInt64, Int) -> Void
    private typealias SpacesFunction = @convention(c) (Int32, CFArray) -> Void
    private typealias WindowsFunction = @convention(c) (Int32, CFArray, CFArray) -> Void
    private typealias DestroyFunction = @convention(c) (Int32, UInt64) -> Void

    private let connection: Int32
    private let space: UInt64
    private let addWindows: WindowsFunction
    private let removeWindows: WindowsFunction
    private let hideSpaces: SpacesFunction
    private let destroySpace: DestroyFunction

    init?() {
        func load<T>(_ name: String, as type: T.Type) -> T? {
            dlsym(UnsafeMutableRawPointer(bitPattern: -2), name).map { unsafeBitCast($0, to: type) }
        }
        guard let defaultConnection = load("_CGSDefaultConnection", as: ConnectionFunction.self),
              let create = load("CGSSpaceCreate", as: CreateFunction.self),
              let setLevel = load("CGSSpaceSetAbsoluteLevel", as: LevelFunction.self),
              let show = load("CGSShowSpaces", as: SpacesFunction.self),
              let hide = load("CGSHideSpaces", as: SpacesFunction.self),
              let add = load("CGSAddWindowsToSpaces", as: WindowsFunction.self),
              let remove = load("CGSRemoveWindowsFromSpaces", as: WindowsFunction.self),
              let destroy = load("CGSSpaceDestroy", as: DestroyFunction.self) else { return nil }
        connection = defaultConnection()
        // 1 makes a plain space; other values have Finder draw desktop icons into it.
        space = create(connection, 1, nil)
        guard space != 0 else { return nil }
        setLevel(connection, space, Int(Int32.max))
        show(connection, [NSNumber(value: space)] as CFArray)
        addWindows = add
        removeWindows = remove
        hideSpaces = hide
        destroySpace = destroy
    }

    /// Ordering a window out and back in drops it from the space, so callers add it again after.
    func add(_ window: NSWindow) {
        addWindows(connection, [NSNumber(value: window.windowNumber)] as CFArray, [NSNumber(value: space)] as CFArray)
    }

    func remove(_ window: NSWindow) {
        removeWindows(connection, [NSNumber(value: window.windowNumber)] as CFArray, [NSNumber(value: space)] as CFArray)
    }

    isolated deinit {
        hideSpaces(connection, [NSNumber(value: space)] as CFArray)
        destroySpace(connection, space)
    }
}
