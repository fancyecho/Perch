import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// Something to send by AirDrop: files, a link or an image, as read off a pasteboard.
struct ShareParcel {
    enum Kind: Equatable {
        case files, link, image
    }

    var kind: Kind
    /// What NSSharingService takes: file or web URLs, or an NSImage.
    var items: [Any]
    var fileURLs: [URL] = []

    var count: Int { kind == .files ? fileURLs.count : 1 }

    /// A few words for what it is: the file's name, "3 files", the link's site.
    var label: String {
        switch kind {
        case .files:
            fileURLs.count == 1 ? fileURLs[0].lastPathComponent : tr("\(fileURLs.count) 个文件", "\(fileURLs.count) files")
        case .link:
            (items.first as? URL)?.host(percentEncoded: false).map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? tr("链接", "Link")
        case .image:
            tr("一张图片", "An image")
        }
    }

    /// Up to three pictures of it, the first on top: file icons, the image itself, or a symbol.
    var icons: [NSImage] {
        switch kind {
        case .files:
            fileURLs.prefix(3).map { NSWorkspace.shared.icon(forFile: $0.path) }
        case .image:
            (items.first as? NSImage).map { [$0] } ?? []
        case .link:
            NSImage(systemSymbolName: "link", accessibilityDescription: nil).map { [$0] } ?? []
        }
    }

    /// What a pasteboard holds, in the order AirDrop handles best. A copied address that is only
    /// text counts as a link when asked (from the clipboard, not a drag of words).
    static func read(_ pasteboard: NSPasteboard, readingAddresses: Bool = false) -> ShareParcel? {
        let files = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !files.isEmpty {
            return ShareParcel(kind: .files, items: files, fileURLs: files)
        }
        let links = (pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []).filter { ["http", "https"].contains($0.scheme?.lowercased()) }
        if let link = links.first {
            return ShareParcel(kind: .link, items: [link])
        }
        if NSImage.canInit(with: pasteboard), let image = NSImage(pasteboard: pasteboard) {
            return ShareParcel(kind: .image, items: [image])
        }
        if readingAddresses, let text = pasteboard.string(forType: .string),
           let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
           ["http", "https"].contains(url.scheme?.lowercased()), url.host() != nil {
            return ShareParcel(kind: .link, items: [url])
        }
        return nil
    }

    /// What the clipboard holds, judged from its types (and, for plain text, whether macOS sees a
    /// web address in it), so nothing is read, and macOS asks nothing, until it's sent.
    static func peekClipboard() async -> Kind? {
        guard let types = NSPasteboard.general.types else { return nil }
        if types.contains(.fileURL) { return .files }
        if types.contains(.URL) { return .link }
        if types.contains(where: { [.tiff, .png, NSPasteboard.PasteboardType(UTType.jpeg.identifier), NSPasteboard.PasteboardType(UTType.heic.identifier)].contains($0) }) { return .image }
        guard types.contains(.string) else { return nil }
        let clipboard = NSPasteboard.general
        let patterns = (try? await clipboard.detectedPatterns(for: [\.probableWebURL])) ?? []
        return patterns.contains(\NSPasteboard.DetectedValues.probableWebURL) ? .link : nil
    }

    /// Kinds worth sensing in a drag on its way to the island.
    static let dragTypes: [NSPasteboard.PasteboardType] = [.fileURL, .URL, .tiff, .png]
}

/// Sends a parcel by AirDrop through the system's own sheet, which opens out of the notch.
final class AirDropSender: NSObject {
    enum Outcome: Equatable {
        case sent(count: Int), cancelled, failed
    }

    var onFinish: ((Outcome) -> Void)?
    /// Where on screen the sheet should grow from: the camera housing.
    var sourceFrame: () -> NSRect = { .zero }

    private var service: NSSharingService?
    private var count = 0
    private var transitionImage: NSImage?

    func canSend(_ parcel: ShareParcel) -> Bool {
        NSSharingService(named: .sendViaAirDrop)?.canPerform(withItems: parcel.items) ?? false
    }

