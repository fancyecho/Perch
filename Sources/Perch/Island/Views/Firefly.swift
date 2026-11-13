import SwiftUI

/// Fireflies under the resting bar, there while something is going on. While you focus, one warm
/// light hovers close under the bar, breathing slowly. With tasks still open today, a few green
/// lights, one for each task up to three, wander in the air below it and flash now and again, each
/// to its own rhythm, rising a little as they light. The glass catches their light along its lower
/// edge as one comes near, so bar and fireflies read as one scene. Nothing to do and nothing
/// running, there are none.
struct BarFirefly: View {
    @Environment(TaskStore.self) private var store
    @Environment(ScheduleStore.self) private var schedules
    let barSize: CGSize

    var body: some View {
        // What they're out for only changes with the tasks or by the minute.
        TimelineView(.everyMinute) { context in
            if let mood = mood(at: context.date) {
                Fireflies(mood: mood, bar: barSize)
                    .transition(.opacity.animation(.easeInOut(duration: 0.9)))
            }
        }
    }

    private func mood(at now: Date) -> Fireflies.Mood? {
        if store.focus != nil || !schedules.activeOccurrences(at: now).isEmpty { return .focus }
        let progress = store.progress(now: now)
        let left = progress.total - progress.done
        return left > 0 ? .tasks(min(left, 3)) : nil
    }
}

struct Fireflies: View {
    enum Mood: Equatable {
        case focus
        case tasks(Int)
    }

    let mood: Mood
    let bar: CGSize
    /// Each evening's fireflies keep their own paths and rhythms.
    @State private var seed = Double.random(in: 0...10_000)

    /// Room around the bar: to the sides and below, where they fly. The view is centred on the bar.
    static let margin = CGSize(width: 38, height: 30)

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            Canvas { ctx, size in
                Self.draw(mood: mood, bar: bar, seed: seed, in: &ctx, size: size,
                          at: context.date.timeIntervalSinceReferenceDate)
            }
        }
        .frame(width: bar.width + Self.margin.width * 2, height: bar.height + Self.margin.height * 2)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: Where they are and how bright

    struct Fly {
        var at: CGPoint
        var brightness: Double
        var color: Color
        /// The same light, deeper, for the edge of its glow.
        var deep: Color
    }

    private static let warm = Color(red: 1.0, green: 0.74, blue: 0.34)
    private static let warmDeep = Color(red: 0.95, green: 0.52, blue: 0.12)
    private static let greens = [
        Color(red: 0.78, green: 1.0, blue: 0.38),
        Color(red: 0.92, green: 1.0, blue: 0.48),
        Color(red: 0.62, green: 1.0, blue: 0.54),
    ]
    private static let deepGreens = [
        Color(red: 0.42, green: 0.82, blue: 0.1),
        Color(red: 0.66, green: 0.84, blue: 0.12),
        Color(red: 0.24, green: 0.8, blue: 0.3),
    ]

    static func flies(mood: Mood, bar rect: CGRect, seed: Double, at t: Double) -> [Fly] {
        let s = t + seed
        let reach = rect.width / 2 + 22
        switch mood {
        case .focus:
            // Close under the middle of the bar, drifting slowly, a breath every five and a half seconds.
            let x = rect.midX + reach * 0.42 * CGFloat(0.8 * sin(s * 0.19) + 0.2 * sin(s * 0.47 + 1))
            let y = rect.maxY + 6.5 + CGFloat(2.2 * sin(s * 0.6) + 0.8 * sin(s * 1.7))
            let breath = 0.5 - 0.5 * cos(2 * .pi * s / 5.5)
            return [Fly(at: CGPoint(x: x, y: y), brightness: 0.42 + 0.58 * breath, color: warm, deep: warmDeep)]
        case .tasks(let count):
            return (0..<count).map { i in
                let k = Double(i)
                let b = flashes(s, k, seed: seed)
                let x = rect.midX + reach * CGFloat(0.62 * sin(s * (0.2 + 0.055 * k) + k * 2.3) + 0.28 * sin(s * (0.51 + 0.11 * k) + k))
                // Lit, it rises a little, the way they do.
                let y = rect.maxY + 9 + CGFloat(5.5 * sin(s * (0.35 + 0.08 * k) + k * 1.7) + 2.2 * sin(s * (1.05 + 0.2 * k)))
                    - 3 * CGFloat(max(0, b - 0.15))
                return Fly(at: CGPoint(x: x, y: max(rect.maxY + 2.5, y)), brightness: b, color: greens[i % greens.count], deep: deepGreens[i % deepGreens.count])
            }
        }
    }

    /// A firefly's rhythm: a quick rise, a short hold, a soft fade, then a long dim rest; now and
    /// then two flashes close together. Each one keeps its own period.
    private static func flashes(_ s: Double, _ k: Double, seed: Double) -> Double {
        let period = 3.2 + 0.85 * k
        let shifted = s + k * 1.31
        let n = floor(shifted / period)
        let u = shifted / period - n
        let h = hash(n * 3 + k, seed)
        let start = 0.06 + 0.32 * h
        var env = flash(u - start)
        if h > 0.7 { env = max(env, 0.75 * flash(u - start - 0.13)) }
        return 0.14 + 0.86 * env
    }

    private static func flash(_ x: Double) -> Double {
        guard x > 0 else { return 0 }
        if x < 0.06 { return 0.5 - 0.5 * cos(.pi * x / 0.06) }
        if x < 0.1 { return 1 }
        return exp(-(x - 0.1) / 0.09)
    }

    private static func hash(_ n: Double, _ seed: Double) -> Double {
        let v = sin(n * 127.1 + seed * 0.013) * 43_758.5453
        return v - floor(v)
    }

    // MARK: Drawing

    static func draw(mood: Mood, bar: CGSize, seed: Double, in ctx: inout GraphicsContext, size: CGSize, at t: Double) {
        let rect = CGRect(x: (size.width - bar.width) / 2, y: (size.height - bar.height) / 2,
                          width: bar.width, height: bar.height)
        let flies = flies(mood: mood, bar: rect, seed: seed, at: t)

        // The glass catches each one's light along its lower edge, brighter the closer it flies.
        let tube = Path(roundedRect: rect, cornerRadius: rect.height / 2, style: .continuous)
        var glass = ctx
        glass.clip(to: tube)
        glass.drawLayer { edge in
            edge.addFilter(.blur(radius: 1.3))
            edge.blendMode = .plusLighter
            for fly in flies {
                let gx = min(max(fly.at.x, rect.minX + 2), rect.maxX - 2)
                let near = max(0, 1 - Double(hypot(fly.at.x - gx, fly.at.y - rect.maxY)) / 20)
                guard near > 0 else { continue }
                let w = 10 + 8 * CGFloat(near)
                edge.fill(Path(ellipseIn: CGRect(x: gx - w, y: rect.maxY - 3.2, width: w * 2, height: 6.4)),
                          with: .radialGradient(Gradient(colors: [fly.color.opacity(0.95 * fly.brightness * near), fly.color.opacity(0)]),
                                                center: CGPoint(x: gx, y: rect.maxY), startRadius: 0, endRadius: w))
            }
        }

        for fly in flies {
            let b = CGFloat(fly.brightness)
            let p = fly.at
            // The glow, wide and soft. Its outer edge is a deeper shade of the same colour, never
            // grey, so on a light wallpaper it still shows as a soft coloured bloom.
            let wide = 3.8 + 8 * b
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - wide, y: p.y - wide, width: wide * 2, height: wide * 2)),
                     with: .radialGradient(Gradient(stops: [
                        .init(color: fly.color.opacity(0.62 * fly.brightness), location: 0),
                        .init(color: fly.deep.opacity(0.2 * fly.brightness + 0.03), location: 0.45),
                        .init(color: fly.deep.opacity(0), location: 1),
                     ]), center: p, startRadius: 0, endRadius: wide))
            // The light itself: coloured at rest, white at its heart when it flashes.
            let r = 0.85 + 0.65 * b
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                     with: .color(fly.color.opacity(0.55 + 0.45 * fly.brightness)))
            let heart = r * 0.62
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - heart, y: p.y - heart, width: heart * 2, height: heart * 2)),
                     with: .color(Color.white.opacity(0.95 * pow(fly.brightness, 1.6))))
        }
    }
}

