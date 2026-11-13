import AppKit
import AVFoundation
import Combine
import os

let log = Logger(subsystem: "app.perch.Perch", category: "line")

/// The two lines either side of the island. Each keeps its own photos, in its own folder: the
/// right one the screenshots that come and go, the left one what you collect, like notes from a class.
public enum LineSide: String, CaseIterable, Sendable {
    case left, right

    var other: LineSide { self == .left ? .right : .left }
}

/// One screenshot hanging on the line.
struct Pegged: Identifiable, Equatable {
    let id = UUID()
    /// Changes when the photo moves to the other line, and its file with it.
    var url: URL
    var side: LineSide = .right
    var thumb: NSImage
    /// Every photo hangs a little crooked, like on a real line.
    let tilt = Double.random(in: -2.5...2.5)
    var falling = false
    /// Still flying in from where it was captured; the card waits hidden.
    var flying = false
    /// Pinned, left of the knot: it stays until you take it down.
    var kept = false
    /// Taken off the line to hold in front of you. Its clip waits empty
    /// until it comes back.
    var held = false
    /// Hung from another app with Hang on Perch, rather than pinned
    /// from the photos that came and went. Always pinned.
    var byHand = false
    /// A screen recording rather than a screenshot.
    var isRecording: Bool { PerchLine.isRecording(url) }

    static func == (a: Pegged, b: Pegged) -> Bool {
        a.id == b.id && a.side == b.side && a.url == b.url && a.falling == b.falling && a.flying == b.flying && a.kept == b.kept && a.byHand == b.byHand && a.held == b.held && a.thumb === b.thumb
    }
}

/// The line itself: what hangs on it and what you can do with each item.
/// The files never move. The line is only a view onto them.
@MainActor
final class Line: ObservableObject {
    @Published private(set) var items: [Pegged] = []
    @Published private(set) var gust = 0
    @Published var copiedID: UUID?
    @Published var draggingID: UUID?
    @Published var pressedID: UUID?
    /// Whether the line has slid down into view.
    @Published var revealed = false

    /// Card frames in window coordinates, reported by the views. The panel
    /// uses them to only catch clicks over photos and let the rest through.
    var hitRects: [UUID: CGRect] = [:]
    /// The labels between the two lines, which take clicks too.
    var labelRects: [CGRect] = []
    /// While a photo is dragged over the other line: that line, where it would hang.
    @Published var dropSide: LineSide?

    /// How many photos fit across each line. With Keep on line set, a line
    /// can hold more, and the rest are reached by scrolling.
    var visibleCount: [LineSide: Int] = [.left: 4, .right: 4]
    /// How far each line is scrolled towards older photos, in points; 0
    /// shows the newest.
    @Published var scroll: [LineSide: CGFloat] = [:]

    /// The birds that come to sit on the line while it is down.
    let flock = Flock()

    func visible(on side: LineSide) -> Int { visibleCount[side] ?? 4 }

    /// How many photos a line keeps before its oldest falls off.
    func maxItems(on side: LineSide) -> Int {
        let fits = visible(on: side)
        return max(fits, Line.keepOnLine ?? fits)
    }

    func scroll(on side: LineSide) -> CGFloat { scroll[side] ?? 0 }

    /// The photos on one line, in order, empty places included.
    func items(on side: LineSide) -> [Pegged] { items.filter { $0.side == side } }

    func liveCount(on side: LineSide) -> Int { items.filter { $0.side == side && !$0.falling }.count }

    // MARK: Two lines, two folders

    /// Where new captures hang. Switched from the labels between the two
    /// lines, Perch's menu or its settings.
    @Published var target: LineSide = LineSide(rawValue: UserDefaults.standard.string(forKey: "lineTarget") ?? "") ?? .right {
        didSet { UserDefaults.standard.set(target.rawValue, forKey: "lineTarget") }
    }

