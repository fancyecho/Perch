import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Which schedule the editor shows.
@Observable
final class SchedulesRouter {
    static let shared = SchedulesRouter()
    var selection: UUID?
}

/// The schedule editor: the schedules in a glass sidebar, the selected one on the right.
final class SchedulesWindowController: NSObject, NSWindowDelegate {
    static let shared = SchedulesWindowController()
    private var window: NSWindow?

    /// Opens the editor on a schedule, or on a new one.
    func show(selecting id: UUID? = nil, creating: Bool = false) {
        let store = ScheduleStore.shared
        if creating {
            let rule = store.newRule()
            store.rules.append(rule)
            SchedulesRouter.shared.selection = rule.id
        } else if let id {
            SchedulesRouter.shared.selection = id
        }
        NSApp.activate()
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let hosting = NSHostingController(rootView: SchedulesView(store: store)
            .environment(AppSettings.shared)
            .environment(BrowserAccess.shared))
        hosting.sizingOptions = []
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.title = tr("时段", "Schedules")
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.setContentSize(NSSize(width: 920, height: 660))
        window.minSize = NSSize(width: 800, height: 560)
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        // Don't land in the name field the moment it opens.
        Task {
            try? await Task.sleep(for: .milliseconds(50))
            window.makeFirstResponder(nil)
        }
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

// MARK: - Layout

struct SchedulesView: View {
    @Bindable var store: ScheduleStore
    @Bindable var router = SchedulesRouter.shared

    var body: some View {
        NavigationSplitView {
            ScheduleSidebar(store: store, selection: $router.selection)
                .navigationSplitViewColumnWidth(min: 250, ideal: 280, max: 340)
        } detail: {
            Group {
                if let id = router.selection, store.rules.contains(where: { $0.id == id }) {
                    RuleEditor(rule: binding(for: id), store: store) {
                        withAnimation(.smooth) {
                            store.rules.removeAll { $0.id == id }
                            router.selection = store.rules.first?.id
                        }
                    }
                    .id(id)
                    .transition(.opacity)
                } else {
                    EmptySchedules(store: store, selection: $router.selection)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { router.selection = router.selection ?? store.rules.first?.id }
        .animation(.smooth(duration: 0.3), value: router.selection)
    }

    /// By id, not index: deleting another schedule shifts the indexes.
    private func binding(for id: UUID) -> Binding<BlockRule> {
        Binding(
            get: { store.rules.first { $0.id == id } ?? store.newRule() },
            set: { updated in
                if let index = store.rules.firstIndex(where: { $0.id == id }) { store.rules[index] = updated }
            })
    }
}

// MARK: - Sidebar

private struct ScheduleSidebar: View {
    @Bindable var store: ScheduleStore
    @Binding var selection: UUID?
    @Environment(AppSettings.self) private var settings

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            List(selection: $selection) {
                Section {
                    ForEach(store.rules) { rule in
                        RuleRow(rule: rule, now: context.date, locked: store.isLocked(rule, at: context.date),
                                isEnabled: enabledBinding(rule.id))
                            .tag(rule.id)
                    }
                } header: {
                    Text(tr("在固定的时间，让分心的 App 和网站暂停", "Pause distracting apps and sites at set times"))
                        .font(.system(size: 11))
                        .textCase(nil)
                        .padding(.bottom, 4)
                }
            }
            .listStyle(.sidebar)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Button(action: addRule) {
                    Label(tr("新建时段", "New Schedule"), systemImage: "plus")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .contentShape(.capsule)
                }
                .buttonStyle(.glass)
                .keyboardShortcut("n", modifiers: .command)
                .help(tr("新建时段（⌘N）", "New schedule (⌘N)"))

                // Every schedule keeps the app's clock; say which, since it may not be this Mac's.
                Label(zoneLine, systemImage: "globe")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(tr("在 设置 › 专注 中更改时区，待办和时段共用它", "Change it in Settings › Focus; tasks and schedules share it"))
            }
            .padding(14)
        }
    }

    private var zoneLine: String {
        let zone = settings.timeZone
        return tr("按 \(ZoneCatalog.title(for: zone)) 时间 · \(TimeZoneText.offset(zone))",
                  "On \(ZoneCatalog.title(for: zone)) time · \(TimeZoneText.offset(zone))")
    }

    private func addRule() {
        let rule = store.newRule()
        withAnimation(.smooth) { store.rules.append(rule) }
        selection = rule.id
    }

    private func enabledBinding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { store.rules.first { $0.id == id }?.isEnabled ?? false },
            set: { value in
                if let index = store.rules.firstIndex(where: { $0.id == id }) { store.rules[index].isEnabled = value }
            })
    }
}

private struct RuleRow: View {
    let rule: BlockRule
    let now: Date
    let locked: Bool
    @Binding var isEnabled: Bool

