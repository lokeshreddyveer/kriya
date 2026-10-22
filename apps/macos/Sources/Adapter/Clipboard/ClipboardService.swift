import AppKit
import Combine

/// Watches the system clipboard and records what is copied, under the person's rules. It polls the clipboard's change
/// counter, which costs almost nothing, and reads the content only when it changed.
final class ClipboardMonitor {
    private let store: ClipboardStore
    private let queue = DispatchQueue(label: "app.kriya.clipboard", qos: .utility)
    private var timer: Timer?
    private var lastChange = NSPasteboard.general.changeCount
    private var ignored: Set<Int> = []

    var onRecorded: () -> Void = {}

    init(store: ClipboardStore) {
        self.store = store
    }

    func start() {
        guard timer == nil else { return }
        lastChange = NSPasteboard.general.changeCount
        let timer = Timer(timeInterval: 0.35, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Kriya's own writes (pasting an item) must not be recorded again.
    func ignore(changeCount: Int) {
        ignored.insert(changeCount)
        if ignored.count > 20 { ignored = ignored.filter { $0 >= changeCount - 5 } }
    }

    private func tick() {
        let board = NSPasteboard.general
        let count = board.changeCount
        guard count != lastChange else { return }
        lastChange = count
        if ignored.remove(count) != nil { return }

        let config = store.currentConfig
        let source = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let types = (board.types ?? []).map(\.rawValue)
        let concealed = !Set(types).isDisjoint(with: clipConcealedTypes())
        // Decide from what is known before reading any content, so a skipped copy is never even read.
        if let reason = clipEarlySkip(config: config, sourceApp: source, concealed: concealed) {
            DispatchQueue.main.async { [store] in store.noteSkipped(reason) }
            return
        }
        guard let clip = Self.read(board, source: source, config: config) else { return }
        queue.async { [store, onRecorded] in
            if store.record(clip) != nil { DispatchQueue.main.async { store.refreshStats(); onRecorded() } }
        }
    }

    /// What is on the clipboard now, as a `NewClip`. Files win over text, text over an image.
    static func read(_ board: NSPasteboard, source: String?, config: ClipConfig) -> NewClip? {
        var clip = NewClip(text: nil, rich: nil, richFormat: nil, image: nil, imageFormat: nil, imageWidth: nil, imageHeight: nil, files: [], sourceApp: source, concealed: false)
        if config.captureFiles, let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            clip.files = urls.map(\.path)
            return clip
        }
        if let text = board.string(forType: .string), !text.isEmpty {
            clip.text = text
            if config.captureRichText {
                if let rtf = board.data(forType: .rtf) { clip.rich = rtf; clip.richFormat = "rtf" }
                else if let html = board.data(forType: .html) { clip.rich = html; clip.richFormat = "html" }
            }
            return clip
        }
        if config.captureImages {
            let limit = Int(config.maxItemMb) * 1024 * 1024
            if let png = board.data(forType: .png), png.count <= limit {
                clip.image = png
                clip.imageFormat = "png"
                if let rep = NSBitmapImageRep(data: png) { clip.imageWidth = UInt32(rep.pixelsWide); clip.imageHeight = UInt32(rep.pixelsHigh) }
                return clip
            }
            if let tiff = board.data(forType: .tiff), tiff.count <= limit * 4, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                clip.image = png
                clip.imageFormat = "png"
                clip.imageWidth = UInt32(rep.pixelsWide)
                clip.imageHeight = UInt32(rep.pixelsHigh)
                return clip
            }
        }
        return nil
    }
}

/// Puts items back on the clipboard and pastes them into the app in front.
final class ClipboardPaster {
    private let store: ClipboardStore
    private let monitor: ClipboardMonitor
    private let toast = Toast()

    init(store: ClipboardStore, monitor: ClipboardMonitor) {
        self.store = store
        self.monitor = monitor
    }

    /// Writes an item to the clipboard. With `plain`, only its text goes, without formatting.
    @discardableResult
    func put(_ item: ClipItem, plain: Bool) -> Bool {
        guard let blob = store.blob(item.id) else { return false }
        let board = NSPasteboard.general
        board.clearContents()
        var ok = false
        switch item.kind {
        case .files:
            ok = board.writeObjects(item.files.map { URL(fileURLWithPath: $0) as NSURL })
            if !ok { ok = board.setString(item.files.joined(separator: "\n"), forType: .string) }
        case .image:
            if let image = blob.image { ok = board.setData(image, forType: .png) }
        case .text, .url, .richText:
            if !plain, item.kind == .richText, let rich = blob.rich {
                _ = board.setData(rich, forType: blob.richFormat == "html" ? .html : .rtf)
            }
            if let text = blob.plain { ok = board.setString(text, forType: .string) }
        }
        monitor.ignore(changeCount: board.changeCount)
        return ok
    }

