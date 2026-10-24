import AppKit
import Combine
import ImageIO
import UniformTypeIdentifiers

/// Taking screenshots with the Mac's own screenshot tool, reading text in them, hiding private text, marking them up, and
/// putting the result on the clipboard or in a folder. Everything happens on this Mac; nothing is uploaded.
final class ScreenCaptureService: ObservableObject {
    let settings: CaptureSettingsStore

    @Published private(set) var isCapturing = false
    /// Kriya's own screen recorder, with its control strip, keys and camera.
    let recording = RecordingController()

    private let toast = Toast()
    private let recognizer = TextRecognizer()
    let ruler = PixelRuler()
    private let queue = DispatchQueue(label: "app.kriya.capture", qos: .userInitiated)
    private var hotkeys: HotkeyCenter?
    private var cancellables = Set<AnyCancellable>()

    /// Opens the editor with a picture and calls back with the finished one (nil when the person cancels). Set by the app.
    var showEditor: (CGImage, @escaping (CGImage?) -> Void) -> Void = { image, done in done(image) }
    /// The app that was in front when the last capture began, for naming it.
    private var frontApp: String?
    /// Whether Kriya may capture the screen. Replaced in tests.
    var hasPermission: () -> Bool = { CGPreflightScreenCaptureAccess() }
    var requestPermission: () -> Void = { _ = CGRequestScreenCaptureAccess() }
    /// Runs the screenshot tool with these arguments. Replaced in tests.
    var capturer: ([String]) -> Void = { arguments in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = arguments
        try? process.run()
        process.waitUntilExit()
    }
    /// Where pictures and text go. Replaced in tests.
    var pasteboard: NSPasteboard = .general

    init(settings: CaptureSettingsStore) {
        self.settings = settings
        recording.onEnd = { [weak self] in self?.isCapturing = false }
        recording.onSaved = { [weak self] url in self?.recordingSaved(url) }
        CaptureOverlay.shared.actions = overlayActions(settings: settings.settings)
    }

    // MARK: Starting and shortcuts