    var body: some View {
        let active = rule.activeOccurrence(at: now) != nil
        HStack(alignment: .center, spacing: 11) {
            Circle()
                .fill(RuleTint.gradient(rule.tint))
                .frame(width: 10, height: 10)
                .shadow(color: active ? RuleTint.color(rule.tint) : .clear, radius: 5)
                .opacity(rule.isEnabled ? 1 : 0.35)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(rule.name.isEmpty ? tr("未命名", "Untitled") : rule.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    if active { StatusPill(text: tr("进行中", "Now"), tint: rule.tint) }
                    if locked {
                        Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                }
                Text(ScheduleText.summary(rule))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !rule.hasNoTargets {
                    TargetStack(rule: rule, size: 16)
                }
            }
            .opacity(rule.isEnabled ? 1 : 0.5)

            Spacer(minLength: 4)

            Toggle(tr("启用", "On"), isOn: $isEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .disabled(locked)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Editor

private struct RuleEditor: View {
    @Binding var rule: BlockRule
    let store: ScheduleStore
    let onDelete: () -> Void

    @State private var confirmingDelete = false
    @State private var editingName = false
    @State private var hoveringName = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let locked = store.isLocked(rule, at: context.date)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header(now: context.date)

                    if locked, let active = store.activeOccurrences(at: context.date).first(where: { $0.rule.id == rule.id }) {
                        Label(tr("严格时段进行中，\(ScheduleText.moment(active.end)) 结束后才能修改",
                                 "This strict schedule is running; it can be changed after \(ScheduleText.moment(active.end))"),
                              systemImage: "lock.fill")
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RuleTint.color(rule.tint).opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }

                    VStack(alignment: .leading, spacing: 18) {
                        TargetsCard(apps: $rule.apps, sites: $rule.sites, tint: rule.tint)
                        TimeCard(rule: $rule)
                        DaysCard(weekdays: $rule.weekdays, tint: rule.tint)
                        ModeCard(isStrict: $rule.isStrict, tint: rule.tint)

                        Button(tr("删除这个时段", "Delete This Schedule"), role: .destructive) { confirmingDelete = true }
                            .buttonStyle(.plain)
                            .foregroundStyle(.red)
                            .font(.system(size: 12, weight: .medium))
                            .padding(.top, 4)
                    }
                    .disabled(locked)
                    .opacity(locked ? 0.55 : 1)
                }
                .padding(.horizontal, 36)
                .padding(.top, 24)
                .padding(.bottom, 36)
                .frame(maxWidth: 680, alignment: .leading)
                .frame(maxWidth: .infinity)
                .environment(\.cardTint, rule.tint)
                // A soft glow of the schedule's color behind the title.
                .background(alignment: .top) {
                    Circle()
                        .fill(RuleTint.color(rule.tint).opacity(0.2))
                        .frame(width: 520, height: 520)
                        .blur(radius: 110)
                        .offset(x: -160, y: -330)
                        .allowsHitTesting(false)
                        .animation(.smooth(duration: 0.6), value: rule.tint)
                }
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
        }
        // A brand-new schedule starts by naming it (once per selection).
        .onAppear { if rule.name == tr("新时段", "New Schedule") { editingName = true } }
        .confirmationDialog(tr("删除「\(rule.name)」？", "Delete “\(rule.name)”?"), isPresented: $confirmingDelete) {
            Button(tr("删除", "Delete"), role: .destructive, action: onDelete)
        } message: {
            Text(tr("这个时段和它的设置会被移除。", "The schedule and its settings will be removed."))
        }
    }

    private func header(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 16) {
                nameView
                Spacer(minLength: 12)
                TintPicker(tint: $rule.tint)
            }
            StatusCapsule(rule: rule, store: store, now: now)
        }
    }

    /// A title until clicked, then a field, so opening the window doesn't put a cursor in it.
    @ViewBuilder
    private var nameView: some View {
        if editingName {
            TextField(tr("时段名称", "Schedule name"), text: $rule.name)
                .textFieldStyle(.plain)
                .font(.system(size: 30, weight: .bold))
                .focused($nameFocused)
                .onSubmit { editingName = false }
                .onChange(of: nameFocused) { _, focused in if !focused { editingName = false } }
                .onAppear { Task { nameFocused = true } }
                .onExitCommand { editingName = false }
        } else {
            HStack(spacing: 10) {
                Text(rule.name.isEmpty ? tr("未命名", "Untitled") : rule.name)
                    .font(.system(size: 30, weight: .bold))
                    .lineLimit(1)
                Image(systemName: "pencil")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .opacity(hoveringName ? 1 : 0)
            }
            .contentShape(Rectangle())
            .onHover { hoveringName = $0 }
            .onTapGesture { if !store.isLocked(rule) { editingName = true } }
            .animation(.smooth(duration: 0.15), value: hoveringName)
            .help(tr("点击改名", "Click to rename"))
        }
    }
}

/// Under the title: running (with a small ring of what's left), next, or what's missing.
private struct StatusCapsule: View {
    let rule: BlockRule
    let store: ScheduleStore
    let now: Date

    var body: some View {
        let tint = RuleTint.color(rule.tint)
        HStack(spacing: 7) {
            switch state {
            case .active(let occurrence):
                ZStack {
                    Circle().stroke(tint.opacity(0.25), lineWidth: 2)
                    Circle()
                        .trim(from: 0, to: 1 - occurrence.progress(at: now))
                        .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 12, height: 12)
                Text(tr("进行中 · \(ScheduleText.moment(occurrence.end, from: now)) 结束 · 还剩 \(ScheduleText.remaining(until: occurrence.end, from: now))",
                        "Running · ends \(ScheduleText.moment(occurrence.end, from: now)) · \(ScheduleText.remaining(until: occurrence.end, from: now)) left"))
            case .next(let occurrence):
                Image(systemName: "clock")
                Text(tr("下一次 · \(ScheduleText.moment(occurrence.start, from: now)) 开始", "Next · starts \(ScheduleText.moment(occurrence.start, from: now))"))
            case .message(let icon, let text):
                Image(systemName: icon)
                Text(text)
            }
        }
        .font(.system(size: 12, weight: .medium))
        .monospacedDigit()
        .foregroundStyle(isActive ? AnyShapeStyle(tint) : AnyShapeStyle(.secondary))
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(isActive ? tint.opacity(0.14) : Color.primary.opacity(0.055), in: Capsule())
        .contentTransition(.interpolate)
        .animation(.smooth, value: isActive)
    }

    private enum State {
        case active(Occurrence), next(Occurrence), message(String, String)
    }

    private var isActive: Bool {
        if case .active = state { return true }
        return false
    }

    private var state: State {
        if !rule.isEnabled { return .message("pause.circle", tr("已停用", "Off")) }
        if rule.hasNoTargets { return .message("exclamationmark.circle", tr("还没有选要暂停的 App 或网站", "No apps or sites to pause yet")) }
        if let active = store.activeOccurrences(at: now).first(where: { $0.rule.id == rule.id }) { return .active(active) }
        if let next = rule.nextOccurrence(after: now) { return .next(next) }
        return .message("calendar.badge.exclamationmark", tr("当前设置下不会生效，选一下重复的日子", "Never runs as set; pick the days it repeats"))
    }
}

private struct TintPicker: View {
    @Binding var tint: Int

    var body: some View {
        HStack(spacing: 7) {
            ForEach(RuleTint.all.indices, id: \.self) { index in
                Circle()
                    .fill(RuleTint.gradient(index))
                    .frame(width: 16, height: 16)
                    .padding(3)
                    .overlay { Circle().strokeBorder(Color.primary.opacity(tint == index ? 0.5 : 0), lineWidth: 1.5) }
                    .contentShape(Circle())
                    .onTapGesture { withAnimation(.snappy) { tint = index } }
                    .accessibilityLabel(tr("颜色 \(index + 1)", "Color \(index + 1)"))
                    .accessibilityAddTraits(tint == index ? [.isSelected, .isButton] : .isButton)
            }
        }
    }
}

