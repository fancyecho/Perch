import SwiftUI

/// The open island, with the date up beside the notch as on Alcove. It holds what's playing (and
/// in merged style today's tasks beside it, or alone when nothing plays). With neither, a row of
/// quick things to do: AirDrop, Focus, the screenshot line.
struct ExpandedIslandView: View {
    @Environment(IslandModel.self) private var model
    @Environment(NowPlayingService.self) private var media
    @Environment(FocusController.self) private var focus

    var body: some View {
        TimelineView(.everyMinute) { context in
            let now = context.date
            let hasMedia = media.track != nil
            let showsTasks = model.taskStyle == .merged && !model.isLocked
            VStack(spacing: 0) {
                Group {
                    if let hud = model.inlineLevel {
                        LevelWings(hud: hud)
                    } else {
                        TopWings(now: now, hasMedia: hasMedia, showsTasks: showsTasks)
                    }
                }
                .frame(height: model.geometry.notchSize.height)
                ZStack(alignment: .top) {
                    if let pass = focus.passes.first {
                        PassStrip(pass: pass).padding(.top, 12)
                    } else {
                        content(now: now, hasMedia: hasMedia, showsTasks: showsTasks)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .clipped()
            }
        }
        .foregroundStyle(.white)
    }

    @ViewBuilder
    private func content(now: Date, hasMedia: Bool, showsTasks: Bool) -> some View {
        if showsTasks {
            HStack(alignment: .top, spacing: 16) {
                if hasMedia {
                    MediaColumn().frame(width: 150)
                }
                TodayColumn(now: now)
            }
            .padding(.top, 10)
        } else if hasMedia {
            WidePlayer().padding(.top, 8)
        } else if model.isLocked {
            NothingPlaying().padding(.top, 14)
        } else {
            QuickShelf().padding(.top, 2)
        }
    }
}

/// The open island on the lock screen with nothing playing.
private struct NothingPlaying: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "music.note")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(0.35))
                .frame(width: 36, height: 36)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(tr("没有正在播放的内容", "Nothing playing"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.75))
                Text(tr("在任意 App 中播放，就能在这里控制", "Play something in any app to control it here"))
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }
}

/// Beside the notch: where the sound comes from (or how today is going), and the date.
private struct TopWings: View {
    let now: Date
    let hasMedia: Bool
    let showsTasks: Bool
    @Environment(NowPlayingService.self) private var media
    @Environment(TaskStore.self) private var store
    @Environment(PowerMonitor.self) private var power

    var body: some View {
        WingsLayout {
            leading
        } trailing: {
            trailing
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.white.opacity(0.6))
    }

    @ViewBuilder
    private var leading: some View {
        Group {
            if hasMedia, let icon = media.sourceIcon {
                HStack(spacing: 5) {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 15, height: 15)
                    Text(media.sourceName ?? "")
                        .lineLimit(1)
                }
            } else if showsTasks {
                let progress = store.progress(now: now)
                let remaining = progress.total - progress.done
                HStack(spacing: 5) {
                    ProgressRing(done: progress.done, total: progress.total, lineWidth: 2)
                        .frame(width: 13, height: 13)
                    Text(remaining > 0 ? tr("还剩 \(remaining) 项", "\(remaining) left") : tr("都做完了", "All done"))
                        .lineLimit(1)
                }
            } else if let battery = power.battery {
                // With nothing playing, the Mac's own battery, as Alcove shows it.
                HStack(spacing: 5) {
                    BatteryGlyph(level: battery.level, isCharging: battery.isPluggedIn && battery.isCharging, tint: battery.tint)
                        .frame(width: 22, height: 10)
                    Text("\(battery.level)%")
                        .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                }
            }
        }
    }

    private var trailing: some View {
        let today = DateText.today(now)
        return HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(DateText.weekday(today))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color(red: 1, green: 0.36, blue: 0.32))
            Text("\(today.day)")
                .font(.system(size: 19, weight: .semibold, design: .rounded).monospacedDigit())
        }
        .fixedSize()
    }
}