    /// Chooses an item: copies it, and pastes it if Kriya may.
    func choose(_ item: ClipItem, plain: Bool) {
        guard put(item, plain: plain) else {
            toast.show("That item could not be copied.", isError: true)
            return
        }
        store.markUsed(item.id)
        if store.currentConfig.autoPaste, AXIsProcessTrusted() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { Self.sendPaste() }
        } else {
            toast.show(store.currentConfig.autoPaste ? "Copied. Allow Accessibility to paste automatically." : "Copied. Press ⌘V to paste.")
        }
    }

    /// Pastes whatever is on the clipboard as plain text, then puts the original (formatted) clipboard back.
    func pasteCurrentAsPlainText() {
        let board = NSPasteboard.general
        guard let text = board.string(forType: .string), !text.isEmpty else {
            toast.show("The clipboard has no text.", isError: true)
            return
        }
        let saved = Self.snapshot(board)
        board.clearContents()
        board.setString(text, forType: .string)
        monitor.ignore(changeCount: board.changeCount)
        guard AXIsProcessTrusted() else {
            toast.show("Copied as plain text. Press ⌘V. (Allow Accessibility to paste automatically.)")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { Self.sendPaste() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [monitor] in
            Self.restore(saved, to: board)
            monitor.ignore(changeCount: board.changeCount)
        }
    }

    /// Removes formatting from what is on the clipboard now, leaving the plain text.
    func removeFormattingFromClipboard() {
        let board = NSPasteboard.general
        guard let text = board.string(forType: .string), !text.isEmpty else {
            toast.show("The clipboard has no text.", isError: true)
            return
        }
        board.clearContents()
        board.setString(text, forType: .string)
        monitor.ignore(changeCount: board.changeCount)
        toast.show("Formatting removed")
    }

    static func sendPaste() {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: down) else { continue }
            event.flags = .maskCommand
            event.setIntegerValueField(.eventSourceUserData, value: EventMonitor.syntheticMarker)
            event.post(tap: .cghidEventTap)
        }
    }

    static func snapshot(_ board: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (board.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type, $0) } })
        }
    }

    static func restore(_ saved: [[NSPasteboard.PasteboardType: Data]], to board: NSPasteboard) {
        board.clearContents()
        let items = saved.map { entry -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in entry { item.setData(data, forType: type) }
            return item
        }
        board.writeObjects(items)
    }
}

/// Everything behind the clipboard feature: recording, pasting, the quick-access window and its shortcuts.
final class ClipboardService: ObservableObject {
    let store: ClipboardStore
    let monitor: ClipboardMonitor
    let paster: ClipboardPaster
    let quick: QuickAccessPanel

    @Published private(set) var isRunning = false
    private var hotkeys: HotkeyCenter?
    private var cleanupTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    init(store: ClipboardStore) {
        self.store = store
        monitor = ClipboardMonitor(store: store)
        paster = ClipboardPaster(store: store, monitor: monitor)
        quick = QuickAccessPanel(store: store, paster: paster)
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        monitor.start()
        store.cleanup()
        let timer = Timer(timeInterval: 3600, repeats: true) { [store] _ in store.cleanup() }
        RunLoop.main.add(timer, forMode: .common)
        cleanupTimer = timer
        hotkeys = HotkeyCenter(owner: "Clipboard") { [weak self] command in self?.fire(command) }
        store.$config
            .receive(on: DispatchQueue.main)
            .sink { [weak self] config in self?.registerShortcuts(config) }
            .store(in: &cancellables)
        Log.info("Clipboard", "Clipboard history started")
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        monitor.stop()
        cleanupTimer?.invalidate()
        cleanupTimer = nil
        cancellables.removeAll()
        hotkeys?.unregisterAll()
        hotkeys = nil
        quick.close()
        Log.info("Clipboard", "Clipboard history stopped")
    }

    private func registerShortcuts(_ config: ClipConfig) {
        var bindings: [ShortcutBinding] = []
        if let key = config.quickKey, config.quickModifiers != 0 { bindings.append(ShortcutBinding(command: "clipboard.quick", keyCode: key, modifiers: config.quickModifiers)) }
        if let key = config.plainKey, config.plainModifiers != 0 { bindings.append(ShortcutBinding(command: "clipboard.plain", keyCode: key, modifiers: config.plainModifiers)) }
        if let key = config.stripKey, config.stripModifiers != 0 { bindings.append(ShortcutBinding(command: "clipboard.strip", keyCode: key, modifiers: config.stripModifiers)) }
        hotkeys?.update(bindings)
    }

    private func fire(_ command: String) {
        switch command {
        case "clipboard.quick": quick.toggle()
        case "clipboard.plain": paster.pasteCurrentAsPlainText()
        case "clipboard.strip": paster.removeFormattingFromClipboard()
        default: break
        }
    }

    /// Pauses or resumes recording.
    func setPaused(_ paused: Bool) {
        store.updateConfig { $0.paused = paused }
    }
}

/// The clipboard as a switchable feature.
final class ClipboardFeature: FeatureModule {
    let feature = FeatureId.clipboard
    private var context: ServiceContext?

    func start(context: ServiceContext) throws {
        self.context = context
        context.clipboard.start()
    }

    func stop() {
        context?.clipboard.stop()
        context = nil
    }
}