private struct CardTintKey: EnvironmentKey {
    static let defaultValue: Int? = nil
}

extension EnvironmentValues {
    /// Card icons take the schedule's color while one is being edited.
    var cardTint: Int? {
        get { self[CardTintKey.self] }
        set { self[CardTintKey.self] = newValue }
    }
}

/// A card of the editor.
struct FocusCard<Content: View>: View {
    let title: String
    let icon: String
    var trailing: String?
    @ViewBuilder let content: Content
    @Environment(\.cardTint) private var tint

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(tint.map { AnyShapeStyle(RuleTint.color($0)) } ?? AnyShapeStyle(.secondary))
                    .frame(width: 24, height: 24)
                    .background((tint.map { RuleTint.color($0) } ?? .primary).opacity(0.13), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if let trailing {
                    Text(trailing).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            content
        }
        .padding(18)
        .background(.background.secondary.opacity(0.6), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.primary.opacity(0.07))
        }
    }
}

// MARK: Time

private struct TimeCard: View {
    @Binding var rule: BlockRule

    var body: some View {
        let total = rule.windows.reduce(0) { $0 + $1.durationMinutes }
        FocusCard(title: tr("时间", "Time"), icon: "clock", trailing: tr("共 \(ScheduleText.duration(total))", "\(ScheduleText.duration(total)) total")) {
            DayTimeline(windows: $rule.windows, tint: rule.tint, timeZone: rule.timeZone)
                .padding(.top, 6)
                .padding(.bottom, 2)

            ForEach($rule.windows) { $window in
                WindowRow(window: $window, tint: rule.tint, canDelete: rule.windows.count > 1) {
                    withAnimation(.smooth) { rule.windows.removeAll { $0.id == window.id } }
                }
            }

            HStack {
                Button {
                    withAnimation(.smooth) { rule.windows.append(nextWindow()) }
                } label: {
                    Label(tr("添加一段", "Add a Stretch"), systemImage: "plus.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(RuleTint.color(rule.tint))
                }
                .buttonStyle(.plain)
                Spacer()
                Text(tr("拖动色块调整时间，在空白处拖动添加一段", "Drag a block to change it; drag in the gaps to add one"))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// A new stretch follows the last one an hour later.
    private func nextWindow() -> TimeWindow {
        let start = ((rule.windows.last?.end ?? 18 * 60) + 60) % 1440
        return TimeWindow(start: start, end: (start + 120) % 1440)
    }
}

/// The day as one draggable bar: drag an end to move it, the middle to shift the whole stretch, or
/// empty space to draw a new one. Snaps to 15 minutes with a tap on the trackpad at each hour; the
/// line is "now" in the app's time zone.
private struct DayTimeline: View {
    @Binding var windows: [TimeWindow]
    let tint: Int
    let timeZone: TimeZone

    private enum Drag {
        case start(UUID)
        case end(UUID)
        case move(UUID, original: TimeWindow, anchor: Int)
        case create(UUID, anchor: Int)

        var id: UUID {
            switch self {
            case .start(let id), .end(let id), .move(let id, _, _), .create(let id, _): id
            }
        }
    }

    @State private var drag: Drag?
    @State private var lastSnapped: Int?

    private static let snap = 15
    private static let edgeSlop: CGFloat = 7
    private static let trackHeight: CGFloat = 44

    private struct Segment: Identifiable {
        let id: String
        let window: UUID
        let start: Int
        let end: Int
    }

    private var segments: [Segment] {
        windows.flatMap { window -> [Segment] in
            let end = window.end == 0 ? 1440 : window.end
            if !window.crossesMidnight || window.end == 0 {
                return [Segment(id: "\(window.id)", window: window.id, start: window.start, end: end)]
            }
            return [Segment(id: "\(window.id)-a", window: window.id, start: window.start, end: 1440),
                    Segment(id: "\(window.id)-b", window: window.id, start: 0, end: window.end)]
        }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            VStack(spacing: 8) {
                GeometryReader { proxy in
                    let width = proxy.size.width
                    ZStack(alignment: .topLeading) {
                        track(width: width)
                        ForEach(segments) { segment in
                            segmentView(segment, width: width)
                        }
                        Capsule()
                            .fill(Color.primary)
                            .frame(width: 2, height: Self.trackHeight + 8)
                            .offset(x: width * nowFraction(context.date) - 1, y: -4)
                            .allowsHitTesting(false)
                        if let drag, let window = windows.first(where: { $0.id == drag.id }) {
                            dragBubble(window, width: width)
                        }
                    }
                    .contentShape(Rectangle())
                    .gesture(dragGesture(width: width))
                    .onContinuousHover { phase in updateCursor(phase, width: width) }
                }
                .frame(height: Self.trackHeight)

                hourLabels
            }
        }
        .accessibilityElement()
        .accessibilityLabel(tr("时间轴：", "Timeline: ") + windows.map(ScheduleText.window).joined(separator: tr("，", ", ")))
    }

    // MARK: Drawing

    private func track(width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.05))
            ForEach(1..<24) { hour in
                Rectangle()
                    .fill(Color.primary.opacity(hour % 6 == 0 ? 0.12 : 0.05))
                    .frame(width: 1, height: hour % 6 == 0 ? Self.trackHeight * 0.5 : Self.trackHeight * 0.25)
                    .offset(x: width * CGFloat(hour) / 24)
            }
        }
        .frame(height: Self.trackHeight)
    }

    private func segmentView(_ segment: Segment, width: CGFloat) -> some View {
        let active = drag?.id == segment.window
        let segmentWidth = max(6, width * CGFloat(segment.end - segment.start) / 1440)
        return RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(RuleTint.gradient(tint))
            .overlay(alignment: .leading) { handle.opacity(segment.id.hasSuffix("-b") ? 0 : 1) }
            .overlay(alignment: .trailing) { handle.opacity(segment.id.hasSuffix("-a") ? 0 : 1) }
            .frame(width: segmentWidth, height: Self.trackHeight - 10)
            .shadow(color: RuleTint.color(tint).opacity(active ? 0.6 : 0.3), radius: active ? 10 : 6, y: 2)
            .scaleEffect(y: active ? 1.08 : 1)
            .offset(x: width * CGFloat(segment.start) / 1440, y: 5)
            .animation(.snappy(duration: 0.18), value: active)
            .allowsHitTesting(false)
    }

