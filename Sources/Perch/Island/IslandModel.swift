import AppKit
import SwiftUI

/// Where the island lives: a screen and the camera housing it hangs from.
struct NotchGeometry: Equatable {
    var screenFrame: CGRect
    /// The hardware notch, or a virtual one in the middle of the menu bar on screens without one.
    var notchSize: CGSize
    var hasNotch: Bool

    init(screen: NSScreen?) {
        guard let screen else {
            screenFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
            notchSize = CGSize(width: 150, height: 24)
            hasNotch = false
            return
        }
        screenFrame = screen.frame
        if screen.safeAreaInsets.top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            notchSize = CGSize(width: right.minX - left.maxX, height: screen.safeAreaInsets.top)
            hasNotch = true
        } else {
            let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
            notchSize = CGSize(width: 150, height: menuBar > 0 ? menuBar : 24)
            hasNotch = false
        }
    }

    /// The built-in display while it has a notch (and the lid is open), otherwise the menu bar screen.
    static func preferredScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.screens.first
    }
}

/// Where today's tasks show while the island is on.
enum TaskStyle: String, CaseIterable {
    /// A glass capsule hanging under the island, widening and moving with it.
    case capsule
    /// Inside the island itself: beside the notch, in its open view, and as a black list.
    case merged
    /// The original floating pill, wherever it was put.
    case floating

    static var current: TaskStyle {
        UserDefaults.standard.string(forKey: Pref.islandTaskStyle).flatMap(TaskStyle.init(rawValue:)) ?? .capsule
    }
}

/// The glass card under the island: the capsule (capsule style), and what it opens into.
enum CardMode: Equatable {
    case capsule, peek, panel
}

/// The detail under the status page's gauges.
enum StatusMetric: Equatable {
    case cpu, memory, temperature, network
}

enum ReminderAction {
    case complete, snooze
}

enum LevelKind: Equatable {
    case volume, brightness, keyboard
}

struct LevelHUD: Equatable {
    var kind: LevelKind
    var value: Double
    var isMuted = false
    var route: AudioRoute?

    var isSilent: Bool { kind == .volume && (isMuted || value < 0.001) }
}

/// A short-lived message from the island.
enum IslandBanner: Equatable {
    case level(LevelHUD)
    case device(BluetoothDevice, connected: Bool)
    case power(PowerEvent)
    case route(AudioRoute)
    case track
    case reminder(TaskItem, alsoDue: Int)
    case alert(SystemAlert)

    enum Kind: Equatable {
        case level, device, power, route, track, reminder, alert
    }

    /// Banners of the same kind update in place instead of closing and reopening.
    var kind: Kind {
        switch self {
        case .level: .level
        case .device: .device
        case .power: .power
        case .route: .route
        case .track: .track
        case .reminder: .reminder
        case .alert: .alert
        }
    }

    /// What still shows while the focus blur is up: a key the user pressed, a task falling due.
    var passesCurtain: Bool {
        switch kind {
        case .level, .reminder: true
        case .device, .power, .route, .track, .alert: false
        }
    }

    /// Status stretches out sideways at the notch's own height, like the HUDs do; messages with more
    /// to say drop down below it.
    var dropsDown: Bool {
        switch kind {
        case .track, .reminder, .alert: true
        case .level, .device, .power, .route: false
        }
    }
}

/// What sits in the wings beside the notch while nothing else is going on.
struct LiveActivity: Equatable {
    enum Leading: Equatable {
        case artwork, progress
        /// The screen is locked; `unlocked` plays for a moment as it opens.
        case locked, unlocked
        /// A paused app or site let through for a few minutes: its icon in the ring of time left.
        case pass
    }

    enum Trailing: Equatable {
        case equalizer, due, focus
        /// The pass's minutes and seconds.
        case countdown
    }

    var leading: Leading?
    var trailing: Trailing?

    /// Times need a little more room than icons.
    var wing: CGFloat {
        switch trailing {
        case .due, .focus, .countdown: 60
        case .equalizer, nil: 44
        }
    }
}

/// The open island's pages, one above the other: what's playing (or today's tasks in merged
/// style), then the Mac's status. A two-finger swipe moves between them.
enum IslandPage: Equatable {
    case main, status

    /// The pages there are right now. Without anything playing (or tasks inside the island) the
    /// status is the only page; on the lock screen only the first one shows.
    static func available(hasMain: Bool, gauges: Bool, locked: Bool) -> [IslandPage] {
        if locked { return [hasMain ? .main : .status] }
        var pages: [IslandPage] = hasMain ? [.main] : []
        if gauges || !hasMain { pages.append(.status) }
        return pages
    }
}

/// A light that passes once along the island's lower lip.
enum IslandGlow: Equatable {
    case charging, celebration, lowBattery
    /// Something about the Mac needs a look: running hot, short of memory or disk.
    case alert
}