// MARK: - Focus

/// A running pass, opened up: what it lets through, how long is left, and the way to end it now.
private struct PassStrip: View {
    let pass: ActivePass
    @Environment(FocusController.self) private var focus
    @State private var hovering = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = max(0, Int(pass.end.timeIntervalSince(context.date).rounded(.up)))
            let urgent = remaining <= 30
            HStack(spacing: 12) {
                PassRing(icon: pass.icon, isSite: pass.site != nil,
                         fraction: min(Double(remaining) / pass.duration, 1), urgent: urgent, lineWidth: 3)
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(pass.name)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        Text(urgent ? tr("马上结束", "Ending") : tr("临时使用", "Pass"))
                        Text(String(format: "%d:%02d", remaining / 60, remaining % 60))
                            .monospacedDigit()
                            .foregroundStyle(urgent ? PassRing.urgentColor : .white.opacity(0.85))
                            .contentTransition(.numericText(countsDown: true))
                            .animation(.snappy(duration: 0.3), value: remaining)
                    }
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                }
                Spacer(minLength: 8)
                Button { focus.endPass(pass.key) } label: {
                    Text(tr("现在结束", "End Now"))
                        .font(.system(size: 11.5, weight: .semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.white.opacity(hovering ? 0.22 : 0.14)))
                        .contentShape(.capsule)
                }
                .buttonStyle(PressScaleStyle())
                .onHover { hovering = $0 }
                .help(tr("回到时段里，App 会被收起", "Back to the schedule; the app is put away"))
            }
        }
    }
}

// MARK: - Now Playing

private struct MediaColumn: View {
    @Environment(NowPlayingService.self) private var media

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Button { media.openSourceApp() } label: {
                    ArtworkView(size: 40, cornerRadius: 9)
                        .background {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(media.accent ?? .clear)
                                .blur(radius: 12)
                                .opacity(0.5)
                        }
                }
                .buttonStyle(PressScaleStyle())
                .help(tr("打开正在播放的 App", "Open the playing app"))

                VStack(alignment: .leading, spacing: 2) {
                    MarqueeText(text: media.track?.title ?? "", font: .system(size: 13, weight: .semibold))
                    Text(media.track?.artist ?? "")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
            }
            MiniProgress()
                .padding(.top, 11)
            HStack(spacing: 4) {
                IslandButton(symbol: "backward.fill", size: 12, label: tr("上一首", "Previous")) { media.send(.previous) }
                IslandButton(
                    symbol: media.isPlaying ? "pause.fill" : "play.fill",
                    size: 17,
                    label: media.isPlaying ? tr("暂停", "Pause") : tr("播放", "Play")
                ) { media.send(.toggle) }
                IslandButton(symbol: "forward.fill", size: 12, label: tr("下一首", "Next")) { media.send(.next) }
            }
            .frame(maxWidth: .infinity)
            .overlay(alignment: .trailing) { OutputPicker() }
            .padding(.top, 6)
        }
    }
}

/// The player across the whole island: artwork, title and controls on one row, timed progress below.
private struct WidePlayer: View {
    @Environment(NowPlayingService.self) private var media

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Button { media.openSourceApp() } label: {
                    ArtworkView(size: 52, cornerRadius: 12)
                        .background {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(media.accent ?? .clear)
                                .blur(radius: 14)
                                .opacity(0.5)
                        }
                }
                .buttonStyle(PressScaleStyle())
                .help(tr("打开正在播放的 App", "Open the playing app"))

