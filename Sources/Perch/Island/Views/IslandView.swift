import SwiftUI

/// Everything that hangs from the notch: the black island and, in capsule style, the glass task
/// capsule beneath it. Both live in one window and move on the same springs.
struct IslandView: View {
    @Environment(IslandModel.self) private var model

    var body: some View {
        ZStack(alignment: .top) {
            if model.taskStyle == .capsule {
                TaskCard()
            }
            // Drawn last so it passes over the capsule: banners drop in front of it, and the open
            // island swallows it.
            IslandShape()
                .environment(\.colorScheme, .dark)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// The black island hanging from the top of the screen. One shape morphs between every state; each
/// state's content is laid out at its own final size and revealed as the shape grows around it.
private struct IslandShape: View {
    @Environment(IslandModel.self) private var model

    var body: some View {
        let layout = model.layout
        let shape = NotchShape(shoulder: layout.shoulder, cornerRadius: layout.cornerRadius)
        IslandContent(state: model.state)
            .frame(width: layout.width, height: layout.height, alignment: .top)
            .clipShape(shape)
            // The shadow sits on its own shape so the animating content never redraws it.
            .background {
                shape
                    .fill(Color.black)
                    .shadow(color: .black.opacity(layout.shadowOpacity), radius: 18, y: 8)
            }
            .overlay {
                if let glow = model.glow {
                    GlowRing(glow: glow, shape: shape)
                        .transition(.opacity.animation(.easeOut(duration: 0.5)))
                }
            }
            .opacity(layout.isHidden ? 0 : 1)
            .contentShape(shape)
            .onTapGesture { model.expand() }
            .contextMenu { IslandMenu() }
    }
}

/// A light that runs once around the island's edge: green when charging starts, a rainbow when
/// today is cleared, a red pulse when the battery runs low.
private struct GlowRing: View {
    let glow: IslandGlow
    let shape: NotchShape
    @State private var turn = 0.0

    /// Colors go all the way round: a gradient with a gap blinks out each time the gap passes
    /// the top edge, which sits off screen.
    private var colors: [Color] {
        switch glow {
        case .charging: [.green, .mint, .green, .mint, .green]
        case .celebration: [.pink, .orange, .yellow, .green, .cyan, .blue, .purple, .pink]
        case .lowBattery: [.red, .orange, .red, .orange, .red]
        case .alert: [.orange, .yellow, .orange, .red, .orange]
        }
    }

    var body: some View {
        let gradient = AngularGradient(colors: colors, center: .center, angle: .degrees(turn * 360))
        ZStack {
            shape.stroke(gradient, lineWidth: 6).blur(radius: 6).opacity(0.8)
            shape.stroke(gradient, lineWidth: 1.5)
        }
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.6)) { turn = 1 }
        }
    }
}

/// Locked: a closed padlock; on unlocking it springs open, as on iPhone.
private struct LockGlyph: View {
    let isOpen: Bool

    var body: some View {
        Image(systemName: isOpen ? "lock.open.fill" : "lock.fill")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(isOpen ? Color.green : .white)
            .contentTransition(.symbolEffect(.replace))
            .symbolEffect(.bounce, value: isOpen)
            .frame(width: 20)
    }
}

/// Right-click on the island: play controls when something plays, a pass to end, the tasks,
/// Focus, and Settings.
private struct IslandMenu: View {
    @Environment(IslandModel.self) private var model
    @Environment(NowPlayingService.self) private var media
    @Environment(FocusController.self) private var focus

    var body: some View {
        if media.track != nil {
            Button(media.isPlaying ? tr("暂停", "Pause") : tr("播放", "Play")) { media.send(.toggle) }
            Button(tr("下一首", "Next Track")) { media.send(.next) }
            Button(tr("上一首", "Previous Track")) { media.send(.previous) }
            Divider()
        }
        // On the lock screen only the player is anyone's business.
        if !model.isLocked {
            ForEach(focus.passes) { pass in
                Button(tr("结束 \(pass.name) 的临时使用", "End \(pass.name) Pass")) { focus.endPass(pass.key) }
            }
            if !focus.passes.isEmpty { Divider() }
            if model.taskStyle != .floating {
                Button(tr("全部任务", "All Tasks")) { model.tasksHandler?(false) }
                Button(tr("新建任务", "New Task")) { model.tasksHandler?(true) }
                Divider()
            }
            FocusMenuItems()
            Button(tr("系统状态", "System Status")) { model.statusHandler?() }
            Divider()
            Button(tr("灵动岛设置…", "Island Settings…")) { model.settingsHandler?(.island) }
            QuitMenuItem()
        }
    }
}

