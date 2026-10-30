import AppKit
import SwiftUI

/// What every screen's blur shows, driven by FocusOverlay.
@Observable
final class OverlayModel {
    struct TaskLine: Equatable {
        let id: UUID
        let title: String
    }

    struct Summary {
        let session: TimeInterval
        let today: TimeInterval
        let streak: Int
    }

    var appeared = false
    var quote = Quotes.random()
    /// The task this session is about.
    var task: TaskLine?
    var taskCompleted = false
    var shortcutText = "⌥⌘F"

    /// Untouched for a while: only the quote and the clock stay.
    var ambient = false

    /// Seconds counted before the display last slept, plus when the current stretch began.
    var accumulated: TimeInterval = 0
    var segmentStart: Date? = .now

    var holding = false
    var holdProgress: Double = 0

    var typingRevealed = false
    var typed = ""
    var wrongAttempts = 0
    /// An input method is composing (pinyin not yet committed).
    var composing = false
    /// The pointer rests on the clock, which turns into the session timer.
    var hoveringClock = false

    /// After unlocking, the summary takes the middle of the screen.
    var summary: Summary?

    var onSubmit: () -> Void = {}
    var onTypedChange: () -> Void = {}
    var onCompleteTask: () -> Void = {}
    var onDismissSummary: () -> Void = {}

    func elapsed(at date: Date = .now) -> TimeInterval {
        accumulated + (segmentStart.map { max(0, date.timeIntervalSince($0)) } ?? 0)
    }

    /// Characters of the phrase typed correctly so far, ignoring spaces, punctuation and case.
    var matchedCount: Int {
        let phrase = Array(Self.normalize(FocusOverlay.unlockPhrase))
        var count = 0
        for char in Self.normalize(typed) {
            guard count < phrase.count, phrase[count] == char else { break }
            count += 1
        }
        return count
    }

    var isComplete: Bool {
        Self.normalize(typed) == Self.normalize(FocusOverlay.unlockPhrase)
    }

    static func isIgnored(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { ignored.contains($0) }
    }

    static func normalize(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { !ignored.contains($0) })).lowercased()
    }

    private static let ignored = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
}

// MARK: - The blur's content

struct OverlayView: View {
    @Bindable var model: OverlayModel
    let showsControls: Bool

    var body: some View {
        ZStack {
            Atmosphere()
                .opacity(model.appeared ? 1 : 0)
                .animation(.easeInOut(duration: model.appeared ? 1.4 : 0.6), value: model.appeared)

            VStack(spacing: 0) {
                Spacer(minLength: 80)

                ZStack {
                    if let summary = model.summary {
                        SummaryView(summary: summary, model: model, showsActions: showsControls)
                            .transition(.blurReplace.combined(with: .scale(0.97)))
                    } else {
                        focusContent
                            .transition(.blurReplace.combined(with: .scale(1.03)))
                    }
                }
                .reveal(model.appeared, delay: 0)

                Spacer(minLength: 40)

                if showsControls {
                    UnlockControls(model: model)
                        .opacity(model.ambient ? 0 : 1)
                        .blur(radius: model.ambient ? 6 : 0)
                        .allowsHitTesting(!model.ambient)
                        .reveal(model.appeared && model.summary == nil, delay: 1.5)
                        .padding(.bottom, 44)
                }
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.22), radius: 24, y: 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var focusContent: some View {
        VStack(spacing: 0) {
            QuoteView(quote: model.quote)
                .id(model.quote.text)
                .transition(.blurReplace)
                .reveal(model.appeared, delay: 0.75)

            Capsule()
                .fill(.white.opacity(0.35))
                .frame(width: model.appeared ? 48 : 0, height: 1.5)
                .animation(.smooth(duration: 1.1).delay(model.appeared ? 1.15 : 0), value: model.appeared)
                .padding(.top, 40)
                .padding(.bottom, 34)

            HeroClock(model: model)
                .reveal(model.appeared, delay: 1.25)

            if let task = model.task {
                // What this session is for, quietly, under the clock.
                Label(task.title, systemImage: "scope")
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
                    .frame(maxWidth: 520)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.white.opacity(0.08), in: Capsule())
                    .opacity(model.ambient ? 0.45 : 0.8)
                    .padding(.top, 26)
                    .reveal(model.appeared, delay: 1.45)
            }
        }
    }
}

/// Chinese in Songti, English in New York: a bookish serif rather than a sans.
private struct QuoteView: View {
    let quote: Quote

    private var isChinese: Bool { quote.text.unicodeScalars.contains { $0.properties.isIdeographic } }