#if DEBUG
/// The bar and its fireflies at a few moments, focus and one to three tasks, under a sketch of the
/// island, on dark and light, as a PNG.
enum FireflySnapshot {
    static func write(to url: URL) {
        let times: [Double] = [0, 0.8, 1.6, 2.4, 3.2, 4.0]
        let moods: [Fireflies.Mood] = [.focus, .tasks(1), .tasks(2), .tasks(3)]
        let bar = CGSize(width: 56, height: 5)
        let view = VStack(spacing: 0) {
            ForEach(0..<2, id: \.self) { shade in
                VStack(spacing: 0) {
                    ForEach(0..<moods.count, id: \.self) { m in
                        HStack(spacing: 0) {
                            ForEach(times, id: \.self) { t in
                                ZStack(alignment: .top) {
                                    UnevenRoundedRectangle(bottomLeadingRadius: 12, bottomTrailingRadius: 12)
                                        .fill(.black).frame(width: 120, height: 14)
                                    ZStack {
                                        Capsule().fill(Color(white: shade == 0 ? 0.55 : 0.2).opacity(0.5))
                                            .frame(width: bar.width, height: bar.height)
                                        Canvas { ctx, size in
                                            Fireflies.draw(mood: moods[m], bar: bar, seed: Double(m) * 5 + 2, in: &ctx, size: size, at: t)
                                        }
                                        .frame(width: bar.width + Fireflies.margin.width * 2, height: bar.height + Fireflies.margin.height * 2)
                                    }
                                    .offset(y: 20 - Fireflies.margin.height + 2)
                                }
                                .frame(width: 150, height: 66, alignment: .top)
                                .clipped()
                            }
                        }
                    }
                }
                .background(shade == 0 ? Color(white: 0.1) : Color(white: 0.88))
            }
        }
        let renderer = ImageRenderer(content: view)
        renderer.scale = 3
        guard let cg = renderer.cgImage else { return }
        try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: url)
    }
}
#endif
