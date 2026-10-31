import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

/// What a quick access card can do. Set by the capture service.
struct CaptureOverlayActions {
    var edit: (CGImage) -> Void = { _ in }
    var copyText: (CGImage) -> Void = { _ in }
    var pin: (CGImage) -> Void = { _ in }
    var save: (CGImage, CaptureFormat) -> URL? = { _, _ in nil }
    /// Saves a picture in a folder of the person's choosing (a card's Save with another destination).
    var saveInFolder: (CGImage, CaptureFormat, URL) -> URL? = { _, _, _ in nil }
    var message: (String, Bool) -> Void = { _, _ in }
    var sendToShelf: (URL) -> Void = { _ in }
    var openHistory: () -> Void = {}
    var openSettings: () -> Void = {}
    var runCommand: (String) -> Void = { _ in }
    var captureFolder: () -> URL = { CaptureSettings.defaultFolder }
    /// The shortcut a command is bound to, written as it is shown in a menu ("⌘⇧4"), or nil if it has none.
    var shortcutText: (String) -> String? = { _ in nil }
    /// Which recorder is running now, if one is.
    var recordingKind: () -> OverlayRecordingKind = { .none }
    /// How long the recording running now has been going, in seconds, for the timer beside the icon.
    var recordingElapsed: () -> TimeInterval? = { nil }
    /// Saved areas to offer now, by name and command.
    var savedAreas: () -> [(name: String, command: String)] = { [] }
    /// Whether a menu capture was made before, so it can be taken again.
    var hasMenuCapture: () -> Bool = { false }
}

/// Who is recording: Kriya's own recorder (which can pause) or macOS's (which can only stop).
enum OverlayRecordingKind: Equatable { case none, kriya, macOS }

/// One capture shown as a card: its picture (a frame, for a recording), where it is saved, and what it is.
final class OverlayCard: ObservableObject, Identifiable {
    let id = UUID()
    let image: CGImage
    var file: URL?
    let isRecording: Bool
    let date: Date
    var onClose: () -> Void = {}
    var onHover: (Bool) -> Void = { _ in }

    init(image: CGImage, file: URL?, isRecording: Bool, date: Date = Date()) {
        self.image = image; self.file = file; self.isRecording = isRecording; self.date = date
    }

    var title: String { file?.lastPathComponent ?? (isRecording ? "Recording" : "Capture") }

    var infoLine: String {
        let bytes = file.flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }
        let format = file?.pathExtension ?? (isRecording ? "mov" : "png")
        // A recording's card says how long it is, which its first frame cannot.
        let length: Double? = isRecording ? file.map { AVURLAsset(url: $0).duration.seconds }.flatMap { $0.isFinite ? $0 : nil } : nil
        return QuickAccessInfo.line(width: isRecording ? nil : image.width, height: isRecording ? nil : image.height, bytes: bytes, format: format, date: date, seconds: length)
    }
}

/// A card's window. It can take the keyboard while the pointer is over it, so the letter keys work without Kriya coming to the front.
private final class CardPanel: NSPanel {
    var onKey: (NSEvent) -> Bool = { _ in false }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func keyDown(with event: NSEvent) { if !onKey(event) { super.keyDown(with: event) } }
}

/// The cards that appear after a capture. Where, how big, how long and for what is set in Settings › Capture. Several recent cards
/// stack; closed ones can be brought back.
final class CaptureOverlay {
    static let shared = CaptureOverlay()

    static let hideWhenSharingKey = "capture.hideWhenSharing"
    static var hideWhenSharing: Bool { UserDefaults.standard.object(forKey: hideWhenSharingKey) as? Bool ?? true }
    private static var underTest: Bool { ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil }

    var actions = CaptureOverlayActions()
    /// Whether a recording is running now, so a screenshot card can wait. Set by the capture service.
    var isRecording: () -> Bool = { false }

    private struct Shown { let card: OverlayCard; let panel: CardPanel; var work: DispatchWorkItem? }
    private var shown: [Shown] = []
    private(set) var closed: [OverlayCard] = []
    private var tempFolder: URL { FileManager.default.temporaryDirectory.appendingPathComponent("kriya-capture-drag", isDirectory: true) }
    private var lastActivity = Date.distantPast
    private let statusItem = QuickAccessStatusItem()

    /// Whether the cards on the screen are put away for now (they come back together, or when a new capture arrives).
    private(set) var cardsHidden = false
    /// How many cards are on the screen, hidden or not.
    var cardCount: Int { shown.count }

    var canRestore: Bool { !closed.isEmpty }

    /// Puts every card away, or brings them all back.
    func toggleHidden() {
        guard !shown.isEmpty else { return }
        setCardsHidden(!cardsHidden)
    }