    private var handle: some View {
        Capsule()
            .fill(.white.opacity(0.85))
            .frame(width: 3, height: 14)
            .padding(.horizontal, 4)
    }

    private func dragBubble(_ window: TimeWindow, width: CGFloat) -> some View {
        let center = CGFloat(window.start) + CGFloat(window.durationMinutes) / 2
        let x = min(max(width * (center.truncatingRemainder(dividingBy: 1440)) / 1440, 60), width - 60)
        return Text(ScheduleText.window(window))
            .font(.system(size: 11, weight: .semibold))
            .monospacedDigit()
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .glassEffect(.regular, in: .capsule)
            .fixedSize()
            .position(x: x, y: -16)
            .transition(.opacity)
            .allowsHitTesting(false)
    }

    private var hourLabels: some View {
        GeometryReader { proxy in
            ForEach([0, 6, 12, 18, 24], id: \.self) { hour in
                Text("\(hour):00")
                    .font(.system(size: 10, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .fixedSize()
                    .position(x: min(max(proxy.size.width * CGFloat(hour) / 24, 14), proxy.size.width - 16), y: 6)
            }
        }
        .frame(height: 12)
    }

    // MARK: Dragging

    private func minute(at x: CGFloat, width: CGFloat) -> Int {
        let raw = Double(x / max(width, 1)) * 1440 / Double(Self.snap)
        return min(max(Int(raw.rounded()) * Self.snap, 0), 1440)
    }

    private func edgeX(_ minute: Int, width: CGFloat) -> CGFloat { width * CGFloat(minute) / 1440 }

    /// Where the drag starts decides what it does: ends resize, the middle moves, empty space creates.
    private func target(at x: CGFloat, width: CGFloat) -> Drag {
        for window in windows {
            let end = window.end == 0 ? 1440 : window.end
            if abs(x - edgeX(window.start, width: width)) <= Self.edgeSlop { return .start(window.id) }
            if abs(x - edgeX(end, width: width)) <= Self.edgeSlop { return .end(window.id) }
        }
        let m = minute(at: x, width: width)
        for window in windows {
            let end = window.end == 0 ? 1440 : window.end
            let inside = window.crossesMidnight && window.end != 0 ? (m >= window.start || m <= window.end) : (m >= window.start && m <= end)
            if inside { return .move(window.id, original: window, anchor: m) }
        }
        return .create(UUID(), anchor: m)
    }

    private func dragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if drag == nil {
                    let target = target(at: value.startLocation.x, width: width)
                    if case .create(let id, let anchor) = target {
                        let start = min(anchor, 1440 - Self.snap)
                        windows.append(TimeWindow(id: id, start: start, end: start + Self.snap))
                    }
                    drag = target
                    if case .move = target { NSCursor.closedHand.set() }
                }
                let m = minute(at: value.location.x, width: width)
                if m != lastSnapped {
                    if m % 60 == 0 { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
                    lastSnapped = m
                }
                apply(m)
            }
            .onEnded { _ in
                drag = nil
                lastSnapped = nil
                NSCursor.arrow.set()
                // The list goes by start time, the same order as the bar.
                withAnimation(.smooth) { windows.sort { $0.start < $1.start } }
            }
    }

    private func apply(_ m: Int) {
        guard let drag, let index = windows.firstIndex(where: { $0.id == drag.id }) else { return }
        var window = windows[index]
        switch drag {
        case .start:
            let start = m % 1440
            guard start != window.end else { return }
            window.start = start
        case .end:
            let end = m % 1440
            guard end != window.start else { return }
            window.end = end
        case .move(_, let original, let anchor):
            let delta = m - anchor
            window.start = ((original.start + delta) % 1440 + 1440) % 1440
            window.end = ((original.end + delta) % 1440 + 1440) % 1440
        case .create(_, let anchor):
            let lower = min(anchor, m), upper = max(anchor, m)
            window.start = min(lower, 1440 - Self.snap)
            window.end = max(upper, window.start + Self.snap) % 1440
        }
        windows[index] = window
    }

    private func updateCursor(_ phase: HoverPhase, width: CGFloat) {
        guard drag == nil else { return }
        guard case .active(let point) = phase else {
            NSCursor.arrow.set()
            return
        }
        switch target(at: point.x, width: width) {
        case .start, .end: NSCursor.resizeLeftRight.set()
        case .move: NSCursor.openHand.set()
        case .create: NSCursor.crosshair.set()
        }
    }

    private func nowFraction(_ date: Date) -> CGFloat {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return CGFloat((parts.hour ?? 0) * 60 + (parts.minute ?? 0)) / 1440
    }
}

private struct WindowRow: View {
    @Binding var window: TimeWindow
    let tint: Int
    let canDelete: Bool
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(tr("从", "From")).foregroundStyle(.secondary)
            ClockField(minutes: $window.start)
            Text(tr("到", "to")).foregroundStyle(.secondary)
            ClockField(minutes: $window.end)
            if window.crossesMidnight {
                StatusPill(text: tr("次日", "next day"), tint: tint)
                    .transition(.scale.combined(with: .opacity))
            }
            Spacer()
            Text(ScheduleText.duration(window.durationMinutes))
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
            Button(action: onDelete) {
                Image(systemName: "minus.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .opacity(canDelete ? 1 : 0)
            .disabled(!canDelete)
            .accessibilityLabel(tr("删除这一段", "Remove this stretch"))
        }
        .font(.system(size: 13))
        .animation(.smooth(duration: 0.25), value: window)
    }
}

/// An hours-and-minutes field. Minutes go through a fixed UTC date and show in UTC, so this Mac's
/// own time zone can't shift them.
private struct ClockField: View {
    @Binding var minutes: Int

    private static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    var body: some View {
        DatePicker(tr("时间", "Time"), selection: Binding(
            get: { Date(timeIntervalSinceReferenceDate: TimeInterval(minutes * 60)) },
            set: { date in
                let parts = Self.utc.dateComponents([.hour, .minute], from: date)
                minutes = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            }), displayedComponents: .hourAndMinute)
            .labelsHidden()
            .datePickerStyle(.field)
            .environment(\.timeZone, TimeZone(identifier: "UTC")!)
            .environment(\.locale, Locale(identifier: "en_GB"))
            .fixedSize()
    }
}

// MARK: Days

private struct DaysCard: View {
    @Binding var weekdays: Set<Int>
    let tint: Int

