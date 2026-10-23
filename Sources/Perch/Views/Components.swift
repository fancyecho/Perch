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

    private var fraction: Double { total == 0 ? 0 : Double(done) / Double(total) }
    private var isComplete: Bool { total > 0 && done == total }

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.12), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(isComplete ? Color.green : Color.accentColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
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
        .animation(.spring(duration: 0.6, bounce: 0.2), value: fraction)
        .animation(.spring(duration: 0.4, bounce: 0.3), value: isComplete)
        .accessibilityElement()
        .accessibilityLabel(tr("今日进度 \(done)/\(total)", "Today's progress \(done)/\(total)"))
    }
}

/// Round checkbox that fills with a spring and throws a little ripple when checked.
struct CheckCircle: View {
    let isOn: Bool
    let tint: Color
    var size: CGFloat = 18
    let action: () -> Void

    @State private var hovering = false

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
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.5, weight: .heavy))
                    .foregroundStyle(isOn ? Color.white : tint)
                    .scaleEffect(isOn || hovering ? 1 : 0.4)
                    .opacity(isOn ? 1 : hovering ? 0.55 : 0)
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