    private func setCardsHidden(_ hidden: Bool) {
        cardsHidden = hidden
        for entry in shown {
            if hidden {
                NSAnimationContext.runAnimationGroup({ $0.duration = 0.16; entry.panel.animator().alphaValue = 0 }, completionHandler: { [weak self] in
                    if self?.cardsHidden == true { entry.panel.orderOut(nil) }
                })
            } else {
                entry.panel.alphaValue = 0
                entry.panel.orderFrontRegardless()
                NSAnimationContext.runAnimationGroup { $0.duration = 0.18; entry.panel.animator().alphaValue = 1 }
            }
        }
    }

    /// Saves every card that is not saved yet, and says how it went.
    func saveAll() {
        var saved = 0, already = 0, failed = 0
        for entry in shown {
            let card = entry.card
            // A recording is always saved already; a picture with a file that is still there needs nothing.
            if card.isRecording || card.file.map({ FileManager.default.fileExists(atPath: $0.path) }) == true { already += 1; continue }
            if let url = actions.save(card.image, CaptureExtraSettings.format) { card.file = url; saved += 1 } else { failed += 1 }
        }
        actions.message(CardBatch.summary(saved: saved, alreadySaved: already, failed: failed), failed > 0)
    }

    /// Uploads a file to the bucket and gives back the link, or why it failed. Nothing is put on the clipboard: what to do with the link is
    /// for the caller to say.
    func uploadReturningLink(_ file: URL, contentType: String? = nil) async -> UploadResult {
        guard let data = try? Data(contentsOf: file) else { return .failed("The file could not be read to upload it.") }
        let type = contentType ?? UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        return await withCheckedContinuation { continuation in
            CaptureUploader.upload(data, fileName: file.lastPathComponent, contentType: type) { result in
                switch result {
                case .success(let uploaded): continuation.resume(returning: .uploaded(link: uploaded.link))
                case .failure(let error): continuation.resume(returning: .failed(error.localizedDescription))
                }
            }
        }
    }

