import AppKit
import Combine
import SwiftUI

// MARK: The flock

/// Small birds that come to sit on the line while it is down and leave as it goes up, like on a
/// real washing line. How many, which kind, where they sit, how they come in and what they do
/// while they wait all vary, so no two visits look the same.
@MainActor
final class Flock: ObservableObject {
    @Published private(set) var birds: [Bird] = []

    /// Birds, in Settings › Line. On out of the box; Reduce Motion keeps them away.
    static var isEnabled: Bool {
        get { !UserDefaults.standard.bool(forKey: "birdsOff") }
        set { UserDefaults.standard.set(!newValue, forKey: "birdsOff") }
    }

    /// The panel's width and where clips and knots are, so birds sit between them.
    var ground: () -> (width: CGFloat, taken: [CGFloat])? = { nil }
    /// The top of the screen, in the line's coordinates: birds come from above it and leave past it.
    var ceiling: CGFloat = -40

    private var down = false
    /// When the next bird comes or goes on its own, while the line stays down.
    private var nextVisit = Double.infinity

    private static var now: Double { Date().timeIntervalSinceReferenceDate }
    private static var allowed: Bool {
        isEnabled && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// The line has come down: a few birds may come, one after another.
    func lineCameDown() {
        down = true
        let now = Self.now
        birds.removeAll { $0.isGone(at: now) }
        guard Self.allowed else { return }
        // Usually one or two, now and then none or three. Sometimes two come together.
        let roll = Double.random(in: 0..<1)
        let count = roll < 0.14 ? 0 : roll < 0.54 ? 1 : roll < 0.86 ? 2 : 3
        var delay = Double.random(in: 0.35...0.8)
        for _ in 0..<max(0, count - birds.filter { $0.departure == nil }.count) {
            if let bird = makeBird(arrivingAt: now + delay) { birds.append(bird) }
            delay += Double.random(in: 0..<1) < 0.3 ? Double.random(in: 0.05...0.2) : Double.random(in: 0.5...1.6)
        }
        nextVisit = now + Double.random(in: 6...14)
    }

    /// The line is going up. Birds on it take off, those still on their way turn back. Returns how
    /// long the line should wait so they visibly leave it first.
    func lineGoesUp() -> TimeInterval {
        down = false
        nextVisit = .infinity
        let now = Self.now
        var lead: TimeInterval = 0
        var changed = false
        defer {
            // Forgotten once they are out of sight, which lets their window go.
            DispatchQueue.main.asyncAfter(deadline: .now() + flyingTime() + 0.15) { [weak self] in self?.prune() }
        }
        birds = birds.compactMap { bird in
            if bird.arrival.start > now { changed = true; return nil }
            guard bird.departure == nil else { return bird }
            changed = true
            let start = now + Double.random(in: 0...0.07)
            if bird.isPerched(at: now) { lead = max(lead, start - now + Bird.crouch + 0.05) }
            return bird.leaving(at: start, awayFrom: nil)
        }
        return changed ? lead : 0
    }

    /// Whether any bird is still in the air, so the panel stays until it is out of sight.
    func flyingTime() -> TimeInterval {
        let now = Self.now
        return birds.compactMap { $0.departure.map { $0.start + Bird.crouch + $0.duration - now } }.max().map { max(0, $0) } ?? 0
    }

    /// Several times a second while the line is down: birds the pointer comes near fly off,
    /// gone ones are forgotten, and now and then one comes or goes.
    func tick(pointer: CGPoint?) {
        let now = Self.now
        var next = birds.filter { !$0.isGone(at: now) }
        if let pointer {
            for i in next.indices where next[i].departure == nil && next[i].isPerched(at: now) {
                let p = next[i].perch
                if abs(pointer.x - p.x) < 40 * next[i].size, pointer.y > p.y - 48, pointer.y < p.y + 42 {
                    next[i] = next[i].leaving(at: now, awayFrom: pointer)
                    // A bird taking fright often sets off the one beside it.
                    for j in next.indices where j != i && next[j].departure == nil && next[j].isPerched(at: now)
                        && abs(next[j].perch.x - p.x) < 110 && Double.random(in: 0..<1) < 0.6 {
                        next[j] = next[j].leaving(at: now + Double.random(in: 0.08...0.25), awayFrom: pointer)
                    }
                }
            }
        }
        if down, now >= nextVisit {
            nextVisit = now + Double.random(in: 7...16)
            let sitting = next.indices.filter { next[$0].departure == nil && next[$0].arrival.start <= now }
            if Self.allowed, sitting.count < 3, sitting.isEmpty || Double.random(in: 0..<1) < 0.55 {
                birds = next
                if let bird = makeBird(arrivingAt: now + 0.05) { next.append(bird) }
            } else if let i = sitting.randomElement(), next[i].isPerched(at: now) {
                next[i] = next[i].leaving(at: now, awayFrom: nil)
            }
        }
        if next.map(\.id) != birds.map(\.id) || zip(next, birds).contains(where: { ($0.departure == nil) != ($1.departure == nil) }) {
            birds = next
        }
    }

    func prune() {
        let now = Self.now
        if birds.contains(where: { $0.isGone(at: now) }) { birds.removeAll { $0.isGone(at: now) } }
    }

    /// Something now hangs where a bird sits: it hops off.
    func makeRoom(at xs: [CGFloat]) {
        let now = Self.now
        var changed = false
        let next = birds.map { bird -> Bird in
            guard bird.departure == nil, xs.contains(where: { abs($0 - bird.perch.x) < 22 }) else { return bird }
            changed = true
            return bird.leaving(at: max(now, bird.landed), awayFrom: nil)
        }
        if changed { birds = next }
    }

    // MARK: The rope under them

    /// How far down the rope is pulled at a point across the panel: a little under each bird
    /// sitting there, more as one lands, and a spring back up as one leaves.
    func ropeDip(at x: CGFloat, t: Double) -> CGFloat {
        var dip: CGFloat = 0
        for bird in birds {
            let load = bird.load(at: t)
            guard load != 0 else { continue }
            let d = (x - bird.perch.x) / 17
            dip += load * exp(-d * d)
        }
        return dip
    }

    /// Whether any bird weighs on this stretch of line now.
    func weighs(between range: ClosedRange<CGFloat>, at t: Double) -> Bool {
        birds.contains { range.contains($0.perch.x) && $0.load(at: t) != 0 }
    }

    /// A new bird, with a free place on the line to come to.
    private func makeBird(arrivingAt start: Double) -> Bird? {
        guard let (width, taken) = ground() else { return nil }
        let size = CGFloat.random(in: 1.12...1.38)
        let others = birds.filter { $0.departure == nil }.map(\.perch.x)
        for _ in 0..<30 {
            let side = Bool.random() ? LineSide.left : .right
            let segment = Layout.segment(side, width: width)
            let length = segment.upperBound - segment.lowerBound
            let x = segment.lowerBound + length * CGFloat.random(in: 0.1...0.9)
            guard taken.allSatisfy({ abs($0 - x) > 28 }), others.allSatisfy({ abs($0 - x) > 30 }) else { continue }
            let perch = CGPoint(x: x, y: Layout.ropeCurveY(x: x, width: width) - 0.3)
            return Bird(kind: BirdKind.pick(), size: size, perch: perch, start: start, width: width, side: side, ceiling: ceiling)
        }
        return nil
    }
}

// MARK: One bird

/// One bird's visit: where it comes from, where it sits and when it leaves. Everything it does is
/// worked out from the time, so drawing a frame needs nothing else.
struct Bird: Identifiable {
    let id = UUID()
    let kind: BirdKind
    let look: BirdLook
    let size: CGFloat
    let perch: CGPoint
    let arrival: Flight
    var departure: Flight?
    /// Which way it faces once it has landed: the way it flew in.
    let settledFacing: CGFloat
    let seed: UInt64
    let flapHz: Double
    /// How long each little thing it does while sitting takes.
    let beat: Double
    /// How often its head snaps to a new direction.
    let glance: Double
    /// The top of the screen, in the line's coordinates.
    let ceiling: CGFloat

