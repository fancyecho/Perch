import SwiftUI

extension Priority {
    var title: String {
        switch self {
        case .none: tr("无", "None")
        case .low: tr("低", "Low")
        case .medium: tr("中", "Medium")
        case .high: tr("高", "High")
        }
    }

    var tint: Color {
        switch self {
        case .none: Color.secondary
        case .low: Color.blue
        case .medium: Color.orange
        case .high: Color.red
        }
    }
}

struct ProgressRing: View {
    let done: Int
    let total: Int
    var lineWidth: CGFloat = 3
    var showsCount = false

    @Environment(Feedback.self) private var feedback
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var fraction: Double { total == 0 ? 0 : Double(done) / Double(total) }
    private var isComplete: Bool { total > 0 && done == total }

    var body: some View {
        let popScale: CGFloat = reduceMotion ? 1 : 1.22
        ZStack {
            Circle().stroke(Color.primary.opacity(0.12), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(
                    isComplete ? AnyShapeStyle(Color.green) : AnyShapeStyle(AngularGradient(
                        colors: [Color.accentColor.opacity(0.7), Color.accentColor],
                        center: .center, startAngle: .zero, endAngle: .degrees(360 * max(fraction, 0.01))
                    )),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .shadow(color: (isComplete ? Color.green : Color.accentColor).opacity(isComplete ? 0.6 : 0), radius: 4)
            Group {
                if isComplete {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(.green)
                        .transition(.scale.combined(with: .opacity))
                } else if total == 0 {
                    Image(systemName: "bird.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                } else if showsCount {
                    Text("\(total - done)")
                        .font(.system(size: 11, weight: .bold, design: .rounded).monospacedDigit())
                        .contentTransition(.numericText())
                }
            }
        }
        // A small pop each time something gets done.
        .keyframeAnimator(initialValue: 1.0, trigger: feedback.completionCount) { content, scale in
            content.scaleEffect(scale)
        } keyframes: { _ in
            KeyframeTrack {
                SpringKeyframe(popScale, duration: 0.14, spring: .snappy)
                SpringKeyframe(1.0, duration: 0.4, spring: .bouncy)
            }
        }
        .animation(.spring(duration: 0.6, bounce: 0.2), value: fraction)
        .animation(.spring(duration: 0.4, bounce: 0.3), value: isComplete)
        .accessibilityElement()
        .accessibilityLabel(tr("今日进度 \(done)/\(total)", "Today's progress \(done)/\(total)"))
    }
}

/// Round checkbox: fills with a spring, draws its checkmark, and throws a ripple and a burst of sparks.
struct CheckCircle: View {
    let isOn: Bool
    let tint: Color
    var size: CGFloat = 18
    let action: () -> Void

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Ripple {
        var scale: CGFloat = 1
        var opacity: Double = 0
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .strokeBorder(tint.opacity(isOn || hovering ? 1 : 0.65), lineWidth: 1.5)
                Circle()
                    .fill(tint)
                    .scaleEffect(isOn ? 1 : 0.01)
                    .opacity(isOn ? 1 : 0)
                CheckmarkShape()
                    .trim(from: 0, to: isOn ? 1 : (hovering ? 1 : 0))
                    .stroke(isOn ? Color.white : tint.opacity(0.55), style: StrokeStyle(lineWidth: size * 0.12, lineCap: .round, lineJoin: .round))
                    .frame(width: size * 0.5, height: size * 0.5)
                    .animation(isOn ? .easeOut(duration: 0.28).delay(0.08) : .easeOut(duration: 0.12), value: isOn)
            }
            .frame(width: size, height: size)
            .background {
                Circle()
                    .stroke(tint, lineWidth: 1.5)
                    .keyframeAnimator(initialValue: Ripple(), trigger: isOn) { content, ripple in
                        content.scaleEffect(ripple.scale).opacity(ripple.opacity)
                    } keyframes: { _ in
                        KeyframeTrack(\.scale) {
                            LinearKeyframe(1, duration: 0)
                            SpringKeyframe(2.1, duration: 0.5)
                        }
                        KeyframeTrack(\.opacity) {
                            LinearKeyframe(isOn ? 0.7 : 0, duration: 0)
                            LinearKeyframe(0, duration: 0.5)
                        }
                    }
            }
            .overlay {
                if !reduceMotion { SparkBurst(isOn: isOn, tint: tint, radius: size * 1.5) }
            }
            .padding(4)
            .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.spring(duration: 0.32, bounce: 0.45), value: isOn)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityLabel(isOn ? tr("标记为未完成", "Mark as not done") : tr("完成", "Complete"))
    }
}

nonisolated struct CheckmarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.08, y: rect.minY + rect.height * 0.55))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.4, y: rect.maxY - rect.height * 0.12))
        path.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.05, y: rect.minY + rect.height * 0.15))
        return path
    }
}

