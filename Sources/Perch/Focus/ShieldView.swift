import AppKit
import SwiftUI

/// The shield's windows: a blur on every screen, the content on the main one.
final class ShieldController {
    static let holdSeconds: TimeInterval = 3

    private(set) var target: BlockTarget?
    private var model = ShieldModel()
    private var windows: [(window: CurtainWindow, blur: BackdropBlurView)] = []
    private var isDismissing = false

    var onBack: () -> Void = {}
    var onPass: (BlockTarget, BlockRule) -> Void = { _, _ in }

    var isShowing: Bool { target != nil && !isDismissing }

    func show(_ target: BlockTarget, occurrence: Occurrence, passesLeft: Int, attempt: Int?) {
        if isShowing, self.target?.identity == target.identity {
            // The same thing came forward again (say, from its notification): refresh, take focus back.
            model.occurrence = occurrence
            model.passesLeft = passesLeft
            NSApp.activate()
            windows.first?.window.makeKeyAndOrderFront(nil)
            return
        }
        if self.target != nil { tearDown() }

        self.target = target
        model = ShieldModel()
        model.appName = target.name
        model.appIcon = target.icon
        model.isSite = target.isSite
        model.occurrence = occurrence
        model.passesLeft = passesLeft
        model.attempt = attempt ?? 1
        model.onBack = { [weak self] in self?.onBack() }
        model.onHoldChanged = { [weak self] holding in self?.setHolding(holding) }
        model.onHoldCompleted = { [weak self] in
            guard let self, let target = self.target, let rule = self.model.occurrence?.rule else { return }
            SoundPlayer.shared.playNote(4)
            self.onPass(target, rule)
        }

        buildWindows()
        NSApp.activate()
        windows.first?.window.makeKeyAndOrderFront(nil)
        windows.forEach { $0.blur.setBlurred(true, duration: 0.8) }
        SoundPlayer.shared.playNote(0)
        Task {
            try? await Task.sleep(for: .milliseconds(80))
            model.appeared = true
        }
    }

    func dismiss(playSound: Bool) {
        guard target != nil, !isDismissing else { return }
        isDismissing = true
        if playSound { SoundPlayer.shared.playNote(5) }
        SoundPlayer.shared.stop(.hold, fade: 0.2)
        model.appeared = false
        windows.forEach { $0.blur.setBlurred(false, duration: 0.5) }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.5
            windows.forEach { $0.window.animator().alphaValue = 0 }
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.tearDown() }
        })
    }

    private func setHolding(_ holding: Bool) {
        guard isShowing else { return }
        model.holding = holding
        if holding {
            withAnimation(.linear(duration: Self.holdSeconds)) { model.holdProgress = 1 }
            SoundPlayer.shared.play(.hold)
        } else {
            withAnimation(.spring(duration: 0.5, bounce: 0.25)) { model.holdProgress = 0 }
            SoundPlayer.shared.stop(.hold, fade: 0.25)
        }
    }

    private func tearDown() {
        windows.forEach { $0.window.orderOut(nil) }
        windows.removeAll()
        target = nil
        isDismissing = false
    }

    private func buildWindows() {
        let mainScreen = NSScreen.main ?? NSScreen.screens.first
        let screens = NSScreen.screens.filter { $0 == mainScreen } + NSScreen.screens.filter { $0 != mainScreen }
        for screen in screens {
            let window = CurtainWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.setFrame(screen.frame, display: false)
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)

            let container = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
            let blur = BackdropBlurView(frame: container.bounds)
            container.addSubview(blur)
            let content = NSHostingView(rootView: ShieldView(model: model, showsContent: screen == mainScreen))
            content.frame = container.bounds
            content.autoresizingMask = [.width, .height]
            container.addSubview(content)

            window.contentView = container
            window.orderFrontRegardless()
            windows.append((window, blur))
        }
    }
}

@Observable
final class ShieldModel {
    var appeared = false
    var appName = ""
    /// A site: its icon keeps its color and the strict note reads differently.
    var isSite = false
    var appIcon = NSImage()
    var occurrence: Occurrence?
    var quote = Quotes.random()
    var passesLeft = 0
    /// The how-many-th time today it was opened.
    var attempt = 1
    var holding = false
    var holdProgress: Double = 0

    var onBack: () -> Void = {}
    var onHoldChanged: (Bool) -> Void = { _ in }
    var onHoldCompleted: () -> Void = {}
}