enum IslandState: Equatable {
    /// Just the notch.
    case idle
    /// Small status beside the notch: Now Playing, today's tasks.
    case live(LiveActivity)
    case banner(IslandBanner)
    case expanded
    /// The full task list, grown down out of the notch.
    case tasks
}

/// The island's outline for one state. `width` includes the shoulders that flare into the menu bar.
struct IslandLayout: Equatable {
    var width: CGFloat
    var height: CGFloat
    var shoulder: CGFloat
    var cornerRadius: CGFloat
    var shadowOpacity: Double
    var isHidden = false

    init(body: CGSize, shoulder: CGFloat, cornerRadius: CGFloat, shadowOpacity: Double, isHidden: Bool = false) {
        width = body.width + shoulder * 2
        height = body.height
        self.shoulder = shoulder
        self.cornerRadius = cornerRadius
        self.shadowOpacity = shadowOpacity
        self.isHidden = isHidden
    }
}

@Observable
final class IslandModel {
    /// How far status banners reach out beside the notch.
    static let bannerWing: CGFloat = 104
    static let bannerDrop: CGFloat = 44
    /// About Alcove's proportions: twice the notch wide, a little over five notches tall with today's
    /// tasks in it (merged style), shorter when it only holds the player.
    static let expandedExtraWidth: CGFloat = 180
    static let expandedDrop: CGFloat = 144
    static let playerDrop: CGFloat = 100
    /// The task list under the notch; the panel view itself is 368 wide.
    static let taskPanel = CGSize(width: 372, height: 528)
    static let windowMargin: CGFloat = 40
    static let capsuleGap: CGFloat = 6
    static let capsuleHeight: CGFloat = 34
    static let capsuleHoverHeight: CGFloat = 46
    static let capsuleMinWidth: CGFloat = 196
    static let peekRowHeight: CGFloat = 34
    static let panelSize = CGSize(width: 368, height: 560)
    /// The open island on its status page: gauges and a detail strip under them.
    static let statusDrop: CGFloat = 174
    /// The status page is a little wider than the player, so its four gauges have room.
    static let statusExtraWidth: CGFloat = 36

    var geometry: NotchGeometry
    var isExpanded = false
    var isShowingTasks = false
    var banner: IslandBanner?
    var live: LiveActivity?
    var isHovering = false
    /// A level change while the island is open shows inside it instead of as a banner.
    var inlineLevel: LevelHUD?

    var taskStyle = TaskStyle.capsule
    var cardMode = CardMode.capsule
    var isCardHovering = false
    /// The capsule fades back while nobody is looking at it.
    var isCardFaded = false
    var peekRows = 0
    /// An open panel stays where it opened while the island above it changes.
    var pinnedCardTop: CGFloat?
    /// The screen is locked: the island stays on the notch but keeps tasks out of sight.
    var isLocked = false
    /// The focus blur is up: the island stays a plain notch above it and the capsule steps away.
    var isCurtained = false
    /// Another app has a menu open; the island's space sits above menus, so the capsule steps aside.
    var isMenuOpen = false
    var glow: IslandGlow?
    /// A sideways kick of the artwork when a swipe changes the track: -1 left, 1 right.
    var mediaNudge: CGFloat = 0
    /// How far the capsule's task has been swiped: right completes, left moves it to tomorrow.
    var capsuleSwipe: CGFloat = 0
    var statusMetric = StatusMetric.cpu
    /// The status page has its gauges and details (Settings › Status).
    var showsStatusDetail = true
    var page = IslandPage.main
    /// The last page change went to the page below, so the new one comes up from the bottom.
    var pageMovesForward = true

    @ObservationIgnored var expandHandler: (() -> Void)?
    @ObservationIgnored var levelHandler: ((LevelKind, Double) -> Void)?
    @ObservationIgnored var reminderHandler: ((UUID, ReminderAction) -> Void)?
    /// Opens the full task list; true also focuses the new-task field.
    @ObservationIgnored var tasksHandler: ((Bool) -> Void)?
    @ObservationIgnored var settingsHandler: ((SettingsTab) -> Void)?
    /// Opens the island on its status page.
    @ObservationIgnored var statusHandler: (() -> Void)?
    /// Shows a gauge's detail on the status page.
    @ObservationIgnored var metricHandler: ((StatusMetric) -> Void)?
    /// Moves the open island to a page.
    @ObservationIgnored var pageHandler: ((IslandPage) -> Void)?
    /// The action on an alert banner: quit the runaway process, or look at the status.
    @ObservationIgnored var alertHandler: ((SystemAlert) -> Void)?

    init(geometry: NotchGeometry) {
        self.geometry = geometry
    }

    var state: IslandState {
        if isShowingTasks { return .tasks }
        if isExpanded { return .expanded }
        if let banner { return .banner(banner) }
        if let live { return .live(live) }
        return .idle
    }