                VStack(alignment: .leading, spacing: 3) {
                    MarqueeText(text: media.track?.title ?? "", font: .system(size: 14, weight: .semibold))
                    Text(media.track?.artist ?? "")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                HStack(spacing: 2) {
                    IslandButton(symbol: "backward.fill", size: 12, label: tr("上一首", "Previous")) { media.send(.previous) }
                    IslandButton(
                        symbol: media.isPlaying ? "pause.fill" : "play.fill",
                        size: 17,
                        label: media.isPlaying ? tr("暂停", "Pause") : tr("播放", "Play")
                    ) { media.send(.toggle) }
                    IslandButton(symbol: "forward.fill", size: 12, label: tr("下一首", "Next")) { media.send(.next) }
                }
            }
            TimedProgress()
        }
    }
}

/// Where the sound plays, drawn as the device; a click lists the others to send it to.
private struct OutputPicker: View {
    @Environment(SystemVolume.self) private var volume
    @Environment(BluetoothMonitor.self) private var bluetooth
    @State private var hovering = false

    var body: some View {
        Menu {
            Section(tr("输出到", "Play On")) {
                ForEach(volume.outputs) { output in
                    Toggle(isOn: Binding(get: { output.id == volume.outputID }, set: { _ in volume.selectOutput(output.id) })) {
                        Label(output.route.name, systemImage: bluetooth.refine(output.route).symbol)
                    }
                }
            }
        } label: {
            Image(systemName: bluetooth.refine(volume.route).symbol)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.white.opacity(hovering ? 0.95 : 0.6))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 22, height: 20)
                .background(Circle().fill(Color.white.opacity(hovering ? 0.12 : 0)))
                .contentShape(.circle)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .help(volume.route.name.isEmpty ? tr("选择输出设备", "Choose where it plays") : tr("正在通过「\(volume.route.name)」播放", "Playing on \(volume.route.name)"))
        .accessibilityLabel(tr("输出设备", "Output device"))
    }
}

private struct TimedProgress: View {
    @Environment(NowPlayingService.self) private var media

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let duration = media.duration
            let position = media.position(at: context.date)
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Text(Self.format(position))
                        .frame(width: 34, alignment: .leading)
                    MiniProgress()
                    Text("-" + Self.format(max(duration - position, 0)))
                        .frame(width: 38, alignment: .trailing)
                }
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.5))
                .opacity(duration > 0 ? 1 : 0)
                OutputPicker()
            }
        }
    }

    private static func format(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        let hours = total / 3600
        let minutes = total / 60 % 60
        let rest = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%d:%02d", minutes, rest)
    }
}

/// A hairline of progress; it thickens under the pointer and can be dragged to seek.
private struct MiniProgress: View {
    @Environment(NowPlayingService.self) private var media
    @State private var scrub: Double?
    @State private var hovering = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.5, paused: !media.isPlaying || scrub != nil)) { context in
            let duration = media.duration
            let fraction = scrub ?? (duration > 0 ? media.position(at: context.date) / duration : 0)
            let active = hovering || scrub != nil
            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.16))
                    Capsule()
                        .fill(media.accent ?? .white)
                        .frame(width: max(width * min(max(fraction, 0), 1), active ? 5 : 3))
                }
                .frame(height: active ? 5 : 3)
                .frame(maxHeight: .infinity)
                .contentShape(.rect)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { scrub = min(max($0.location.x / max(width, 1), 0), 1) }
                        .onEnded { _ in
                            if let scrub { media.seek(to: scrub * media.duration) }
                            scrub = nil
                        }
                )
            }
            .opacity(duration > 0 ? 1 : 0)
            .animation(.snappy(duration: 0.2), value: active)
        }
        .frame(height: 9)
        .onHover { hovering = $0 }
    }
}

// MARK: - Today

/// The next few things to do today, checkable right here; the rest is one click away.
private struct TodayColumn: View {
    let now: Date
    @Environment(TaskStore.self) private var store
    @Environment(IslandModel.self) private var model

    private static let rows = 3

