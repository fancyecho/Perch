import AppKit
import SwiftUI

/// A task opened up: its checklist, then its notes. The same block sits under a task in a list
/// and under its capsule on the timeline.
///
/// Only what has been written shows. The ways to add more ("Add a step", "Add notes") wait in
/// one faint line at the foot that comes up while the pointer is over the block, or stays when
/// there is nothing else to show. Click a step to edit it; Return adds the next step under it,
/// Backspace in an empty step removes it, Esc puts the text down.
struct TaskDetails: View {
    let task: TaskItem
    /// The parent's checkbox color, so the steps read as part of it.
    let tint: Color

    @Environment(TaskStore.self) private var store
    @Environment(PanelModel.self) private var model: PanelModel?

    /// The step being edited, and its text so far.
    @State private var editing: UUID?
    @State private var draft = ""
    /// Writing a new step at the end of the list.
    @State private var addingStep = false
    @State private var newStep = ""
    @State private var newStepFocus = 0
    @State private var notes = ""
    /// The notes show as plain text until clicked.
    @State private var editingNotes = false
    @State private var notesFocused = false
    @State private var hovering = false

    static let rowHeight: CGFloat = 22
    static let footerHeight: CGFloat = 20
    /// The checkbox column; titles start after it.
    static let markWidth: CGFloat = 21

    #if DEBUG
    /// Lets a snapshot show the foot as it is under the pointer.
    static var debugHovering = false
    private var isHovering: Bool { hovering || Self.debugHovering }
    #else
    private var isHovering: Bool { hovering }
    #endif