    static let crouch: Double = 0.09

    var landed: Double { arrival.start + arrival.duration }

    init(kind: BirdKind, size: CGFloat, perch: CGPoint, start: Double, width: CGFloat, side: LineSide, ceiling: CGFloat) {
        self.kind = kind
        self.ceiling = ceiling
        look = kind.look(jitter: Double.random(in: -0.05...0.05))
        self.size = size
        self.perch = perch
        seed = UInt64.random(in: 0...UInt64.max)
        flapHz = kind == .swallow ? Double.random(in: 7...9) : Double.random(in: 11...15)
        beat = Double.random(in: 1.3...2.4)
        glance = Double.random(in: 0.45...0.85)
        // In from above, out from under the menu bar, or along the line from the side of the screen.
        let from: CGPoint, control: CGPoint
        let dir: CGFloat = Bool.random() ? 1 : -1
        if Double.random(in: 0..<1) < 0.62 {
            from = CGPoint(x: perch.x + dir * .random(in: 120...300), y: ceiling - 18)
            control = CGPoint(x: perch.x + dir * .random(in: 25...70), y: perch.y + .random(in: 14...36))
        } else {
            let outer: CGFloat = side == .left ? -34 : width + 34
            from = CGPoint(x: outer, y: perch.y + .random(in: 15...70))
            control = CGPoint(x: (outer + perch.x) / 2, y: perch.y + .random(in: 22...54))
        }
        let distance = hypot(perch.x - from.x, perch.y - from.y)
        arrival = Flight(from: from, control: control, to: perch, start: start,
                         duration: min(2.0, max(0.8, Double(distance) / .random(in: 220...330))))
        settledFacing = perch.x >= control.x ? 1 : -1
    }

    func isGone(at t: Double) -> Bool {
        guard let departure else { return false }
        return t > departure.start + Bird.crouch + departure.duration
    }

    func isPerched(at t: Double) -> Bool { departure == nil && t >= landed }

    /// Off it goes, from wherever it is: up and away, out of sight past the top of the screen.
    func leaving(at t: Double, awayFrom pointer: CGPoint?) -> Bird {
        var bird = self
        let at = pose(at: t)?.at ?? perch
        let dir: CGFloat = pointer.map { $0.x < at.x ? 1 : -1 } ?? (Bool.random() ? 1 : -1)
        let to = CGPoint(x: at.x + dir * .random(in: 180...380), y: ceiling - 30)
        // Off the line it drops a touch before it climbs.
        let control = CGPoint(x: at.x + dir * .random(in: 40...95), y: at.y + .random(in: 2...14))
        bird.departure = Flight(from: at, control: control, to: to, start: t,
                                duration: .random(in: 0.7...1.1), wasPerched: t >= landed)
        return bird
    }

    /// How much it pulls the rope down at its feet, in points: its weight while it sits, the
    /// bounce as it lands, the push as it springs off and the rope swinging back after.
    func load(at t: Double) -> CGFloat {
        guard t >= landed else { return 0 }
        let rest = 0.75 * size
        if let d = departure, d.wasPerched, t >= d.start {
            let tau = t - d.start
            if tau < Bird.crouch { return rest + 1.1 * size * CGFloat(tau / Bird.crouch) }
            let after = tau - Bird.crouch
            guard after < 1.2 else { return 0 }
            return (rest + 1.1 * size) * CGFloat(exp(-4.5 * after) * cos(17 * after))
        }
        if departure != nil, let d = departure, !d.wasPerched { return 0 }
        let tau = t - landed
        return rest * CGFloat(min(1, tau / 0.08)) + 2.3 * size * CGFloat(exp(-5 * tau) * sin(16 * tau))
    }

    // MARK: Pose

    func pose(at t: Double) -> BirdPose? {
        if let d = departure, t >= d.start { return leavingPose(d, t) }
        if t < arrival.start { return nil }
        let p = (t - arrival.start) / arrival.duration
        if p < 1 { return arrivingPose(p, t) }
        return sittingPose(t - landed, t)
    }

    /// Small birds fly in bounds: a few quick beats, then wings shut for a moment. A swallow glides
    /// on open wings between beats. Either way the wing is shorter coming up than going down.
    private func wingBeat(_ tau: Double, speed: Double = 1) -> (wing: CGFloat, span: CGFloat, folded: Bool, lift: CGFloat) {
        let phase = 2 * .pi * flapHz * speed * tau
        switch kind.flight {
        case .bounding:
            let cycle = 0.36 / speed
            let u = tau.truncatingRemainder(dividingBy: cycle) / cycle
            if u > 0.7 {
                return (0, 0.5, true, CGFloat(sin(.pi * (u - 0.7) / 0.3)) * 1.6)
            }
        case .gliding:
            let cycle = 0.9 / speed
            let u = tau.truncatingRemainder(dividingBy: cycle) / cycle
            if u > 0.45 {
                return (0.18 + 0.05 * CGFloat(sin(tau * 7)), 1, false, 0)
            }
        case .steady:
            break
        }
        return (CGFloat(sin(phase)), CGFloat(0.8 - 0.22 * cos(phase)), false, 0)
    }

    private func arrivingPose(_ p: Double, _ t: Double) -> BirdPose {
        let eased = 1 - pow(1 - p, 2.1)
        let tau = t - arrival.start
        var pose = BirdPose(at: arrival.point(eased))
        let v = arrival.tangent(eased)
        pose.facing = v.dx >= 0 ? 1 : -1
        pose.flying = true
        let flare = max(0, (p - 0.78) / 0.22)
        if flare > 0 {
            // Braking: wings beat fast and wide, the tail fans, the body rears up, feet forward.
            let phase = 2 * .pi * flapHz * 1.5 * tau
            pose.wing = CGFloat(sin(phase))
            pose.span = 1
            pose.tilt = CGFloat(flare) * 0.75
            pose.tailFan = 1 + CGFloat(flare) * 0.8
            pose.legsDown = flare > 0.25
        } else {
            let beat = wingBeat(tau)
            pose.wing = beat.wing
            pose.span = beat.span
            pose.foldedInFlight = beat.folded
            pose.at.y -= beat.lift
            pose.tilt = CGFloat(-atan2(v.dy, abs(v.dx)) * 0.45)
        }
        pose.opacity = topFade(pose.at.y)
        return pose
    }

    private func leavingPose(_ d: Flight, _ t: Double) -> BirdPose? {
        let tau = t - d.start
        let crouch = d.wasPerched ? Bird.crouch : 0
        if tau < crouch {
            var pose = sittingPose(t - landed, t)
            pose.squash = 1 - 0.16 * CGFloat(tau / crouch)
            pose.tilt += 0.15 * CGFloat(tau / crouch)
            pose.wingOpen = CGFloat(tau / crouch) * 0.6
            return pose
        }
        let p = (tau - crouch) / d.duration
        if p >= 1 { return nil }
        let eased = pow(p, 1.55)
        var pose = BirdPose(at: d.point(eased))
        let v = d.tangent(eased)
        pose.facing = v.dx >= 0 ? 1 : -1
        pose.flying = true
        if p < 0.3 {
            // Hard beats to get off the line.
            let phase = 2 * .pi * flapHz * 1.25 * (tau - crouch) - .pi / 2
            pose.wing = CGFloat(sin(phase))
            pose.span = CGFloat(0.8 - 0.22 * cos(phase))
        } else {
            let beat = wingBeat(tau, speed: 1.15)
            pose.wing = beat.wing
            pose.span = beat.span
            pose.foldedInFlight = beat.folded
            pose.at.y -= beat.lift
        }
        pose.tilt = CGFloat(-atan2(v.dy, abs(v.dx)) * 0.4)
        pose.legsDown = p < 0.1
        pose.opacity = topFade(pose.at.y)
        return pose
    }