    var body: some View {
        let tasks = store.overdue(now: now) + store.dueToday(now: now)
        VStack(alignment: .leading, spacing: 5) {
            if tasks.isEmpty {
                let progress = store.progress(now: now)
                Text(progress.total > 0 ? tr("今天的事都做完了", "All done for today") : tr("今天没有安排", "Nothing planned today"))
                    .font(.system(size: 13, weight: .semibold))
                Text(tr("想到什么，随手记下来", "Jot down what comes up"))
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
                Spacer(minLength: 0)
                IslandLinkButton(title: tr("添加任务", "Add a task"), symbol: "plus") { model.tasksHandler?(true) }
            } else {
                ForEach(tasks.prefix(Self.rows)) { task in
                    IslandTaskRow(task: task, now: now)
                        .transition(.asymmetric(insertion: .opacity, removal: .opacity.combined(with: .move(edge: .leading))))
                }
                Spacer(minLength: 0)
                HStack {
                    IslandLinkButton(
                        title: tasks.count > Self.rows ? tr("还有 \(tasks.count - Self.rows) 项", "\(tasks.count - Self.rows) more") : tr("全部任务", "All tasks"),
                        symbol: "chevron.right",
                        trailingSymbol: true
                    ) { model.tasksHandler?(false) }
                    Spacer()
                    IslandLinkButton(title: nil, symbol: "plus") { model.tasksHandler?(true) }
                        .help(tr("添加任务", "Add a task"))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.snappy(duration: 0.35), value: tasks.map(\.id))
    }
}

private struct IslandTaskRow: View {
    let task: TaskItem
    let now: Date
    @Environment(TaskStore.self) private var store
    @Environment(Feedback.self) private var feedback
    @Environment(IslandModel.self) private var model
    @State private var completing = false

    var body: some View {
        HStack(alignment: .top, spacing: 5) {
            CheckCircle(isOn: completing, tint: task.priority.tint, size: 14, action: complete)
                .padding(-3)
            VStack(alignment: .leading, spacing: 1) {
                Text(task.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .strikethrough(completing, color: .white.opacity(0.5))
                    .foregroundStyle(completing ? .white.opacity(0.5) : .white)
                    .lineLimit(1)
                let label = DateText.dueLabel(task, now: now)
                let checklist = task.checklist
                if label != nil || checklist.total > 0 {
                    HStack(spacing: 6) {
                        if let label {
                            Text(label)
                                .foregroundStyle(DateText.isOverdue(task, now: now) ? Color.red.opacity(0.9) : .white.opacity(0.5))
                        }
                        // Just how far along its checklist is.
                        if checklist.total > 0 {
                            HStack(spacing: 2) {
                                Image(systemName: checklist.done == checklist.total ? "checklist.checked" : "checklist")
                                    .imageScale(.small)
                                Text("\(checklist.done)/\(checklist.total)")
                            }
                            .foregroundStyle(.white.opacity(0.4))
                        }
                    }
                    .font(.system(size: 10.5).monospacedDigit())
                }
            }
            .padding(.top, 1)
            Spacer(minLength: 0)
        }
        .contentShape(.rect)
        .onTapGesture { model.tasksHandler?(false) }
        .help(task.title)
    }

    private func complete() {
        guard !completing else { return }
        Haptics.confirm()
        feedback.taskChecked()
        completing = true
        let id = task.id
        Task {
            try? await Task.sleep(for: .milliseconds(520))
            withAnimation(.snappy(duration: 0.35)) { store.complete(id, playsSound: false) }
        }
    }
}

private struct IslandLinkButton: View {
    let title: String?
    let symbol: String
    var trailingSymbol = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                if !trailingSymbol { Image(systemName: symbol) }
                if let title { Text(title) }
                if trailingSymbol { Image(systemName: symbol).imageScale(.small) }
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white.opacity(hovering ? 0.95 : 0.6))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.white.opacity(hovering ? 0.14 : 0.07)))
            .contentShape(.capsule)
        }
        .buttonStyle(PressScaleStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}