    /// The left line's folder: chosen in settings, or one in Pictures,
    /// made the first time something hangs there.
    static var leftFolder: URL {
        get {
            if let path = UserDefaults.standard.string(forKey: "leftLineFolder"), !path.isEmpty {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
            // Named once, so switching Perch's language later does not move it.
            let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
            let folder = pictures.appendingPathComponent(L("Kept Screenshots"), isDirectory: true)
            UserDefaults.standard.set(folder.path, forKey: "leftLineFolder")
            return folder
        }
        set { UserDefaults.standard.set(newValue.path, forKey: "leftLineFolder") }
    }

    /// The name on the left line's label.
    static var leftName: String { FileManager.default.displayName(atPath: leftFolder.path) }

    static func name(of side: LineSide) -> String { side == .left ? leftName : L("Screenshots") }

    private static func isInside(_ url: URL, _ folder: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path + "/")
    }

    /// Moves a file into a folder under a name nothing else has there, and
    /// the clipboard with it. Nil when it could not be moved.
    private func move(_ url: URL, into folder: URL) -> URL? {
        if Self.isInside(url, folder) { return url }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let target = uniqueURL(in: folder, for: url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: target)
            clipboardFollows(url, to: target)
            log.notice("Moved \(url.lastPathComponent, privacy: .public) to \(folder.lastPathComponent, privacy: .public)")
            return target
        } catch {
            log.error("Could not move \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// A new capture for the left line goes into its folder first. Nil when
    /// it could not, and it then hangs on the right as before.
    func adoptForLeft(_ url: URL) -> URL? { move(url, into: Line.leftFolder) }

    /// From a photo's menu: over to the other line, and into its folder. What
    /// was hung by hand from elsewhere stays where it is. Going right, a photo
    /// from the left folder moves into Perch's screenshot folder, where the
    /// cross sends it to the Trash, while Perch handles screenshots.
    func move(_ id: UUID, to side: LineSide) {
        guard let i = items.firstIndex(where: { $0.id == id && !$0.falling && !$0.held }), items[i].side != side else { return }
        var url = items[i].url
        if !items[i].byHand {
            if side == .left {
                guard let moved = move(url, into: Line.leftFolder) else { return NSSound.beep() }
                url = moved
            } else if Inbox.isEnabled, Self.isInside(url, Line.leftFolder), let moved = move(url, into: Inbox.folder) {
                url = moved
            }
        }
        var item = items.remove(at: i)
        item.url = url
        item.side = side
        hitRects[id] = nil
        items.append(item)
        scroll[side] = 0
        keepKeptFirst()
        letGoOverflow(on: side, sparing: [id])
        save()
        play("Tink", volume: 0.35)
    }

    /// Keep on line, from the menu bar: how many photos the line keeps, or
    /// nil for as many as fit across the screen.
    nonisolated static let keepChoices = [25, 50, 100]
    nonisolated static var keepOnLine: Int? {
        get {
            let n = UserDefaults.standard.integer(forKey: "keepOnLine")
            return keepChoices.contains(n) ? n : nil
        }
        set { UserDefaults.standard.set(newValue ?? 0, forKey: "keepOnLine") }
    }


    var soundOn: Bool {
        get { !UserDefaults.standard.bool(forKey: "soundOff") }
        set { UserDefaults.standard.set(!newValue, forKey: "soundOff") }
    }

    var liveCount: Int { items.filter { !$0.falling }.count }

    /// How many photos at the start of a line are pinned, the empty places
    /// of pinned ones that just came down included. Pinned photos hang
    /// together at the left end of their line, before the knot, and never
    /// fall to make room.
    func pinnedLead(on side: LineSide) -> Int { items(on: side).prefix { $0.kept }.count }

    /// The oldest photo on a line that can fall: the first one past the knot.
    private func oldestLoose(on side: LineSide, sparing: Set<UUID> = []) -> Pegged? {
        items.first { $0.side == side && !$0.falling && !$0.kept && !$0.held && !sparing.contains($0.id) }
    }

    /// A full line lets its oldest photos fall off the far end.
    private func letGoOverflow(on side: LineSide, sparing: Set<UUID> = []) {
        while liveCount(on: side) > maxItems(on: side), let oldest = oldestLoose(on: side, sparing: sparing) {
            letGo(oldest.id)
        }
    }

    private let storeKey = "pegged"

    init() {
        restore()
        scheduleGust()
    }

    // MARK: Hanging and dropping

    @discardableResult
    func hang(_ url: URL, on side: LineSide = .right, quietly: Bool = false, flying: Bool = false) -> UUID? {
        guard !items.contains(where: { $0.url == url && !$0.falling }),
              let thumb = makeThumbnail(url) else { return nil }
        var item = Pegged(url: url, thumb: thumb)
        item.flying = flying
        item.side = side
        // The line moves anyway for a new photo, so the gaps close with it.
        sweepFallen()
        items.append(item)
        scroll[side] = 0
        letGoOverflow(on: side, sparing: [item.id])
        save()
        if !quietly { play("Tink", volume: 0.35) }
        return item.id
    }

    /// From a photo's menu: over to the other line. The app flies it across.
    var onMoveAcross: ((UUID, LineSide) -> Void)?

    func moveAcross(_ id: UUID, to side: LineSide) {
        if let onMoveAcross { onMoveAcross(id, side) } else { move(id, to: side) }
    }

    /// About to fly to its place, from where it was dropped: the card waits hidden.
    func setFlying(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].flying = true
    }

    /// The capture has reached the line: the real card takes over.
    func land(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].flying = false
    }