    private static let order = [2, 3, 4, 5, 6, 7, 1]
    private static let segment: CGFloat = 42
    private static let height: CGFloat = 34

    /// Days next to each other join into one capsule, lighter than seven separate dots.
    private var runs: [(start: Int, count: Int)] {
        var result: [(Int, Int)] = []
        for (index, day) in Self.order.enumerated() where weekdays.contains(day) {
            if let last = result.last, last.0 + last.1 == index {
                result[result.count - 1].1 += 1
            } else {
                result.append((index, 1))
            }
        }
        return result
    }

    var body: some View {
        FocusCard(title: tr("重复", "Repeat"), icon: "repeat", trailing: ScheduleText.weekdays(weekdays)) {
            HStack(spacing: 16) {
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.06))
                    ForEach(runs, id: \.start) { run in
                        Capsule()
                            .fill(RuleTint.gradient(tint))
                            .frame(width: Self.segment * CGFloat(run.count) - 4, height: Self.height - 4)
                            .offset(x: Self.segment * CGFloat(run.start) + 2)
                            .shadow(color: RuleTint.color(tint).opacity(0.3), radius: 4, y: 1)
                    }
                    HStack(spacing: 0) {
                        ForEach(Self.order, id: \.self) { day in
                            let on = weekdays.contains(day)
                            Text(ScheduleText.shortWeekday(day))
                                .font(.system(size: AppSettings.shared.isChinese ? 13 : 11.5, weight: on ? .semibold : .regular))
                                .foregroundStyle(on ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                                .frame(width: Self.segment, height: Self.height)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    withAnimation(.snappy(duration: 0.22)) {
                                        if on { weekdays.remove(day) } else { weekdays.insert(day) }
                                    }
                                }
                                .accessibilityAddTraits(on ? [.isSelected, .isButton] : .isButton)
                        }
                    }
                }
                .frame(width: Self.segment * 7, height: Self.height)
                .animation(.snappy(duration: 0.22), value: weekdays)

                Spacer(minLength: 0)

                HStack(spacing: 12) {
                    ForEach([(tr("每天", "Daily"), Set(1...7)), (tr("工作日", "Weekdays"), Set([2, 3, 4, 5, 6])), (tr("周末", "Weekends"), Set([1, 7]))], id: \.0) { preset in
                        Button(preset.0) { withAnimation(.snappy(duration: 0.22)) { weekdays = preset.1 } }
                            .buttonStyle(.plain)
                            .font(.system(size: 12, weight: weekdays == preset.1 ? .semibold : .regular))
                            .foregroundStyle(weekdays == preset.1 ? AnyShapeStyle(RuleTint.color(tint)) : AnyShapeStyle(.secondary))
                    }
                }
            }
        }
    }
}

// MARK: Apps and sites

/// Paused apps and sites share one card: what's added as tiles, then "Add App" beside an address field.
private struct TargetsCard: View {
    @Binding var apps: [BlockedApp]
    @Binding var sites: [BlockedSite]
    let tint: Int
    @State private var input = ""
    @State private var invalid = false
    @State private var pickingApp = false
    let icons = SiteIcons.shared
    @Environment(BrowserAccess.self) private var access

    private var unusedSuggestions: [BlockedSite] {
        BlockedSite.suggestions.filter { suggestion in !sites.contains { $0.pattern == suggestion.pattern } }
    }

    private var countText: String? {
        let parts = [apps.isEmpty ? nil : tr("\(apps.count) 个 App", "\(apps.count) apps"),
                     sites.isEmpty ? nil : tr("\(sites.count) 个网站", "\(sites.count) sites")].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var body: some View {
        FocusCard(title: tr("暂停的 App 与网站", "Paused Apps & Sites"), icon: "pause.circle", trailing: countText) {
            if apps.isEmpty && sites.isEmpty {
                Text(tr("选几个容易分心的 App 或网站。时段里打开它们，就会被轻轻拦下。",
                        "Pick the apps and sites that pull you away. Open one during the schedule and it's gently stopped."))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 172), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(apps) { app in
                        TargetChip(icon: AppIcons.icon(for: app.bundleID), title: app.name, subtitle: "App", roundsIcon: false) {
                            withAnimation(.smooth) { apps.removeAll { $0.bundleID == app.bundleID } }
                        }
                        .transition(.scale(scale: 0.85).combined(with: .opacity))
                    }
                    ForEach(sites) { site in
                        TargetChip(icon: icons.icon(for: site), title: site.displayName,
                                   subtitle: BlockedSite.knownName(for: site.pattern) == nil ? tr("网站", "Site") : site.pattern, roundsIcon: true) {
                            withAnimation(.smooth) { sites.removeAll { $0.pattern == site.pattern } }
                        }
                        .help(site.pattern)
                        .transition(.scale(scale: 0.85).combined(with: .opacity))
                    }
                }
            }

            HStack(spacing: 8) {
                Button { pickingApp = true } label: {
                    Label(tr("添加 App", "Add App"), systemImage: "plus.app")
                        .font(.system(size: 12.5, weight: .medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .contentShape(RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(SoftPressStyle())
                .popover(isPresented: $pickingApp, arrowEdge: .bottom) {
                    AppPicker(selected: Set(apps.map(\.bundleID))) { picked in
                        withAnimation(.smooth) {
                            for app in picked where !apps.contains(where: { $0.bundleID == app.bundleID }) {
                                apps.append(app)
                            }
                        }
                    }
                }

                HStack(spacing: 8) {
                    Image(systemName: "link").foregroundStyle(.tertiary)
                    TextField(tr("输入网址，比如 bilibili.com 或 youtube.com/shorts", "Type an address, like youtube.com or youtube.com/shorts"), text: $input)
                        .textFieldStyle(.plain)
                        .onSubmit(addTyped)
                        .onChange(of: input) { invalid = false }
                    if !input.trimmingCharacters(in: .whitespaces).isEmpty {
                        Button(action: addTyped) {
                            Image(systemName: "return")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(RuleTint.color(tint))
                        }
                        .buttonStyle(.plain)
                        .help(tr("添加这个网站", "Add this site"))
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(invalid ? Color.red.opacity(0.6) : .clear)
                }
                .modifier(Shake(attempts: invalid ? 1 : 0))
                .animation(.default, value: invalid)
                .animation(.smooth(duration: 0.2), value: input.isEmpty)
            }
            if invalid {
                Text(tr("这看起来不像网址，试试 bilibili.com 这样的写法", "That doesn't look like an address; try something like youtube.com"))
                    .font(.system(size: 11))
                    .foregroundStyle(.red.opacity(0.8))
            }

            if !unusedSuggestions.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(tr("常用网站", "Common sites")).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 6)], alignment: .leading, spacing: 6) {
                        ForEach(unusedSuggestions) { suggestion in
                            Button {
                                withAnimation(.smooth) { sites.append(suggestion) }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(nsImage: icons.icon(for: suggestion))
                                        .resizable()
                                        .frame(width: 14, height: 14)
                                        .clipShape(RoundedRectangle(cornerRadius: 3.5, style: .continuous))
                                    Text(suggestion.displayName).font(.system(size: 12)).lineLimit(1)
                                    Spacer(minLength: 0)
                                    Image(systemName: "plus").font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary)
                                }
                                .padding(.horizontal, 9)
                                .padding(.vertical, 6)
                                .background(Color.primary.opacity(0.045), in: Capsule())
                                .contentShape(Capsule())
                            }
                            .buttonStyle(SoftPressStyle())
                            .help(suggestion.pattern)
                        }
                    }
                }
            }

            if !sites.isEmpty {
                Divider().padding(.vertical, 2)
                BrowserAccessRow(access: access)
            }
        }
    }

    private func addTyped() {
        guard let pattern = BlockedSite.normalize(input) else {
            invalid = true
            return
        }
        if !sites.contains(where: { $0.pattern == pattern }) {
            withAnimation(.smooth) { sites.append(BlockedSite(pattern: pattern, name: BlockedSite.knownName(for: pattern))) }
        }
        input = ""
    }
}