private struct IslandContent: View {
    let state: IslandState
    @Environment(IslandModel.self) private var model

    var body: some View {
        let size = bodySize(of: state)
        ZStack(alignment: .top) {
            switch state {
            case .idle:
                Color.clear
            case .live(let live):
                LiveActivityView(live: live)
                    .frame(width: size.width, height: size.height)
                    .transition(.materialize)
            case .banner(let banner):
                BannerView(banner: banner)
                    .frame(width: size.width, height: size.height)
                    .id(banner.kind)
                    .transition(.materialize)
            case .expanded:
                ExpandedIslandView()
                    .frame(width: size.width, height: size.height)
                    .transition(.materialize)
            case .tasks:
                IslandTaskList()
                    .frame(width: size.width, height: size.height)
                    .transition(.materialize)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func bodySize(of state: IslandState) -> CGSize {
        let layout = model.layout(for: state, hovering: false)
        return CGSize(width: layout.width - layout.shoulder * 2, height: layout.height)
    }
}

/// The island's outline: concave shoulders where it meets the top of the screen, so it seems to pour
/// out of the menu bar, and soft rounded corners below.
nonisolated struct NotchShape: Shape {
    var shoulder: CGFloat
    var cornerRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(shoulder, cornerRadius) }
        set {
            shoulder = newValue.first
            cornerRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let s = max(min(shoulder, rect.width / 4, rect.height / 2), 0)
        let r = max(min(cornerRadius, (rect.width - s * 2) / 2, rect.height - s), 0)
        // Bézier handle length for a quarter circle.
        let k: CGFloat = 0.552
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addCurve(
            to: CGPoint(x: rect.minX + s, y: rect.minY + s),
            control1: CGPoint(x: rect.minX + s * k, y: rect.minY),
            control2: CGPoint(x: rect.minX + s, y: rect.minY + s * (1 - k))
        )
        path.addLine(to: CGPoint(x: rect.minX + s, y: rect.maxY - r))
        path.addCurve(
            to: CGPoint(x: rect.minX + s + r, y: rect.maxY),
            control1: CGPoint(x: rect.minX + s, y: rect.maxY - r * (1 - k)),
            control2: CGPoint(x: rect.minX + s + r * (1 - k), y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - s - r, y: rect.maxY))
        path.addCurve(
            to: CGPoint(x: rect.maxX - s, y: rect.maxY - r),
            control1: CGPoint(x: rect.maxX - s - r * (1 - k), y: rect.maxY),
            control2: CGPoint(x: rect.maxX - s, y: rect.maxY - r * (1 - k))
        )
        path.addLine(to: CGPoint(x: rect.maxX - s, y: rect.minY + s))
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control1: CGPoint(x: rect.maxX - s, y: rect.minY + s * (1 - k)),
            control2: CGPoint(x: rect.maxX - s * k, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }
}

/// Content fades in slightly after the shape starts to grow, sharpening from a blur, and leaves fast.
private struct Materialize: ViewModifier {
    let isActive: Bool

    func body(content: Content) -> some View {
        content
            .opacity(isActive ? 0 : 1)
            .blur(radius: isActive ? 8 : 0)
            .scaleEffect(isActive ? 0.92 : 1, anchor: .top)
    }
}

extension AnyTransition {
    static var materialize: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: Materialize(isActive: true), identity: Materialize(isActive: false))
                .animation(.smooth(duration: 0.34).delay(0.08)),
            removal: .modifier(active: Materialize(isActive: true), identity: Materialize(isActive: false))
                .animation(.easeOut(duration: 0.14))
        )
    }
}

