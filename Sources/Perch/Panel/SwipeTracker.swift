import AppKit
import SwiftUI

enum SwipeDirection {
    case complete, postpone
}

/// Turns a two-finger horizontal trackpad swipe over a task row into a row offset,
/// and commits complete / postpone once it passes the threshold.
@Observable
final class SwipeTracker {
    static let threshold: CGFloat = 72

    private(set) var rowID: UUID?
    private(set) var offset: CGFloat = 0

    @ObservationIgnored private var hoveredRowID: UUID?
    @ObservationIgnored private var candidateID: UUID?
    @ObservationIgnored private var isTracking = false
    @ObservationIgnored private var isHorizontal = false
    @ObservationIgnored private var rawOffset: CGFloat = 0
    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private let windows = NSHashTable<NSWindow>.weakObjects()
    @ObservationIgnored private var onCommit: ((UUID, SwipeDirection) -> Void)?

    func install(in window: NSWindow, onCommit: @escaping (UUID, SwipeDirection) -> Void) {
        windows.add(window)
        self.onCommit = onCommit
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }

    /// Lets the same swipes work in another window, such as the notch island's task list.
    func track(_ window: NSWindow) {
        windows.add(window)
    }

    func hover(_ id: UUID, _ hovering: Bool) {
        if hovering {
            hoveredRowID = id
        } else if hoveredRowID == id {
            hoveredRowID = nil
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let window = event.window, windows.contains(window), event.hasPreciseScrollingDeltas else { return event }

        if event.phase.contains(.began) {
            isTracking = true
            isHorizontal = false
            rawOffset = 0
            candidateID = hoveredRowID
            return event
        }

        if event.phase.contains(.changed), isTracking, let candidateID {
            let dx = event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
            let dy = event.scrollingDeltaY
            if !isHorizontal {
                if abs(dx) > abs(dy) * 1.4, abs(dx) > 1.5 {
                    isHorizontal = true
                    rowID = candidateID
                } else if abs(dy) > abs(dx) {
                    isTracking = false
                    return event
                } else {
                    return event
                }
            }
            rawOffset += dx
            offset = Self.rubberBand(rawOffset)
            return nil
        }

        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            defer { isTracking = false; isHorizontal = false }
            guard isHorizontal, let id = rowID else { return event }
            if rawOffset >= Self.threshold {
                onCommit?(id, .complete)
            } else if rawOffset <= -Self.threshold {
                onCommit?(id, .postpone)
            }
            rawOffset = 0
            withAnimation(.spring(duration: 0.35, bounce: 0.25)) { offset = 0 } completion: { [weak self] in
                if self?.offset == 0 { self?.rowID = nil }
            }
            return nil
        }

        return event
    }

    static func rubberBand(_ x: CGFloat) -> CGFloat {
        let limit: CGFloat = 110
        let magnitude = abs(x)
        guard magnitude > limit else { return x }
        let extra = magnitude - limit
        return (limit + extra * 0.25) * (x < 0 ? -1 : 1)
    }
}

enum Haptics {
    static func tick() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    static func confirm() {
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }
}
