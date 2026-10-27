import AppKit
import SwiftUI

/// Popover for changing an existing task's date and time. Every change applies immediately,
/// so the list, the timeline and reminders follow along while it is open.
struct ScheduleEditor: View {
    let taskID: UUID

    @Environment(TaskStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @Environment(PanelModel.self) private var model
    @State private var phrase = ""
    @State private var rejected = 0

    private static let quickTimes = [(9, 0), (12, 0), (15, 0), (18, 0), (21, 0)]

    private var calendar: Calendar { settings.calendar }
    private var schedule: Schedule? { store.task(taskID)?.schedule }
    private var today: Day { Day(.now, in: calendar) }
    private var day: Day? { schedule?.day(in: calendar) }
    private var clock: (hour: Int, minute: Int)? {
        schedule?.time.map {
            let c = calendar.dateComponents([.hour, .minute], from: $0)
            return (c.hour ?? 9, c.minute ?? 0)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            quickDays
            MonthCalendar(selection: dayBinding, calendar: calendar, locale: settings.locale)
                .opacity(day == nil ? 0.5 : 1)
                .frame(maxWidth: .infinity)
            Divider()
            timeSection
            phraseField
        }
        .padding(14)
        .frame(width: 270)
        .animation(.snappy(duration: 0.25), value: clock == nil)
    }

    // MARK: - Parts

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(tr("日期与时间", "Date & Time"))
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Text(DateText.dueLabel(schedule, now: .now) ?? tr("无日期", "No date"))
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(schedule == nil ? Color.secondary : Color.accentColor)
                .contentTransition(.numericText())
        }
    }

    private var quickDays: some View {
        HStack(spacing: 6) {
            chip(tr("今天", "Today"), isOn: day == today) { setDay(today) }
            chip(tr("明天", "Tmrw"), isOn: day == today.adding(days: 1)) { setDay(today.adding(days: 1)) }
            chip(tr("下周一", "Next Mon"), isOn: day == today.adding(days: 7 - today.mondayIndex)) {
                setDay(today.adding(days: 7 - today.mondayIndex))
            }
            chip(tr("无日期", "No date"), isOn: schedule == nil) { apply(nil) }
        }
    }

    private var timeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label(tr("时间", "Time"), systemImage: "clock")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                if clock != nil {
                    DatePicker("", selection: timeBinding, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .datePickerStyle(.stepperField)
                        .environment(\.calendar, calendar)
                        .environment(\.timeZone, calendar.timeZone)
                        .environment(\.locale, settings.locale)
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                }
                Toggle("", isOn: hasTimeBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            if let clock {
                HStack(spacing: 4) {
                    ForEach(Self.quickTimes, id: \.0) { hour, minute in
                        chip(String(format: "%d:%02d", hour, minute), isOn: clock.hour == hour && clock.minute == minute, padding: 3) {
                            setTime(hour: hour, minute: minute)
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var phraseField: some View {
        HStack(spacing: 7) {
            Image(systemName: "text.cursor")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            InputField(
                text: $phrase,
                placeholder: tr("或直接输入：后天下午3点", "Or type: fri 3pm"),
                fontSize: 12,
                onSubmit: applyPhrase
            )
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.06)))
        .keyframeAnimator(initialValue: 0.0, trigger: rejected) { content, x in
            content.offset(x: x)
        } keyframes: { _ in
            KeyframeTrack {
                SpringKeyframe(6, duration: 0.06)
                SpringKeyframe(-6, duration: 0.08)
                SpringKeyframe(0, duration: 0.14)
            }
        }
    }

    private func chip(_ title: String, isOn: Bool, padding: CGFloat = 7, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
            .font(.system(size: 11, weight: isOn ? .semibold : .medium).monospacedDigit())
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, padding)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity)
            .foregroundStyle(isOn ? Color.accentColor : .primary)
            .background(Capsule().fill(isOn ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06)))
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Bindings

    private var dayBinding: Binding<Date> {
        Binding(
            get: { (day ?? today).date(hour: 12, minute: 0, in: calendar) },
            set: { setDay(Day($0, in: calendar)) }
        )
    }

    private var timeBinding: Binding<Date> {
        Binding(
            get: { schedule?.time ?? .now },
            set: { date in
                let c = calendar.dateComponents([.hour, .minute], from: date)
                setTime(hour: c.hour ?? 9, minute: c.minute ?? 0)
            }
        )
    }

    private var hasTimeBinding: Binding<Bool> {
        Binding(
            get: { clock != nil },
            set: { wantsTime in
                let target = day ?? today
                if wantsTime {
                    let suggested = suggestedTime(on: target)
                    apply(.time(target.date(hour: suggested.hour, minute: suggested.minute, in: calendar)))
                } else {
                    apply(.day(target))
                }
            }
        )
    }

    // MARK: - Changes

    private func setDay(_ newDay: Day) {
        if let clock {
            apply(.time(newDay.date(hour: clock.hour, minute: clock.minute, in: calendar)))
        } else {
            apply(.day(newDay))
        }
    }

    private func setTime(hour: Int, minute: Int) {
        apply(.time((day ?? today).date(hour: hour, minute: minute, in: calendar)))
    }

    /// For today: the next full hour, or the next quarter-hour late at night. Otherwise 9:00.
    private func suggestedTime(on target: Day) -> (hour: Int, minute: Int) {
        guard target == today else { return (9, 0) }
        let now = calendar.dateComponents([.hour, .minute], from: .now)
        let hour = (now.hour ?? 0) + 1
        if hour <= 23 { return (hour, 0) }
        return (23, min(45, ((now.minute ?? 0) / 15 + 1) * 15))
    }

    private func applyPhrase(_ text: String) {
        let parsed = QuickParser.parse(text, now: .now, calendar: calendar)
        guard parsed.hasExplicitDate, let schedule = parsed.schedule else {
            rejected += 1
            NSSound.beep()
            return
        }
        apply(schedule)
        phrase = ""
    }

    private func apply(_ schedule: Schedule?) {
        withAnimation(.snappy) { store.reschedule(taskID, to: schedule) }
        // Say where the task went when it leaves the list being looked at.
        let destination: TaskTab = schedule.map { $0.day(in: calendar) <= today ? .today : .upcoming } ?? .inbox
        if destination != model.tab, model.tab != .done {
            let label = DateText.dueLabel(schedule, now: .now).map { " · \($0)" } ?? ""
            store.announce(tr("已移到「\(destination.title)」\(label)", "Moved to \(destination.title)\(label)"), undo: nil)
        }
    }
}

/// A borderless month calendar without AppKit's focus ring.
private struct MonthCalendar: NSViewRepresentable {
    @Binding var selection: Date
    let calendar: Calendar
    let locale: Locale

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSDatePicker {
        let picker = NSDatePicker()
        picker.datePickerStyle = .clockAndCalendar
        picker.datePickerElements = .yearMonthDay
        picker.datePickerMode = .single
        picker.isBordered = false
        picker.isBezeled = false
        picker.drawsBackground = false
        picker.focusRingType = .none
        picker.refusesFirstResponder = true
        picker.target = context.coordinator
        picker.action = #selector(Coordinator.changed(_:))
        return picker
    }

    func updateNSView(_ picker: NSDatePicker, context: Context) {
        context.coordinator.parent = self
        picker.calendar = calendar
        picker.timeZone = calendar.timeZone
        picker.locale = locale
        if picker.dateValue != selection { picker.dateValue = selection }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSDatePicker, context: Context) -> CGSize? {
        nsView.fittingSize
    }

    final class Coordinator: NSObject {
        var parent: MonthCalendar
        init(_ parent: MonthCalendar) { self.parent = parent }

        @objc func changed(_ sender: NSDatePicker) {
            parent.selection = sender.dateValue
        }
    }
}