/// An added app or site: icon, name and a line under it; a remove button shows under the pointer.
private struct TargetChip: View {
    let icon: NSImage
    let title: String
    let subtitle: String
    let roundsIcon: Bool
    let onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 9) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: roundsIcon ? 22 : 26, height: roundsIcon ? 22 : 26)
                .clipShape(RoundedRectangle(cornerRadius: roundsIcon ? 5.5 : 0, style: .continuous))
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.system(size: 12.5, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Text(subtitle).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 4)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0)
            .accessibilityLabel(tr("移除 \(title)", "Remove \(title)"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(hovering ? 0.08 : 0.045), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .onHover { hovering = $0 }
        .animation(.smooth(duration: 0.18), value: hovering)
    }
}

/// Picking apps: the running ones first, or any from the Applications folder.
private struct AppPicker: View {
    let selected: Set<String>
    let onPick: ([BlockedApp]) -> Void

    private var running: [BlockedApp] {
        let own = Bundle.main.bundleIdentifier
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> BlockedApp? in
                guard let id = app.bundleIdentifier, id != own, seen.insert(id).inserted else { return nil }
                return BlockedApp(bundleID: id, name: app.localizedName ?? id)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(tr("正在运行", "Running"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 6)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(running) { app in
                        let added = selected.contains(app.bundleID)
                        Button { onPick([app]) } label: {
                            HStack(spacing: 10) {
                                Image(nsImage: AppIcons.icon(for: app.bundleID))
                                    .resizable().frame(width: 22, height: 22)
                                Text(app.name).font(.system(size: 13))
                                Spacer()
                                Image(systemName: added ? "checkmark" : "plus")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(added ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(added)
                    }
                }
                .padding(.horizontal, 6)
            }
            .frame(maxHeight: 320)
            Divider()
            Button {
                onPick(Self.chooseFromApplications())
            } label: {
                Label(tr("从「应用程序」文件夹选择…", "Choose from Applications…"), systemImage: "folder")
                    .font(.system(size: 12, weight: .medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(width: 300)
    }

    private static func chooseFromApplications() -> [BlockedApp] {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = tr("添加", "Add")
        guard panel.runModal() == .OK else { return [] }
        return panel.urls.compactMap { url in
            guard let id = Bundle(url: url)?.bundleIdentifier, id != Bundle.main.bundleIdentifier else { return nil }
            let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            return BlockedApp(bundleID: id, name: name)
        }
    }
}

/// Whether each installed browser lets Perch read its tabs; a button to ask the ones that don't.
struct BrowserAccessRow: View {
    let access: BrowserAccess

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { _ in
            let browsers = Browser.allCases.filter(\.isInstalled)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text(tr("浏览器", "Browsers")).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    Text(tr("需要允许 Perch 读取当前标签页的网址；不会记录或上传浏览记录",
                            "Perch needs to read the current tab's address; nothing is recorded or sent anywhere"))
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                FlowRow(spacing: 8) {
                    ForEach(browsers, id: \.self) { browser in
                        pill(browser, state: access.states[browser])
                    }
                }
                if NSWorkspace.shared.urlForApplication(withBundleIdentifier: "org.mozilla.firefox") != nil {
                    Text(tr("Firefox 读不到网址。需要的话，把 Firefox 整个加进暂停的 App", "Firefox can't be read. If needed, pause Firefox itself as an app"))
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
            .onAppear { access.refreshAll() }
        }
    }

    @ViewBuilder
    private func pill(_ browser: Browser, state: Browser.Permission?) -> some View {
        let icon = Image(nsImage: AppIcons.icon(for: browser.bundleID)).resizable().frame(width: 15, height: 15)
        switch state {
        case .granted:
            HStack(spacing: 5) {
                icon
                Text(browser.name)
                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.green)
            }
            .font(.system(size: 11.5))
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(Color.primary.opacity(0.045), in: Capsule())
            .help(tr("\(browser.name) 已允许", "\(browser.name) is allowed"))
        case .denied:
            Button { Browser.openAutomationSettings() } label: {
                HStack(spacing: 5) { icon; Text(tr("\(browser.name) 已拒绝 · 去设置", "\(browser.name) denied · Settings")) }
            }
            .controlSize(.small)
            .help(tr("在「系统设置 › 隐私与安全性 › 自动化」里打开 Perch 对 \(browser.name) 的权限",
                     "Turn on Perch's access to \(browser.name) in System Settings › Privacy & Security › Automation"))
        case .notRunning:
            Button {
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.bundleID) {
                    NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(1.5))
                            access.request(browser)
                        }
                    }
                }
            } label: {
                HStack(spacing: 5) { icon; Text(tr("打开 \(browser.name) 并允许", "Open \(browser.name) and Allow")) }
            }
            .controlSize(.small)
        default:
            Button { access.request(browser) } label: {
                HStack(spacing: 5) { icon; Text(tr("允许 \(browser.name)", "Allow \(browser.name)")) }
            }
            .controlSize(.small)
        }
    }
}