    var layout: IslandLayout { layout(for: state, hovering: isHovering) }

    func layout(for state: IslandState, hovering: Bool) -> IslandLayout {
        let notch = geometry.notchSize
        switch state {
        // A glow swells the island a little, so the light runs outside the camera housing instead
        // of half behind it.
        case .idle where hovering || glow != nil:
            return IslandLayout(body: CGSize(width: notch.width + 18, height: notch.height + 6), shoulder: 6, cornerRadius: 13, shadowOpacity: 0.3)
        case .idle:
            // Exactly the camera housing, so it disappears into it.
            return IslandLayout(body: notch, shoulder: 0, cornerRadius: 10, shadowOpacity: 0, isHidden: !geometry.hasNotch)
        case .live(let live):
            let grow: CGFloat = hovering || glow != nil ? 10 : 0
            return IslandLayout(body: CGSize(width: notch.width + live.wing * 2 + grow, height: notch.height + grow / 3), shoulder: 6, cornerRadius: 12, shadowOpacity: 0.2)
        case .banner(let banner) where banner.dropsDown:
            return IslandLayout(body: CGSize(width: notch.width + 190, height: notch.height + Self.bannerDrop), shoulder: 10, cornerRadius: 22, shadowOpacity: 0.45)
        case .banner:
            return IslandLayout(body: CGSize(width: notch.width + Self.bannerWing * 2, height: notch.height), shoulder: 6, cornerRadius: 12, shadowOpacity: 0.3)
        case .expanded:
            // Tasks stay off the lock screen, so there it's only ever the player.
            let drop = page == .status && showsStatusDetail ? Self.statusDrop : taskStyle == .merged && !isLocked ? Self.expandedDrop : Self.playerDrop
            let wider = page == .status && showsStatusDetail ? Self.statusExtraWidth : 0
            return IslandLayout(body: CGSize(width: max(notch.width + Self.expandedExtraWidth, 340) + wider, height: notch.height + drop), shoulder: 12, cornerRadius: 26, shadowOpacity: 0.55)
        case .tasks:
            return IslandLayout(body: CGSize(width: Self.taskPanel.width, height: notch.height + Self.taskPanel.height), shoulder: 14, cornerRadius: 30, shadowOpacity: 0.55)
        }
    }

    /// Big enough for the largest form, and for the task panel hanging below the tallest banner,
    /// plus room for shadows.
    var windowSize: CGSize {
        let forms: [IslandState] = [.expanded, .tasks, .banner(.track), .banner(.route(.speakers))]
        let layouts = forms.map { layout(for: $0, hovering: false) }
        let lowestCardTop = layout(for: .banner(.track), hovering: false).height + Self.capsuleGap
        return CGSize(
            width: max(layouts.map(\.width).max() ?? 0, Self.panelSize.width) + Self.windowMargin * 2,
            height: max(layouts.map(\.height).max() ?? 0, lowestCardTop + Self.panelSize.height) + Self.windowMargin
        )
    }

    // MARK: - The capsule under the island

    /// The island's form at rest, without banners or its open views.
    var restState: IslandState { live.map { .live($0) } ?? .idle }

    /// Just under whatever the island shows, so it rides down when the island drops a banner or
    /// opens, and back up after; an open panel stays where it opened.
    var cardTop: CGFloat {
        pinnedCardTop ?? layout(for: state, hovering: false).height + Self.capsuleGap
    }

    /// As wide as the island at rest, so the two read as one piece; a little bigger under the pointer.
    var cardSize: CGSize {
        let rest = layout(for: restState, hovering: false)
        let width = max(rest.width - rest.shoulder * 2, Self.capsuleMinWidth)
        switch cardMode {
        case .capsule:
            return isCardHovering
                ? CGSize(width: width + 16, height: Self.capsuleHoverHeight)
                : CGSize(width: width, height: Self.capsuleHeight)
        case .peek:
            return CGSize(width: width + 16, height: Self.capsuleHoverHeight + CGFloat(max(peekRows, 1)) * Self.peekRowHeight + 10)
        case .panel:
            return Self.panelSize
        }
    }

    func expand() {
        expandHandler?()
    }
}

/// When the next timed task falls due, and which tasks fall due at that moment.
nonisolated enum ReminderClock {
    static func next(after now: Date, in tasks: [TaskItem]) -> (time: Date, tasks: [TaskItem])? {
        let upcoming = tasks.compactMap { task -> (task: TaskItem, time: Date)? in
            guard !task.isDone, let time = task.schedule?.time, time > now else { return nil }
            return (task, time)
        }
        guard let first = upcoming.map(\.time).min() else { return nil }
        return (first, upcoming.filter { $0.time == first }.map(\.task))
    }
}
