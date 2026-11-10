import SwiftUI

/// When the evening review comes due, from Settings › Tasks.
enum EveningReview {
    @MainActor static var isEnabled: Bool { UserDefaults.standard.bool(forKey: Pref.reviewEnabled) }

    @MainActor static var minutes: Int { UserDefaults.standard.integer(forKey: Pref.reviewTime) }

    /// Past today's review time, and not waved away today.
    @MainActor static func isDue(now: Date) -> Bool {
        guard isEnabled else { return false }
        let cal = AppSettings.shared.calendar
        let today = Day(now, in: cal)
        guard UserDefaults.standard.string(forKey: Pref.reviewDismissedDay) != today.description else { return false }
        return now >= time(on: today, in: cal)
    }

    /// The next review after `now`.
    @MainActor static func next(after now: Date) -> Date {
        let cal = AppSettings.shared.calendar
        let today = Day(now, in: cal)
        let tonight = time(on: today, in: cal)
        return tonight > now ? tonight : time(on: today.adding(days: 1), in: cal)
    }

    @MainActor static func dismiss(now: Date = .now) {
        UserDefaults.standard.set(Day(now, in: AppSettings.shared.calendar).description, forKey: Pref.reviewDismissedDay)
    }

    @MainActor private static func time(on day: Day, in cal: Calendar) -> Date {
        let minutes = Self.minutes
        return day.date(hour: minutes / 60, minute: minutes % 60, in: cal)
    }
}

/// What's left over, with one tap each to settle it: done, or onto another day (a repeating
/// task skips to its next time instead). `earlier` holds tasks from days already gone and sends
/// them to today; `tonight` is the evening review of today's and sends them to tomorrow.
struct LeftoverCard: View {
    enum Kind { case earlier, tonight }

    let kind: Kind
    let tasks: [TaskItem]
    let now: Date

    @Environment(TaskStore.self) private var store

    private var today: Day { DateText.today(now) }
    private var destination: Day { kind == .tonight ? today.adding(days: 1) : today }
    private var tint: Color { kind == .tonight ? .indigo : .orange }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
                .padding(.bottom, 4)
            ForEach(tasks) { task in
                LeftoverRow(task: task, now: now, kind: kind, destination: destination)
                    .transition(.asymmetric(insertion: .opacity, removal: .opacity.combined(with: .move(edge: .leading))))
            }
            if tasks.count > 1 {
                Button {
                    Haptics.confirm()
                    withAnimation(.snappy) { store.carryAll(tasks.map(\.id), to: destination) }
                } label: {
                    Label(kind == .tonight ? tr("全部挪到明天", "Move all to tomorrow") : tr("全部移到今天", "Move all to today"),
                          systemImage: kind == .tonight ? "moon.zzz" : "arrow.down.to.line")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(tint)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(tint.opacity(0.12)))
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(tint.opacity(0.07))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(tint.opacity(0.16), lineWidth: 0.6)
        }
        .padding(.horizontal, 2)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .animation(.snappy, value: tasks.map(\.id))
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 9) {
            Image(systemName: kind == .tonight ? "moon.stars.fill" : "tray.full.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(Circle().fill(tint.opacity(0.14)))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .contentTransition(.numericText())
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if kind == .tonight {
                Button {
                    withAnimation(.snappy) { EveningReview.dismiss(now: now) }
                } label: {
                    Text(tr("先不管", "Not now"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .help(tr("今晚不再提", "Don't ask again tonight"))
            }
        }
    }

    private var title: String {
        switch kind {
        case .tonight:
            return tr("今天还有 \(tasks.count) 项没做完", "\(tasks.count) left from today")
        case .earlier:
            let yesterday = today.adding(days: -1)
            let allYesterday = tasks.allSatisfy { $0.day(in: AppSettings.shared.calendar) == yesterday }
            return allYesterday ? tr("昨天还剩 \(tasks.count) 项", "\(tasks.count) left from yesterday")
                : tr("之前还剩 \(tasks.count) 项", "\(tasks.count) left from before")
        }
    }

    private var subtitle: String {
        kind == .tonight ? tr("做完的勾掉，其余挪到明天", "Check off what's done, move the rest to tomorrow")
            : tr("做完的勾掉，还要做的移到今天", "Check off what's done, bring the rest to today")
    }
}

private struct LeftoverRow: View {
    let task: TaskItem
    let now: Date
    let kind: LeftoverCard.Kind
    let destination: Day

    @Environment(TaskStore.self) private var store
    @Environment(Feedback.self) private var feedback
    @State private var hovering = false
    @State private var checking = false

    var body: some View {
        HStack(spacing: 9) {
            capsule
            VStack(alignment: .leading, spacing: 1) {
                Text(task.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .strikethrough(checking, color: .secondary)
                    .foregroundStyle(checking ? .secondary : .primary)
                    .lineLimit(1)
                if let label = detail {
                    Text(label)
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            if task.recurrence != nil {
                pill(tr("跳过", "Skip"), symbol: "forward.end", help: tr("跳过这次，等下次", "Skip this one and wait for the next")) {
                    withAnimation(.snappy) { store.skip(task.id) }
                }
            } else {
                pill(kind == .tonight ? tr("明天", "Tomorrow") : tr("今天", "Today"), symbol: "arrow.turn.down.right",
                     help: kind == .tonight ? tr("挪到明天", "Move to tomorrow") : tr("移到今天", "Move to today")) {
                    withAnimation(.snappy) { store.carry(task.id, to: destination) }
                }
            }
            CheckCircle(isOn: checking, tint: task.tint.color, size: 18, action: check)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.04 : 0))
        }
        .onHover { hovering in withAnimation(.easeOut(duration: 0.12)) { self.hovering = hovering } }
    }

    private var capsule: some View {
        let tint = task.tint.color
        return ZStack {
            Capsule(style: .circular).fill(tint.opacity(0.18))
            Group {
                switch task.glyph {
                case .symbol(let name): Image(systemName: name).font(.system(size: 8.5, weight: .semibold))
                case .text(let text): Text(text).font(.system(size: 9.5, weight: .semibold, design: .rounded))
                }
            }
            .foregroundStyle(tint)
        }
        .frame(width: 18, height: 24)
    }

    /// "Yesterday 15:00 – 16:00" or "15:00 – 16:00 · every day".
    private var detail: String? {
        var parts: [String] = []
        if kind == .earlier, let day = task.day(in: AppSettings.shared.calendar) {
            parts.append(DateText.relativeDay(day, now: now))
        }
        if let range = DateText.timeRange(task) { parts.append(range) }
        if let recurrence = task.recurrence { parts.append(recurrence.title) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func pill(_ title: String, symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tick()
            action()
        } label: {
            Label(title, systemImage: symbol)
                .labelStyle(.titleOnly)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.primary.opacity(hovering ? 0.08 : 0.05)))
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func check() {
        guard !checking else { return }
        Haptics.confirm()
        feedback.taskChecked()
        checking = true
        let id = task.id
        Task {
            try? await Task.sleep(for: .milliseconds(420))
            withAnimation(.snappy(duration: 0.35)) { store.complete(id, playsSound: false) }
        }
    }
}