    /// Just landed, then sitting: it rocks and folds its wings, then never quite keeps still: the
    /// head snaps from one direction to the next, it blinks, breathes, and every little while does
    /// something more: turns round, pecks, preens, flicks its tail or wings, fluffs up, hops.
    private func sittingPose(_ tau: Double, _ t: Double) -> BirdPose {
        var pose = BirdPose(at: perch)
        pose.facing = settledFacing
        pose.wingOpen = CGFloat(max(0, 1 - tau / 0.22))
        // Landing: it dips with the rope and rocks forward and back, the tail balancing.
        pose.squash = 1 - 0.13 * CGFloat(exp(-7 * tau) * sin(min(.pi, tau * 12)))
        pose.tilt = 0.32 * CGFloat(exp(-5.5 * tau) * sin(14 * tau))
        pose.tailLift = 0.6 * CGFloat(exp(-4 * tau) * sin(13 * tau + 0.6))
        pose.puff = 1 + 0.012 * CGFloat(sin(2 * .pi * 0.9 * tau + Double(seed % 7)))

        // The head: a new direction every so often, reached in a quick snap.
        let g = tau / glance
        let gi = Int(g)
        let snap = CGFloat(min(1, (g - Double(gi)) * glance / 0.07))
        let from = headTarget(gi - 1), to = headTarget(gi)
        pose.headTilt = from.tilt + (to.tilt - from.tilt) * snap
        pose.headBack = snap > 0.5 ? to.back : from.back

        // Blinks.
        let bi = Int(t / 2.7 + Double(seed % 13))
        let bu = (t / 2.7 + Double(seed % 13)) - Double(bi)
        if hash(UInt64(bi) &+ 7_777) % 3 != 0, bu > 0.4, bu < 0.4 + 0.12 / 2.7 { pose.blink = true }

        let idle = tau - 0.6
        guard idle > 0 else { return pose }
        let step = Int(idle / beat)
        let u = idle / beat - Double(step)
        var turns = 0
        for k in 0..<step where action(k) == 4 { turns += 1 }
        func bump(_ from: Double, _ length: Double) -> CGFloat {
            let x = (u - from) / length
            return x > 0 && x < 1 ? CGFloat(sin(.pi * x)) : 0
        }
        switch action(step) {
        case 4:
            // Turns round with a little hop.
            if u > 0.5 { turns += 1 }
            pose.hop = 2.6 * bump(0.38, 0.24)
            pose.wingOpen = max(pose.wingOpen, 0.25 * bump(0.38, 0.24))
        case 5:
            // Pecks at the rope, twice.
            pose.headDip = max(bump(0.1, 0.18), bump(0.34, 0.18))
            pose.headTilt = 0.35 * max(bump(0.1, 0.18), bump(0.34, 0.18))
        case 6:
            // Preens: head round to its wing.
            let b = bump(0.08, 0.7)
            pose.headBack = b > 0.2
            pose.headDip = 0.55 * b
        case 7:
            pose.tailLift = max(pose.tailLift, bump(0.28, 0.12), 0.7 * bump(0.44, 0.12))
        case 8:
            pose.puff += 0.1 * bump(0.1, 0.75)
        case 9:
            // A quick flick of both wings.
            pose.wingOpen = max(pose.wingOpen, 0.55 * max(bump(0.3, 0.1), bump(0.45, 0.1)))
        case 10:
            // Looks up at the sky, head cocked.
            pose.headTilt = 0.45 * bump(0.1, 0.6)
        default:
            break
        }
        if turns % 2 == 1 { pose.facing = -settledFacing }
        return pose
    }

    private func headTarget(_ i: Int) -> (tilt: CGFloat, back: Bool) {
        guard i >= 0 else { return (0, false) }
        let h = hash(UInt64(i) &+ 1_000_003)
        let tilts: [CGFloat] = [-0.22, -0.1, 0, 0, 0.08, 0.18, 0.3]
        return (tilts[Int(h % 7)], (h >> 8) % 7 == 0)
    }

    /// What it does in each little while, the same every time it is drawn.
    private func action(_ step: Int) -> UInt64 { hash(UInt64(step + 1)) % 12 }

    private func hash(_ n: UInt64) -> UInt64 {
        var z = seed &+ n &* 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Gone past the top of the screen: it fades in and out right at the edge.
    private func topFade(_ y: CGFloat) -> Double { Double(min(1, max(0, (y - ceiling + 6) / 12))) }
}

/// A curved flight from one point to another.
struct Flight {
    let from: CGPoint
    let control: CGPoint
    let to: CGPoint
    let start: Double
    let duration: Double
    var wasPerched = false

    func point(_ u: Double) -> CGPoint {
        let u = CGFloat(u), v = 1 - u
        return CGPoint(x: v * v * from.x + 2 * u * v * control.x + u * u * to.x,
                       y: v * v * from.y + 2 * u * v * control.y + u * u * to.y)
    }

    func tangent(_ u: Double) -> CGVector {
        let u = CGFloat(u)
        return CGVector(dx: 2 * (1 - u) * (control.x - from.x) + 2 * u * (to.x - control.x),
                        dy: 2 * (1 - u) * (control.y - from.y) + 2 * u * (to.y - control.y))
    }
}

struct BirdPose {
    /// Where its feet are, or would be, in the line's coordinates.
    var at: CGPoint
    var facing: CGFloat = 1
    var headBack = false
    /// Head turned up (positive) or down, in radians.
    var headTilt: CGFloat = 0
    var blink = false
    var flying = false
    /// In flight, wings shut for a moment between beats.
    var foldedInFlight = false
    /// Wing beat, from down (-1) to up (1).
    var wing: CGFloat = 0
    /// How far the wing reaches: full on the downstroke, drawn in coming up.
    var span: CGFloat = 1
    /// Wings opening, from folded (0) to spread (1): just after landing, or a flick.
    var wingOpen: CGFloat = 0
    /// Nose up, in radians.
    var tilt: CGFloat = 0
    var headDip: CGFloat = 0
    var tailLift: CGFloat = 0
    var tailFan: CGFloat = 1
    var squash: CGFloat = 1
    var puff: CGFloat = 1
    var hop: CGFloat = 0
    var legsDown = false
    var opacity: Double = 1
}

// MARK: Kinds

enum BirdKind: CaseIterable {
    case sparrow, treeSparrow, tit, robin, swallow, finch

    enum Flight { case bounding, gliding, steady }

    var flight: Flight {
        switch self {
        case .swallow: .gliding
        case .robin: .steady
        default: .bounding
        }
    }

    static func pick() -> BirdKind {
        switch Double.random(in: 0..<1) {
        case ..<0.32: .sparrow
        case ..<0.52: .treeSparrow
        case ..<0.67: .tit
        case ..<0.78: .robin
        case ..<0.91: .swallow
        default: .finch
        }
    }