    /// Called just before a photo starts falling, so the fall can be drawn
    /// over the whole screen.
    var onFall: ((Pegged) -> Void)?

    /// Hold, from a photo's menu: the app takes it off the line.
    var onHold: ((UUID) -> Void)?
    /// A click on a held photo's faded trace: it comes back.
    var onHangBack: ((UUID) -> Void)?

    func drop(_ id: UUID, quietly: Bool = false) {
        guard let i = items.firstIndex(where: { $0.id == id }), !items[i].falling else { return }
        onFall?(items[i])
        items[i].falling = true
        hitRects[id] = nil
        save()
        if !quietly { play("Pop", volume: 0.25) }
        lastFall = Date()
    }

    /// When the last photo started falling. A fallen photo keeps its empty
    /// place while the pointer stays on the line, so the next cross stays
    /// under it while discarding several in a row.
    private var lastFall = Date.distantPast

    /// The pointer left the line: the gaps close, once the last photo has
    /// finished falling.
    func closeGaps() {
        guard items.contains(where: { $0.falling }),
              Date().timeIntervalSince(lastFall) >= 0.6 else { return }
        sweepFallen()
    }

    /// The fallen photos leave their places and the rest close up.
    private func sweepFallen() {
        items.removeAll { $0.falling }
    }

    /// "Take everything down": every photo past the knot goes the way of its
    /// corner cross. What you hung by hand stays.
    func clear() {
        takeDown(items.filter { !$0.falling && !$0.kept && !$0.held })
    }

    /// The photos hung before (left) or after (right) this one, on its own line.
    func neighbours(of id: UUID, toTheLeft: Bool) -> [Pegged] {
        guard let side = items.first(where: { $0.id == id })?.side else { return [] }
        let live = items.filter { !$0.falling && $0.side == side }
        guard let i = live.firstIndex(where: { $0.id == id }) else { return [] }
        return (toTheLeft ? Array(live[..<i]) : Array(live[(i + 1)...])).filter { !$0.kept && !$0.held }
    }

    /// Takes down everything on one side of a photo. Each one goes the way
    /// of its own corner button: to the Trash from Perch's folder, and
    /// only off the line from anywhere else.
    func takeDown(_ id: UUID, toTheLeft: Bool) {
        takeDown(neighbours(of: id, toTheLeft: toTheLeft))
    }

