import Foundation

enum Pref {
    static let pinned = "pinned"
    static let peekOnHover = "peekOnHover"
    static let fadeWhenIdle = "fadeWhenIdle"
    static let idleOpacity = "idleOpacity"
    /// The capsule under the notch draws itself in to a short bar while nobody looks at it.
    static let capsuleRests = "capsule.restsAsBar"
    /// A firefly on the resting bar while you focus or have tasks left today.
    static let capsuleFirefly = "capsule.firefly"
    static let pillOrigin = "pillOrigin"
    static let completionSound = "completionSound"
    static let celebrations = "celebrations"
    static let todayTimeline = "todayTimeline"
    /// The color a task wears when nothing else picks one (a TaskColor raw value).
    static let taskDefaultColor = "task.defaultColor"
    /// Tasks recognized from their title (running, meetings, study…) take that kind's color.
    static let taskTopicColors = "task.topicColors"
    static let chimeStyle = "chimeStyle"
    /// Reminders at the start and at the end of a timed task's block (Settings › Tasks).
    static let remindAtStart = "reminders.atStart"
    static let remindAtEnd = "reminders.atEnd"
    /// Each evening, a look at what's left of the day: done, or on to tomorrow.
    static let reviewEnabled = "review.enabled"
    /// When, in minutes after midnight.
    static let reviewTime = "review.time"
    /// How much of the day the Today timeline spans as a rule, in minutes after midnight.
    static let timelineStart = "timeline.dayStart"
    static let timelineEnd = "timeline.dayEnd"
    /// The day the evening review was waved away ("2026-11-10"), so it stays away until tomorrow.
    static let reviewDismissedDay = "review.dismissedDay"
    static let islandEnabled = "islandEnabled"
    /// The screenshot line along the top of the screen (adapted from Tendedero).
    static let lineEnabled = "line.enabled"
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
    /// The time in the capsule, taking turns with the task (see CapsuleClockMode), in Dayline's styles.
    static let clockMode = "clock.mode"
    static let clockShowsDate = "clock.showsDate"
    static let clockShowsWeekday = "clock.showsWeekday"
    static let clockUses24Hour = "clock.uses24Hour"
    static let clockWideTracking = "clock.wideTracking"
    static let clockEmphasizesTime = "clock.emphasizesTime"
    static let clockRollsDigits = "clock.rollsDigits"
    /// "system", "zh" or "en": the time can read in English while the rest is Chinese.

    static func register() {
        UserDefaults.standard.register(defaults: [
            pinned: true,
            peekOnHover: true,
            fadeWhenIdle: true,
            idleOpacity: 0.6,
            capsuleRests: true,
            capsuleFirefly: true,
            completionSound: true,
            celebrations: true,
            todayTimeline: true,
            taskDefaultColor: TaskColor.coral.rawValue,
            taskTopicColors: true,
            chimeStyle: ChimeStyle.perch.rawValue,
            remindAtStart: false,
            remindAtEnd: true,
            reviewEnabled: true,
            reviewTime: 21 * 60 + 30,
            timelineStart: 7 * 60,
            timelineEnd: 23 * 60,
            islandEnabled: true,
            lineEnabled: true,
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
            clockMode: CapsuleClockMode.onTheMinute.rawValue,
            clockShowsDate: true,
            clockShowsWeekday: true,
            clockUses24Hour: true,
            clockWideTracking: true,
            clockEmphasizesTime: false,
            clockRollsDigits: true,
        ])
    }
}