    var body: some View {
        VStack(spacing: 22) {
            Text(quote.text)
                .font(isChinese ? .custom("STSongti-SC-Bold", size: 48) : .system(size: 46, weight: .semibold, design: .serif))
                .tracking(isChinese ? 2 : 0)
                .lineSpacing(isChinese ? 16 : 10)
                .multilineTextAlignment(.center)
                .frame(maxWidth: isChinese ? 1000 : 960)
                .fixedSize(horizontal: false, vertical: true)

            Text(isChinese ? quote.author : quote.author.uppercased())
                .font(.system(size: isChinese ? 15 : 12, weight: .medium))
                .tracking(isChinese ? 6 : 3)
                .opacity(0.6)
        }
    }
}

/// The big clock. It shows the time, not the session, so there's nothing to stare at; moving the
/// mouse brings "focused for N minutes" underneath, and resting on the clock turns it into the
/// session timer with seconds.
private struct HeroClock: View {
    @Bindable var model: OverlayModel
    @Environment(AppSettings.self) private var settings

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let showElapsed = model.hoveringClock && !model.ambient
            let elapsed = Int(model.elapsed(at: context.date))
            let clock = ScheduleText.time(context.date)

            VStack(spacing: 14) {
                ZStack {
                    if showElapsed {
                        Text(DurationText.clock(TimeInterval(elapsed)))
                            .contentTransition(.numericText())
                            .animation(.snappy(duration: 0.4), value: elapsed)
                            .transition(.blurReplace)
                    } else {
                        Text(clock)
                            .contentTransition(.numericText())
                            .animation(.smooth(duration: 0.8), value: clock)
                            .transition(.blurReplace)
                    }
                }
                .font(.system(size: 92, weight: .thin))
                .monospacedDigit()
                .frame(height: 100)

                ZStack {
                    Text(caption(showElapsed: showElapsed, elapsed: elapsed, date: context.date))
                        .id(captionKind(showElapsed: showElapsed))
                        .transition(.blurReplace)
                }
                .font(.system(size: 13, weight: .semibold))
                .tracking(3)
                .opacity(0.55)
            }
            .padding(.horizontal, 40)
            .contentShape(Rectangle())
        }
        .onHover { hovering in
            withAnimation(.smooth(duration: 0.5)) { model.hoveringClock = hovering }
        }
    }

    private func captionKind(showElapsed: Bool) -> String {
        showElapsed ? "elapsed" : model.ambient ? "date" : "focused"
    }

    private func caption(showElapsed: Bool, elapsed: Int, date: Date) -> String {
        if model.segmentStart == nil { return tr("已暂停", "PAUSED") }
        if showElapsed { return tr("本次专注", "THIS SESSION") }
        if model.ambient { return dateText(date) }
        return elapsed < 60 ? tr("刚刚开始专注", "JUST STARTED") : tr("已专注 \(DurationText.long(TimeInterval(elapsed)))", "FOCUSED \(DurationText.long(TimeInterval(elapsed)).uppercased())")
    }

    private func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = settings.locale
        formatter.timeZone = settings.timeZone
        formatter.setLocalizedDateFormatFromTemplate(settings.isChinese ? "MMMdEEEE" : "EEEEMMMd")
        return settings.isChinese ? formatter.string(from: date) : formatter.string(from: date).uppercased()
    }
}

private struct SummaryView: View {
    let summary: OverlayModel.Summary
    @Bindable var model: OverlayModel
    let showsActions: Bool

    var body: some View {
        VStack(spacing: 0) {
            Label(summary.session >= 60 ? tr("本次专注", "THIS SESSION") : tr("欢迎回来", "WELCOME BACK"), systemImage: "checkmark.circle")
                .font(.system(size: 14, weight: .semibold))
                .tracking(4)
                .opacity(0.65)
                .padding(.bottom, 18)

            if summary.session >= 60 {
                let minutes = Int(summary.session / 60)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if minutes >= 60 {
                        Text("\(minutes / 60)").font(.system(size: 110, weight: .thin))
                        Text(tr("小时", "h")).font(.system(size: 26)).opacity(0.7).padding(.trailing, 12)
                    }
                    Text("\(minutes % 60)").font(.system(size: 110, weight: .thin))
                    Text(tr("分钟", "min")).font(.system(size: 26)).opacity(0.7)
                }
                .monospacedDigit()

                HStack(spacing: 14) {
                    Text(tr("今日累计 \(DurationText.long(summary.today))", "\(DurationText.long(summary.today)) today"))
                    if summary.streak > 1 {
                        Circle().frame(width: 3, height: 3).opacity(0.6)
                        Text(tr("连续专注 \(summary.streak) 天", "\(summary.streak) days in a row"))
                    }
                }
                .font(.system(size: 16, weight: .medium))
                .opacity(0.65)
                .padding(.top, 22)
            } else if model.task == nil {
                Text(tr("用完电脑，记得回到书桌前", "Back to the desk when you're done"))
                    .font(.custom("STSongti-SC-Bold", size: 40))
                    .tracking(2)
            }

            if let task = model.task, showsActions {
                TaskQuestion(task: task, completed: model.taskCompleted,
                             onComplete: model.onCompleteTask, onDismiss: model.onDismissSummary)
                    .padding(.top, 40)
            }
        }
    }
}