    func start() {
        hotkeys = HotkeyCenter(owner: "Screen capture", title: { command in
            CaptureSettings.commands.first { $0.command == command }?.title ?? command
        }) { [weak self] command in self?.run(command: command) }
        settings.$settings
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                self?.hotkeys?.update(value.shortcuts.map { ShortcutBinding(command: $0.command, keyCode: $0.keyCode, modifiers: $0.modifiers) })
            }
            .store(in: &cancellables)
    }

    func stop() {
        hotkeys?.unregisterAll()
        hotkeys = nil
        cancellables.removeAll()
    }

    /// Runs one of the capture commands by name. False if the name is not one.
    @discardableResult
    func run(command: String) -> Bool {
        guard let entry = CaptureSettings.commands.first(where: { $0.command == command }) else { return false }
        DispatchQueue.main.async { self.capture(entry.mode, action: entry.action) }
        return true
    }

    // MARK: Capturing

    func capture(_ mode: CaptureMode, action: CaptureAction = .normal) {
        // These act on a recording already running (or need no capture permission), so they come before the checks below.
        switch action {
        case .pauseRecording: recording.togglePause(); return
        case .stopRecording: recording.stop(); return
        case .mirror: recording.showMirror(); return
        case .trimRecording: DispatchQueue.main.async { self.trimRecording() }; return
        default: break
        }
        guard !isCapturing else { return }
        // A password manager or bank in front is never photographed, so a secret is not captured by accident.
        if action != .ruler, CaptureExclusions.isExcluded(NSWorkspace.shared.frontmostApplication?.bundleIdentifier, list: CaptureExtraSettings.excludedApps) {
            toast.show("Not captured: \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "that app") is on the list of apps Kriya never captures.", isError: true)
            return
        }
        guard hasPermission() else {
            requestPermission()
            toast.show("Allow Screen Recording for Kriya in System Settings, then try again.", isError: true)
            return
        }
        isCapturing = true
        frontApp = NSWorkspace.shared.frontmostApplication?.localizedName
        var current = settings.settings
        // A menu closes when you click, so the screen is taken after a countdown, with nothing to click. It opens in the editor to be
        // cropped to the menu.
        var action = action
        if action == .menu {
            current.delaySeconds = max(current.delaySeconds, 5)
            current.openEditor = true
            action = .normal
            toast.show("Open the menu now. Capturing in \(current.delaySeconds) seconds…")
        }
        if action == .recordScreen || action == .recordWindow || action == .recordApp {
            var options = current.recording
            options.source = action == .recordWindow ? .window : action == .recordApp ? .app : .screen
            recording.start(options, into: current.folder, namePattern: current.namePattern, app: frontApp, mode: options.source.rawValue)
            return
        }
        if action == .record || action == .recordGIF { return record(asGIF: action == .recordGIF, settings: current) }
        if action == .scroll { return scrollingCapture(settings: current) }
        if action == .ruler { isCapturing = false; DispatchQueue.main.async { self.ruler.show() }; return }
        if action == .pin {
            isCapturing = false
            DispatchQueue.main.async { if !PinnedShots.shared.pinClipboardOrLatest(folder: current.folder) { self.toast.show("There is no picture on the clipboard or in the capture folder to pin.", isError: true) } }
            return
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("kriya-capture-\(UUID().uuidString).png")
        if action == .area || action == .previousArea {
            return captureArea(pickNew: action == .area, settings: current, file: file)
        }
        let arguments = ScreenCaptureArguments.make(mode: mode, delay: current.delaySeconds, sound: current.playSound, output: file, cursor: current.includeCursor ?? false)
        queue.async { [self] in
            capturer(arguments)
            defer { try? FileManager.default.removeItem(at: file) }
            // No file means the person pressed Escape: nothing to do.
            guard let image = Self.loadImage(at: file) else {
                DispatchQueue.main.async { self.isCapturing = false }
                return
            }
            process(image, action: action, settings: current)
        }
    }

    /// Records part of the screen with the system's own recorder, which shows its stop button in the menu bar.
    private func record(asGIF: Bool, settings: CaptureSettings) {
        let folder = settings.folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let stamp = ScreenCaptureArguments.fileName(for: Date()).replacingOccurrences(of: "Capture", with: "Recording").replacingOccurrences(of: ".png", with: "")
        let movie = folder.appendingPathComponent(stamp + ".mov")
        toast.show("Choose what to record. Click the stop button in the menu bar when you are done.")
        queue.async { [self] in
            capturer(["-i", "-v", movie.path])
            DispatchQueue.main.async { self.isCapturing = false }
            guard FileManager.default.fileExists(atPath: movie.path) else { return }
            guard asGIF else { DispatchQueue.main.async { self.toast.show("Recording saved as \(movie.lastPathComponent)"); self.recordingSaved(movie, settings: settings) }; return }
            let gif = movie.deletingPathExtension().appendingPathExtension("gif")
            Task {
                let ok = await GIFExporter.convert(movie: movie, to: gif)
                await MainActor.run {
                    if ok { try? FileManager.default.removeItem(at: movie); self.toast.show("GIF saved as \(gif.lastPathComponent)"); self.recordingSaved(gif, settings: settings) }
                    else { self.toast.show("The recording was saved, but could not be turned into a GIF.", isError: true) }
                }
            }
        }
    }

    /// Scrolls the window in front from top to bottom and joins what it sees.
    private func scrollingCapture(settings: CaptureSettings) {
        guard AXIsProcessTrusted() else {
            isCapturing = false
            toast.show("Allow Accessibility for Kriya to scroll the window for you.", isError: true)
            return
        }
        guard let frame = AXWindow.focused()?.frame?.cg, frame.width > 100, frame.height > 100 else {
            isCapturing = false
            toast.show("There is no window in front to capture.", isError: true)
            return
        }
        toast.show("Capturing the whole page. Keep the mouse still.")
        queue.async { [self] in
            let image = ScrollingCapture(capturer: capturer).run(frame: frame)
            DispatchQueue.main.async {
                self.isCapturing = false
                guard let image else { self.toast.show("The page could not be captured.", isError: true); return }
                self.deliver(image, settings: settings, hidden: 0)
            }
        }
    }

    private static let areaKey = "capture.previousArea.v1"
    private let areaPicker = AreaPicker()

    private var previousArea: PreviousArea? {
        get { UserDefaults.standard.data(forKey: Self.areaKey).flatMap { try? JSONDecoder().decode(PreviousArea.self, from: $0) } }
        set {
            if let data = newValue.flatMap({ try? JSONEncoder().encode($0) }) { UserDefaults.standard.set(data, forKey: Self.areaKey) }
            else { UserDefaults.standard.removeObject(forKey: Self.areaKey) }
        }
    }

    /// Captures an area: the one remembered if the displays are as they were, or one the person drags out now.
    private func captureArea(pickNew: Bool, settings current: CaptureSettings, file: URL) {
        if !pickNew, let saved = previousArea {
            if saved.valid(for: AreaPicker.currentLayout) != nil {
                return captureArea(saved, settings: current, file: file)
            }
            previousArea = nil
            toast.show("The displays changed since that area was captured. Pick the area again.")
        } else if !pickNew {
            toast.show("No area has been captured yet. Drag one out.")
        }
        DispatchQueue.main.async {
            self.areaPicker.pick { rect in
                guard let rect, let area = PreviousArea(rect: rect, layout: AreaPicker.currentLayout) else { self.isCapturing = false; return }
                self.previousArea = area
                self.captureArea(area, settings: current, file: file)
            }
        }
    }

    private func captureArea(_ area: PreviousArea, settings current: CaptureSettings, file: URL) {
        let arguments = ScreenCaptureArguments.area(area, delay: current.delaySeconds, sound: current.playSound, output: file)
        queue.async { [self] in
            capturer(arguments)
            defer { try? FileManager.default.removeItem(at: file) }
            guard let image = Self.loadImage(at: file) else {
                DispatchQueue.main.async { self.isCapturing = false }
                return
            }
            process(image, action: .normal, settings: current)
        }
    }

    /// Asks for a recording and the part to keep, then writes the trimmed copy beside it. The original is left as it is.
    func trimRecording() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        panel.directoryURL = settings.settings.folder
        panel.prompt = "Trim"
        panel.message = "Choose the recording to trim. The original is kept."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let alert = NSAlert()
        alert.messageText = "Keep which part?"
        alert.informativeText = "Times as seconds or minutes:seconds, for example 12 or 1:05."
        let row = NSStackView(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        let from = NSTextField(string: "0:00"), to = NSTextField(string: "")
        to.placeholderString = "end"
        row.addArrangedSubview(from); row.addArrangedSubview(NSTextField(labelWithString: "to")); row.addArrangedSubview(to)
        alert.accessoryView = row
        alert.addButton(withTitle: "Trim"); alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let start = RecordingTrim.seconds(from: from.stringValue) else { toast.show("The start time is not a time.", isError: true); return }
        let end = to.stringValue.trimmingCharacters(in: .whitespaces).isEmpty ? Double.greatestFiniteMagnitude : RecordingTrim.seconds(from: to.stringValue)
        guard let end else { toast.show("The end time is not a time.", isError: true); return }
        toast.show("Trimming…")
        RecordingTrimmer.trim(url, start: start, end: end) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let out): self.toast.show("Saved \(out.lastPathComponent)"); NSWorkspace.shared.activateFileViewerSelecting([out])
                case .failure(let error): self.toast.show(error.localizedDescription, isError: true)
                }
            }
        }
    }

    /// Reads the text in a picture and copies it. For a picture that is already on this Mac.
    func copyText(from image: CGImage) {
        queue.async { [self] in
            let text = (try? recognizer.text(in: image)) ?? ""
            DispatchQueue.main.async { self.deliverText(text) }
        }
    }

    private func process(_ image: CGImage, action: CaptureAction, settings: CaptureSettings) {
        switch action {
        case .text:
            let text = (try? recognizer.text(in: image)) ?? ""
            DispatchQueue.main.async {
                self.isCapturing = false
                self.deliverText(text)
            }
        case .textJoined, .textMarkdown, .textTable:
            let lines = (try? recognizer.recognize(image)) ?? []
            let text: String
            switch action {
            case .textJoined: text = OCRText.joined(lines)
            case .textMarkdown: text = OCRText.markdown(lines)
            default: text = OCRText.csv(OCRText.table(lines))
            }
            DispatchQueue.main.async {
                self.isCapturing = false
                self.deliverText(text)
            }
        case .qr:
            let found = QRCodeReader.read(image)
            DispatchQueue.main.async {
                self.isCapturing = false
                guard let first = found.first else { self.toast.show("No QR code found in that picture.", isError: true); return }
                self.pasteboard.clearContents()
                self.pasteboard.setString(first, forType: .string)
                self.toast.show(found.count > 1 ? "Copied the first of \(found.count) codes: \(String(first.prefix(60)))" : "Copied: \(String(first.prefix(60)))")
            }
        case .cutout:
            let cut = SubjectCutout.cut(image)
            DispatchQueue.main.async {
                self.isCapturing = false
                guard let cut, let data = cut.pngData else { self.toast.show("No subject found in that picture.", isError: true); return }
                self.pasteboard.clearContents()
                self.pasteboard.setData(data, forType: .png)
                var done = "copied"
                if settings.saveToFolder, let name = self.save(cut, to: settings.folder) { done += ", saved as \(name)" }
                self.toast.show("Subject cut out: " + done)
            }
        case .record, .recordGIF, .scroll, .ruler, .pin, .recordScreen, .recordWindow, .recordApp, .pauseRecording, .stopRecording, .mirror, .menu, .trimRecording, .area, .previousArea:
            DispatchQueue.main.async { self.isCapturing = false }
        case .normal, .redacted:
            var picture = image
            var hidden = 0
            if action == .redacted || settings.redactAutomatically {
                let result = redacted(image, words: settings.redactWords)
                picture = result.image
                hidden = result.count
            }
            DispatchQueue.main.async {
                if settings.openEditor {
                    self.showEditor(picture) { finished in
                        if let finished { self.deliver(finished, settings: settings, hidden: hidden, original: picture, edited: true) }
                        self.isCapturing = false
                    }
                } else {
                    self.deliver(picture, settings: settings, hidden: hidden)
                    self.isCapturing = false
                }
            }
        }
    }

    /// The picture with private-looking text covered, and how many places were covered.
    func redacted(_ image: CGImage, words: [String]) -> (image: CGImage, count: Int) {
        guard let lines = try? recognizer.recognize(image) else { return (image, 0) }
        let boxes = Redaction.plan(lines, options: Redaction.Options(extraWords: words))
        guard !boxes.isEmpty, let covered = CaptureRenderer.hide(image, rects: boxes) else { return (image, 0) }
        return (covered, boxes.count)
    }

    /// Where private-looking text is in a picture, for the editor to offer as boxes.
    func privateTextBoxes(in image: CGImage, words: [String]) -> [CGRect] {
        guard let lines = try? recognizer.recognize(image) else { return [] }
        return Redaction.plan(lines, options: Redaction.Options(extraWords: words))
    }

    // MARK: Delivering

    private func deliverText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            toast.show("No text found in that picture.", isError: true)
            return
        }
        pasteboard.clearContents()
        pasteboard.setString(trimmed, forType: .string)
        toast.show("Copied \(trimmed.count) characters of text")
    }

    /// Hands the picture on as the settings say, then shows the quick card with it. `original` is the picture before editing, kept
    /// beside the edited one when that is turned on.
    private func deliver(_ image: CGImage, settings: CaptureSettings, hidden: Int, original: CGImage? = nil, edited: Bool = false) {
        var done: [String] = []
        var picture = image
        // A backdrop set for every capture is put on pictures that were not styled in the editor.
        let style = CaptureExtraSettings.beautify
        if !edited, style.isOn, let styled = CaptureRenderer.beautified(picture, style) { picture = styled }
        if hidden > 0 { done.append("\(hidden) private place\(hidden == 1 ? "" : "s") hidden") }
        if settings.copyImage, let data = picture.pngData {
            pasteboard.clearContents()
            pasteboard.setData(data, forType: .png)
            done.append("copied")
        }
        var savedFile: URL?
        if settings.saveToFolder {
            if let name = save(picture, to: settings.folder) { done.append("saved as \(name)"); savedFile = settings.folder.appendingPathComponent(name) }
            else { toast.show("The capture could not be saved in \(settings.folder.lastPathComponent).", isError: true) }
            if edited, CaptureExtraSettings.keepOriginal, let original, save(original, to: settings.folder, original: true) != nil { done.append("original kept") }
        }
        toast.show(done.isEmpty ? "Captured, but copying and saving are both off." : "Captured: " + done.joined(separator: ", "))
        showCard(picture, file: savedFile, recording: false, settings: settings)
    }

    /// Shows the quick access card for a capture (the settings decide whether it gets one).
    private func showCard(_ image: CGImage, file: URL?, recording: Bool, settings: CaptureSettings) {
        let overlay = CaptureOverlay.shared
        overlay.actions = overlayActions(settings: settings)
        overlay.isRecording = { [weak self] in self?.recording.isRecording ?? false }
        overlay.show(image, file: file, isRecording: recording)
    }

    /// Called when a recording has been saved, so it gets a card too.
    func recordingSaved(_ url: URL, settings: CaptureSettings? = nil) {
        let current = settings ?? self.settings.settings
        DispatchQueue.global(qos: .userInitiated).async {
            guard let frame = CaptureOverlay.thumbnail(forMovie: url) else { return }
            DispatchQueue.main.async { self.showCard(frame, file: url, recording: true, settings: current) }
        }
    }

    /// What the cards' buttons and keys do. Also what the menu-bar icon uses.
    func overlayActions(settings: CaptureSettings) -> CaptureOverlayActions {
        var actions = CaptureOverlayActions(
            edit: { [weak self] image in
                self?.showEditor(image) { finished in if let finished { self?.deliver(finished, settings: settings, hidden: 0, original: image, edited: true) } }
            },
            copyText: { [weak self] in self?.copyText(from: $0) },
            pin: { PinnedShots.shared.pin(NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height))) },
            save: { [weak self] image, format in self?.saveFile(image, format: format, folder: settings.folder) },
            message: { [weak self] text, isError in self?.toast.show(text, isError: isError) }
        )
        actions.sendToShelf = { [weak self] in self?.sendToShelf($0) }
        actions.openHistory = { [weak self] in self?.openHistory() }
        actions.openSettings = { [weak self] in self?.openSettings() }
        actions.runCommand = { [weak self] in self?.run(command: $0) }
        actions.captureFolder = { settings.folder }
        return actions
    }

    /// Put a file on the shelf, open the history, open settings: set by the app, which owns those screens.
    var sendToShelf: (URL) -> Void = { _ in }
    var openHistory: () -> Void = {}
    var openSettings: () -> Void = {}

    /// Saves in a chosen format (from the card's menu) and returns the file.
    private func saveFile(_ image: CGImage, format: CaptureFormat, folder: URL) -> URL? {
        guard let name = save(image, to: folder, format: format) else { return nil }
        return folder.appendingPathComponent(name)
    }

    /// Writes the picture into the folder and returns the file's name. In the saved format (PNG unless changed); `original` marks the
    /// untouched copy of an edited capture.
    @discardableResult
    func save(_ image: CGImage, to folder: URL, now: Date = Date(), format: CaptureFormat = CaptureExtraSettings.format, original: Bool = false) -> String? {
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let name = CaptureNaming.fileName(pattern: settings.settings.namePattern, date: now, app: frontApp, mode: original ? "original" : "capture", ext: format.fileExtension) { manager.fileExists(atPath: folder.appendingPathComponent($0).path) }
            guard let data = image.data(as: format) else { return nil }
            try data.write(to: folder.appendingPathComponent(name), options: .atomic)
            return name
        } catch {
            Log.warning("Capture", "Could not save a capture: \(error.localizedDescription)")
            return nil
        }
    }

    static func loadImage(at url: URL) -> CGImage? {
        // The picture is read into memory and decoded now, because the file is removed as soon as the capture is handled.
        guard let data = try? Data(contentsOf: url), let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }
}
