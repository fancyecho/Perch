import SwiftUI

/// The pill, plus the peek list that slides out of it on hover.
struct CompactView: View {
    @Environment(TaskStore.self) private var store
    @Environment(PanelModel.self) private var model

    var body: some View {
        TimelineView(.everyMinute) { context in
            let now = context.date
            VStack(spacing: 0) {
                if model.growsUpward {
                    peekList(now: now)
                    PillRow(now: now)
                } else {
                    PillRow(now: now)
                    peekList(now: now)
                }
            }
            .onChange(of: store.peekTasks(now: now).count) {
                if model.mode == .peek { model.go(.peek) }
            }
        }
    }

    @ViewBuilder
    private func peekList(now: Date) -> some View {
        if model.mode == .peek {
            PeekList(now: now)
                .transition(.opacity)
        }
    }
}

private struct PillRow: View {
    let now: Date
    @Environment(TaskStore.self) private var store
    @Environment(PanelModel.self) private var model

    var body: some View {
        let progress = store.progress(now: now)
        let headline = store.headline(now: now)
        let isFocusing = store.focus != nil && headline?.id == store.focus?.taskID

        HStack(spacing: 10) {
            ProgressRing(done: progress.done, total: progress.total, lineWidth: 3)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 1) {
                Text(headline?.title ?? (progress.total > 0 ? tr("今天的事都做完了", "All done for today") : tr("今天很清闲", "Nothing planned today")))
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(subtitle(headline: headline, isFocusing: isFocusing, remaining: progress.total - progress.done))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            if isFocusing, let focus = store.focus {
                FocusTimer(start: focus.startedAt)
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Color.accentColor)
            } else if let headline, headline.hasTime || DateText.isOverdue(headline, now: now),
                      let label = DateText.dueLabel(headline, now: now) {
                Text(label)
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(DateText.isOverdue(headline, now: now) ? Color.red : .secondary)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: PanelController.pillSize.height)
        .contentShape(.rect)
        .gesture(WindowDragGesture())
        .onTapGesture { model.go(.panel) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(tr("打开任务面板", "Opens the task panel"))
    }

    private func subtitle(headline: TaskItem?, isFocusing: Bool, remaining: Int) -> String {
        if isFocusing { return tr("专注中", "Focusing") }
        if headline == nil { return tr("点击添加任务", "Click to add a task") }
        return remaining > 1 ? tr("下一项 · 还剩 \(remaining) 项", "Up next · \(remaining) left") : tr("最后一项", "Last one")
    }
}

private struct PeekList: View {
    let now: Date
    @Environment(TaskStore.self) private var store
    @Environment(PanelModel.self) private var model

    var body: some View {
        let tasks = store.peekTasks(now: now)
        VStack(spacing: 0) {
            if tasks.isEmpty {
                Button { model.go(.panel, focusInput: true) } label: {
                    Label(tr("添加一项任务", "Add a task"), systemImage: "plus")
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity, minHeight: PanelController.peekRowHeight)
                }
                .buttonStyle(.plain)
            } else {
                ForEach(tasks.prefix(PanelController.peekMaxRows)) { task in
                    TaskRow(task: task, now: now, style: .compact)
                        .frame(height: PanelController.peekRowHeight)
                        .transition(.asymmetric(insertion: .opacity, removal: .opacity.combined(with: .scale(scale: 0.96))))
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(model.growsUpward ? .top : .bottom, 8)
        .overlay(alignment: model.growsUpward ? .bottom : .top) {
            Divider().padding(.horizontal, 14).opacity(0.6)
        }
    }
}

struct FocusTimer: View {
    let start: Date

    var body: some View {
        TimelineView(.periodic(from: start, by: 1)) { context in
            Text(DateText.elapsed(since: start, now: context.date))
        }
    }
}