    /// Uploads a saved file to the bucket and puts the link on the clipboard.
    func uploadFile(_ file: URL) {
        guard let data = try? Data(contentsOf: file) else { actions.message("The picture could not be read to upload it.", true); return }
        let type = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        CaptureUploader.upload(data, fileName: file.lastPathComponent, contentType: type) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let uploaded):
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(uploaded.link, forType: .string)
                    self?.actions.message("Uploaded. The link is on the clipboard", false)
                    if CaptureUploadStore.shared.config.deleteLocalAfterUpload { try? FileManager.default.trashItem(at: file, resultingItemURL: nil) }
                case .failure(let error): self?.actions.message(error.localizedDescription, true)
                }
            }
        }
    }
    var recentActivity: Bool { !shown.isEmpty || Date().timeIntervalSince(lastActivity) < 300 }

    /// Shows a card for a capture, if the settings say this kind of capture gets one.
    func show(_ image: CGImage, file: URL?, isRecording recording: Bool = false) {
        let settings = QuickAccessStore.settings
        guard !Self.underTest, settings.shows(recording: recording) else { return }
        if !recording, settings.holdWhileRecording, isRecording() { return }
        let card = OverlayCard(image: image, file: file, isRecording: recording)
        DispatchQueue.main.async { [self] in
            lastActivity = Date()
            present(card, settings: settings)
            refreshIcon()
        }
    }

    private func present(_ card: OverlayCard, settings: QuickAccessSettings) {
        // A new card brings the others back, so it does not appear beside cards that are out of sight.
        if cardsHidden { setCardsHidden(false) }
        // The oldest card makes way when the stack is full.
        while shown.count >= settings.stackLimit { remove(shown[0].card, remember: true) }
        card.onClose = { [weak self, weak card] in if let card { self?.remove(card, remember: true) } }
        card.onHover = { [weak self, weak card] inside in if let card { self?.hover(card, inside: inside) } }
        let host = NSHostingView(rootView: CaptureOverlayView(card: card, actions: actions, settings: settings, tempFolder: tempFolder))
        let size = host.fittingSize
        host.frame.size = size
        let panel = CardPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true; panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        // Left out of screen sharing and other apps' screenshots and recordings, unless the person turned that off.
        panel.sharingType = Self.hideWhenSharing ? .none : .readOnly
        panel.contentView = host
        panel.onKey = { [weak self, weak card] event in
            guard let self, let card else { return false }
            let flags = event.modifierFlags.intersection([.command, .control, .option])
            guard let key = QuickAccessKey.action(characters: event.charactersIgnoringModifiers ?? "", keyCode: event.keyCode, hasCommandLikeModifier: !flags.isEmpty) else { return false }
            self.perform(key, on: card)
            return true
        }
        shown.append(Shown(card: card, panel: panel, work: nil))
        layout(newest: panel)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.18; panel.animator().alphaValue = 1 }
        scheduleClose(card, after: settings.autoCloseSeconds)
    }

    // MARK: Placing the cards

    private func targetScreen(_ settings: QuickAccessSettings) -> NSScreen? {
        switch settings.display {
        case .main: return NSScreen.main ?? NSScreen.screens.first
        case .pointer: return NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        }
    }

    private func layout(newest: CardPanel? = nil) {
        let settings = QuickAccessStore.settings
        guard let screen = targetScreen(settings)?.visibleFrame else { return }
        let pointer = NSEvent.mouseLocation
        // Newest nearest the edge: the first card sits at the corner, older ones step away from it.
        for (offset, entry) in shown.reversed().enumerated() {
            let origin = QuickAccessLayout.origin(position: settings.position, panel: entry.panel.frame.size, screen: screen, margin: CGFloat(settings.margin), pointer: pointer, stackIndex: offset)
            if entry.panel === newest { entry.panel.setFrameOrigin(origin) }
            else { NSAnimationContext.runAnimationGroup { $0.duration = 0.18; entry.panel.animator().setFrame(NSRect(origin: origin, size: entry.panel.frame.size), display: true) } }
        }
    }

    // MARK: Closing and bringing back

    private func scheduleClose(_ card: OverlayCard, after seconds: Int) {
        guard let i = shown.firstIndex(where: { $0.card.id == card.id }) else { return }
        shown[i].work?.cancel()
        guard seconds > 0 else { shown[i].work = nil; return }
        let work = DispatchWorkItem { [weak self, weak card] in if let card { self?.remove(card, remember: true) } }
        shown[i].work = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(seconds), execute: work)
    }

    private func hover(_ card: OverlayCard, inside: Bool) {
        guard let i = shown.firstIndex(where: { $0.card.id == card.id }) else { return }
        if inside {
            shown[i].work?.cancel()
            shown[i].panel.makeKey()
        } else {
            scheduleClose(card, after: max(QuickAccessStore.settings.autoCloseSeconds > 0 ? 3 : 0, 0))
        }
    }

    func remove(_ card: OverlayCard, remember: Bool) {
        guard let i = shown.firstIndex(where: { $0.card.id == card.id }) else { return }
        let entry = shown.remove(at: i)
        entry.work?.cancel()
        if remember { closed.append(card); if closed.count > 10 { closed.removeFirst(closed.count - 10) } }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.16; entry.panel.animator().alphaValue = 0 }, completionHandler: { entry.panel.orderOut(nil) })
        layout()
        refreshIcon()
    }

    func dismissAll() { for entry in shown { remove(entry.card, remember: true) } }

    /// Brings back the capture that was closed last.
    func restoreLast() {
        pruneHistory()
        guard let card = closed.popLast() else { actions.message("There is no closed capture to bring back.", false); return }
        present(card, settings: QuickAccessStore.settings)
        lastActivity = Date()
        refreshIcon()
    }

    /// Shows a card for a file already in the capture folder (from the menu bar's recent list).
    func showAgain(_ entry: CaptureHistory.Entry) {
        let url = URL(fileURLWithPath: entry.path)
        let image: CGImage? = entry.isMovie ? Self.thumbnail(forMovie: url) : (CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        guard let image else { actions.message("That file could not be opened.", true); return }
        present(OverlayCard(image: image, file: url, isRecording: entry.isMovie, date: entry.date), settings: QuickAccessStore.settings)
        lastActivity = Date()
        refreshIcon()
    }

    /// Forgets closed cards older than the history limit (the files themselves are not touched). Done by itself whenever the icon or
    /// the list of closed cards is looked at.
    func pruneHistory(now: Date = Date()) {
        let retention = CaptureExtraSettings.delivery.retention
        guard retention.captureHistoryDays > 0 else { return }
        closed.removeAll { !retention.keepsInHistory($0.date, now: now) }
    }

    private func refreshIcon() {
        pruneHistory()
        // Not while the automated tests run, so they never add icons to the real menu bar.
        guard !Self.underTest else { return }
        // While anything is recording the icon is there (even if it is set to appear only when needed) and turns red.
        let recording = actions.recordingKind() != .none
        statusItem.update(mode: QuickAccessStore.settings.icon, active: recentActivity || canRestore || recording, overlay: self)
    }

    /// A recording started or ended: the icon shows it.
    func recordingChanged() { refreshIcon() }

    /// Applies a changed setting at once: the icon, and where the cards are.
    func settingsChanged() { refreshIcon(); layout() }

    /// Takes the icon away (the capture feature was switched off).
    func removeIcon() {
        guard !Self.underTest else { return }
        statusItem.update(mode: .hidden, active: false, overlay: self)
    }

    /// The first frame of a recording, for its card.
    static func thumbnail(forMovie url: URL) -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 900, height: 900)
        return try? generator.copyCGImage(at: CMTime(seconds: 0.4, preferredTimescale: 600), actualTime: nil)
    }

    // MARK: What the keys and buttons do

    func perform(_ key: QuickAccessKey, on card: OverlayCard) {
        switch key {
        case .copy:
            if card.isRecording, let file = card.file { copyFile(file) } else if let data = card.image.pngData {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setData(data, forType: .png); actions.message("Copied the picture", false)
            }
        case .save:
            save(card)
        case .annotate:
            if card.isRecording, let file = card.file { NSWorkspace.shared.open(file) } else { actions.edit(card.image); remove(card, remember: false) }
        case .text:
            if !card.isRecording { actions.copyText(card.image) }
        case .pin:
            if !card.isRecording { actions.pin(card.image) }
        case .shelf:
            if let url = fileForDrag(card) { actions.sendToShelf(url); actions.message("Put on the shelf", false) }
        case .share:
            if let url = fileForDrag(card), let anchor = shown.first(where: { $0.card.id == card.id })?.panel.contentView {
                NSSharingServicePicker(items: [url]).show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
            }
        case .delete:
            if let file = card.file, FileManager.default.fileExists(atPath: file.path) {
                do { try FileManager.default.trashItem(at: file, resultingItemURL: nil); actions.message("Moved \(file.lastPathComponent) to the Trash", false) } catch { actions.message("It could not be moved to the Trash.", true); return }
            }
            remove(card, remember: false)
        case .history:
            actions.openHistory()
        case .dismiss:
            remove(card, remember: true)
        }
    }

    private func copyFile(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([url as NSURL])
        actions.message("Copied the file", false)
    }

    // MARK: What happens to a card after it is used
    //
    // Every way of dragging, uploading or saving (the buttons, the keys, the menu) comes through these, and the rules are in
    // `QuickAccessCard`, so a card behaves the same whichever way it is used.

    /// The card's picture was dragged out and accepted: the card goes away if the settings say so (⌥ held keeps it).
    func cardWasDragged(_ card: OverlayCard, optionHeld: Bool) {
        if QuickAccessCard.afterDrag(QuickAccessStore.settings, optionHeld: optionHeld) == .close { remove(card, remember: true) }
    }

    /// The card's picture was uploaded: the card goes away if the settings say so.
    func cardWasUploaded(_ card: OverlayCard) {
        if QuickAccessCard.afterUpload(QuickAccessStore.settings) == .close { remove(card, remember: true) }
    }

    /// Saves the card's picture where the settings say: the default destination, or the alternate one when ⌥ is held.
    func save(_ card: OverlayCard, format: CaptureFormat = CaptureExtraSettings.format, optionHeld: Bool = NSEvent.modifierFlags.contains(.option)) {
        let destination = QuickAccessCard.destination(QuickAccessStore.settings, optionHeld: optionHeld)
        let capture = actions.captureFolder()
        let place = destination.place(captureFolder: capture, home: FileManager.default.homeDirectoryForCurrentUser)
        // Saving to the capture folder is what it always was: a capture that is already there is shown, not saved again.
        if place == .folder(capture), let file = card.file, FileManager.default.fileExists(atPath: file.path) {
            NSWorkspace.shared.activateFileViewerSelecting([file])
            actions.message("Already saved as \(file.lastPathComponent)", false)
            return
        }
        switch place {
        case .folder(let folder): saveInto(card, format: format, folder: folder)
        case .ask: askWhereToSave(card, format: format, start: capture)
        }
    }

    private func saveInto(_ card: OverlayCard, format: CaptureFormat, folder: URL) {
        if card.isRecording {
            guard let file = card.file else { actions.message("It could not be saved.", true); return }
            copyRecording(file, into: folder)
        } else if let url = actions.saveInFolder(card.image, format, folder) {
            card.file = url
            actions.message("Saved \(url.lastPathComponent) in \(folder.lastPathComponent)", false)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            actions.message("It could not be saved in \(folder.lastPathComponent).", true)
        }
    }

    private func copyRecording(_ file: URL, into folder: URL) {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var target = folder.appendingPathComponent(file.lastPathComponent)
            var n = 2
            while FileManager.default.fileExists(atPath: target.path) {
                target = folder.appendingPathComponent(file.deletingPathExtension().lastPathComponent + " \(n)." + file.pathExtension)
                n += 1
            }
            try FileManager.default.copyItem(at: file, to: target)
            actions.message("Saved \(target.lastPathComponent) in \(folder.lastPathComponent)", false)
            NSWorkspace.shared.activateFileViewerSelecting([target])
        } catch {
            actions.message("It could not be saved in \(folder.lastPathComponent): \(error.localizedDescription)", true)
        }
    }

    private func askWhereToSave(_ card: OverlayCard, format: CaptureFormat, start: URL) {
        let panel = NSSavePanel()
        panel.directoryURL = start
        panel.nameFieldStringValue = card.isRecording ? (card.file?.lastPathComponent ?? "Recording.mov") : "Capture.\(format.fileExtension)"
        panel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if card.isRecording, let file = card.file {
            do { try? FileManager.default.removeItem(at: url); try FileManager.default.copyItem(at: file, to: url); actions.message("Saved \(url.lastPathComponent)", false) }
            catch { actions.message("It could not be saved: \(error.localizedDescription)", true) }
        } else if let data = card.image.data(as: format), (try? data.write(to: url, options: .atomic)) != nil {
            card.file = url
            actions.message("Saved \(url.lastPathComponent)", false)
        } else {
            actions.message("It could not be saved.", true)
        }
    }

    /// The saved file, or a temporary PNG written for a picture that was not saved.
    func fileForDrag(_ card: OverlayCard) -> URL? {
        if let file = card.file, FileManager.default.fileExists(atPath: file.path) { return file }
        guard !card.isRecording else { return nil }
        try? FileManager.default.createDirectory(at: tempFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Pictures written only so they can be dragged or shared do not stay behind: anything older than ten minutes is removed.
        let old = Date().addingTimeInterval(-600)
        for file in (try? FileManager.default.contentsOfDirectory(at: tempFolder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            if let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, modified < old { try? FileManager.default.removeItem(at: file) }
        }
        let url = tempFolder.appendingPathComponent("Capture \(Int(card.date.timeIntervalSince1970)).png")
        guard let data = card.image.pngData, (try? data.write(to: url)) != nil else { return nil }
        return url
    }
}

struct CaptureOverlayView: View {
    @ObservedObject var card: OverlayCard
    let actions: CaptureOverlayActions
    let settings: QuickAccessSettings
    let tempFolder: URL
    @State private var drag: CGFloat = 0

    private var thumb: NSImage { NSImage(cgImage: card.image, size: NSSize(width: card.image.width, height: card.image.height)) }
    private var thumbHeight: CGFloat { min(settings.size.thumbnailWidth * 0.62, 240) }

    var body: some View {
        VStack(spacing: 7) {
            ZStack(alignment: .topTrailing) {
                Image(nsImage: thumb).resizable().scaledToFit()
                    .frame(width: settings.size.thumbnailWidth, height: thumbHeight)
                    .background(Color.black.opacity(0.25))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(alignment: .center) { if card.isRecording { Image(systemName: "play.circle.fill").font(.system(size: 30)).foregroundStyle(.white.opacity(0.9)).shadow(radius: 4) } }
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.2)))
                    .onDrag { dragProvider() }
                    .help("Drag this into Finder, Mail, Slack or Messages")
                Button { card.onClose() } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 15)).foregroundStyle(.white, .black.opacity(0.55)) }
                    .buttonStyle(.plain).padding(5).accessibilityLabel("Close")
            }
            Text(card.infoLine).font(.system(size: 10)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
            HStack(spacing: 2) {
                ForEach(buttons, id: \.key) { b in
                    Button { CaptureOverlay.shared.perform(b.key, on: card) } label: { Image(systemName: b.symbol).frame(width: 26, height: 22) }
                        .buttonStyle(.plain).help("\(b.key.title) (\(b.key.key.uppercased()))").accessibilityLabel(b.key.title)
                }
                Menu {
                    Section("Copy as") {
                        Button("Markdown image link") { copyLink { CaptureLinks.markdown(url: $0) } }
                        Button("HTML image tag") { copyLink { CaptureLinks.html(url: $0) } }
                        if !card.isRecording { Button("Base64 data address") { if let d = card.image.pngData { copy(CaptureLinks.dataURI(d), "Copied as a data address") } } }
                        Button("File path") { if let f = CaptureOverlay.shared.fileForDrag(card) { copy(f.path, "Copied the path") } }
                    }
                    if !card.isRecording { Section("Save as") { ForEach(CaptureFormat.allCases) { f in Button(f.title) { saveAs(f) } } } }
                    Section("Captures") {
                        Button("Bring Back the Last Closed") { CaptureOverlay.shared.restoreLast() }.disabled(!CaptureOverlay.shared.canRestore)
                        Button("Close All") { CaptureOverlay.shared.dismissAll() }
                        Button("Quick Access Settings…") { actions.openSettings() }
                    }
                } label: { Image(systemName: "ellipsis.circle").frame(width: 26, height: 22) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("More").accessibilityLabel("More")
                if CaptureUploadStore.shared.ready {
                    Button { upload() } label: { Image(systemName: "icloud.and.arrow.up").frame(width: 26, height: 22) }.buttonStyle(.plain).help("Upload to your bucket and copy the link").accessibilityLabel("Upload to your bucket")
                }
            }
            .foregroundStyle(.white)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.ultraThinMaterial))
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.black.opacity(0.55)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.16)))
        .padding(8)
        .environment(\.colorScheme, .dark)
        .offset(x: drag).opacity(1 - min(abs(drag) / 220, 0.7))
        // A swipe sideways sends the card away.
        .gesture(DragGesture(minimumDistance: 14).onChanged { drag = $0.translation.width }.onEnded { value in
            if abs(value.translation.width) > 70 { withAnimation(.easeOut(duration: 0.15)) { drag = value.translation.width * 3 }; DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { card.onClose() } }
            else { withAnimation(.smooth(duration: 0.18)) { drag = 0 } }
        })
        .onHover { card.onHover($0) }
    }

    private var buttons: [(key: QuickAccessKey, symbol: String)] {
        var list: [(QuickAccessKey, String)] = [(.copy, "doc.on.doc"), (.save, "square.and.arrow.down")]
        if !card.isRecording { list += [(.annotate, "pencil.and.outline"), (.text, "text.viewfinder"), (.pin, "pin")] } else { list += [(.annotate, "play.rectangle")] }
        list += [(.shelf, "tray.and.arrow.down"), (.share, "square.and.arrow.up"), (.delete, "trash"), (.history, "clock.arrow.circlepath")]
        return list.map { (key: $0.0, symbol: $0.1) }
    }

    /// What is dragged out of the card. The card is told when the picture is actually taken by what it was dropped on, so "close after
    /// dragging" waits for a drop and never closes a card whose drag was cancelled.
    private func dragProvider() -> NSItemProvider {
        guard let url = CaptureOverlay.shared.fileForDrag(card), let provider = NSItemProvider(contentsOf: url) else { return NSItemProvider() }
        let type = UTType(filenameExtension: url.pathExtension)?.identifier ?? UTType.data.identifier
        provider.registerFileRepresentation(forTypeIdentifier: type, fileOptions: [.openInPlace], visibility: .all) { completion in
            completion(url, true, nil)
            // Read at the moment of the drop: ⌥ held then keeps the card open.
            let option = NSEvent.modifierFlags.contains(.option)
            DispatchQueue.main.async { CaptureOverlay.shared.cardWasDragged(card, optionHeld: option) }
            return nil
        }
        return provider
    }

    private func copy(_ text: String, _ done: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string); actions.message(done, false)
    }

    private func saveAs(_ format: CaptureFormat) { CaptureOverlay.shared.save(card, format: format) }

    /// Uploads first when a bucket is set up (the link must point somewhere), otherwise links to the file on this Mac.
    private func copyLink(_ format: @escaping (String) -> String) {
        if CaptureUploadStore.shared.ready { upload { copy(format($0), "Copied") } }
        else if let f = CaptureOverlay.shared.fileForDrag(card) { copy(format(CaptureLinks.fileURL(f.path)), "Copied (a link to the file on this Mac)") }
    }

    private func upload(then done: ((String) -> Void)? = nil) {
        guard let file = CaptureOverlay.shared.fileForDrag(card), let data = try? Data(contentsOf: file) else { actions.message("The picture could not be read to upload it.", true); return }
        let type = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        CaptureUploader.upload(data, fileName: file.lastPathComponent, contentType: type) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let uploaded):
                    if let done { done(uploaded.link) } else { copy(uploaded.link, "Uploaded. The link is on the clipboard") }
                    if CaptureUploadStore.shared.config.deleteLocalAfterUpload, card.file != nil { try? FileManager.default.trashItem(at: file, resultingItemURL: nil) }
                    // Whether the card goes away is decided in one place, not here.
                    CaptureOverlay.shared.cardWasUploaded(card)
                case .failure(let error): actions.message(error.localizedDescription, true)
                }
            }
        }
    }
}