    /// One after another, and only the first makes a sound. They are one
    /// step, so Put back brings them all back at once.
    private func takeDown(_ live: [Pegged]) {
        let step = UUID()
        for (n, item) in live.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06 * Double(n)) { [weak self] in
                self?.discard(item.id, quietly: n > 0, step: step)
            }
        }
    }

    /// Photos whose file was deleted or moved away fall off by themselves.
    func prune() {
        for item in items where !item.falling && !FileManager.default.fileExists(atPath: item.url.path) {
            drop(item.id, quietly: true)
        }
    }

    // MARK: Actions on one photo

    func copy(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        putOnClipboard(item.url)

        copiedID = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            if self?.copiedID == id { self?.copiedID = nil }
        }
    }

    /// The file last put on the clipboard, and the clipboard's change count
    /// right after. While the count is the same, nothing else has been copied.
    private var onClipboard: (url: URL, change: Int)?

    private func putOnClipboard(_ url: URL) {
        let entry = NSPasteboardItem()
        // A recording is copied as the file, which apps paste as the video.
        if !isRecording(url), let png = pngData(url) { entry.setData(png, forType: .png) }
        entry.setString(url.absoluteString, forType: .fileURL)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([entry])
        onClipboard = (url, pb.changeCount)
    }

    /// Apps like Finder or a chat window paste the copied file rather than the
    /// picture. When the file moves after a copy, to the Trash or the Desktop,
    /// the clipboard follows it, or those apps would find nothing to paste.
    private func clipboardFollows(_ url: URL, to moved: URL) {
        guard let onClipboard, onClipboard.url == url,
              onClipboard.change == NSPasteboard.general.changeCount else { return }
        putOnClipboard(moved)
    }

    func open(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        NSWorkspace.shared.open(item.url)
    }

    /// Moves the file to the Trash and takes the photo off the line. When a
    /// drag ends on the Dock's Trash, macOS only reports it: deleting the file
    /// is the source app's job, as Finder does.
    ///
    /// `step` is what Put back brings it back with. Nil when the line lets
    /// a photo go by itself, which is not undone.
    @discardableResult
    func trash(_ id: UUID, quietly: Bool = false, step: UUID? = UUID()) -> Bool {
        guard let item = items.first(where: { $0.id == id }) else { return false }
        let index = liveIndex(of: id)
        do {
            var trashed: NSURL?
            try FileManager.default.trashItem(at: item.url, resultingItemURL: &trashed)
            if let trashed { clipboardFollows(item.url, to: trashed as URL) }
            log.notice("Trashed \(item.url.lastPathComponent, privacy: .public)")
            if soundOn && !quietly { Line.trashSound?.play() }
            drop(id, quietly: true)
            if let step, let index {
                remember(TakenDown(url: item.url, index: index, trashed: trashed as URL?, kept: item.kept, byHand: item.byHand, side: item.side), in: step)
            }
            return true
        } catch {
            log.error("Could not trash \(item.url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            if !quietly { NSSound.beep() }
            return false
        }
    }

    private static let trashSound = NSSound(
        contentsOfFile: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/dock/drag to trash.aif",
        byReference: true)

    /// Whether the file lives in Perch's own folder. Those are discarded
    /// to the Trash, or the folder would fill up with forgotten screenshots.
    /// Files anywhere else, like the Desktop, stay where they are.
    func isInInbox(_ id: UUID) -> Bool {
        guard let item = items.first(where: { $0.id == id }) else { return false }
        return item.url.standardizedFileURL.path.hasPrefix(Inbox.folder.standardizedFileURL.path + "/")
    }

    /// What the button in a photo's corner does.
    enum Corner {
        /// A file in Perch's folder: to the Trash.
        case trash
        /// A file anywhere else, or hung by hand: off the line, file untouched.
        case hide
        /// Pinned from the photos that come and go: back among them.
        case unpin
    }

    func corner(of id: UUID) -> Corner {
        guard let item = items.first(where: { $0.id == id }) else { return .hide }
        if item.kept { return item.byHand ? .hide : .unpin }
        return isInInbox(id) ? .trash : .hide
    }

    /// The button in the corner.
    func pressCorner(_ id: UUID) {
        if corner(of: id) == .unpin { unpin(id) } else { discard(id) }
    }

    /// The corner cross and "Take down" both end up here. A pinned photo is
    /// never sent to the Trash: it only leaves the line.
    func discard(_ id: UUID, quietly: Bool = false, step: UUID = UUID()) {
        if isInInbox(id), items.first(where: { $0.id == id })?.kept == false {
            trash(id, quietly: quietly, step: step)
        } else if let item = items.first(where: { $0.id == id && !$0.falling }), let index = liveIndex(of: id) {
            drop(id, quietly: quietly)
            remember(TakenDown(url: item.url, index: index, trashed: nil, kept: item.kept, byHand: item.byHand, side: item.side), in: step)
        }
    }

    /// Moves along a line that holds more than fit, from a scroll gesture.
    func scroll(by delta: CGFloat, on side: LineSide) {
        let most = CGFloat(max(0, items(on: side).count - visible(on: side))) * Layout.spacing
        let next = min(most, max(0, scroll(on: side) + delta))
        if next != scroll(on: side) { scroll[side] = next }
    }

    /// After Keep on line is lowered, the oldest photos past it go the way
    /// of a full line.
    func trim() {
        for side in LineSide.allCases { letGoOverflow(on: side) }
        scroll = [:]
    }

    /// The oldest photo falling off a full line. It only leaves the line: the
    /// file stays in its folder, with the rest, to clear out when you like.
    /// Discarding it is what the cross is for.
    private func letGo(_ id: UUID) {
        drop(id, quietly: true)
    }

    /// Inbox mode: keep a screenshot by moving it to the Desktop.
    func saveToDesktop(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        let target = uniqueURL(in: desktop, for: item.url.lastPathComponent)
        do {
            try FileManager.default.moveItem(at: item.url, to: target)
            clipboardFollows(item.url, to: target)
            drop(id, quietly: true)
        } catch {
            log.error("Could not save to Desktop: \(error.localizedDescription, privacy: .public)")
            NSSound.beep()
        }
    }

    private func uniqueURL(in folder: URL, for name: String) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
            n += 1
        }
        return candidate
    }

    /// Long press: open the photo in the system Markup editor. Markup does
    /// not edit video, so a recording opens in the trimming editor instead.
    func markup(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        if item.isRecording {
            Trim.shared.edit(item.url, size: item.thumb.size)
        } else {
            Markup.shared.edit(item.url)
        }
    }

    /// After editing, the photo on the line shows the new version.
    func reloadThumbnail(for url: URL) {
        guard let i = items.firstIndex(where: { $0.url == url && !$0.falling }),
              let thumb = makeThumbnail(url) else { return }
        items[i].thumb = thumb
    }

    /// Quick Look on this photo, with the rest of the line a key press away.
    func quickLook(_ id: UUID) {
        guard let side = items.first(where: { $0.id == id })?.side else { return }
        let live = items.filter { !$0.falling && $0.side == side }
        guard let index = live.firstIndex(where: { $0.id == id }) else { return }
        QuickLook.shared.show(live.map(\.url), at: index)
    }

    /// After a change of size, every photo is redrawn sharp at the new one.
    func reloadThumbnails() {
        for i in items.indices where !items[i].falling {
            if let thumb = makeThumbnail(items[i].url) { items[i].thumb = thumb }
        }
    }

    func reveal(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    // MARK: Putting back

    /// A photo taken down by hand: its file, where it hung among the photos
    /// still on the line, and where the file went if it went to the Trash.
    private struct TakenDown {
        let url: URL
        let index: Int
        let trashed: URL?
        var kept = false
        var byHand = false
        var side: LineSide = .right
    }

    /// What was taken down, the latest last. A step holds everything one
    /// action took down. Only kept while the app runs.
    private var steps: [(id: UUID, photos: [TakenDown])] = []
    private static let maxSteps = 20

    var canPutBack: Bool { !steps.isEmpty }

    private func remember(_ photo: TakenDown, in step: UUID) {
        if let i = steps.lastIndex(where: { $0.id == step }) {
            steps[i].photos.append(photo)
        } else {
            steps.append((step, [photo]))
            if steps.count > Self.maxSteps { steps.removeFirst() }
        }
    }

    /// Put back, or ⌘Z over the line: what was taken down last hangs again
    /// where it was, and a file sent to the Trash comes back out of it.
    func putBack() {
        guard let step = steps.popLast() else { return }
        var back: Set<UUID> = []
        // The last one taken down goes back first, so each finds its place.
        for photo in step.photos.reversed() {
            guard let url = restore(photo), !items.contains(where: { $0.url == url && !$0.falling }),
                  let thumb = makeThumbnail(url) else { continue }
            var item = Pegged(url: url, thumb: thumb)
            item.kept = photo.kept
            item.byHand = photo.byHand
            item.side = photo.side
            let live = items.filter { !$0.falling && $0.side == photo.side }
            if let gap = items.firstIndex(where: { $0.falling && $0.url == photo.url }) {
                // Its empty place is still on the line: it hangs back there.
                items[gap] = item
            } else if photo.index < live.count, let i = items.firstIndex(where: { $0.id == live[photo.index].id }) {
                items.insert(item, at: i)
            } else if let after = items.lastIndex(where: { $0.side == photo.side }) {
                items.insert(item, at: after + 1)
            } else {
                items.append(item)
            }
            back.insert(item.id)
        }
        guard !back.isEmpty else {
            NSSound.beep()
            return
        }
        // As when something new hangs, a full line lets its oldest photo go,
        // never one that just came back.
        for side in LineSide.allCases { letGoOverflow(on: side, sparing: back) }
        keepKeptFirst()
        save()
        play("Tink", volume: 0.35)
    }

    /// The photo's file, where it was before. Nil when it is gone: the Trash
    /// was emptied, or the file was moved or deleted since.
    private func restore(_ photo: TakenDown) -> URL? {
        guard let trashed = photo.trashed else {
            return FileManager.default.fileExists(atPath: photo.url.path) ? photo.url : nil
        }
        let url = uniqueURL(in: photo.url.deletingLastPathComponent(), for: photo.url.lastPathComponent)
        do {
            try FileManager.default.moveItem(at: trashed, to: url)
            clipboardFollows(trashed, to: url)
            log.notice("Put back \(url.lastPathComponent, privacy: .public)")
            return url
        } catch {
            log.error("Could not put back \(trashed.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Where a photo hangs, counting only the photos still on its line.
    private func liveIndex(of id: UUID) -> Int? {
        guard let side = items.first(where: { $0.id == id })?.side else { return nil }
        return items.filter { !$0.falling && $0.side == side }.firstIndex { $0.id == id }
    }

    // MARK: Hanging by hand

    /// On each line, kept photos hang left of the knot, the rest after it,
    /// each in its own order.
    private func keepKeptFirst() {
        let pinned = { (p: Pegged) in p.kept && !p.falling }
        var ordered: [Pegged] = []
        for side in LineSide.allCases {
            let mine = items.filter { $0.side == side }
            ordered += mine.filter(pinned) + mine.filter { !pinned($0) }
        }
        if ordered.map(\.id) != items.map(\.id) { items = ordered }
    }

    /// Pin: the photo joins the kept ones at the left end of its line.
    func pin(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id && !$0.falling && !$0.kept }) else { return }
        items[i].kept = true
        keepKeptFirst()
        save()
        play("Tink", volume: 0.35)
    }

    /// Unpin: it hangs loose again, first past the kept ones, so it is the
    /// next to fall from a full line.
    func unpin(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id && !$0.falling && $0.kept && !$0.byHand }) else { return }
        var item = items.remove(at: i)
        item.kept = false
        let side = item.side
        let at = items.firstIndex { $0.side == side && !($0.kept && !$0.falling) }
            ?? (items.lastIndex { $0.side == side }.map { $0 + 1 } ?? items.count)
        items.insert(item, at: at)
        keepKeptFirst()
        save()
    }

    /// An image hung from another app, with Hang on Perch. Like a
    /// photo from a watched folder, the line only shows the file where it
    /// is: taking it down leaves the file alone. What you hang yourself is
    /// pinned.
    @discardableResult
    func hangKept(_ url: URL) -> Bool {
        // Already on the line: it is pinned where it is.
        if let hanging = items.first(where: { $0.url.standardizedFileURL == url.standardizedFileURL && !$0.falling }) {
            pin(hanging.id)
            return true
        }
        guard let id = hang(url, on: target),
              let i = items.firstIndex(where: { $0.id == id }) else { return false }
        items[i].kept = true
        items[i].byHand = true
        keepKeptFirst()
        save()
        return true
    }

    // MARK: Holding

    /// Off the line and into your hand, or back onto its clip.
    func setHeld(_ id: UUID, _ held: Bool) {
        guard let i = items.firstIndex(where: { $0.id == id && !$0.falling }) else { return }
        items[i].held = held
        if !held { items[i].flying = true }
    }

    // MARK: Breeze

    /// Every so often a little wind moves the line. It is the detail that
    /// makes it feel like an object and not a widget.
    private func scheduleGust() {
        DispatchQueue.main.asyncAfter(deadline: .now() + .random(in: 7...16)) { [weak self] in
            guard let self else { return }
            if !self.items.isEmpty && self.draggingID == nil { self.gust += 1 }
            self.scheduleGust()
        }
    }

    // MARK: Persistence

    private let keptKey = "kept"
    private let byHandKey = "byHand"
    private let leftKey = "peggedLeft"

    private func save() {
        let live = items.filter { !$0.falling }
        UserDefaults.standard.set(live.map(\.url.path), forKey: storeKey)
        UserDefaults.standard.set(live.filter(\.kept).map(\.url.path), forKey: keptKey)
        UserDefaults.standard.set(live.filter(\.byHand).map(\.url.path), forKey: byHandKey)
        UserDefaults.standard.set(live.filter { $0.side == .left }.map(\.url.path), forKey: leftKey)
    }

    /// Everything comes back as it was. This runs before the line knows its
    /// screen, so the capacity is still the default one: hanging through
    /// `hang` would let photos fall off a wide screen's line at every launch.
    private func restore() {
        let paths = UserDefaults.standard.stringArray(forKey: storeKey) ?? []
        let kept = Set(UserDefaults.standard.stringArray(forKey: keptKey) ?? [])
        let byHand = Set(UserDefaults.standard.stringArray(forKey: byHandKey) ?? [])
        let left = Set(UserDefaults.standard.stringArray(forKey: leftKey) ?? [])
        for path in paths where FileManager.default.fileExists(atPath: path) {
            let url = URL(fileURLWithPath: path)
            guard !items.contains(where: { $0.url == url }), let thumb = makeThumbnail(url) else { continue }
            var item = Pegged(url: url, thumb: thumb)
            item.byHand = byHand.contains(path)
            item.kept = kept.contains(path) || item.byHand
            item.side = left.contains(path) ? .left : .right
            items.append(item)
        }
        keepKeptFirst()
    }

    // MARK: Helpers

    private func play(_ name: String, volume: Float) {
        guard soundOn, let sound = NSSound(named: name)?.copy() as? NSSound else { return }
        sound.volume = volume
        sound.play()
    }

    private func pngData(_ url: URL) -> Data? {
        if url.pathExtension.lowercased() == "png" { return try? Data(contentsOf: url) }
        guard let tiff = NSImage(contentsOf: url)?.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

/// Screen recordings, as macOS saves them.
func isRecording(_ url: URL) -> Bool {
    ["mov", "mp4"].contains(url.pathExtension.lowercased())
}

/// The default size covers a card at twice its size in points, as on a
/// Retina screen, and no more: every photo on the line keeps one in memory.
func makeThumbnail(_ url: URL, maxPixels: Int = Int(320 * Layout.size.scale)) -> NSImage? {
    if isRecording(url) { return firstFrame(url, maxPixels: maxPixels) }
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixels,
    ]
    guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
    return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
}

/// A recording shows its first frame.
private func firstFrame(_ url: URL, maxPixels: Int) -> NSImage? {
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: maxPixels, height: maxPixels)
    guard let cg = try? generator.copyCGImage(at: .zero, actualTime: nil) else { return nil }
    return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
}