    private var showsNotes: Bool { editingNotes || !notes.isEmpty }
    private var offersStep: Bool { !addingStep }
    private var offersNotes: Bool { !showsNotes }
    /// Nothing written yet: the foot is all there is, so it stays.
    private var footerAlwaysShown: Bool { task.subtasks.isEmpty && !showsNotes && !addingStep }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(task.subtasks) { step in
                stepRow(step)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if addingStep {
                addRow
                    .transition(.opacity)
            }
            if showsNotes {
                notesRow
                    .transition(.opacity)
            }
            if offersStep || offersNotes {
                footer
                    .opacity(isHovering || footerAlwaysShown ? 1 : 0)
                    .allowsHitTesting(isHovering || footerAlwaysShown)
            }
        }
        .contentShape(.rect)
        .onHover { inside in
            withAnimation(.easeOut(duration: inside ? 0.15 : 0.25)) { hovering = inside }
        }
        .animation(.snappy(duration: 0.25), value: task.subtasks.map(\.id))
        .animation(.snappy(duration: 0.25), value: addingStep)
        .animation(.snappy(duration: 0.25), value: showsNotes)
        .onAppear {
            notes = task.notes ?? ""
            takeFocusRequest()
        }
        .onChange(of: model?.detailFocus) { takeFocusRequest() }
        .onChange(of: task.notes) { _, value in
            if !notesFocused { notes = value ?? "" }
        }
        .onDisappear(perform: putDown)
    }

    // MARK: - Rows

    private func stepRow(_ step: Subtask) -> some View {
        SubtaskRow(
            step: step,
            tint: tint,
            isEditing: editing == step.id,
            draft: $draft,
            onToggle: {
                Haptics.tick()
                withAnimation(.snappy) { store.toggleSubtask(task.id, step.id) }
            },
            onEdit: { beginEditing(step) },
            onSubmit: { submit(step) },
            onCancel: { cancel(step) },
            onEndEditing: { finish(step) },
            onDeleteWhenEmpty: { deleteFromKeyboard(step) },
            menu: { menu(for: step) }
        )
    }

    /// The new step being written: an empty circle, as it will be, and the field.
    private var addRow: some View {
        HStack(spacing: 6) {
            Circle()
                .strokeBorder(tint.opacity(0.4), lineWidth: 1.5)
                .frame(width: 13, height: 13)
                .frame(width: Self.markWidth, height: Self.rowHeight)
            InputField(
                text: $newStep,
                placeholder: tr("子任务", "Step"),
                fontSize: 12,
                focusRequest: newStepFocus,
                focusOnAppear: true,
                quietPlaceholder: true,
                onSubmit: addStep,
                onCancel: cancelNewStep,
                onFocusChange: { focused in if !focused { endNewStep() } },
                onDeleteWhenEmpty: editLastStep
            )
        }
        .frame(height: Self.rowHeight)
    }

    private var notesRow: some View {
        Group {
            if editingNotes {
                NotesField(
                    text: $notes,
                    placeholder: tr("备注", "Notes"),
                    fontSize: 12,
                    focusOnAppear: true,
                    onFocusChange: { focused in
                        notesFocused = focused
                        if !focused {
                            saveNotes()
                            editingNotes = false
                        }
                    }
                )
            } else {
                Text(notes)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineSpacing(1)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                    .onTapGesture { editingNotes = true }
                    .help(tr("点按编辑备注", "Click to edit the notes"))
            }
        }
        // A short paragraph, lined up with the task's title and the steps' circles.
        .padding(.leading, 4)
        .padding(.top, task.subtasks.isEmpty && !addingStep ? 2 : 5)
        .padding(.bottom, 2)
    }

    /// "+ Add a step   Add notes", in the faintest grey.
    private var footer: some View {
        HStack(spacing: 14) {
            if offersStep {
                FooterButton(title: tr("添加子任务", "Add a step"), spacing: 6) {
                    addingStep = true
                    newStepFocus += 1
                } icon: {
                    Image(systemName: "plus")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: Self.markWidth)
                }
            }
            if offersNotes {
                // First in the line, its glyph keeps to the circles' column.
                FooterButton(title: tr("添加备注", "Add notes"), spacing: offersStep ? 4 : 6) {
                    editingNotes = true
                } icon: {
                    Image(systemName: "text.alignleft")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: offersStep ? nil : Self.markWidth)
                }
            }
        }
        .frame(height: Self.footerHeight)
    }

    // MARK: - Editing

    private func beginEditing(_ step: Subtask) {
        if let editing, editing != step.id, let current = task.subtasks.first(where: { $0.id == editing }) {
            finish(current)
        }
        draft = step.title
        editing = step.id
    }

    /// Return: keep the text and open a new step underneath. Return on an empty step ends the list.
    private func submit(_ step: Subtask) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            editing = nil
            withAnimation(.snappy) { store.deleteSubtask(task.id, step.id) }
            resignFocus()
            return
        }
        store.renameSubtask(task.id, step.id, to: text)
        guard let next = withAnimation(.snappy, { store.addSubtask(task.id, after: step.id) }) else { return }
        draft = ""
        editing = next.id
    }

    /// Esc: put the text down unchanged. A step that never got a title goes away.
    private func cancel(_ step: Subtask) {
        guard editing == step.id else { return }
        editing = nil
        if step.title.isEmpty { withAnimation(.snappy) { store.deleteSubtask(task.id, step.id) } }
        resignFocus()
    }

    /// Clicking elsewhere keeps what was typed; a step left blank goes away.
    private func finish(_ step: Subtask) {
        guard editing == step.id else { return }
        editing = nil
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            withAnimation(.snappy) { store.deleteSubtask(task.id, step.id) }
        } else {
            store.renameSubtask(task.id, step.id, to: text)
        }
    }

    /// Backspace in an empty step: remove it and carry on at the end of the one above.
    private func deleteFromKeyboard(_ step: Subtask) {
        let steps = task.subtasks
        let index = steps.firstIndex { $0.id == step.id } ?? 0
        editing = nil
        withAnimation(.snappy) { store.deleteSubtask(task.id, step.id) }
        if index > 0 {
            beginEditing(steps[index - 1])
        } else {
            resignFocus()
        }
    }

    /// Return in the new step: add it and stay for the next one. Return with nothing written
    /// ends the list.
    private func addStep(_ value: String) {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            addingStep = false
            resignFocus()
            return
        }
        Haptics.tick()
        withAnimation(.snappy) { _ = store.addSubtask(task.id, title: text) }
        newStep = ""
    }

    /// Clicking away from the new step keeps what was typed in it.
    private func endNewStep() {
        guard addingStep else { return }
        let text = newStep.trimmingCharacters(in: .whitespacesAndNewlines)
        newStep = ""
        addingStep = false
        if !text.isEmpty { withAnimation(.snappy) { _ = store.addSubtask(task.id, title: text) } }
    }

    private func cancelNewStep() {
        newStep = ""
        addingStep = false
        resignFocus()
        // Opened just to add something, and nothing was: fold it away again.
        if !task.hasDetails { withAnimation(.snappy) { model?.expandedTaskID = nil } }
    }

    private func editLastStep() {
        guard let last = task.subtasks.last else { return }
        newStep = ""
        addingStep = false
        beginEditing(last)
    }

    private func saveNotes() {
        store.setNotes(task.id, notes)
    }

    /// Folding the task away keeps whatever was being written.
    private func putDown() {
        if let editing, let step = task.subtasks.first(where: { $0.id == editing }) { finish(step) }
        if notesFocused { saveNotes() }
        let text = newStep.trimmingCharacters(in: .whitespacesAndNewlines)
        if addingStep, !text.isEmpty { store.addSubtask(task.id, title: text) }
        newStep = ""
        addingStep = false
        store.removeBlankSubtasks(task.id)
    }

    private func takeFocusRequest() {
        guard let request = model?.detailFocus, request.taskID == task.id else { return }
        model?.detailFocus = nil
        switch request.field {
        case .newSubtask:
            addingStep = true
            newStepFocus += 1
        case .notes:
            editingNotes = true
        }
    }

    private func resignFocus() {
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    @ViewBuilder
    private func menu(for step: Subtask) -> some View {
        let index = task.subtasks.firstIndex { $0.id == step.id } ?? 0
        Button(step.isDone ? tr("标记为未完成", "Mark as Not Done") : tr("完成", "Complete")) {
            withAnimation(.snappy) { store.toggleSubtask(task.id, step.id) }
        }
        Button(tr("编辑", "Edit")) { beginEditing(step) }
        Divider()
        Button(tr("上移", "Move Up")) { withAnimation(.snappy) { store.moveSubtask(task.id, step.id, by: -1) } }
            .disabled(index == 0)
        Button(tr("下移", "Move Down")) { withAnimation(.snappy) { store.moveSubtask(task.id, step.id, by: 1) } }
            .disabled(index == task.subtasks.count - 1)
        Divider()
        Button(tr("删除", "Delete"), role: .destructive) { withAnimation(.snappy) { store.deleteSubtask(task.id, step.id) } }
    }
}