/// What goes over a paused app. In the middle its icon, drained of color, inside a ring that burns
/// down like lamp oil: lit for as much of the schedule as is left.
struct ShieldView: View {
    @Bindable var model: ShieldModel
    let showsContent: Bool

    var body: some View {
        ZStack {
            Atmosphere()
                .opacity(model.appeared ? 1 : 0)
                .animation(.easeInOut(duration: model.appeared ? 1.0 : 0.4), value: model.appeared)

            if showsContent, let occurrence = model.occurrence {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    content(occurrence, now: context.date)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func content(_ occurrence: Occurrence, now: Date) -> some View {
        let rule = occurrence.rule
        return VStack(spacing: 0) {
            Spacer(minLength: 60)

            HStack(spacing: 8) {
                Circle().fill(RuleTint.color(rule.tint)).frame(width: 7, height: 7)
                Text(tr("\(rule.name) · 进行中", "\(rule.name) · IN PROGRESS"))
            }
            .font(.system(size: 12, weight: .semibold))
            .tracking(3)
            .opacity(0.7)
            .reveal(model.appeared, delay: 0.35)
            .padding(.bottom, 36)

            LampRing(icon: model.appIcon, remaining: 1 - occurrence.progress(at: now),
                     tint: rule.tint, lit: model.appeared, roundsIcon: model.isSite)
                .frame(width: 176, height: 176)
                .reveal(model.appeared, delay: 0.1)
                .padding(.bottom, 44)

            Text(tr("此刻，先不打开 \(model.appName)", "Not \(model.appName), not right now"))
                .font(AppSettings.shared.isChinese ? .custom("STSongti-SC-Bold", size: 42) : .system(size: 40, weight: .semibold, design: .serif))
                .tracking(2)
                .multilineTextAlignment(.center)
                .reveal(model.appeared, delay: 0.5)

            Text(tr("「\(rule.name)」\(ScheduleText.moment(occurrence.end, from: now)) 结束 · 还有 \(ScheduleText.remaining(until: occurrence.end, from: now))",
                    "“\(rule.name)” ends at \(ScheduleText.moment(occurrence.end, from: now)) · \(ScheduleText.remaining(until: occurrence.end, from: now)) to go"))
                .font(.system(size: 15, weight: .medium))
                .monospacedDigit()
                .opacity(0.62)
                .padding(.top, 18)
                .reveal(model.appeared, delay: 0.65)

            // Not a reproach, just something to notice: only from the second time on.
            if model.attempt >= 2 {
                Text(tr("这是今天第 \(model.attempt) 次想打开它", "That's \(model.attempt) times today"))
                    .font(.system(size: 12.5, weight: .medium))
                    .opacity(0.55)
                    .padding(.top, 8)
                    .reveal(model.appeared, delay: 0.75)
            }

            Spacer(minLength: 40)

            Text(model.quote.text)
                .font(.system(size: 15, weight: .regular, design: .serif))
                .italic()
                .multilineTextAlignment(.center)
                .frame(maxWidth: 640)
                .opacity(0.55)
                .reveal(model.appeared, delay: 0.85)
                .padding(.bottom, 34)

            ShieldActions(model: model, rule: rule)
                .reveal(model.appeared, delay: 1.0)
                .padding(.bottom, 60)
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.22), radius: 24, y: 2)
        .accessibilityElement(children: .contain)
    }
}

/// The icon and its ring. A point of flame rides the ring's head back as time runs out.
private struct LampRing: View {
    let icon: NSImage
    let remaining: Double
    let tint: Int
    let lit: Bool
    var roundsIcon = false

    var body: some View {
        let shown = lit ? remaining : 0
        let color = RuleTint.color(tint)
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            let radius = size / 2
            ZStack {
                Circle()
                    .stroke(.white.opacity(0.1), lineWidth: 3)

                Circle()
                    .trim(from: 0, to: shown)
                    .stroke(AngularGradient(colors: [color.opacity(0.25), color], center: .center,
                                            startAngle: .degrees(0), endAngle: .degrees(360 * max(shown, 0.01))),
                            style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: color.opacity(0.8), radius: 8)

                // The flame starts at twelve o'clock and the whole thing turns, so it travels along
                // the arc in step with the ring (offsetting by sin and cos would cut across the middle).
                Circle()
                    .fill(.white)
                    .frame(width: 7, height: 7)
                    .shadow(color: color, radius: 6)
                    .shadow(color: color.opacity(0.8), radius: 14)
                    .offset(y: -radius)
                    .rotationEffect(.degrees(360 * shown))
                    .opacity(lit ? 1 : 0)

                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size * (roundsIcon ? 0.44 : 0.56), height: size * (roundsIcon ? 0.44 : 0.56))
                    // Site icons are mostly square; round them like an app icon.
                    .clipShape(RoundedRectangle(cornerRadius: roundsIcon ? size * 0.1 : 0, style: .continuous))
                    .saturation(0.12)
                    .opacity(0.88)
                    .scaleEffect(lit ? 1 : 1.12)
                    .shadow(color: .black.opacity(0.3), radius: 18, y: 8)
            }
            .frame(width: size, height: size)
            .animation(.smooth(duration: 1.4).delay(lit ? 0.2 : 0), value: lit)
        }
        .accessibilityElement()
        .accessibilityLabel(tr("时段还剩 \(Int(remaining * 100))%", "\(Int(remaining * 100))% of the schedule left"))
    }
}

