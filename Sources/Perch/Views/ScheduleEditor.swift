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
    @Namespace private var segments

    private var calendar: Calendar { settings.calendar }
    private var task: TaskItem? { store.task(taskID) }
    private var schedule: Schedule? { task?.schedule }
    private var minutes: Int { task?.minutes ?? TaskItem.defaultDuration }
    private var today: Day { Day(.now, in: calendar) }
    private var nextMonday: Day { today.adding(days: 7 - today.mondayIndex) }
    private var day: Day? { schedule?.day(in: calendar) }
    private var clock: (hour: Int, minute: Int)? {
        schedule?.time.map {
            let c = calendar.dateComponents([.hour, .minute], from: $0)
            return (c.hour ?? 9, c.minute ?? 0)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            daySegments
            WeekStrip(selection: day, today: today, tint: task?.tint.color ?? .accentColor, onPick: setDay)
            timeCard
            repeatCard
            colorRow
            phraseField
        }
        .padding(16)
        .frame(width: 288)
        .animation(.snappy(duration: 0.25), value: clock == nil)
        .animation(.snappy(duration: 0.25), value: isWeekly)
    }

    // MARK: - Parts

    /// The task's own capsule, then the day and the time span in words.
    private var header: some View {
        HStack(spacing: 11) {
            if let task {
                ZStack {
                    Capsule().fill(LinearGradient(colors: [task.tint.color.mix(with: .white, by: 0.14), task.tint.color], startPoint: .top, endPoint: .bottom))
                    switch task.glyph {
                    case .symbol(let name): Image(systemName: name).font(.system(size: 11, weight: .semibold))
                    case .text(let text): Text(text).font(.system(size: 12, weight: .semibold, design: .rounded))
                    }
                }
                .foregroundStyle(.white)
                .frame(width: 24, height: 34)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(dayTitle)
                    .font(.system(size: 15, weight: .semibold))
                Text(timeSummary)
                    .font(.system(size: 12, weight: .regular).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            .lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    private var dayTitle: String {
        guard let day else { return tr("未安排日期", "No date") }
        let relative = DateText.relativeDay(day, now: .now)
        let date = "\(DateText.monthDay(day)) \(DateText.weekday(day))"
        return relative == DateText.monthDay(day) ? date : "\(relative) · \(date)"
    }

    private var timeSummary: String {
        guard day != nil else { return tr("放在收件箱里，想到再安排", "Sits in the Inbox until you plan it") }
        guard let task, let range = DateText.timeRange(task) else { return tr("全天 · 没有具体时间", "All day · no set time") }
        return "\(range) · \(DateText.duration(task.minutes))"
    }

    private var daySegments: some View {
        let choice: Int? = switch day {
        case nil: 3
        case today: 0
        case today.adding(days: 1): 1
        case nextMonday: 2
        default: nil
        }
        return SegmentedPills(
            labels: [tr("今天", "Today"), tr("明天", "Tomorrow"), tr("下周一", "Next Mon"), tr("无日期", "No date")],
            selection: choice,
            namespace: segments,
            id: "day"
        ) { index in
            switch index {
            case 0: setDay(today)
            case 1: setDay(today.adding(days: 1))
            case 2: setDay(nextMonday)
            default: apply(nil)
            }
        }
    }

    /// Start, end and length together, behind one switch.
    private var timeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(tr("具体时间", "Set a time"), systemImage: "clock")
                    .font(.system(size: 12.5, weight: .medium))
                Spacer()
                Toggle("", isOn: hasTimeBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
            }
            if clock != nil {
                HStack(alignment: .bottom, spacing: 0) {
                    timeBox(tr("开始", "Starts"), selection: timeBinding)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 6)
                    timeBox(tr("结束", "Ends"), selection: endBinding)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
                SegmentedPills(
                    labels: DurationChoice.quick.map(shortDuration),
                    selection: DurationChoice.quick.firstIndex(of: minutes),
                    namespace: segments,
                    id: "duration"
                ) { index in
                    withAnimation(.snappy) { store.setDuration(taskID, minutes: DurationChoice.quick[index]) }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.045)))
    }

    private var isWeekly: Bool {
        if case .weekly = task?.recurrence { return true }
        return false
    }

    /// Never, every day, weekdays, weekly (on the days picked below), monthly.
    private var repeatCard: some View {
        let recurrence = task?.recurrence
        let choice = switch recurrence {
        case nil: 0
        case .daily: 1
        case .weekdays: 2
        case .weekly: 3
        case .monthly: 4
        }
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(tr("重复", "Repeat"), systemImage: "repeat")
                    .font(.system(size: 12.5, weight: .medium))
                Spacer()
                if let recurrence {
                    Text(recurrence.title)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .contentTransition(.opacity)
                }
            }
            SegmentedPills(
                labels: [tr("不重复", "Never"), tr("每天", "Daily"), tr("工作日", "Weekdays"), tr("每周", "Weekly"), tr("每月", "Monthly")],
                selection: choice,
                namespace: segments,
                id: "repeat"
            ) { index in
                let weekday = (day ?? today).mondayIndex
                let rule: Recurrence? = switch index {
                case 1: .daily
                case 2: .weekdays
                case 3: .weekly([weekday])
                case 4: .monthly
                default: nil
                }
                withAnimation(.snappy) { store.setRecurrence(taskID, rule) }
            }
            if case .weekly(let days) = recurrence {
                weekdayPicker(days)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.045)))
    }

    /// Seven small circles, Monday first; at least one stays on.
    private func weekdayPicker(_ days: Set<Int>) -> some View {
        let names = settings.isChinese ? ["一", "二", "三", "四", "五", "六", "日"] : ["M", "T", "W", "T", "F", "S", "S"]
        let tint = task?.tint.color ?? .accentColor
        return HStack(spacing: 0) {
            ForEach(0..<7, id: \.self) { index in
                let isOn = days.contains(index)
                Button {
                    var next = days
                    if isOn { next.remove(index) } else { next.insert(index) }
                    guard !next.isEmpty else { return }
                    withAnimation(.snappy) { store.setRecurrence(taskID, .weekly(next)) }
                } label: {
                    Text(names[index])
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isOn ? Color.white : .secondary)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(isOn ? tint : Color.primary.opacity(0.06)))
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func timeBox(_ title: String, selection: Binding<Date>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
            DatePicker("", selection: selection, displayedComponents: .hourAndMinute)
                .labelsHidden()
                .datePickerStyle(.field)
                .environment(\.calendar, calendar)
                .environment(\.timeZone, calendar.timeZone)
                .environment(\.locale, settings.locale)
                .fixedSize()
        }
    }

    /// Eight dots; the chosen one wears a ring. Choosing it again goes back to automatic.
    private var colorRow: some View {
        HStack(spacing: 0) {
            Text(tr("颜色", "Color"))
                .font(.system(size: 12.5, weight: .medium))
            Spacer(minLength: 8)
            HStack(spacing: 5) {
                ForEach(TaskColor.allCases, id: \.self) { color in
                    let isOn = task?.color == color
                    let isAuto = task?.color == nil && task?.tint == color
                    Button {
                        withAnimation(.snappy) { store.setColor(taskID, isOn ? nil : color) }
                    } label: {
                        Circle()
                            .fill(color.color)
                            .frame(width: 14, height: 14)
                            .padding(3)
                            .overlay(Circle().strokeBorder(color.color.opacity(isOn ? 0.95 : isAuto ? 0.45 : 0), style: StrokeStyle(lineWidth: 1.5, dash: isAuto ? [2, 2] : [])))
                            .contentShape(.circle)
                    }
                    .buttonStyle(.plain)
                    .help(isAuto ? tr("\(color.title)（自动）", "\(color.title) (automatic)") : color.title)
                }
            }
        }
    }

    private var phraseField: some View {
        HStack(spacing: 7) {
            Image(systemName: "text.cursor")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
            InputField(
                text: $phrase,
                placeholder: tr("或直接输入：后天下午3点到5点", "Or type: fri 3-5pm"),
                fontSize: 12,
                onSubmit: applyPhrase
            )
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.045)))
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

    private func shortDuration(_ minutes: Int) -> String {
        minutes < 60 ? tr("\(minutes)分", "\(minutes)m") : tr("\(minutes / 60)小时", "\(minutes / 60)h")
    }

    // MARK: - Bindings

    private var timeBinding: Binding<Date> {
        Binding(
            get: { schedule?.time ?? .now },
            set: { date in
                let c = calendar.dateComponents([.hour, .minute], from: date)
                setTime(hour: c.hour ?? 9, minute: c.minute ?? 0)
            }
        )
    }

    /// The end time; one before the start wraps to the next day, as an evening task running past midnight would.
    private var endBinding: Binding<Date> {
        Binding(
            get: { store.task(taskID)?.end ?? .now },
            set: { date in
                guard let start = schedule?.time else { return }
                let c = calendar.dateComponents([.hour, .minute], from: date)
                let startC = calendar.dateComponents([.hour, .minute], from: start)
                var length = ((c.hour ?? 0) * 60 + (c.minute ?? 0)) - ((startC.hour ?? 0) * 60 + (startC.minute ?? 0))
                if length <= 0 { length += 24 * 60 }
                withAnimation(.snappy) { store.setDuration(taskID, minutes: length) }
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
        guard parsed.hasExplicitDate || parsed.recurrence != nil, let schedule = parsed.schedule else {
            rejected += 1
            NSSound.beep()
            return
        }
        apply(schedule)
        if let minutes = parsed.duration { store.setDuration(taskID, minutes: minutes) }
        if let rule = parsed.recurrence { store.setRecurrence(taskID, rule) }
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

/// One week at a time, Monday first: tap a day to move the task there, the arrows to page.
/// Small dots under each day show what's already planned for it.
private struct WeekStrip: View {
    let selection: Day?
    let today: Day
    let tint: Color
    let onPick: (Day) -> Void

    @Environment(TaskStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @State private var weekOffset = 0
    @State private var pageEdge: Edge = .trailing

    private var weekStart: Day {
        let anchor = selection ?? today
        return anchor.adding(days: -anchor.mondayIndex + weekOffset * 7)
    }

    var body: some View {
        let start = weekStart
        let days = (0..<7).map { start.adding(days: $0) }
        let planned = plannedColors(for: days)
        VStack(spacing: 8) {
            HStack(spacing: 4) {
                Text(monthTitle(for: start.adding(days: 3)))
                    .font(.system(size: 12.5, weight: .semibold))
                    .contentTransition(.numericText())
                if weekOffset != 0 {
                    Button(tr("回到所选", "Back")) { page(to: 0) }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(tint)
                        .transition(.opacity)
                }
                Spacer()
                pageButton("chevron.left") { page(to: weekOffset - 1) }
                pageButton("chevron.right") { page(to: weekOffset + 1) }
            }
            HStack(spacing: 0) {
                ForEach(days, id: \.self) { day in
                    DayCell(
                        day: day,
                        isSelected: day == selection,
                        isToday: day == today,
                        isPast: day < today,
                        tint: tint,
                        dots: planned[day] ?? []
                    ) { onPick(day) }
                }
            }
            .id(start)
            .transition(.push(from: pageEdge))
        }
        .clipped()
        .onChange(of: selection) { weekOffset = 0 }
    }

    private func page(to offset: Int) {
        pageEdge = offset > weekOffset ? .trailing : .leading
        withAnimation(.snappy(duration: 0.3)) { weekOffset = offset }
    }

    private func pageButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.primary.opacity(0.05)))
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
    }

    private func monthTitle(for day: Day) -> String {
        if settings.isChinese { return "\(day.year)年\(day.month)月" }
        let formatter = DateFormatter()
        formatter.locale = settings.locale
        formatter.setLocalizedDateFormatFromTemplate("MMMMyyyy")
        return formatter.string(from: day.date(hour: 12, minute: 0, in: settings.calendar))
    }

    /// Up to three colors per day, one for each open task already there.
    private func plannedColors(for days: [Day]) -> [Day: [Color]] {
        let wanted = Set(days)
        var result: [Day: [Color]] = [:]
        for task in store.tasks where !task.isDone {
            guard let day = task.day(in: settings.calendar), wanted.contains(day), (result[day]?.count ?? 0) < 3 else { continue }
            result[day, default: []].append(task.tint.color)
        }
        return result
    }
}

private struct DayCell: View {
    let day: Day
    let isSelected: Bool
    let isToday: Bool
    let isPast: Bool
    let tint: Color
    let dots: [Color]
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Text(weekdayLetter)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(isToday && !isSelected ? AnyShapeStyle(tint) : AnyShapeStyle(.secondary))
                ZStack {
                    if isSelected {
                        Circle().fill(tint)
                    } else if isToday {
                        Circle().strokeBorder(tint.opacity(0.7), lineWidth: 1.2)
                    } else if hovering {
                        Circle().fill(Color.primary.opacity(0.07))
                    }
                    Text("\(day.day)")
                        .font(.system(size: 13, weight: isSelected || isToday ? .semibold : .regular, design: .rounded).monospacedDigit())
                        .foregroundStyle(numberStyle)
                }
                .frame(width: 28, height: 28)
                HStack(spacing: 2) {
                    ForEach(dots.indices, id: \.self) { index in
                        Circle().fill(dots[index]).frame(width: 4, height: 4)
                    }
                }
                .frame(height: 4)
            }
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.snappy(duration: 0.2), value: isSelected)
        .accessibilityLabel(DateText.dayHeader(day, now: .now))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var weekdayLetter: String {
        let name = DateText.weekday(day)
        return AppSettings.shared.isChinese ? String(name.suffix(1)) : String(name.prefix(1))
    }

    private var numberStyle: AnyShapeStyle {
        if isSelected { return AnyShapeStyle(.white) }
        if isToday { return AnyShapeStyle(tint) }
        return isPast ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary)
    }
}

/// A row of equal choices on one track, the chosen one lifted onto a sliding pill.
struct SegmentedPills: View {
    let labels: [String]
    let selection: Int?
    let namespace: Namespace.ID
    let id: String
    let action: (Int) -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 0) {
            ForEach(labels.indices, id: \.self) { index in
                let isOn = selection == index
                Button { action(index) } label: {
                    Text(labels[index])
                        .font(.system(size: 12, weight: isOn ? .semibold : .medium).monospacedDigit())
                        .foregroundStyle(isOn ? Color.primary : Color.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background {
                            if isOn {
                                Capsule()
                                    .fill(colorScheme == .dark ? Color.white.opacity(0.16) : Color.white)
                                    .shadow(color: .black.opacity(colorScheme == .dark ? 0 : 0.1), radius: 2, y: 1)
                                    .matchedGeometryEffect(id: id, in: namespace)
                            }
                        }
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
        .animation(.snappy(duration: 0.25), value: selection)
    }
}