/// The optional menu-bar icon for captures: bring back a closed card, open a recent capture, start a capture. It is one icon, not a
/// window, and it can stay hidden, always show, or appear only while there is something to bring back.
final class QuickAccessStatusItem: NSObject {
    private var item: NSStatusItem?
    private weak var overlay: CaptureOverlay?

    func update(mode: QuickAccessIcon, active: Bool, overlay: CaptureOverlay) {
        self.overlay = overlay
        let recording = overlay.actions.recordingKind() != .none
        let wanted = mode == .visible || (mode == .automatic && active) || (mode == .whileRecording && recording)
        if wanted, item == nil {
            let created = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            created.button?.target = self
            created.button?.action = #selector(clicked)
            // Right-click and Control-click open the full menu; without this only a left click reached the icon.
            created.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
            item = created
        } else if !wanted, let item {
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
        }
        // The icon turns red and filled while something is recording, so it can be seen from across the menu bar, and a running
        // time sits beside it.
        guard let button = item?.button else { return }
        if recording {
            let image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Recording")
            button.image = image?.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.systemRed]))
            button.image?.isTemplate = false
            refreshTimer()
            if ticker == nil {
                let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.refreshTimer() }
                RunLoop.main.add(t, forMode: .common)
                ticker = t
            }
        } else {
            ticker?.invalidate(); ticker = nil
            button.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Kriya captures")
            button.image?.isTemplate = true
            button.title = ""
            button.imagePosition = .imageOnly
            item?.length = NSStatusItem.squareLength
        }
    }

    private var ticker: Timer?

    /// "● 01:23" beside the icon while recording (if that is on), and nothing otherwise.
    private func refreshTimer() {
        guard let button = item?.button, let overlay else { return }
        guard CaptureExtraSettings.modes.showRecordingTimer, let seconds = overlay.actions.recordingElapsed() else {
            button.title = ""
            button.imagePosition = .imageOnly
            item?.length = NSStatusItem.squareLength
            return
        }
        button.attributedTitle = NSAttributedString(string: " " + RecordingTime.text(seconds), attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)])
        button.imagePosition = .imageLeading
        item?.length = NSStatusItem.variableLength
    }

    private let popover = NSPopover()

    @objc private func clicked() {
        guard let overlay, let button = item?.button else { return }
        // A plain click opens the launcher; a right-click or Control-click opens the full menu.
        if (StatusClick.current ?? .secondary) == .primary {
            if popover.isShown { popover.performClose(nil); return }
            showLauncher(from: button, overlay: overlay)
            return
        }
        popover.performClose(nil)
        showMenu(from: button, overlay: overlay)
    }

    private func showLauncher(from button: NSStatusBarButton, overlay: CaptureOverlay) {
        let view = CaptureLauncherView(
            actions: overlay.actions, recents: CaptureHistory.read(folder: overlay.actions.captureFolder(), limit: 6), canRestore: overlay.canRestore,
            run: { [weak self] command in self?.popover.performClose(nil); overlay.actions.runCommand(command) },
            showRecent: { [weak self] entry in self?.popover.performClose(nil); overlay.showAgain(entry) },
            restore: { [weak self] in self?.popover.performClose(nil); overlay.restoreLast() })
        popover.behavior = .transient
        // The window is as tall as its content, so nothing is cut off at the bottom.
        let host = NSHostingController(rootView: view)
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func showMenu(from button: NSStatusBarButton, overlay: CaptureOverlay) {
        // Laid out the way people expect a capture tool's menu: pictures first, then recordings, then the text and special tools,
        // then what was captured, then the settings. Every command shows its shortcut on the right, and each has an icon.
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, _ symbol: String, _ command: String, to target: NSMenu, enabled: Bool = true) {
            let mi = target.addItem(withTitle: title, action: #selector(runCommand(_:)), keyEquivalent: "")
            mi.target = self; mi.representedObject = command
            mi.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            mi.isEnabled = enabled
            if let shortcut = overlay.actions.shortcutText(command) { mi.attributedTitle = Self.titled(title, shortcut: shortcut) }
        }
        // While a recording runs its controls come first, and say whose recording it is: Kriya's can pause, macOS's can only stop.
        let kind = overlay.actions.recordingKind()
        if kind != .none {
            let header = menu.addItem(withTitle: kind == .kriya ? "Recording with Kriya" : "Recording with macOS's recorder", action: nil, keyEquivalent: "")
            header.isEnabled = false
            header.image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: nil)?.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.systemRed]))
            add("Stop Recording", "stop.circle", "capture.rec.stop", to: menu)
            add(kind == .kriya ? "Pause or Resume Recording" : "Pause (macOS's recorder cannot pause)", "pause.circle", "capture.rec.pause", to: menu, enabled: kind == .kriya)
            menu.addItem(.separator())
        }
        add("All-in-One…", "square.grid.3x3", "capture.all", to: menu)
        menu.addItem(.separator())
        add("Capture Area", "viewfinder", "capture.region", to: menu)
        add("Capture Previous Area", "arrow.counterclockwise", "capture.again", to: menu)
        add("Capture Window", "macwindow", "capture.window", to: menu)
        add("Capture Fullscreen", "display", "capture.screen", to: menu)
        add("Scrolling Capture", "arrow.up.and.down.text.horizontal", "capture.scroll", to: menu)
        add(overlay.actions.hasMenuCapture() ? "Recapture Menu" : "Capture Menu", "filemenu.and.cursorarrow", "capture.menu", to: menu)
        let saved = overlay.actions.savedAreas()
        if !saved.isEmpty {
            let parent = NSMenuItem(title: "Saved Areas", action: nil, keyEquivalent: "")
            parent.image = NSImage(systemSymbolName: "rectangle.dashed", accessibilityDescription: nil)
            let sub = NSMenu()
            for area in saved { add(area.name, "viewfinder", area.command, to: sub) }
            parent.submenu = sub
            menu.addItem(parent)
        }
        menu.addItem(.separator())
        add("Record Screen", "record.circle", "capture.rec.screen", to: menu, enabled: kind == .none)
        add("Record Window", "macwindow.badge.plus", "capture.rec.window", to: menu, enabled: kind == .none)
        add("Record Area (macOS recorder)", "rectangle.dashed.badge.record", "capture.record", to: menu, enabled: kind == .none)
        add("Record GIF (macOS recorder)", "photo.on.rectangle", "capture.gif", to: menu, enabled: kind == .none)
        menu.addItem(.separator())
        let text = NSMenuItem(title: "Capture Text (OCR)", action: nil, keyEquivalent: "")
        text.image = NSImage(systemSymbolName: "text.viewfinder", accessibilityDescription: nil)
        let textMenu = NSMenu()
        add("Copy Text", "text.alignleft", "capture.text", to: textMenu)
        add("Copy Text as One Paragraph", "paragraphsign", "capture.text.joined", to: textMenu)
        add("Copy Text as Markdown", "number", "capture.text.markdown", to: textMenu)
        add("Copy Table as CSV", "tablecells", "capture.table", to: textMenu)
        add("Read QR Code", "qrcode.viewfinder", "capture.qr", to: textMenu)
        text.submenu = textMenu
        menu.addItem(text)
        let tools = NSMenuItem(title: "More Tools", action: nil, keyEquivalent: "")
        tools.image = NSImage(systemSymbolName: "wand.and.stars", accessibilityDescription: nil)
        let toolsMenu = NSMenu()
        add("Capture and Hide Private Text", "eye.slash", "capture.redacted", to: toolsMenu)
        add("Cut Out the Subject", "person.crop.rectangle", "capture.cutout", to: toolsMenu)
        add("Pin to Screen", "pin", "capture.pin", to: toolsMenu)
        add("Float a Live Window", "pip", "capture.mirror", to: toolsMenu)
        add("Pixel Ruler", "ruler", "capture.ruler", to: toolsMenu)
        add("Trim a Recording", "scissors", "capture.trim", to: toolsMenu)
        tools.submenu = toolsMenu
        menu.addItem(tools)
        menu.addItem(.separator())
        let history = menu.addItem(withTitle: "Open Capture History", action: #selector(openHistory), keyEquivalent: "")
        history.target = self
        history.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: nil)
        let recents = CaptureHistory.read(folder: overlay.actions.captureFolder(), limit: 8)
        let parent = NSMenuItem(title: "Recent Captures", action: nil, keyEquivalent: "")
        parent.image = NSImage(systemSymbolName: "photo.stack", accessibilityDescription: nil)
        if recents.isEmpty {
            parent.isEnabled = false
        } else {
            let sub = NSMenu()
            for entry in recents {
                let mi = NSMenuItem(title: "\(entry.name)", action: #selector(showEntry(_:)), keyEquivalent: "")
                mi.target = self
                mi.representedObject = entry.path
                mi.image = NSImage(systemSymbolName: entry.isMovie ? "video" : "photo", accessibilityDescription: nil)
                sub.addItem(mi)
            }
            parent.submenu = sub
        }
        menu.addItem(parent)
        let restore = menu.addItem(withTitle: "Restore Recently Closed Capture", action: #selector(restore), keyEquivalent: "")
        restore.target = self
        restore.image = NSImage(systemSymbolName: "arrow.uturn.backward.circle", accessibilityDescription: nil)
        restore.isEnabled = overlay.canRestore
        menu.addItem(.separator())
        let folder = menu.addItem(withTitle: "Open Capture Folder", action: #selector(openFolder), keyEquivalent: "")
        folder.target = self
        folder.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        let settings = menu.addItem(withTitle: "Capture Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        settings.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        // Opened directly under the icon, placed from the icon's window on screen, so it lands in the same place on every display.
        StatusMenu.popUp(menu, from: button)
    }

    /// A menu title with its shortcut set apart on the right in a lighter colour, after a tab.
    private static func titled(_ title: String, shortcut: String) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [NSTextTab(textAlignment: .right, location: 250)]
        let text = NSMutableAttributedString(string: "\(title)\t\(shortcut)", attributes: [.font: NSFont.menuFont(ofSize: 0), .paragraphStyle: paragraph])
        text.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: NSRange(location: title.count + 1, length: shortcut.count))
        return text
    }

    @objc private func openHistory() { overlay?.actions.openHistory() }

    @objc private func restore() { overlay?.restoreLast() }
    @objc private func showEntry(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String, let entry = CaptureHistory.read(folder: overlay?.actions.captureFolder() ?? CaptureSettings.defaultFolder, limit: 50).first(where: { $0.path == path }) else { return }
        overlay?.showAgain(entry)
    }
    @objc private func runCommand(_ sender: NSMenuItem) { if let c = sender.representedObject as? String { overlay?.actions.runCommand(c) } }
    @objc private func openFolder() { if let folder = overlay?.actions.captureFolder() { NSWorkspace.shared.open(folder) } }
    @objc private func openSettings() { overlay?.actions.openSettings() }
}