private struct ShieldActions: View {
    @Bindable var model: ShieldModel
    let rule: BlockRule

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 14) {
                if model.passesLeft > 0 {
                    HoldToPass(model: model)
                }
                Button(action: model.onBack) {
                    Label(tr("回到学习", "Back to Work"), systemImage: "arrow.uturn.backward")
                        .font(.system(size: 14, weight: .semibold))
                        .padding(.horizontal, 22)
                        .padding(.vertical, 12)
                        .background(Brand.gradient, in: .capsule)
                        .overlay { Capsule().strokeBorder(.white.opacity(0.2)) }
                        .shadow(color: Brand.glow.opacity(0.4), radius: 14, y: 4)
                        .contentShape(Capsule())
                }
                .buttonStyle(SoftPressStyle())
                .keyboardShortcut(.defaultAction)

                // Esc goes back to work too.
                Button("", action: model.onBack)
                    .keyboardShortcut(.cancelAction)
                    .opacity(0)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }

            Text(footnote)
                .font(.system(size: 12, weight: .medium))
                .opacity(0.5)
        }
    }

    private var footnote: String {
        if rule.isStrict {
            return model.isSite
                ? tr("严格时段 · 结束前不能跳过，回去时会关掉这个标签页", "Strict schedule · no skipping; going back closes this tab")
                : tr("严格时段 · 结束前不能跳过，回去时会退出 \(model.appName)", "Strict schedule · no skipping; going back quits \(model.appName)")
        }
        if model.isSite { return tr("按回车回去，这个标签页会被关掉", "Press Return to go back; this tab will close") }
        if model.passesLeft == 0 { return tr("今天的临时使用次数已经用完了", "No more passes today") }
        return tr("按回车回去", "Press Return to go back")
    }
}

/// Hold for three seconds to use it five more minutes: the capsule fills from the left and springs
/// back if let go early.
private struct HoldToPass: View {
    @Bindable var model: ShieldModel

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle().stroke(.white.opacity(0.25), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: model.holdProgress)
                    .stroke(.white, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 15, height: 15)
            Text(model.holding ? tr("继续按住…", "Keep holding…") : tr("按住，再用 \(ScheduleStore.passMinutes) 分钟", "Hold for \(ScheduleStore.passMinutes) more minutes"))
                .contentTransition(.interpolate)
            Text(tr("剩 \(model.passesLeft) 次", "\(model.passesLeft) left"))
                .opacity(0.5)
        }
        .font(.system(size: 13, weight: .semibold))
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(alignment: .leading) {
            GeometryReader { proxy in
                Capsule()
                    .fill(.white.opacity(0.2))
                    .frame(width: proxy.size.width * model.holdProgress)
            }
        }
        .clipShape(Capsule())
        .glassEffect(.regular.interactive(), in: .capsule)
        .contentShape(Capsule())
        .animation(.smooth(duration: 0.3), value: model.holding)
        .onLongPressGesture(minimumDuration: ShieldController.holdSeconds, maximumDistance: 60,
                            perform: model.onHoldCompleted, onPressingChanged: model.onHoldChanged)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(tr("按住三秒，临时使用 \(ScheduleStore.passMinutes) 分钟", "Hold for three seconds to use it \(ScheduleStore.passMinutes) more minutes"))
    }
}