    func look(jitter: Double) -> BirdLook {
        func c(_ r: Double, _ g: Double, _ b: Double) -> Color {
            Color(red: min(1, r * (1 + jitter)), green: min(1, g * (1 + jitter)), blue: min(1, b * (1 + jitter)))
        }
        let black = Color(white: 0.1)
        switch self {
        case .sparrow:
            var look = BirdLook(back: c(0.60, 0.45, 0.31), belly: c(0.80, 0.78, 0.73), wing: c(0.56, 0.40, 0.26),
                                flight: c(0.30, 0.21, 0.15), edge: c(0.86, 0.72, 0.52), tail: c(0.36, 0.27, 0.2),
                                cap: c(0.50, 0.49, 0.50), beak: c(0.26, 0.23, 0.22), beakLower: c(0.42, 0.37, 0.33),
                                legs: c(0.66, 0.52, 0.44))
            look.wingBar = c(0.95, 0.93, 0.88)
            look.cheek = c(0.80, 0.79, 0.76)
            look.bib = c(0.16, 0.15, 0.15)
            look.brow = c(0.62, 0.42, 0.28)
            look.streaks = true
            return look
        case .treeSparrow:
            var look = BirdLook(back: c(0.62, 0.46, 0.31), belly: c(0.84, 0.82, 0.77), wing: c(0.58, 0.40, 0.25),
                                flight: c(0.30, 0.21, 0.15), edge: c(0.88, 0.74, 0.54), tail: c(0.38, 0.28, 0.2),
                                cap: c(0.56, 0.30, 0.18), beak: c(0.16, 0.15, 0.15), beakLower: c(0.24, 0.22, 0.21),
                                legs: c(0.66, 0.52, 0.44))
            look.wingBar = c(0.97, 0.95, 0.9)
            look.cheek = Color(white: 0.95)
            look.cheekSpot = true
            look.bib = c(0.12, 0.11, 0.11)
            look.collar = Color(white: 0.92)
            look.streaks = true
            return look
        case .tit:
            var look = BirdLook(back: c(0.46, 0.56, 0.38), belly: c(0.98, 0.84, 0.32), wing: c(0.42, 0.52, 0.62),
                                flight: c(0.26, 0.33, 0.42), edge: c(0.80, 0.86, 0.9), tail: c(0.32, 0.40, 0.5),
                                cap: black, beak: black, beakLower: Color(white: 0.2), legs: c(0.46, 0.5, 0.6))
            look.wingBar = Color(white: 0.96)
            look.cheek = Color(white: 0.98)
            look.bib = black
            look.stripe = true
            look.capCovers = 0.6
            look.length = 12.4
            look.height = 9.8
            return look
        case .robin:
            var look = BirdLook(back: c(0.50, 0.44, 0.34), belly: c(0.93, 0.91, 0.87), wing: c(0.50, 0.43, 0.32),
                                flight: c(0.36, 0.31, 0.23), edge: c(0.66, 0.58, 0.44), tail: c(0.42, 0.36, 0.27),
                                cap: c(0.50, 0.44, 0.34), beak: c(0.18, 0.16, 0.15), beakLower: c(0.3, 0.27, 0.25),
                                legs: c(0.55, 0.45, 0.38))
            look.breast = c(0.94, 0.50, 0.24)
            look.breastEdge = c(0.68, 0.70, 0.72)
            look.length = 12.6
            look.height = 10.4
            look.posture = 0.36
            look.beakLength = 2.3
            return look
        case .swallow:
            var look = BirdLook(back: c(0.12, 0.17, 0.36), belly: c(0.96, 0.93, 0.88), wing: c(0.10, 0.13, 0.27),
                                flight: c(0.07, 0.08, 0.16), edge: c(0.22, 0.3, 0.5), tail: c(0.08, 0.1, 0.22),
                                cap: c(0.12, 0.17, 0.36), beak: black, beakLower: Color(white: 0.16),
                                legs: Color(white: 0.22))
            look.bib = c(0.72, 0.28, 0.17)
            look.bibBig = true
            look.forked = true
            look.tailLength = 13
            look.length = 13.6
            look.height = 8.4
            look.headR = 3.5
            look.beakLength = 1.4
            look.posture = 0.2
            look.wingLength = 1.35
            look.gloss = true
            return look
        case .finch:
            var look = BirdLook(back: c(0.74, 0.61, 0.44), belly: c(0.95, 0.91, 0.84), wing: Color(white: 0.12),
                                flight: Color(white: 0.08), edge: Color(white: 0.92), tail: Color(white: 0.12),
                                cap: black, beak: c(0.93, 0.85, 0.77), beakLower: c(0.86, 0.76, 0.68),
                                legs: c(0.74, 0.64, 0.6))
            look.wingBar = c(1.0, 0.82, 0.16)
            look.wingBarWide = true
            look.cheek = Color(white: 0.97)
            look.mask = c(0.86, 0.17, 0.16)
            look.capCovers = 0.32
            look.length = 12.2
            look.height = 9.2
            look.headR = 3.75
            look.beakLength = 2.9
            return look
        }
    }
}

struct BirdLook {
    var back: Color
    var belly: Color
    var wing: Color
    /// The long wing and tail feathers, darker.
    var flight: Color
    /// Pale feather edges, which give the wing its layers.
    var edge: Color
    var tail: Color
    var cap: Color
    var beak: Color
    var beakLower: Color
    var legs: Color
    var wingBar: Color?
    var wingBarWide = false
    var cheek: Color?
    var cheekSpot = false
    var bib: Color?
    var bibBig = false
    var collar: Color?
    var brow: Color?
    var breast: Color?
    var breastEdge: Color?
    var mask: Color?
    var streaks = false
    var stripe = false
    var forked = false
    var gloss = false
    /// How far down the head the cap comes, from the top (0) to the eye (0.5) and past it.
    var capCovers: CGFloat = 0.42
    var length: CGFloat = 13
    var height: CGFloat = 9.6
    var headR: CGFloat = 3.9
    var tailLength: CGFloat = 8
    var beakLength: CGFloat = 2.6
    /// How upright it sits.
    var posture: CGFloat = 0.28
    var wingLength: CGFloat = 1
}

// MARK: Their window

/// The birds' own window: over the line and the menu bar, up to the top of the screen, so a bird
/// flying off is seen all the way out, whatever the line does. It never takes a click, and it is
/// only there while a bird is.
@MainActor
final class BirdWindow {
    private let window: NSPanel
    private let flock: Flock
    private var watch: Any?

    init(flock: Flock) {
        self.flock = flock
        window = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        // Over the menu bar, under the island.
        window.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.hidesOnDeactivate = false
        let host = NSHostingView(rootView: BirdsView(flock: flock))
        host.sizingOptions = []
        let container = NSView()
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        window.contentView = container
        watch = flock.$birds.sink { [weak self] birds in
            MainActor.assumeIsolated { self?.show(!birds.isEmpty) }
        }
    }

    /// Over the line's window, from its bottom to the top of its screen.
    func follow(_ line: NSWindow) {
        guard let screen = line.screen else { return }
        let frame = NSRect(x: line.frame.minX, y: line.frame.minY, width: line.frame.width,
                           height: screen.frame.maxY - line.frame.minY)
        flock.ceiling = -(screen.frame.maxY - line.frame.maxY)
        if window.frame != frame {
            window.setFrame(frame, display: false)
            window.contentView?.subviews.first?.frame = window.contentView?.bounds ?? .zero
        }
    }

    private func show(_ on: Bool) {
        if on, !window.isVisible { window.orderFrontRegardless() }
        if !on, window.isVisible { window.orderOut(nil) }
    }