    /// Opens AirDrop's device picker for the parcel; false if AirDrop can't take it (or is off).
    @discardableResult
    func send(_ parcel: ShareParcel) -> Bool {
        guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: parcel.items) else { return false }
        self.service = service
        count = parcel.count
        transitionImage = parcel.icons.first
        service.delegate = self
        // Perch has no Dock icon; without this the sheet can open behind the frontmost app.
        NSApp.activate()
        service.perform(withItems: parcel.items)
        return true
    }

    private func finish(_ outcome: Outcome) {
        service = nil
        transitionImage = nil
        onFinish?(outcome)
    }
}

extension AirDropSender: NSSharingServiceDelegate {
    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        finish(.sent(count: count))
    }

    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: any Error) {
        let error = error as NSError
        finish(error.domain == NSCocoaErrorDomain && error.code == NSUserCancelledError ? .cancelled : .failed)
    }

    func sharingService(_ sharingService: NSSharingService, sourceFrameOnScreenForShareItem item: Any) -> NSRect {
        sourceFrame()
    }

    func sharingService(_ sharingService: NSSharingService, transitionImageForShareItem item: Any,
                        contentRect: UnsafeMutablePointer<NSRect>) -> NSImage? {
        transitionImage
    }

    /// Its own window, never a sheet on the island's.
    func sharingService(_ sharingService: NSSharingService, sourceWindowForShareItems items: [Any],
                        sharingContentScope: UnsafeMutablePointer<NSSharingService.SharingContentScope>) -> NSWindow? {
        nil
    }
}

/// Notices content being dragged anywhere on screen (from another app or one of Perch's own
/// windows, such as a photo off the screenshot line) and reports where it is while the button is
/// held.
///
/// A drag session swallows the usual mouse events, so this doesn't rely on them: a press starts a
/// light poll that waits for the drag pasteboard to change (a drag has begun, carrying something)
/// and follows the pointer until the button comes up.
final class DragWatcher {
    var onMove: ((NSPoint) -> Void)?
    var onEnd: (() -> Void)?

    private let pasteboard = NSPasteboard(name: .drag)
    private var monitors: [Any] = []
    private var pollTask: Task<Void, Never>?
    private(set) var isCarrying = false

    func start() {
        guard monitors.isEmpty else { return }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.pressed() }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.pressed() }
            return event
        }) {
            monitors.append(local)
        }
    }

    func stop() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
        pollTask?.cancel()
        pollTask = nil
        if isCarrying {
            isCarrying = false
            onEnd?()
        }
    }

    private func pressed() {
        let start = pasteboard.changeCount
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled, NSEvent.pressedMouseButtons & 1 != 0 {
                guard let self else { return }
                if !self.isCarrying, self.pasteboard.changeCount != start,
                   self.pasteboard.types?.contains(where: ShareParcel.dragTypes.contains) == true {
                    self.isCarrying = true
                }
                if self.isCarrying { self.onMove?(NSEvent.mouseLocation) }
                try? await Task.sleep(for: .milliseconds(self.isCarrying ? 16 : 60))
            }
            guard let self, !Task.isCancelled, self.isCarrying else { return }
            self.isCarrying = false
            self.onEnd?()
        }
    }

    /// The parcel being dragged right now.
    func currentParcel() -> ShareParcel? {
        ShareParcel.read(pasteboard)
    }
}

/// Quick Look thumbnails for files, sharper than their Finder icons for photos and documents.
enum ParcelThumbnails {
    static func load(_ urls: [URL], size: CGFloat) async -> [NSImage] {
        var images: [NSImage] = []
        for url in urls.prefix(3) {
            let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: size, height: size),
                                                       scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .thumbnail)
            if let thumbnail = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
                images.append(thumbnail.nsImage)
            } else {
                images.append(NSWorkspace.shared.icon(forFile: url.path))
            }
        }
        return images
    }
}