/// Eight sparks that fly out of the checkbox when it gets checked.
private struct SparkBurst: View {
    let isOn: Bool
    let tint: Color
    let radius: CGFloat

    private static let count = 8

    var body: some View {
        ZStack {
            ForEach(0..<Self.count, id: \.self) { index in
                let angle = Angle.degrees(Double(index) / Double(Self.count) * 360 + 22.5)
                Capsule()
                    .fill(index.isMultiple(of: 2) ? tint : Color.accentColor.opacity(0.85))
                    .frame(width: 2.5, height: index.isMultiple(of: 2) ? 6.5 : 4.5)
                    .rotationEffect(angle + .degrees(90))
                    .keyframeAnimator(initialValue: 0.0, trigger: isOn) { content, progress in
                        content
                            .offset(x: cos(angle.radians) * radius * progress, y: sin(angle.radians) * radius * progress)
                            .opacity(isOn && progress > 0 && progress < 1 ? 1 - progress * progress : 0)
                            .scaleEffect(1.2 - progress * 0.6)
                    } keyframes: { _ in
                        KeyframeTrack {
                            LinearKeyframe(0, duration: 0.05)
                            CubicKeyframe(0.6, duration: 0.18)
                            CubicKeyframe(1, duration: 0.22)
                        }
                    }
            }
        }
        .allowsHitTesting(false)
    }
}

/// Confetti that rains down the panel when today's list is cleared.
struct ConfettiRain: View {
    let trigger: Int

    @State private var startedAt: Date?
    @State private var pieces: [Piece] = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let duration = 2.6
    private static let palette: [Color] = [.accentColor, .pink, .yellow, .green, .purple, .orange, .cyan]

    private struct Piece {
        let x: Double
        let delay: Double
        let fallSpeed: Double
        let swayAmount: Double
        let swaySpeed: Double
        let spin: Double
        let size: CGSize
        let color: Color
        let isRound: Bool
    }

    var body: some View {
        TimelineView(.animation(paused: startedAt == nil)) { context in
            Canvas { canvas, size in
                guard let startedAt else { return }
                let elapsed = context.date.timeIntervalSince(startedAt)
                for piece in pieces {
                    let t = elapsed - piece.delay
                    guard t > 0 else { continue }
                    let y = -20 + piece.fallSpeed * t + 140 * t * t
                    guard y < size.height + 20 else { continue }
                    let x = piece.x * size.width + sin(t * piece.swaySpeed) * piece.swayAmount
                    let fade = max(0, min(1, (Self.duration - elapsed) / 0.5))
                    var layer = canvas
                    layer.opacity = fade
                    layer.translateBy(x: x, y: y)
                    layer.rotate(by: .radians(t * piece.spin))
                    // Flipping width fakes the paper turning over as it falls.
                    let flip = abs(cos(t * piece.spin * 0.7))
                    let rect = CGRect(x: -piece.size.width * flip / 2, y: -piece.size.height / 2,
                                      width: piece.size.width * flip, height: piece.size.height)
                    layer.fill(piece.isRound ? Path(ellipseIn: rect) : Path(roundedRect: rect, cornerRadius: 1.2), with: .color(piece.color))
                }
            }
        }
        .allowsHitTesting(false)
        .onChange(of: trigger) {
            guard !reduceMotion else { return }
            pieces = (0..<70).map { _ in
                Piece(
                    x: .random(in: 0.02...0.98),
                    delay: .random(in: 0...0.5),
                    fallSpeed: .random(in: 60...170),
                    swayAmount: .random(in: 6...22),
                    swaySpeed: .random(in: 2...6),
                    spin: .random(in: -9...9),
                    size: CGSize(width: .random(in: 5...8), height: .random(in: 8...12)),
                    color: Self.palette.randomElement() ?? .accentColor,
                    isRound: Int.random(in: 0..<5) == 0
                )
            }
            startedAt = .now
            let started = startedAt
            Task {
                try? await Task.sleep(for: .seconds(Self.duration))
                if startedAt == started { startedAt = nil; pieces = [] }
            }
        }
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    var size: CGFloat = 24
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: size, height: size)
                .background(Circle().fill(Color.primary.opacity(hovering ? 0.1 : 0)))
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

struct Chip: View {
    let text: String
    let symbol: String
    var tint: Color = .accentColor

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 11, weight: .medium))
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .foregroundStyle(tint)
            .background(Capsule().fill(tint.opacity(0.14)))
    }
}