    func close() {
        watch = nil
        window.orderOut(nil)
    }
}

// MARK: Drawing

struct BirdsView: View {
    @ObservedObject var flock: Flock

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: flock.birds.isEmpty)) { context in
            Canvas { canvas, _ in
                let t = context.date.timeIntervalSinceReferenceDate
                // The window reaches up over the menu bar to the top of the screen.
                canvas.translateBy(x: 0, y: -flock.ceiling)
                for bird in flock.birds {
                    guard var pose = bird.pose(at: t), pose.opacity > 0.01 else { continue }
                    // On the rope, it rides the rope as it gives and bounces.
                    if !pose.flying { pose.at.y += flock.ropeDip(at: bird.perch.x, t: t) }
                    canvas.drawLayer { layer in
                        layer.opacity = pose.opacity
                        // A soft shadow keeps them clear on light and dark screens alike.
                        layer.addFilter(.shadow(color: .black.opacity(0.3), radius: 1.3, x: 0, y: 0.8))
                        BirdPainter.draw(bird.look, pose, size: bird.size, in: &layer)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// Draws a bird facing right with its feet at the origin, then turns and scales it into place.
/// The body and head are one outline, shaded like a rounded thing lit from above; the wing is
/// laid in feathers with pale edges; the toes close round the rope.
enum BirdPainter {
    private static let legH: CGFloat = 2.7

    static func draw(_ look: BirdLook, _ pose: BirdPose, size: CGFloat, in ctx: inout GraphicsContext) {
        var c = ctx
        c.translateBy(x: pose.at.x, y: pose.at.y - pose.hop)
        c.scaleBy(x: size * pose.facing, y: size)
        if pose.flying {
            flying(look, pose, in: &c)
        } else {
            sitting(look, pose, in: &c)
        }
    }

    // MARK: Sitting

    private static func sitting(_ look: BirdLook, _ pose: BirdPose, in c: inout GraphicsContext) {
        let L = look.length * pose.puff, H = look.height * pose.puff * pose.squash
        let legs = legH * pose.squash
        let bc = CGPoint(x: 0, y: -(legs + H * 0.5))
        feet(look, top: bc.y + H * 0.28, gripping: true, in: &c)

        var body = c
        rotate(&body, around: bc, by: look.posture + pose.tilt)
        tail(look, base: CGPoint(x: bc.x - L * 0.36, y: bc.y + H * 0.14),
             angle: 0.5 - look.posture * 0.6 - pose.tailLift * 0.55, fan: pose.tailFan, in: &body)
        if pose.wingOpen > 0.04 {
            var far = body
            far.opacity = 0.7
            spreadWing(look, shoulder: CGPoint(x: bc.x + L * 0.08, y: bc.y - H * 0.28), length: L * look.wingLength * pose.wingOpen,
                       beat: 0.55, span: 1, in: &far)
        }
        let hc = headCenter(bc, L, H, look, dip: pose.headDip)
        let outline = silhouette(bc, L, H, hc, look.headR * pose.puff)
        plumage(look, outline, bc, L, H, hc, r: look.headR * pose.puff, in: &body)
        foldedWing(look, bc, L, H, in: &body)
        if pose.wingOpen > 0.04 {
            spreadWing(look, shoulder: CGPoint(x: bc.x + L * 0.1, y: bc.y - H * 0.3), length: L * look.wingLength * pose.wingOpen,
                       beat: 0.65, span: 1, in: &body)
        }
        var head = body
        rotate(&head, around: hc, by: -look.posture * 0.85 + pose.headTilt)
        headDetails(look, hc, r: look.headR * pose.puff, back: pose.headBack, blink: pose.blink, in: &head)
    }

    private static func headCenter(_ bc: CGPoint, _ L: CGFloat, _ H: CGFloat, _ look: BirdLook, dip: CGFloat) -> CGPoint {
        CGPoint(x: bc.x + L * 0.31 + dip * 2.8, y: bc.y - H * 0.5 + dip * 4.6)
    }

    /// Head and body as one rounded outline: crown, nape, back, rump, under the tail, belly,
    /// breast, throat, chin.
    private static func silhouette(_ bc: CGPoint, _ L: CGFloat, _ H: CGFloat, _ hc: CGPoint, _ r: CGFloat) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: hc.x + r, y: hc.y - r * 0.05))
        p.addCurve(to: CGPoint(x: hc.x - r * 0.1, y: hc.y - r),
                   control1: CGPoint(x: hc.x + r * 1.0, y: hc.y - r * 0.6),
                   control2: CGPoint(x: hc.x + r * 0.5, y: hc.y - r * 1.02))
        p.addCurve(to: CGPoint(x: bc.x - L * 0.47, y: bc.y - H * 0.02),
                   control1: CGPoint(x: hc.x - r * 0.85, y: hc.y - r * 0.95),
                   control2: CGPoint(x: bc.x - L * 0.12, y: bc.y - H * 0.64))
        p.addCurve(to: CGPoint(x: bc.x - L * 0.2, y: bc.y + H * 0.48),
                   control1: CGPoint(x: bc.x - L * 0.56, y: bc.y + H * 0.22),
                   control2: CGPoint(x: bc.x - L * 0.38, y: bc.y + H * 0.44))
        p.addCurve(to: CGPoint(x: bc.x + L * 0.45, y: bc.y - H * 0.04),
                   control1: CGPoint(x: bc.x + L * 0.02, y: bc.y + H * 0.58),
                   control2: CGPoint(x: bc.x + L * 0.42, y: bc.y + H * 0.4))
        p.addCurve(to: CGPoint(x: hc.x + r * 0.86, y: hc.y + r * 0.45),
                   control1: CGPoint(x: bc.x + L * 0.5, y: bc.y - H * 0.28),
                   control2: CGPoint(x: hc.x + r * 1.0, y: hc.y + r * 0.95))
        p.addCurve(to: CGPoint(x: hc.x + r, y: hc.y - r * 0.05),
                   control1: CGPoint(x: hc.x + r * 1.0, y: hc.y + r * 0.3),
                   control2: CGPoint(x: hc.x + r * 1.02, y: hc.y + r * 0.1))
        p.closeSubpath()
        return p
    }

    /// The colours on the body: back fading into belly, the breast, markings, and light from above.
    private static func plumage(_ look: BirdLook, _ outline: Path, _ bc: CGPoint, _ L: CGFloat, _ H: CGFloat,
                                _ hc: CGPoint, r: CGFloat, in body: inout GraphicsContext) {
        let top = CGPoint(x: bc.x - L * 0.05, y: hc.y - r)
        let bottom = CGPoint(x: bc.x + L * 0.12, y: bc.y + H * 0.5)
        body.fill(outline, with: .linearGradient(Gradient(stops: [
            .init(color: look.back, location: 0), .init(color: look.back, location: 0.44),
            .init(color: look.belly, location: 0.62), .init(color: look.belly, location: 1),
        ]), startPoint: top, endPoint: bottom))
        var inside = body
        inside.clip(to: outline)
        if let breast = look.breast {
            if let edge = look.breastEdge {
                inside.fill(ellipse(CGPoint(x: bc.x + L * 0.3, y: bc.y - H * 0.12), L * 0.6, H * 0.98), with: .color(edge.opacity(0.6)))
            }
            inside.fill(ellipse(CGPoint(x: bc.x + L * 0.33, y: bc.y - H * 0.16), L * 0.52, H * 0.86), with: .color(breast))
            inside.fill(ellipse(CGPoint(x: hc.x + r * 0.45, y: hc.y + r * 0.2), r * 1.6, r * 1.5), with: .color(breast))
        }
        if let bib = look.bib {
            let big: CGFloat = look.bibBig ? 1.3 : 1
            inside.fill(ellipse(CGPoint(x: hc.x + r * 0.5, y: hc.y + r * (1.0 + 0.1 * big)), r * 1.15 * big, r * 1.15 * big),
                        with: .color(bib))
        }
        if look.stripe, let bib = look.bib {
            var stripe = Path()
            stripe.move(to: CGPoint(x: hc.x + r * 0.3, y: hc.y + r * 1.2))
            stripe.addQuadCurve(to: CGPoint(x: bc.x + L * 0.05, y: bc.y + H * 0.5),
                                control: CGPoint(x: bc.x + L * 0.34, y: bc.y + H * 0.1))
            inside.stroke(stripe, with: .color(bib), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
        }
        if let collar = look.collar {
            var ring = Path()
            ring.move(to: CGPoint(x: hc.x - r * 0.9, y: hc.y + r * 0.55))
            ring.addQuadCurve(to: CGPoint(x: hc.x + r * 0.1, y: hc.y + r * 1.15), control: CGPoint(x: hc.x - r * 0.5, y: hc.y + r * 1.2))
            inside.stroke(ring, with: .color(collar.opacity(0.85)), lineWidth: 0.9)
        }
        if look.streaks {
            // Dark streaks down the back, each with a pale edge.
            for i in 0..<3 {
                let x = bc.x - L * 0.02 - CGFloat(i) * L * 0.12
                let y = bc.y - H * 0.42 + CGFloat(i) * H * 0.04
                var dark = Path()
                dark.move(to: CGPoint(x: x, y: y))
                dark.addLine(to: CGPoint(x: x - L * 0.12, y: y + H * 0.12))
                inside.stroke(dark, with: .color(Color.black.opacity(0.42)), style: StrokeStyle(lineWidth: 0.8, lineCap: .round))
                var pale = Path()
                pale.move(to: CGPoint(x: x + 0.4, y: y + 0.7))
                pale.addLine(to: CGPoint(x: x - L * 0.12 + 0.4, y: y + H * 0.12 + 0.7))
                inside.stroke(pale, with: .color(look.edge.opacity(0.7)), style: StrokeStyle(lineWidth: 0.45, lineCap: .round))
            }
        }
        if look.gloss {
            inside.fill(ellipse(CGPoint(x: bc.x - L * 0.05, y: bc.y - H * 0.38), L * 0.5, H * 0.22),
                        with: .color(Color(red: 0.4, green: 0.5, blue: 0.9).opacity(0.28)))
        }
        // Light from above, shade underneath, a soft sheen on the breast.
        inside.fill(outline, with: .linearGradient(Gradient(stops: [
            .init(color: .white.opacity(0.16), location: 0), .init(color: .clear, location: 0.4),
            .init(color: .clear, location: 0.68), .init(color: .black.opacity(0.24), location: 1),
        ]), startPoint: top, endPoint: CGPoint(x: bottom.x, y: bottom.y + 1)))
        inside.fill(outline, with: .radialGradient(Gradient(colors: [.white.opacity(0.14), .clear]),
                                                    center: CGPoint(x: bc.x + L * 0.26, y: bc.y - H * 0.08),
                                                    startRadius: 0, endRadius: H * 0.55))
    }

    /// The wing laid along the side: long flight feathers reaching past the rump, broad feathers
    /// over them with pale edges, and the rounded coverts at the shoulder with the wing bar.
    private static func foldedWing(_ look: BirdLook, _ bc: CGPoint, _ L: CGFloat, _ H: CGFloat, in c: inout GraphicsContext) {
        let reach = look.wingLength
        // Primaries.
        for k in 0..<4 {
            let kk = CGFloat(k)
            let base = CGPoint(x: bc.x - L * 0.08 - kk * 0.6, y: bc.y - H * 0.12 + kk * 0.55)
            let tip = CGPoint(x: bc.x - L * (0.6 + 0.12 * (reach - 1)) + kk * 1.3, y: bc.y + H * (0.04 + 0.03 * kk))
            let leaf = feather(from: base, to: tip, width: 1.25)
            c.fill(leaf, with: .color(look.flight))
            c.stroke(edgeLine(from: base, to: tip, offset: -0.55), with: .color(look.edge.opacity(0.55)), lineWidth: 0.35)
        }
        // Tertials.
        for k in 0..<2 {
            let kk = CGFloat(k)
            let base = CGPoint(x: bc.x + L * 0.02 - kk * 1.2, y: bc.y - H * 0.24 + kk * 0.9)
            let tip = CGPoint(x: bc.x - L * 0.38 + kk * 1.4, y: bc.y - H * 0.02 + kk * 1.0)
            let leaf = feather(from: base, to: tip, width: 2.0)
            c.fill(leaf, with: .color(look.flight.opacity(0.95)))
            c.stroke(leaf, with: .color(look.edge.opacity(0.8)), lineWidth: 0.4)
        }
        // Coverts.
        var coverts = Path()
        coverts.move(to: CGPoint(x: bc.x + L * 0.24, y: bc.y - H * 0.3))
        coverts.addQuadCurve(to: CGPoint(x: bc.x - L * 0.16, y: bc.y - H * 0.36), control: CGPoint(x: bc.x + L * 0.04, y: bc.y - H * 0.52))
        coverts.addQuadCurve(to: CGPoint(x: bc.x - L * 0.12, y: bc.y + H * 0.08), control: CGPoint(x: bc.x - L * 0.3, y: bc.y - H * 0.1))
        coverts.addQuadCurve(to: CGPoint(x: bc.x + L * 0.24, y: bc.y - H * 0.3), control: CGPoint(x: bc.x + L * 0.14, y: bc.y + H * 0.06))
        c.fill(coverts, with: .linearGradient(Gradient(colors: [look.wing, look.wing.opacity(0.92)]),
                                              startPoint: CGPoint(x: bc.x, y: bc.y - H * 0.4), endPoint: CGPoint(x: bc.x, y: bc.y + H * 0.1)))
        // Scalloped edges of the covert rows.
        var rows = Path()
        for k in 0..<3 {
            let y = bc.y - H * 0.2 + CGFloat(k) * H * 0.1
            rows.move(to: CGPoint(x: bc.x + L * 0.14 - CGFloat(k) * 0.8, y: y - 0.6))
            rows.addQuadCurve(to: CGPoint(x: bc.x - L * 0.14, y: y + 0.4), control: CGPoint(x: bc.x, y: y + 1.0))
        }
        c.stroke(rows, with: .color(look.edge.opacity(0.35)), lineWidth: 0.35)
        if let bar = look.wingBar {
            var line = Path()
            line.move(to: CGPoint(x: bc.x + L * 0.1, y: bc.y - H * 0.24))
            line.addQuadCurve(to: CGPoint(x: bc.x - L * 0.16, y: bc.y - H * 0.06), control: CGPoint(x: bc.x - L * 0.04, y: bc.y - H * 0.08))
            c.stroke(line, with: .color(bar), style: StrokeStyle(lineWidth: look.wingBarWide ? 1.5 : 0.8, lineCap: .round))
        }
    }

    // MARK: Flying

    private static func flying(_ look: BirdLook, _ pose: BirdPose, in c: inout GraphicsContext) {
        let L = look.length * 1.04, H = look.height * 0.84
        let bc = CGPoint(x: 0, y: -(legH + H * 0.5))
        var body = c
        rotate(&body, around: bc, by: pose.tilt)
        let shoulder = CGPoint(x: bc.x + L * 0.1, y: bc.y - H * 0.28)
        let wingLength = L * look.wingLength * 1.05

        if !pose.foldedInFlight {
            var far = body
            far.opacity = 0.72
            spreadWing(look, shoulder: CGPoint(x: shoulder.x + 1.2, y: shoulder.y - 0.3), length: wingLength * 0.88,
                       beat: pose.wing * 0.92, span: pose.span, in: &far)
        }
        if pose.legsDown {
            var legs = Path()
            for dx: CGFloat in [-0.6, 0.8] {
                legs.move(to: CGPoint(x: bc.x + dx, y: bc.y + H * 0.3))
                legs.addLine(to: CGPoint(x: bc.x + dx + 2.2, y: bc.y + H * 0.3 + 3))
                legs.addLine(to: CGPoint(x: bc.x + dx + 3.4, y: bc.y + H * 0.3 + 3.2))
            }
            body.stroke(legs, with: .color(look.legs), style: StrokeStyle(lineWidth: 0.75, lineCap: .round, lineJoin: .round))
        }
        tail(look, base: CGPoint(x: bc.x - L * 0.38, y: bc.y + H * 0.04), angle: 0.06, fan: 1.5 * pose.tailFan, in: &body)
        // Neck out, head forward.
        let r = look.headR * 0.95
        let hc = CGPoint(x: bc.x + L * 0.4, y: bc.y - H * 0.32)
        let outline = silhouette(bc, L, H, hc, r)
        plumage(look, outline, bc, L, H, hc, r: r, in: &body)
        if pose.foldedInFlight { foldedWing(look, bc, L, H, in: &body) }
        var head = body
        rotate(&head, around: hc, by: -pose.tilt * 0.6)
        headDetails(look, hc, r: r, back: false, blink: false, in: &head)
        if !pose.foldedInFlight {
            spreadWing(look, shoulder: shoulder, length: wingLength, beat: pose.wing, span: pose.span, in: &body)
        }
    }

    /// A wing spread from the shoulder, raised (beat 1) or lowered (-1), reaching `span` of its
    /// length: an inner wing of coverts and a hand of separate flight feathers at the tip.
    private static func spreadWing(_ look: BirdLook, shoulder s: CGPoint, length: CGFloat, beat: CGFloat, span: CGFloat,
                                   in c: inout GraphicsContext) {
        let reach = length * span
        let sweep = 0.42 + (1 - span) * 0.5
        let tip = CGPoint(x: s.x - reach * sweep, y: s.y - reach * beat)
        let wrist = CGPoint(x: s.x + (tip.x - s.x) * 0.45 + 0.8, y: s.y + (tip.y - s.y) * 0.5)
        let trailBase = CGPoint(x: s.x - length * 0.42, y: s.y + 0.9)

        // The hand: four or five flight feathers fanned from the wrist.
        let count = look.wingLength > 1.2 ? 4 : 5
        for k in 0..<count {
            let f = CGFloat(k) / CGFloat(count - 1)
            let spread = (f - 0.2) * reach * 0.34
            let end = CGPoint(x: tip.x - f * reach * 0.18 - abs(beat) * spread * 0.2, y: tip.y + spread * (beat >= 0 ? 1 : -1) * 0.9 + f * 1.2)
            c.fill(feather(from: wrist, to: end, width: 1.15 + 0.2 * f), with: .color(look.flight))
        }
        // The inner wing.
        var inner = Path()
        inner.move(to: CGPoint(x: s.x + 1.6, y: s.y + 0.4))
        inner.addQuadCurve(to: wrist, control: CGPoint(x: s.x + 1.0, y: s.y + (wrist.y - s.y) * 0.75))
        inner.addQuadCurve(to: tip, control: CGPoint(x: wrist.x - 0.4, y: wrist.y + (tip.y - wrist.y) * 0.5))
        inner.addQuadCurve(to: trailBase, control: CGPoint(x: s.x - length * 0.5, y: s.y + (tip.y - s.y) * 0.35 + 1.2))
        inner.closeSubpath()
        c.fill(inner, with: .linearGradient(Gradient(colors: [look.wing, look.flight]),
                                            startPoint: s, endPoint: tip))
        // Rows of coverts along the leading edge, and the bar.
        var rows = Path()
        for k in 1...2 {
            let f = CGFloat(k) * 0.22
            rows.move(to: CGPoint(x: s.x + (wrist.x - s.x) * f, y: s.y + (wrist.y - s.y) * f + 0.6))
            rows.addLine(to: CGPoint(x: s.x - length * 0.32 + (tip.x - s.x) * f * 0.6, y: s.y + (tip.y - s.y) * f * 0.6 + 1.2))
        }
        c.stroke(rows, with: .color(look.edge.opacity(0.35)), lineWidth: 0.4)
        if let bar = look.wingBar {
            var line = Path()
            line.move(to: CGPoint(x: s.x + (wrist.x - s.x) * 0.55, y: s.y + (wrist.y - s.y) * 0.55 + 0.4))
            line.addLine(to: CGPoint(x: s.x - length * 0.2 + (tip.x - s.x) * 0.3, y: s.y + (tip.y - s.y) * 0.3 + 1.0))
            c.stroke(line, with: .color(bar.opacity(look.wingBarWide ? 1 : 0.75)),
                     style: StrokeStyle(lineWidth: look.wingBarWide ? 1.3 : 0.55, lineCap: .round))
        }
    }

    // MARK: Parts

    private static func tail(_ look: BirdLook, base b: CGPoint, angle: CGFloat, fan: CGFloat, in c: inout GraphicsContext) {
        let feathers: [(CGFloat, CGFloat)] = look.forked
            ? [(-0.2, 1.0), (0.2, 1.0), (-0.07, 0.55), (0.07, 0.55)]
            : [(-0.1, 0.95), (0.1, 0.95), (0, 1.0)]
        for (spread, share) in feathers {
            let a = angle + spread * fan
            let length = look.tailLength * share
            let tip = CGPoint(x: b.x - cos(a) * length, y: b.y + sin(a) * length)
            let leaf = feather(from: b, to: tip, width: look.forked ? 1.0 : 1.5)
            c.fill(leaf, with: .color(look.tail))
            c.stroke(edgeLine(from: b, to: tip, offset: -0.6), with: .color(look.edge.opacity(0.35)), lineWidth: 0.35)
        }
    }

    /// Legs down to the rope, toes closed round it: two forward and down over the front, one behind.
    private static func feet(_ look: BirdLook, top: CGFloat, gripping: Bool, in c: inout GraphicsContext) {
        var legs = Path()
        for x: CGFloat in [-1.4, 1.1] {
            legs.move(to: CGPoint(x: x + 0.3, y: top))
            legs.addLine(to: CGPoint(x: x, y: -0.7))
            legs.move(to: CGPoint(x: x, y: -0.7))
            legs.addQuadCurve(to: CGPoint(x: x + 1.9, y: 0.9), control: CGPoint(x: x + 1.8, y: -0.9))
            legs.move(to: CGPoint(x: x, y: -0.7))
            legs.addQuadCurve(to: CGPoint(x: x - 1.5, y: 0.7), control: CGPoint(x: x - 1.4, y: -0.8))
        }
        c.stroke(legs, with: .color(look.legs), style: StrokeStyle(lineWidth: 0.7, lineCap: .round, lineJoin: .round))
    }

    /// Cap, brow, cheek, mask, eye with its ring and glint, and the two halves of the beak.
    private static func headDetails(_ look: BirdLook, _ hc: CGPoint, r: CGFloat, back: Bool, blink: Bool,
                                    in ctx: inout GraphicsContext) {
        var c = ctx
        if back {
            c.translateBy(x: hc.x, y: 0)
            c.scaleBy(x: -1, y: 1)
            c.translateBy(x: -hc.x, y: 0)
        }
        // The beak, set into the face.
        let base = hc.x + r * 0.8
        var upper = Path()
        upper.move(to: CGPoint(x: base, y: hc.y - r * 0.34))
        upper.addQuadCurve(to: CGPoint(x: base + look.beakLength + r * 0.08, y: hc.y + r * 0.06),
                           control: CGPoint(x: base + look.beakLength * 0.5, y: hc.y - r * 0.34))
        upper.addLine(to: CGPoint(x: base, y: hc.y + r * 0.08))
        upper.closeSubpath()
        var lower = Path()
        lower.move(to: CGPoint(x: base, y: hc.y + r * 0.08))
        lower.addLine(to: CGPoint(x: base + look.beakLength * 0.86, y: hc.y + r * 0.1))
        lower.addQuadCurve(to: CGPoint(x: base - r * 0.04, y: hc.y + r * 0.38),
                           control: CGPoint(x: base + look.beakLength * 0.35, y: hc.y + r * 0.36))
        lower.closeSubpath()
        c.fill(lower, with: .color(look.beakLower))
        c.fill(upper, with: .color(look.beak))

        let circle = Path(ellipseIn: CGRect(x: hc.x - r, y: hc.y - r, width: r * 2, height: r * 2))
        var head = c
        head.clip(to: circle)
        if let cheek = look.cheek {
            head.fill(ellipse(CGPoint(x: hc.x - r * 0.1, y: hc.y + r * 0.32), r * 1.4, r * 0.85), with: .color(cheek))
        }
        if let mask = look.mask {
            head.fill(ellipse(CGPoint(x: hc.x + r * 0.62, y: hc.y - r * 0.04), r * 1.15, r * 1.3), with: .color(mask))
        }
        // The cap, coming down lower at the back of the head.
        let capY = hc.y - r + r * 2 * look.capCovers
        var cap = Path()
        cap.move(to: CGPoint(x: hc.x - r * 1.2, y: hc.y - r * 1.2))
        cap.addLine(to: CGPoint(x: hc.x + r * 1.2, y: hc.y - r * 1.2))
        cap.addLine(to: CGPoint(x: hc.x + r * 1.2, y: capY - r * 0.18))
        cap.addQuadCurve(to: CGPoint(x: hc.x - r * 1.2, y: capY + r * 0.3), control: CGPoint(x: hc.x, y: capY + r * 0.02))
        cap.closeSubpath()
        head.fill(cap, with: .color(look.cap))
        if let brow = look.brow {
            var line = Path()
            line.move(to: CGPoint(x: hc.x + r * 0.15, y: hc.y - r * 0.42))
            line.addQuadCurve(to: CGPoint(x: hc.x - r * 0.95, y: hc.y + r * 0.05), control: CGPoint(x: hc.x - r * 0.5, y: hc.y - r * 0.5))
            head.stroke(line, with: .color(brow), style: StrokeStyle(lineWidth: 1.1, lineCap: .round))
        }
        if look.cheekSpot {
            head.fill(ellipse(CGPoint(x: hc.x - r * 0.05, y: hc.y + r * 0.35), r * 0.42, r * 0.38), with: .color(Color(white: 0.1)))
        }
        // Shading on the head too, so it is round.
        head.fill(circle, with: .radialGradient(Gradient(colors: [.white.opacity(0.12), .clear, .black.opacity(0.18)]),
                                                 center: CGPoint(x: hc.x + r * 0.2, y: hc.y - r * 0.4),
                                                 startRadius: 0, endRadius: r * 1.5))

        let eye = CGPoint(x: hc.x + r * 0.38, y: hc.y - r * 0.12)
        if blink {
            var lid = Path()
            lid.move(to: CGPoint(x: eye.x - 0.9, y: eye.y + 0.1))
            lid.addQuadCurve(to: CGPoint(x: eye.x + 0.9, y: eye.y + 0.1), control: CGPoint(x: eye.x, y: eye.y + 0.7))
            c.stroke(lid, with: .color(Color.black.opacity(0.6)), style: StrokeStyle(lineWidth: 0.5, lineCap: .round))
        } else {
            c.stroke(Path(ellipseIn: CGRect(x: eye.x - 1.2, y: eye.y - 1.2, width: 2.4, height: 2.4)),
                     with: .color(.white.opacity(0.22)), lineWidth: 0.45)
            c.fill(Path(ellipseIn: CGRect(x: eye.x - 0.88, y: eye.y - 0.88, width: 1.76, height: 1.76)), with: .color(Color(white: 0.05)))
            c.fill(Path(ellipseIn: CGRect(x: eye.x + 0.0, y: eye.y - 0.62, width: 0.56, height: 0.56)), with: .color(.white.opacity(0.9)))
        }
    }

    // MARK: Helpers

    private static func rotate(_ c: inout GraphicsContext, around p: CGPoint, by noseUp: CGFloat) {
        c.translateBy(x: p.x, y: p.y)
        c.rotate(by: .radians(-noseUp))
        c.translateBy(x: -p.x, y: -p.y)
    }

    private static func ellipse(_ center: CGPoint, _ w: CGFloat, _ h: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: center.x - w / 2, y: center.y - h / 2, width: w, height: h))
    }

    /// A long feather from its base to its tip, `width` across at its widest, rounded at the end.
    private static func feather(from a: CGPoint, to b: CGPoint, width: CGFloat) -> Path {
        let dx = b.x - a.x, dy = b.y - a.y
        let length = max(0.01, hypot(dx, dy))
        let nx = -dy / length * width / 2, ny = dx / length * width / 2
        let mid = CGPoint(x: a.x + dx * 0.55, y: a.y + dy * 0.55)
        var p = Path()
        p.move(to: a)
        p.addQuadCurve(to: b, control: CGPoint(x: mid.x + nx * 2, y: mid.y + ny * 2))
        p.addQuadCurve(to: a, control: CGPoint(x: mid.x - nx * 2, y: mid.y - ny * 2))
        p.closeSubpath()
        return p
    }

    /// The pale edge along one side of a feather.
    private static func edgeLine(from a: CGPoint, to b: CGPoint, offset: CGFloat) -> Path {
        let dx = b.x - a.x, dy = b.y - a.y
        let length = max(0.01, hypot(dx, dy))
        let nx = -dy / length * offset, ny = dx / length * offset
        var p = Path()
        p.move(to: CGPoint(x: a.x + dx * 0.2 + nx, y: a.y + dy * 0.2 + ny))
        p.addLine(to: CGPoint(x: a.x + dx * 0.9 + nx * 0.6, y: a.y + dy * 0.9 + ny * 0.6))
        return p
    }
}

#if DEBUG
/// Every kind sitting, looking round, pecking, blinking and in flight, beside a stretch of rope, as a PNG.
@MainActor
public enum BirdSnapshot {
    public static func write(to url: URL) {
        let kinds = BirdKind.allCases
        let view = Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .linearGradient(
                Gradient(colors: [Color(red: 0.62, green: 0.50, blue: 0.48), Color(red: 0.36, green: 0.30, blue: 0.36)]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            var rope = Path()
            rope.move(to: CGPoint(x: 0, y: 50))
            rope.addLine(to: CGPoint(x: size.width, y: 50))
            ctx.stroke(rope, with: .color(Color(white: 0.6)), lineWidth: 1.2)
            for (i, kind) in kinds.enumerated() {
                let look = kind.look(jitter: 0)
                let x = 34 + CGFloat(i) * 130
                var sit = BirdPose(at: CGPoint(x: x, y: 50))
                BirdPainter.draw(look, sit, size: 2.2, in: &ctx)
                sit.at.x += 58
                sit.facing = -1
                switch i % 3 {
                case 0: sit.headBack = true
                case 1: sit.headDip = 1; sit.headTilt = 0.35
                default: sit.blink = true; sit.headTilt = 0.3; sit.tailLift = 0.8
                }
                BirdPainter.draw(look, sit, size: 2.2, in: &ctx)
                var fly = BirdPose(at: CGPoint(x: x + 8, y: 128))
                fly.flying = true
                fly.wing = 0.95
                fly.span = 1
                BirdPainter.draw(look, fly, size: 2.2, in: &ctx)
                fly.at.x += 62
                fly.wing = -0.75
                fly.span = 0.95
                fly.tilt = 0.25
                BirdPainter.draw(look, fly, size: 2.2, in: &ctx)
                var land = BirdPose(at: CGPoint(x: x + 30, y: 196))
                land.flying = true
                land.wing = 0.5
                land.tilt = 0.7
                land.tailFan = 1.8
                land.legsDown = true
                BirdPainter.draw(look, land, size: 2.2, in: &ctx)
            }
        }
        .frame(width: 790, height: 215)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 3
        guard let cg = renderer.cgImage else { return }
        let rep = NSBitmapImageRep(cgImage: cg)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
#endif