/// Wraps its items onto as many lines as they need.
struct FlowRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                y += line + spacing
                x = 0
                line = 0
            }
            x += size.width + spacing
            line = max(line, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, width), height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += line + spacing
                x = bounds.minX
                line = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}

// MARK: Strictness

private struct ModeCard: View {
    @Binding var isStrict: Bool
    let tint: Int
    let focusStore = FocusStore.shared

    private var guarantees: [String] {
        [
            tr("被暂停的 App 直接退出、网站标签页直接关掉，后台播放也一起停下",
               "Paused apps quit and their sites' tabs close, background playback included"),
            tr("时段内不能跳过，也不能修改、停用、删除这个时段",
               "No skipping, and the schedule can't be changed, turned off or deleted while it runs"),
            tr("改系统时间、换时区，都不会让它提前结束", "Changing the clock or time zone won't end it early"),
            tr("Perch 不能从菜单退出；被强行结束后会自动重开", "Perch can't be quit from its menus, and comes back if it's killed"),
        ]
    }

    var body: some View {
        FocusCard(title: tr("打开被暂停的 App 时", "When a Paused App Opens"), icon: "hand.raised") {
            HStack(spacing: 12) {
                option(strict: false, title: tr("温和", "Gentle"), icon: "leaf",
                       text: tr("收起 App。可以按住按钮再用 \(ScheduleStore.passMinutes) 分钟，每天最多 \(ScheduleStore.passesPerDay) 次",
                                "The app is put away. Hold a button for \(ScheduleStore.passMinutes) more minutes, up to \(ScheduleStore.passesPerDay) times a day"))
                option(strict: true, title: tr("严格", "Strict"), icon: "lock",
                       text: tr("没有商量的余地，到点才结束", "No exceptions until it ends"))
            }

            if isStrict {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(guarantees, id: \.self) { line in
                        Label {
                            Text(line)
                        } icon: {
                            Image(systemName: "checkmark").foregroundStyle(RuleTint.color(tint))
                        }
                    }
                }
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .transition(.opacity.combined(with: .move(edge: .top)))

                if !focusStore.keepAlive {
                    notice(tr("现在 Perch 被强行结束就不会重开。打开「防止被强行退出」，最后一条才成立。",
                              "Right now a killed Perch stays closed. Turn on Keep Alive for the last promise to hold."),
                           button: tr("打开", "Turn On")) { focusStore.keepAlive = true }
                } else if focusStore.keepAliveNeedsApproval {
                    notice(tr("还需要在「系统设置 › 登录项」里允许 Perch 在后台运行", "Allow Perch to run in the background in System Settings › Login Items"),
                           button: tr("去设置", "Open Settings")) { BackgroundAgent.openLoginItemsSettings() }
                }
            }
        }
        .animation(.smooth(duration: 0.3), value: isStrict)
    }

    private func notice(_ text: String, button: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text)
                .font(.system(size: 11.5))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(button, action: action)
                .controlSize(.small)
        }
        .padding(12)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func option(strict: Bool, title: String, icon: String, text: String) -> some View {
        let selected = isStrict == strict
        return VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(selected ? AnyShapeStyle(RuleTint.color(tint)) : AnyShapeStyle(.primary))
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 78, alignment: .topLeading)
        .background(selected ? RuleTint.color(tint).opacity(0.1) : Color.primary.opacity(0.03),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(selected ? RuleTint.color(tint).opacity(0.7) : Color.primary.opacity(0.08), lineWidth: selected ? 1.5 : 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture { withAnimation(.snappy(duration: 0.2)) { isStrict = strict } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}

// MARK: - Empty

private struct EmptySchedules: View {
    let store: ScheduleStore
    @Binding var selection: UUID?

    private var presets: [(name: String, detail: String, start: Int, end: Int, days: Set<Int>)] {
        [
            (tr("晚自习", "Evening Study"), tr("每天 19:00–22:00", "Daily 19:00–22:00"), 19 * 60, 22 * 60, Set(1...7)),
            (tr("上午刷题", "Morning Practice"), tr("工作日 08:30–11:30", "Weekdays 08:30–11:30"), 8 * 60 + 30, 11 * 60 + 30, [2, 3, 4, 5, 6]),
            (tr("睡前远离屏幕", "Screens Off at Night"), tr("每天 23:00–次日 07:00", "Daily 23:00–07:00"), 23 * 60, 7 * 60, Set(1...7)),
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "lamp.desk.fill")
                .font(.system(size: 46, weight: .regular))
                .foregroundStyle(Brand.gradient)
                .frame(width: 92, height: 92)
                .glassEffect(.regular, in: .circle)
                .padding(.bottom, 22)
            Text(tr("还没有时段", "No Schedules Yet"))
                .font(.system(size: 22, weight: .bold))
                .padding(.bottom, 8)
            Text(tr("在固定的时间，让微信、视频这些容易分心的 App 暂停。\n到点自动开始，到点自动结束。",
                    "Pause chat, video and other distractions at set times.\nThey start and end on their own."))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.bottom, 28)

            VStack(spacing: 8) {
                ForEach(Array(presets.enumerated()), id: \.offset) { index, preset in
                    Button {
                        add(name: preset.name, start: preset.start, end: preset.end, days: preset.days)
                    } label: {
                        HStack(spacing: 12) {
                            Circle().fill(RuleTint.gradient(index)).frame(width: 10, height: 10)
                            Text(preset.name).font(.system(size: 13, weight: .semibold))
                            Spacer()
                            Text(preset.detail).font(.system(size: 12)).foregroundStyle(.secondary)
                            Image(systemName: "plus.circle.fill").foregroundStyle(RuleTint.color(index))
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .frame(width: 380)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .contentShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(SoftPressStyle())
                }
            }
            .padding(.bottom, 16)

            Button(tr("从空白开始", "Start from Scratch")) { add(name: nil, start: 19 * 60, end: 22 * 60, days: Set(1...7)) }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(40)
    }

    private func add(name: String?, start: Int, end: Int, days: Set<Int>) {
        let rule = store.newRule(name: name, start: start, end: end, weekdays: days)
        withAnimation(.smooth) { store.rules.append(rule) }
        selection = rule.id
    }
}

// MARK: - Shared pieces

struct StatusPill: View {
    let text: String
    let tint: Int

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(RuleTint.color(tint))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RuleTint.color(tint).opacity(0.15), in: Capsule())
    }
}

/// A schedule's app and site icons, overlapping.
struct TargetStack: View {
    let rule: BlockRule
    let size: CGFloat
    var limit = 4
    let icons = SiteIcons.shared

    var body: some View {
        let images: [(id: String, image: NSImage, rounded: Bool)] =
            rule.apps.map { ($0.bundleID, AppIcons.icon(for: $0.bundleID), false) }
            + rule.sites.map { ($0.pattern, icons.icon(for: $0), true) }
        HStack(spacing: -size * 0.3) {
            ForEach(images.prefix(limit), id: \.id) { item in
                Image(nsImage: item.image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: item.rounded ? size * 0.82 : size, height: item.rounded ? size * 0.82 : size)
                    .clipShape(RoundedRectangle(cornerRadius: item.rounded ? size * 0.2 : 0, style: .continuous))
                    .frame(width: size, height: size)
            }
            if images.count > limit {
                Text("+\(images.count - limit)")
                    .font(.system(size: size * 0.55, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, size * 0.4)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(ScheduleText.targetList(rule))
    }
}

// MARK: - Time zones

/// Every time zone, with common cities named in Chinese too, searchable in either language or by id.
enum ZoneCatalog {
    struct Entry: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let offset: String
        let search: String
    }

    static let aliases: [String: (String, String)] = [
        "Asia/Shanghai": ("北京 / 上海", "Beijing / Shanghai"), "Asia/Hong_Kong": ("香港", "Hong Kong"), "Asia/Taipei": ("台北", "Taipei"),
        "Asia/Tokyo": ("东京", "Tokyo"), "Asia/Seoul": ("首尔", "Seoul"), "Asia/Singapore": ("新加坡", "Singapore"),
        "Asia/Kolkata": ("印度", "India"), "Asia/Dubai": ("迪拜", "Dubai"), "Europe/London": ("伦敦", "London"),
        "Europe/Paris": ("巴黎", "Paris"), "Europe/Berlin": ("柏林", "Berlin"), "Europe/Moscow": ("莫斯科", "Moscow"),
        "America/New_York": ("纽约", "New York"), "America/Chicago": ("芝加哥", "Chicago"), "America/Denver": ("丹佛", "Denver"),
        "America/Los_Angeles": ("洛杉矶", "Los Angeles"), "America/Toronto": ("多伦多", "Toronto"), "America/Vancouver": ("温哥华", "Vancouver"),
        "Australia/Sydney": ("悉尼", "Sydney"), "Australia/Melbourne": ("墨尔本", "Melbourne"), "Pacific/Auckland": ("奥克兰", "Auckland"),
    ]

    static func title(for zone: TimeZone) -> String {
        aliases[zone.identifier].map { tr($0.0, $0.1) } ?? TimeZoneText.city(zone)
    }

    static var entries: [Entry] {
        TimeZone.knownTimeZoneIdentifiers.compactMap { id -> Entry? in
            guard let zone = TimeZone(identifier: id) else { return nil }
            let name = TimeZoneText.name(zone)
            let alias = aliases[id]
            return Entry(id: id, title: alias.map { tr($0.0, $0.1) } ?? TimeZoneText.city(zone), subtitle: "\(name) · \(id)",
                         offset: TimeZoneText.offset(zone),
                         search: [alias?.0 ?? "", alias?.1 ?? "", name, id, TimeZoneText.city(zone)].joined(separator: " ").lowercased())
        }
        .sorted { a, b in
            // Common ones first, then by offset.
            let ua = aliases[a.id] != nil, ub = aliases[b.id] != nil
            if ua != ub { return ua }
            let oa = TimeZone(identifier: a.id)?.secondsFromGMT() ?? 0, ob = TimeZone(identifier: b.id)?.secondsFromGMT() ?? 0
            return oa != ob ? oa < ob : a.id < b.id
        }
    }
}

/// Searchable zones: following the system, the current choice, then the common cities.
struct ZonePicker: View {
    @Binding var selection: String?
    let onDone: () -> Void
    @State private var query = ""
    @State private var entries = ZoneCatalog.entries

    var body: some View {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        let matches = needle.isEmpty ? entries : entries.filter { $0.search.contains(needle) }
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(tr("搜索城市或时区，比如 纽约、Tokyo", "Search a city or zone, like Tokyo"), text: $query)
                    .textFieldStyle(.plain)
            }
            .padding(10)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
            .padding(12)

            ScrollView {
                LazyVStack(spacing: 2) {
                    if needle.isEmpty {
                        row(id: nil, title: tr("跟随系统", "Follow System"),
                            subtitle: tr("现在是 \(ZoneCatalog.title(for: .current))", "Currently \(ZoneCatalog.title(for: .current))"),
                            offset: TimeZoneText.offset(.current))
                        // The current choice up top, rather than somewhere in the long list.
                        if let current = entries.first(where: { $0.id == selection }) {
                            row(id: current.id, title: current.title, subtitle: current.subtitle, offset: current.offset)
                        }
                        Divider().padding(.vertical, 4)
                    }
                    ForEach(matches) { entry in
                        row(id: entry.id, title: entry.title, subtitle: entry.subtitle, offset: entry.offset)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
        }
        .frame(width: 360, height: 440)
    }

    private func row(id: String?, title: String, subtitle: String, offset: String) -> some View {
        Button {
            selection = id
            onDone()
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .medium))
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Text(offset).font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .opacity(selection == id ? 1 : 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(selection == id ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
