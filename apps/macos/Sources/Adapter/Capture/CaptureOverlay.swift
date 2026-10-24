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
    var message: (String, Bool) -> Void = { _, _ in }
    var sendToShelf: (URL) -> Void = { _ in }
    var openHistory: () -> Void = {}
    var openSettings: () -> Void = {}
    var runCommand: (String) -> Void = { _ in }
    var captureFolder: () -> URL = { CaptureSettings.defaultFolder }
    /// The shortcut a command is bound to, written as it is shown in a menu ("⌘⇧4"), or nil if it has none.
    var shortcutText: (String) -> String? = { _ in nil }
}

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
        return QuickAccessInfo.line(width: isRecording ? nil : image.width, height: isRecording ? nil : image.height, bytes: bytes, format: format, date: date)
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

    var canRestore: Bool { !closed.isEmpty }
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

    private func refreshIcon() {
        // Not while the automated tests run, so they never add icons to the real menu bar.
        guard !Self.underTest else { return }
        statusItem.update(mode: QuickAccessStore.settings.icon, active: recentActivity || canRestore, overlay: self)
    }

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
            if let file = card.file, FileManager.default.fileExists(atPath: file.path) { NSWorkspace.shared.activateFileViewerSelecting([file]); actions.message("Already saved as \(file.lastPathComponent)", false) }
            else if !card.isRecording, let url = actions.save(card.image, CaptureExtraSettings.format) { card.file = url; actions.message("Saved \(url.lastPathComponent)", false) }
            else { actions.message("It could not be saved.", true) }
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

    /// The saved file, or a temporary PNG written for a picture that was not saved.
    func fileForDrag(_ card: OverlayCard) -> URL? {
        if let file = card.file, FileManager.default.fileExists(atPath: file.path) { return file }
        guard !card.isRecording else { return nil }
        try? FileManager.default.createDirectory(at: tempFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
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
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("More")
                if CaptureUploadStore.shared.ready {
                    Button { upload() } label: { Image(systemName: "icloud.and.arrow.up").frame(width: 26, height: 22) }.buttonStyle(.plain).help("Upload to your bucket and copy the link")
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

    private func dragProvider() -> NSItemProvider { CaptureOverlay.shared.fileForDrag(card).flatMap { NSItemProvider(contentsOf: $0) } ?? NSItemProvider() }

    private func copy(_ text: String, _ done: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string); actions.message(done, false)
    }

    private func saveAs(_ format: CaptureFormat) {
        if let url = actions.save(card.image, format) { actions.message("Saved \(url.lastPathComponent)", false); NSWorkspace.shared.activateFileViewerSelecting([url]) } else { actions.message("It could not be saved.", true) }
    }

    /// Uploads first when a bucket is set up (the link must point somewhere), otherwise links to the file on this Mac.
    private func copyLink(_ format: @escaping (String) -> String) {
        if CaptureUploadStore.shared.ready { upload { copy(format($0), "Copied") } }
        else if let f = CaptureOverlay.shared.fileForDrag(card) { copy(format(CaptureLinks.fileURL(f.path)), "Copied (a link to the file on this Mac)") }
    }

    private func upload(then done: ((String) -> Void)? = nil) {
        guard let file = CaptureOverlay.shared.fileForDrag(card), let data = try? Data(contentsOf: file) else { return }
        let type = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        CaptureUploader.upload(data, fileName: file.lastPathComponent, contentType: type) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let uploaded):
                    if let done { done(uploaded.link) } else { copy(uploaded.link, "Uploaded. The link is on the clipboard") }
                    if CaptureUploadStore.shared.config.deleteLocalAfterUpload, card.file != nil { try? FileManager.default.trashItem(at: file, resultingItemURL: nil) }
                case .failure(let error): actions.message(error.localizedDescription, true)
                }
            }
        }
    }
}

/// The optional menu-bar icon for captures: bring back a closed card, open a recent capture, start a capture. It is one icon, not a
/// window, and it can stay hidden, always show, or appear only while there is something to bring back.
final class QuickAccessStatusItem: NSObject, NSMenuDelegate {
    private var item: NSStatusItem?
    private weak var overlay: CaptureOverlay?

    func update(mode: QuickAccessIcon, active: Bool, overlay: CaptureOverlay) {
        self.overlay = overlay
        let wanted = mode == .visible || (mode == .automatic && active)
        if wanted, item == nil {
            let created = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            created.button?.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Kriya captures")
            created.button?.image?.isTemplate = true
            created.button?.target = self
            created.button?.action = #selector(clicked)
            item = created
        } else if !wanted, let item {
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
        }
    }

    @objc private func clicked() {
        guard let overlay, let button = item?.button else { return }
        // Laid out the way people expect a capture tool's menu: pictures first, then recordings, then the text and special tools,
        // then what was captured, then the settings. Every command shows its shortcut on the right, and each has an icon.
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, _ symbol: String, _ command: String, to target: NSMenu) {
            let mi = target.addItem(withTitle: title, action: #selector(runCommand(_:)), keyEquivalent: "")
            mi.target = self; mi.representedObject = command
            mi.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            if let shortcut = overlay.actions.shortcutText(command) { mi.attributedTitle = Self.titled(title, shortcut: shortcut) }
        }
        add("Capture Area", "viewfinder", "capture.region", to: menu)
        add("Capture Previous Area", "arrow.counterclockwise", "capture.again", to: menu)
        add("Capture Window", "macwindow", "capture.window", to: menu)
        add("Capture Fullscreen", "display", "capture.screen", to: menu)
        add("Scrolling Capture", "arrow.up.and.down.text.horizontal", "capture.scroll", to: menu)
        add("Capture Menu", "filemenu.and.cursorarrow", "capture.menu", to: menu)
        menu.addItem(.separator())
        add("Record Screen", "record.circle", "capture.rec.screen", to: menu)
        add("Record Window", "macwindow.badge.plus", "capture.rec.window", to: menu)
        add("Record Area as Video", "rectangle.dashed.badge.record", "capture.record", to: menu)
        add("Record GIF", "photo.on.rectangle", "capture.gif", to: menu)
        add("Pause or Resume Recording", "pause.circle", "capture.rec.pause", to: menu)
        add("Stop Recording", "stop.circle", "capture.rec.stop", to: menu)
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
        // Shown by the menu bar itself, the way every other menu-bar icon's menu is: attached to the item, opened by a click on it, and
        // detached when it closes so the next click comes back here. Placing it by hand put it at the wrong spot on some displays.
        menu.delegate = self
        item?.menu = menu
        button.performClick(nil)
    }

    func menuDidClose(_ menu: NSMenu) {
        DispatchQueue.main.async { [weak self] in self?.item?.menu = nil }
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
