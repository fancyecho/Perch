import SwiftUI

/// Scrolls the task list while a task is carried to its top or bottom edge, so it can be taken
/// to any time of the day, not just the part on screen. The list owns one and hands it down; a
/// dragged row reports where the pointer is and reads how far the list has scrolled.
@MainActor @Observable
final class TimelineScroller {
    /// How far the list is scrolled. Rows read it only while they're being dragged.
    private(set) var offset: CGFloat = 0

    @ObservationIgnored private var range: ClosedRange<CGFloat> = 0...0
    /// The list's frame on screen, in window coordinates.
    @ObservationIgnored var viewport: CGRect = .zero
    @ObservationIgnored var scrollTo: ((CGFloat) -> Void)?
    /// Points per second; negative is up.
    @ObservationIgnored private var speed: CGFloat = 0
    @ObservationIgnored private var loop: Task<Void, Never>?

    /// Within this distance of an edge the list starts to scroll, faster the closer it gets.
    static let edge: CGFloat = 44
    static let topSpeed: CGFloat = 720

    func update(offset: CGFloat, range: ClosedRange<CGFloat>) {
        self.range = range
        if offset != self.offset { self.offset = offset }
    }

    /// Where the pointer is, in window coordinates, as a task is carried.
    func follow(pointer y: CGFloat) {
        guard viewport.height > Self.edge * 3 else { return stop() }
        let intoTop = viewport.minY + Self.edge - y
        let intoBottom = y - (viewport.maxY - Self.edge)
        speed = if intoTop > 0 {
            -Self.speed(depth: intoTop)
        } else if intoBottom > 0 {
            Self.speed(depth: intoBottom)
        } else {
            0
        }
        if speed != 0, loop == nil { run() }
    }

    func stop() {
        speed = 0
        loop?.cancel()
        loop = nil
    }

    /// Eases in across the edge band and tops out once the pointer is past the edge.
    static func speed(depth: CGFloat) -> CGFloat {
        let share = min(depth / edge, 1.4) / 1.4
        return 60 + (topSpeed - 60) * share * share
    }

    private func run() {
        loop = Task { [weak self] in
            var last = ContinuousClock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(16))
                guard let self, self.speed != 0 else { break }
                let now = ContinuousClock.now
                let seconds = CGFloat((now - last) / .seconds(1))
                last = now
                let target = min(max(self.offset + self.speed * seconds, self.range.lowerBound), self.range.upperBound)
                if target != self.offset { self.scrollTo?(target) }
            }
            // A cancelled loop may already have been replaced by a newer one.
            if !Task.isCancelled { self?.loop = nil }
        }
    }
}