/// Content for the two wings beside the notch, kept clear of the camera housing between them.
struct WingsLayout<Leading: View, Trailing: View>: View {
    var inset: CGFloat = 14
    let leading: Leading
    let trailing: Trailing
    @Environment(IslandModel.self) private var model

    init(inset: CGFloat = 14, @ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing) {
        self.inset = inset
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 0) {
            leading.frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(width: model.geometry.notchSize.width + 8)
            trailing.frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, inset)
        .frame(height: model.geometry.notchSize.height)
    }
}

// MARK: - Live activity

/// The island at rest: what's playing on the left, today's tasks on the right (or the progress ring
/// on the left when nothing plays).
private struct LiveActivityView: View {
    let live: LiveActivity
    @Environment(NowPlayingService.self) private var media
    @Environment(TaskStore.self) private var store

    var body: some View {
        TimelineView(.everyMinute) { context in
            WingsLayout(inset: 11) {
                leading(now: context.date)
            } trailing: {
                trailing(now: context.date)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func leading(now: Date) -> some View {
        switch live.leading {
        case .artwork:
            ArtworkView(size: 22, cornerRadius: 6)
        case .progress:
            let progress = store.progress(now: now)
            ProgressRing(done: progress.done, total: progress.total, lineWidth: 2.5, showsCount: true)
                .frame(width: 20, height: 20)
        case .locked, .unlocked:
            LockGlyph(isOpen: live.leading == .unlocked)
        case .pass:
            PassWing(showsTime: false)
        case nil:
            EmptyView()
        }
    }

    @ViewBuilder
    private func trailing(now: Date) -> some View {
        switch live.trailing {
        case .equalizer:
            EqualizerBars(isPlaying: media.isPlaying, tint: media.accent ?? .white, maxHeight: 13)
        case .due:
            if let task = store.headline(now: now) {
                // Just the time: red already says when it's late.
                Text(task.schedule?.time.map(DateText.time) ?? tr("逾期", "Late"))
                    .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(DateText.isOverdue(task, now: now) ? Color.red : .white.opacity(0.9))
                    .fixedSize()
                    .accessibilityLabel(tr("下一项：\(task.title)", "Next: \(task.title)"))
            }
        case .focus:
            if let focus = store.focus {
                FocusTimer(start: focus.startedAt)
                    .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Color.accentColor)
                    .fixedSize()
            }
        case .countdown:
            PassWing(showsTime: true)
        case nil:
            EmptyView()
        }
    }
}

/// A pass beside the notch: its icon in the shrinking ring on the left, the time left on the right,
/// turning red for the last half minute.
private struct PassWing: View {
    let showsTime: Bool
    @Environment(FocusController.self) private var focus

    var body: some View {
        if let pass = focus.passes.first {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = max(0, Int(pass.end.timeIntervalSince(context.date).rounded(.up)))
                let urgent = remaining <= 30
                if showsTime {
                    Text(String(format: "%d:%02d", remaining / 60, remaining % 60))
                        .font(.system(size: 12.5, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(urgent ? PassRing.urgentColor : .white.opacity(0.9))
                        .contentTransition(.numericText(countsDown: true))
                        .animation(.snappy(duration: 0.3), value: remaining)
                        // The last half minute breathes, like a lamp burning down.
                        .opacity(urgent && remaining % 2 == 0 ? 0.55 : 1)
                        .animation(.easeInOut(duration: 0.9), value: remaining % 2)
                        .fixedSize()
                } else {
                    PassRing(icon: pass.icon, isSite: pass.site != nil,
                             fraction: min(Double(remaining) / ActivePass.duration, 1), urgent: urgent, lineWidth: 2)
                        .frame(width: 21, height: 21)
                }
            }
            .accessibilityLabel(tr("\(pass.name) 临时使用", "\(pass.name) pass"))
        }
    }
}

// MARK: - Task list

/// The full task list, grown down out of the notch.
private struct IslandTaskList: View {
    @Environment(IslandModel.self) private var model
    @Environment(Feedback.self) private var feedback

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: model.geometry.notchSize.height)
            PanelView()
                .frame(width: 368, height: IslandModel.taskPanel.height)
        }
        .overlay { ConfettiRain(trigger: feedback.celebrationCount) }
    }
}
