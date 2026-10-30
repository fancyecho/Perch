import SwiftUI

/// The open island, with the date up beside the notch as on Alcove. In merged style it holds what's
/// playing on the left and today's tasks on the right (today takes the whole width when nothing
/// plays). Otherwise the tasks have their own capsule, so it is just the player, or a glance at the
/// Mac's status when nothing plays.
struct ExpandedIslandView: View {
    @Environment(IslandModel.self) private var model
    @Environment(NowPlayingService.self) private var media

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
                Group {
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
                    } else {
                        StatusGlance().padding(.top, 10)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 14)
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .foregroundStyle(.white)
    }
}

/// Beside the notch: where the sound comes from (or how today is going), and the date.
private struct TopWings: View {
    let now: Date
    let hasMedia: Bool
    let showsTasks: Bool
    @Environment(NowPlayingService.self) private var media
    @Environment(TaskStore.self) private var store

    var body: some View {
        WingsLayout {
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
            }
        } trailing: {
            let today = DateText.today(now)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(DateText.weekday(today))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(red: 1, green: 0.36, blue: 0.32))
                Text("\(today.day)")
                    .font(.system(size: 19, weight: .semibold, design: .rounded).monospacedDigit())
            }
            .fixedSize()
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.white.opacity(0.6))
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

private struct TimedProgress: View {
    @Environment(NowPlayingService.self) private var media

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let duration = media.duration
            let position = media.position(at: context.date)
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

/// With nothing playing: the battery, headphones and where sound goes, at a glance.
private struct StatusGlance: View {
    @Environment(SystemVolume.self) private var volume
    @Environment(BluetoothMonitor.self) private var bluetooth
    @Environment(PowerMonitor.self) private var power

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                if let battery = power.battery {
                    StatusChip(text: "\(battery.level)%") {
                        BatteryGlyph(level: battery.level, isCharging: battery.isPluggedIn && battery.isCharging, tint: battery.tint)
                            .frame(width: 20, height: 9)
                    }
                }
                ForEach(bluetooth.devices.prefix(2)) { device in
                    StatusChip(text: device.battery.main.map { "\($0)%" } ?? device.name) { Image(systemName: device.symbol) }
                        .help(device.name)
                }
                if !volume.route.name.isEmpty {
                    StatusChip(text: volume.route.name) { Image(systemName: volume.route.symbol) }
                }
            }
            HStack(spacing: 7) {
                Image(systemName: "music.note")
                    .foregroundStyle(.white.opacity(0.35))
                Text(tr("没有正在播放的内容 · 在任意 App 中播放就能在这里控制", "Nothing playing · play something in any app to control it here"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                if let label = DateText.dueLabel(task, now: now) {
                    Text(label)
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(DateText.isOverdue(task, now: now) ? Color.red.opacity(0.9) : .white.opacity(0.5))
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