/// "Is it done?" for the task the session was about: one click ticks it off.
private struct TaskQuestion: View {
    let task: OverlayModel.TaskLine
    let completed: Bool
    let onComplete: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text(completed ? tr("已完成「\(task.title)」", "Done: “\(task.title)”") : tr("「\(task.title)」做完了吗？", "Finished “\(task.title)”?"))
                .font(.system(size: 17, weight: .medium))
                .lineLimit(1)
                .frame(maxWidth: 640)
                .contentTransition(.interpolate)
            if !completed {
                HStack(spacing: 12) {
                    Button(action: onDismiss) {
                        Text(tr("还没有", "Not yet"))
                            .font(.system(size: 14, weight: .semibold))
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(SoftPressStyle())
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .keyboardShortcut(.cancelAction)

                    Button(action: onComplete) {
                        Label(tr("完成", "Mark Done"), systemImage: "checkmark")
                            .font(.system(size: 14, weight: .semibold))
                            .padding(.horizontal, 22)
                            .padding(.vertical, 10)
                            .background(Brand.gradient, in: .capsule)
                            .overlay { Capsule().strokeBorder(.white.opacity(0.2)) }
                            .shadow(color: Brand.glow.opacity(0.4), radius: 14, y: 4)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(SoftPressStyle())
                    .keyboardShortcut(.defaultAction)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
        .animation(.smooth(duration: 0.35), value: completed)
    }
}

// MARK: - Atmosphere: vignette and grain

/// Darker edges draw the eye to the middle; faint grain keeps a large blur from looking plastic.
struct Atmosphere: View {
    var body: some View {
        GeometryReader { proxy in
            let radius = hypot(proxy.size.width, proxy.size.height) / 2
            ZStack {
                RadialGradient(
                    stops: [
                        .init(color: .black.opacity(0.06), location: 0),
                        .init(color: .black.opacity(0.10), location: 0.45),
                        .init(color: .black.opacity(0.42), location: 1),
                    ],
                    center: .center, startRadius: 0, endRadius: radius)
                Image(nsImage: Grain.image)
                    .resizable(resizingMode: .tile)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

private enum Grain {
    static let image: NSImage = {
        let size = 160
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        var seed: UInt32 = 0x2545_F491
        for i in 0..<(size * size) {
            seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5
            let light = seed & 1 == 0
            let alpha = UInt8((seed >> 8) % 14) // 0…13 of 255: very faint
            let value: UInt8 = light ? alpha : 0 // premultiplied
            pixels[i * 4] = value; pixels[i * 4 + 1] = value; pixels[i * 4 + 2] = value
            pixels[i * 4 + 3] = alpha
        }
        let context = CGContext(data: &pixels, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return NSImage(cgImage: context.makeImage()!, size: NSSize(width: size / 2, height: size / 2))
    }()
}

// MARK: - Unlocking

/// When the field opens, the hold pill's glass melts into it instead of fading out on its own.
private struct UnlockControls: View {
    @Bindable var model: OverlayModel
    @Namespace private var glass

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                if !model.typingRevealed {
                    HoldPill(holding: model.holding, progress: model.holdProgress, shortcut: model.shortcutText, glass: glass)
                }
                TypingCapsule(model: model, glass: glass)
            }
        }
        .animation(.smooth(duration: 0.55), value: model.typingRevealed)
    }
}

/// "Type the phrase" opens in place into a field. The phrase sits in it as faint ghost text and what
/// is typed lands exactly over it, instead of being shown a second time.
private struct TypingCapsule: View {
    @Bindable var model: OverlayModel
    let glass: Namespace.ID
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let font = Font.system(size: 20, weight: .medium)

    /// The phrase as laid out (measured in the field's own font, so the two line up letter by letter).
    private var phraseWidth: CGFloat {
        let font = NSFont.systemFont(ofSize: 20, weight: .medium)
        return ceil((FocusOverlay.unlockPhrase as NSString).size(withAttributes: [.font: font]).width) + 6
    }

    private var revealed: Bool { model.typingRevealed }

    var body: some View {
        ZStack(alignment: .leading) {
            // Correct characters are covered by the real ones in the field; while composing or after
            // a typo the ghost fades, so it never overlaps the pinyin. One Text rather than
            // character by character, so its spacing matches the field's exactly.
            Text(ghostText)
                .font(Self.font)
                .fixedSize()
                .allowsHitTesting(false)
                .animation(.smooth(duration: 0.25), value: model.matchedCount)
                .animation(.smooth(duration: 0.25), value: model.composing)

            TextField("", text: $model.typed)
                .textFieldStyle(.plain)
                .font(Self.font)
                .focused($focused)
                .onSubmit { model.onSubmit() }
                .onChange(of: model.typed) { model.onTypedChange() }
                .opacity(revealed ? 1 : 0)

            Label(tr("输入语句解除", "Type to unlock"), systemImage: "keyboard")
                .font(.system(size: 13, weight: .semibold))
                .fixedSize()
                .frame(maxWidth: .infinity)
                .opacity(revealed ? 0 : 1)
                .blur(radius: revealed ? 6 : 0)
                .allowsHitTesting(false)
        }
        .frame(width: revealed ? phraseWidth : 112, height: 26)
        .padding(.horizontal, 4) // so clipping doesn't cut the first or last letter
        .clipped()
        .padding(.horizontal, revealed ? 20 : 12)
        .padding(.vertical, revealed ? 12 : 7)
        .contentShape(Capsule())
        .onTapGesture {
            if !revealed { withAnimation(.smooth(duration: 0.55)) { model.typingRevealed = true } }
            focused = true
        }
        .glassEffect(.regular.interactive(), in: .capsule)
        .glassEffectID("typing", in: glass)
        // Reduce Motion keeps it still and leaves the telling to the sound.
        .modifier(Shake(attempts: reduceMotion ? 0 : CGFloat(model.wrongAttempts)))
        .animation(.default, value: model.wrongAttempts)
        .animation(.smooth(duration: 0.55), value: revealed)
        .task {
            try? await Task.sleep(for: .milliseconds(200))
            focused = true
        }
    }

    private var ghostText: AttributedString {
        var text = AttributedString()
        var counted = 0
        for character in FocusOverlay.unlockPhrase {
            var piece = AttributedString(String(character))
            piece.foregroundColor = .white.opacity(ghostOpacity(at: counted))
            if !OverlayModel.isIgnored(character) { counted += 1 }
            text += piece
        }
        return text
    }

    private func ghostOpacity(at index: Int) -> Double {
        guard revealed, index >= model.matchedCount else { return 0 }
        let mistyped = OverlayModel.normalize(model.typed).count > model.matchedCount
        return model.composing || mistyped ? 0 : 0.3
    }
}

/// Holding the shortcut fills the pill from the left; letting go springs it back.
private struct HoldPill: View {
    let holding: Bool
    let progress: Double
    let shortcut: String
    let glass: Namespace.ID

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle().stroke(.white.opacity(0.25), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(.white, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 15, height: 15)
            Text(holding ? tr("继续按住…", "Keep holding…") : tr("按住 \(shortcut) 解除", "Hold \(shortcut) to unlock"))
                .contentTransition(.interpolate)
        }
        .font(.system(size: 13, weight: .semibold))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(alignment: .leading) {
            GeometryReader { proxy in
                Capsule()
                    .fill(.white.opacity(0.22))
                    .frame(width: proxy.size.width * progress)
            }
        }
        .clipShape(Capsule())
        .glassEffect(.regular, in: .capsule)
        .glassEffectID("hold", in: glass)
        .animation(.smooth(duration: 0.3), value: holding)
    }
}

// MARK: - Motion

struct Reveal: ViewModifier {
    let shown: Bool
    let delay: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        // Reduce Motion only fades: no rising, no blur.
        content
            .opacity(shown ? 1 : 0)
            .blur(radius: shown || reduceMotion ? 0 : 14)
            .offset(y: shown || reduceMotion ? 0 : 16)
            .animation(shown ? .smooth(duration: 1.1).delay(delay) : .easeIn(duration: 0.35), value: shown)
    }
}

extension View {
    /// From blurred, lowered and clear to sharp, in place and opaque.
    func reveal(_ shown: Bool, delay: Double) -> some View {
        modifier(Reveal(shown: shown, delay: delay))
    }
}

nonisolated struct Shake: GeometryEffect {
    var attempts: CGFloat
    var animatableData: CGFloat {
        get { attempts }
        set { attempts = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 10 * sin(attempts * .pi * 6), y: 0))
    }
}

/// A gentle press for larger buttons: a slight shrink and darkening.
struct SoftPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .brightness(configuration.isPressed ? -0.05 : 0)
            .animation(.snappy(duration: 0.2), value: configuration.isPressed)
    }
}