/// One step of the checklist: a small check circle in the task's color and the title, which
/// turns into a text field when clicked.
private struct SubtaskRow<Menu: View>: View {
    let step: Subtask
    let tint: Color
    let isEditing: Bool
    @Binding var draft: String
    let onToggle: () -> Void
    let onEdit: () -> Void
    let onSubmit: () -> Void
    let onCancel: () -> Void
    let onEndEditing: () -> Void
    let onDeleteWhenEmpty: () -> Void
    @ViewBuilder let menu: () -> Menu

    var body: some View {
        HStack(spacing: 6) {
            CheckCircle(isOn: step.isDone, tint: tint, size: 13, action: onToggle)
                .frame(width: TaskDetails.markWidth, height: TaskDetails.rowHeight)
            if isEditing {
                InputField(
                    text: $draft,
                    placeholder: tr("子任务", "Step"),
                    fontSize: 12,
                    focusOnAppear: true,
                    caretAtEnd: true,
                    quietPlaceholder: true,
                    onSubmit: { _ in onSubmit() },
                    onCancel: onCancel,
                    onFocusChange: { focused in if !focused { onEndEditing() } },
                    onDeleteWhenEmpty: onDeleteWhenEmpty
                )
            } else {
                Text(step.title)
                    .font(.system(size: 12))
                    .strikethrough(step.isDone, color: .secondary)
                    .foregroundStyle(step.isDone ? .tertiary : .secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                    .onTapGesture(perform: onEdit)
            }
        }
        .frame(minHeight: TaskDetails.rowHeight)
        .contentShape(.rect)
        .contextMenu { menu() }
        .animation(.easeOut(duration: 0.15), value: step.isDone)
    }
}

/// A way to add something, in the faintest grey until the pointer is on it.
private struct FooterButton<Icon: View>: View {
    let title: String
    var spacing: CGFloat = 4
    let action: () -> Void
    @ViewBuilder let icon: () -> Icon

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: spacing) {
                icon()
                Text(title)
                    .font(.system(size: 11))
            }
            .foregroundStyle(hovering ? .secondary : .tertiary)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// The quiet mark in a task's detail line saying it has more inside: "☑ 2/5" for its
/// checklist, a lines glyph for notes. Clicking it opens or closes the task.
struct DetailsHint: View {
    let task: TaskItem
    let tint: Color
    let isOpen: Bool
    let action: () -> Void

    var body: some View {
        let checklist = task.checklist
        Button(action: action) {
            HStack(spacing: 5) {
                if checklist.total > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: checklist.done == checklist.total ? "checklist.checked" : "checklist")
                        Text("\(checklist.done)/\(checklist.total)")
                            .monospacedDigit()
                            .contentTransition(.numericText())
                    }
                }
                if task.hasNotes {
                    Image(systemName: "text.alignleft")
                }
            }
            .imageScale(.small)
            .foregroundStyle(isOpen ? AnyShapeStyle(tint) : AnyShapeStyle(.secondary))
            .padding(.vertical, 1)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .animation(.snappy(duration: 0.25), value: checklist.done)
        .help(isOpen ? tr("收起子任务和备注", "Hide steps and notes") : tr("显示子任务和备注", "Show steps and notes"))
        .accessibilityLabel(accessibilityText(checklist))
    }

    private func accessibilityText(_ checklist: (done: Int, total: Int)) -> String {
        var parts: [String] = []
        if checklist.total > 0 { parts.append(tr("子任务 \(checklist.done)/\(checklist.total)", "Steps \(checklist.done) of \(checklist.total)")) }
        if task.hasNotes { parts.append(tr("有备注", "Has notes")) }
        return parts.joined(separator: tr("，", ", "))
    }
}
