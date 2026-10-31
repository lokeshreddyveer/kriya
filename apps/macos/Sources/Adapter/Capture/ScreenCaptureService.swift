import AppKit
import Combine
import ImageIO
import UniformTypeIdentifiers

/// Taking screenshots with the Mac's own screenshot tool, reading text in them, hiding private text, marking them up, and
/// putting the result on the clipboard or in a folder. Everything happens on this Mac; nothing is uploaded.
final class ScreenCaptureService: ObservableObject {
    let settings: CaptureSettingsStore

    @Published private(set) var isCapturing = false
    /// The actions that take a picture of a chosen place, which Kriya's selector can serve.
    static let nativeActions: Set<CaptureAction> = [.normal, .redacted, .text, .textJoined, .textMarkdown, .textTable, .qr, .cutout, .area, .previousArea]
    /// Lets the native capture flow say it is done.
    func finishCapture() { isCapturing = false; request?.forced = nil; deliveryAdjustment = nil }

    /// What a command that starts from an area wants done with the picture, once: it is taken here so a cancelled capture cannot leave
    /// it behind for the next one.
    func consumeForcedDelivery() -> ForcedDelivery? {
        let forced = request?.forced
        request?.forced = nil
        return forced
    }

    /// Where the delivery settings come from. The saved ones; replaced in tests so they never read or change the real preferences.
    var deliveryPolicy: () -> CaptureDeliveryPolicy = { CaptureExtraSettings.delivery }

    /// Asks what to call a capture before it is saved: the name it would get, the extension, the folder, and the suffix to add (such as
    /// "@2x"). Returns the name the person typed, or nil if they chose not to save. Replaced in tests.
    var askForFileName: (_ suggested: String, _ ext: String, _ folder: URL, _ suffix: @escaping (String) -> String) -> String? = FilenameSheet.ask

    /// The macOS screenshot tool makes the sound itself only when the macOS sound is the one chosen; any other choice is played by Kriya.
    private var toolMakesTheSound: Bool { deliveryPolicy().sound.choice == .system }

    /// The sound for a picture just taken. Silent when the sound switch is off or "None" is chosen. When the macOS tool already made
    /// the macOS sound (`byTool`), nothing more is played, so it is never heard twice.
    func playCaptureSound(_ settings: CaptureSettings, byTool: Bool = false) {
        let policy = deliveryPolicy().sound
        if byTool && policy.choice == .system { return }
        let outcome = CaptureSoundPlayer.shared.play(enabled: settings.playSound, policy: policy)
        // Said only when the sound that played is not the one chosen, or none could play.
        if let message = outcome.message { toast.show(message, isError: outcome.result == .failed) }
    }

    /// Copies the picture as the output setting says: the file, the image, or both on one clipboard item. `savedFile` is the file it was
    /// saved as, if it was. The clipboard is cleared only once there is something to put on it, so a copy that cannot be made leaves what
    /// was there. Returns a sentence when the copy was not exactly what was chosen, otherwise nil.
    func copyToClipboard(_ picture: CGImage, mode: ClipboardOutput, savedFile: URL?) -> String? {
        let png = picture.pngData
        let tiff = mode == .file ? nil : NSBitmapImageRep(cgImage: picture).representation(using: .tiff, properties: [:])
        var file = savedFile.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        // Nothing was saved (or it was moved): a file is written just for the copy.
        if file == nil, mode != .image { file = ClipboardWriter.temporaryFile(png: png) }
        let outcome = ClipboardPlan.plan(mode, png: png, tiff: tiff, file: file)
        if let payload = outcome.payload { ClipboardWriter.write(payload, to: pasteboard) }
        return outcome.note
    }

    /// Records the scale of the display the picture was taken on, which decides whether it is a Retina picture. Called once the display is
    /// known; until then the request holds the scale of the screen the pointer was on.
    func noteBackingScale(of display: CGDirectDisplayID) {
        request?.backingScale = max(ScreenGrabber.scale(of: display), 1)
    }

    /// What a command that starts from an area (copy, save, upload) wants done with the steps, once. Taken by `deliver`.
    var deliveryAdjustment: ((inout DeliverySteps) -> Void)?

    /// What is true now, for deciding whether a command can run and what to say when it cannot.
    func commandState() -> CaptureCommandState {
        CaptureCommandState(
            hasScreenPermission: hasPermission(), isCapturing: isCapturing, isScrolling: scrollSession != nil,
            kriyaRecording: recording.isRecording, macOSRecording: systemRecorder?.isRunning == true,
            pinCount: PinnedShots.shared.count, cardCount: CaptureOverlay.shared.cardCount, closedCardCount: CaptureOverlay.shared.closed.count,
            uploadReady: CaptureUploadStore.shared.ready, cameraShown: recording.cameraShown, kriyaSelector: usesNativeSelector
        )
    }

    /// The request for the screenshot being delivered: the one the capture began with, or a new one when a picture arrives from
    /// somewhere that did not begin with a capture here (an old capture reopened, say) or after a recording.
    func screenshotRequest(settings: CaptureSettings) -> CaptureRequest {
        if let request, request.kind == .screenshot { return request }
        return CaptureRequest.make(mode: .region, action: .normal, settings: settings, policy: deliveryPolicy(), backingScale: Self.pointerScale())
    }

    /// The scale of the screen the pointer is on, for keeping Retina screenshots at 1x.
    static func pointerScale() -> CGFloat {
        let point = NSEvent.mouseLocation
        return (NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main)?.backingScaleFactor ?? 2
    }
    func beginCapture() { isCapturing = true }
    /// Hands a picture on for reading text, hiding, editing and delivery, away from the main thread (reading text takes a moment).
    func processInBackground(_ image: CGImage, action: CaptureAction, settings: CaptureSettings) {
        queue.async { [self] in process(image, action: action, settings: settings) }
    }
    /// Kriya's own screen recorder, with its control strip, keys and camera.
    let recording = RecordingController()

    let toast = Toast()
    private let recognizer = TextRecognizer()
    let ruler = PixelRuler()
    private let queue = DispatchQueue(label: "app.kriya.capture", qos: .userInitiated)
    private var hotkeys: HotkeyCenter?
    private var cancellables = Set<AnyCancellable>()
    /// Kept apart from the others: they are dropped when the shortcuts are stopped, this must keep following the recorder.
    private var recordingSub: AnyCancellable?

    /// Opens the editor with a picture and calls back with the finished one (nil when the person cancels). Set by the app.
    var showEditor: (CGImage, @escaping (CGImage?) -> Void) -> Void = { image, done in done(image) }
    /// The backdrop the editor starts with (the picture itself stays untouched underneath), when backdrops are set to go on before the
    /// editor opens. Read by the app when it opens the editor.
    private(set) var editorStartStyle: CaptureBeautify?
    /// The capture being taken or delivered: what to do, the policy as it was when it began, and the keys held then.
    private(set) var request: CaptureRequest?
    /// The app that was in front when the last capture began, for naming it.
    var frontApp: String?
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

    // MARK: The macOS recorder

    /// Starts macOS's own recorder (`screencapture -v`) and returns the running process; it throws if it cannot be started. Replaced in tests.
    var recorderLauncher: ([String], @escaping (Process) -> Void) throws -> Process = { arguments, finished in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = arguments
        process.terminationHandler = finished
        try process.run()
        return process
    }

    /// The macOS recorder while it is choosing what to record or recording. Kept so Kriya's Stop can end it.
    @Published private(set) var systemRecorder: Process?
    /// When the macOS recorder was started, for the timer in the menu bar.
    private(set) var systemRecordingStart: Date?

    /// What is recording now, for the menu-bar icon and menu: Kriya's own recorder, or macOS's.
    enum RecordingKind { case kriya, macOS }
    var recordingKind: RecordingKind? {
        if recording.isRecording { return .kriya }
        if let p = systemRecorder, p.isRunning { return .macOS }
        return nil
    }

    /// Ends macOS's recorder the way Control-C would (it then saves the movie). False if it is not running.
    @discardableResult
    func stopSystemRecorder() -> Bool {
        guard let p = systemRecorder, p.isRunning else { return false }
        kill(p.processIdentifier, SIGINT)
        return true
    }

    init(settings: CaptureSettingsStore) {
        self.settings = settings
        recording.onEnd = { [weak self] in self?.isCapturing = false }
        recording.onSaved = { [weak self] url in self?.recordingSaved(url) }
        // The menu-bar icon follows Kriya's own recorder: red while it starts, records or pauses.
        recordingSub = recording.recorder.$state.receive(on: DispatchQueue.main).sink { _ in CaptureOverlay.shared.recordingChanged() }
        CaptureOverlay.shared.actions = overlayActions(settings: settings.settings)
    }

    // MARK: Starting and shortcuts

    func start() {
        // A display that is no longer connected, or a window that is no longer open, is taken out of what the chooser remembers.
        DispatchQueue.main.async { [weak self] in self?.validateRemembered(); self?.recording.recoverAfterQuit() }
        // Recordings cut off by a crash or a power cut last time are found and shown, a few seconds after launch.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.recoverUnfinishedRecordings() }
        // The menu-bar icon is there from launch (unless hidden in Settings), not only after the first capture.
        DispatchQueue.main.async { CaptureOverlay.shared.actions = self.overlayActions(settings: self.settings.settings); CaptureOverlay.shared.settingsChanged() }
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

    /// Asks the system for the shortcuts again, so ones it refused earlier (because macOS held the keys) are tried anew.
    func reregisterShortcuts() {
        hotkeys?.update(settings.settings.shortcuts.map { ShortcutBinding(command: $0.command, keyCode: $0.keyCode, modifiers: $0.modifiers) })
    }

    func stop() {
        CaptureOverlay.shared.removeIcon()
        hotkeys?.unregisterAll()
        hotkeys = nil
        cancellables.removeAll()
    }

    /// Runs one of the capture commands by name. False if the name is not one.
    @discardableResult
    func run(command: String) -> Bool {
        if command.hasPrefix("capture.area."), command != "capture.area" {
            let id = String(command.dropFirst("capture.area.".count))
            // Everything that touches the screen happens on the main thread; from there it is done now, from elsewhere it is waited for.
            return Thread.isMainThread ? captureNamedArea(id: id) : DispatchQueue.main.sync { captureNamedArea(id: id) }
        }
        // The commands added later (area and copy or save, history, cards, pins, scrolling, the camera) check what they need first.
        if let added = CaptureCommandCatalog.command(command) {
            DispatchQueue.main.async { self.perform(added) }
            return true
        }
        guard let entry = CaptureSettings.commands.first(where: { $0.command == command }) else { return false }
        DispatchQueue.main.async { self.capture(entry.mode, action: entry.action) }
        return true
    }

    // MARK: Capturing

    func capture(_ mode: CaptureMode, action: CaptureAction = .normal, forced: ForcedDelivery? = nil) {
        // The kind of recording asked for is remembered, so the chooser's "Record" starts that kind next time.
        rememberRecording(action)
        // These act on a recording already running (or need no capture permission), so they come before the checks below.
        switch action {
        case .pauseRecording:
            if recording.isRecording { recording.togglePause() }
            else if systemRecorder?.isRunning == true { toast.show("macOS's recorder cannot be paused. Stop it, or use “Record Screen” for a recording that can.", isError: true) }
            return
        case .stopRecording:
            // Whichever recorder is running is the one that stops: Kriya's own, or macOS's, or a scrolling capture in progress.
            if let session = scrollSession { Task { @MainActor in session.stop() } }
            else if recording.isRecording { recording.stop() }
            else if !stopSystemRecorder() { toast.show("There is no recording to stop.") }
            return
        case .mirror: recording.showMirror(); return
        case .chooser: DispatchQueue.main.async { self.showChooser() }; return
        case .scroll:
            // Asking for a scrolling capture while one is running ends it, keeping what was taken.
            if let session = scrollSession { Task { @MainActor in session.stop() }; return }
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
            handleMissingPermission()
            return
        }
        isCapturing = true
        frontApp = NSWorkspace.shared.frontmostApplication?.localizedName
        var current = settings.settings
        request = CaptureRequest.make(mode: mode, action: action, settings: current, policy: deliveryPolicy(), modifiers: .current, backingScale: Self.pointerScale(), forced: forced)
        // A menu closes when you click, so the screen is taken after a countdown, with nothing to click. It opens in the editor to be
        // cropped to the menu.
        var action = action
        if action == .menu, usesNativeSelector { return nativeMenuCapture(settings: current) }
        if action == .menu {
            current.delaySeconds = max(current.delaySeconds, 5)
            current.openEditor = true
            action = .normal
            toast.show("Open the menu now. Capturing in \(current.delaySeconds) seconds…")
        }
        if action == .recordScreen || action == .recordWindow || action == .recordApp {
            var options = current.recording
            options.source = action == .recordWindow ? .window : action == .recordApp ? .app : .screen
            // The app in front is fixed now, before any countdown or permission question, so that is the app recorded.
            startRecordingAfterTimer(options, settings: current, seconds: timerSeconds(for: current), target: NSWorkspace.shared.frontmostApplication)
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
        // Region, window and screen go through Kriya's own selector (frozen screen, magnifier, keyboard control, self-timer) unless
        // macOS's own tool is chosen; the actions that are not a picture of a place keep their own paths above.
        if usesNativeSelector, Self.nativeActions.contains(action) {
            if action == .previousArea { return nativePreviousArea(settings: current) }
            return nativeCapture(action == .area ? .region : mode, action: action == .area ? .normal : action, settings: current)
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("kriya-capture-\(UUID().uuidString).png")
        if action == .area || action == .previousArea {
            return captureArea(pickNew: action == .area, settings: current, file: file)
        }
        let arguments = ScreenCaptureArguments.make(mode: mode, delay: current.delaySeconds, sound: current.playSound && toolMakesTheSound, output: file, cursor: current.includeCursor ?? false)
        queue.async { [self] in
            capturer(arguments)
            defer { try? FileManager.default.removeItem(at: file) }
            // No file means the person pressed Escape: nothing to do.
            guard let image = Self.loadImage(at: file) else {
                DispatchQueue.main.async { self.isCapturing = false }
                return
            }
            DispatchQueue.main.async { self.playCaptureSound(current, byTool: true) }
            // With permission missing macOS can hand back an empty or wallpaper-only picture; the permission check catches the usual case.
            process(image, action: action, settings: current)
        }
    }

    /// Without Screen Recording macOS gives a capture tool nothing, so no picture is made, nothing is copied and no card appears. A
    /// toast is easy to miss, so this says it plainly and opens the right Settings page.
    var onMissingPermission: (() -> Void)?
    private var lastExplained = Date.distantPast
    static let askedKey = "capture.permissionAsked"

    /// One flow, never two at once: the first time, macOS's own question is shown (and nothing else); after that, macOS will not ask
    /// again, so a single explanation with the Settings button is shown instead.
    func handleMissingPermission() {
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: Self.askedKey) {
            defaults.set(true, forKey: Self.askedKey)
            requestPermission()
            toast.show("Allow Screen Recording in the question macOS asks, then capture again.")
        } else {
            explainMissingPermission()
        }
    }

    func explainMissingPermission() {
        guard Date().timeIntervalSince(lastExplained) > 20 else { return }
        lastExplained = Date()
        // Never a real alert under automated tests: a modal window would hang the run.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil || onMissingPermission != nil else { return }
        if let custom = onMissingPermission { custom(); return }
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Kriya needs permission to record the screen"
            alert.informativeText = "macOS has Screen Recording switched off for Kriya, so a capture cannot copy anything or show a card. Open Privacy & Security › Screen & System Audio Recording and switch Kriya on. If Kriya is already in the list, switch it off and on again, then quit and reopen Kriya."
            alert.addButton(withTitle: "Open Settings")
            alert.addButton(withTitle: "Not Now")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn, let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(url) }
        }
    }

    /// Records part of the screen with the system's own recorder, which shows its stop button in the menu bar.
    private func record(asGIF: Bool, settings: CaptureSettings) {
        let folder = settings.folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let stamp = ScreenCaptureArguments.fileName(for: Date()).replacingOccurrences(of: "Capture", with: "Recording").replacingOccurrences(of: ".png", with: "")
        let movie = folder.appendingPathComponent(stamp + ".mov")
        let delay = timerSeconds(for: settings)
        toast.show("Choose what to record, then click the stop button in the menu bar, or use “Stop Recording” in Kriya's menu or its shortcut.")
        // The recorder runs on its own and tells when it has ended, so nothing here waits for it, a failure to start is said, and Kriya's
        // Stop can end it.
        let process: Process
        do {
            process = try recorderLauncher(["-i", "-v"] + (delay > 0 ? ["-T", String(delay)] : []) + [movie.path]) { [weak self] ended in
                DispatchQueue.main.async { self?.systemRecorderEnded(ended, movie: movie, asGIF: asGIF, settings: settings) }
            }
        } catch {
            isCapturing = false
            toast.show("macOS's recorder could not be started (\(error.localizedDescription)). Check Screen Recording under System Settings › Privacy & Security.", isError: true)
            return
        }
        systemRecorder = process
        systemRecordingStart = Date()
        CaptureOverlay.shared.recordingChanged()
    }

    private func systemRecorderEnded(_ ended: Process, movie: URL, asGIF: Bool, settings: CaptureSettings) {
        systemRecorder = nil
        systemRecordingStart = nil
        isCapturing = false
        CaptureOverlay.shared.recordingChanged()
        let saved = FileManager.default.fileExists(atPath: movie.path)
        guard saved else {
            // Escape while choosing leaves no file and a clean exit: that is a cancel. Anything else is a failure and is said.
            if ended.terminationStatus == 0 { toast.show("Recording cancelled.") }
            else { toast.show("macOS did not save a recording (it stopped with code \(ended.terminationStatus)). Allow Screen Recording for Kriya in System Settings › Privacy & Security, then try again.", isError: true) }
            return
        }
        guard asGIF else { toast.show("Recording saved as \(movie.lastPathComponent)"); recordingSaved(movie, settings: settings); return }
        let gif = movie.deletingPathExtension().appendingPathExtension("gif")
        Task { @MainActor in
            // How far along it is, with a Cancel. The recording is only removed once the GIF is safely written.
            let panel = GIFProgressPanel()
            panel.show(title: "Making a GIF from the recording…")
            let outcome = await GIFExporter.convert(movie: movie, to: gif, options: settings.recording.gif,
                                                    progress: { value in Task { @MainActor in panel.update(value) } },
                                                    isCancelled: { DispatchQueue.main.sync { MainActor.assumeIsolated { panel.cancelled } } })
            panel.close()
            switch outcome {
            case .saved:
                try? FileManager.default.removeItem(at: movie)
                self.toast.show("\(outcome.message) Saved as \(gif.lastPathComponent).")
                self.recordingSaved(gif, settings: settings)
            case .cancelled:
                self.toast.show("GIF cancelled. The recording was kept as \(movie.lastPathComponent).")
                self.recordingSaved(movie, settings: settings)
            case .failed(let reason):
                self.toast.show("\(reason) The recording was kept as \(movie.lastPathComponent).", isError: true)
                self.recordingSaved(movie, settings: settings)
            }
        }
    }

    /// A scrolling capture: the area that scrolls is chosen, then it is taken a screen at a time and joined (see `ScrollEngine`).
    private func scrollingCapture(settings: CaptureSettings) { startScrollingCapture(settings: settings) }

    /// The scrolling capture running now, if one is.
    var scrollSession: ScrollCaptureSession?

    private static let areaKey = "capture.previousArea.v1"
    private let areaPicker = AreaPicker()
    let selector = CaptureSelector()
    let chooser = CaptureChooser()
    /// Kriya's own selector takes region, window and screen captures; tests turn it off to use the stand-in screenshot tool.
    var nativeSelectorEnabled = true
    /// A timer chosen in the all-in-one chooser, used by the next capture only.
    var oneShotTimer: Int?
    /// The last menu capture, so it can be taken again.
    var hasMenuCapture = false
    /// Called when a saved area is added or removed, so its command can be added or removed too.
    var onSavedAreasChanged: () -> Void = {}

    var previousArea: PreviousArea? {
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
        let arguments = ScreenCaptureArguments.area(area, delay: current.delaySeconds, sound: current.playSound && toolMakesTheSound, output: file)
        queue.async { [self] in
            capturer(arguments)
            defer { try? FileManager.default.removeItem(at: file) }
            guard let image = Self.loadImage(at: file) else {
                DispatchQueue.main.async { self.isCapturing = false }
                return
            }
            DispatchQueue.main.async { self.playCaptureSound(current, byTool: true) }
            process(image, action: .normal, settings: current)
        }
    }

    /// Asks for a recording and the part to keep, then writes the trimmed copy beside it. The original is left as it is.
    func trimRecording(file: URL? = nil) {
        // Asked to trim a recording that was just made, it goes straight to what to keep; otherwise the recording is chosen first.
        var chosen = file
        if chosen == nil {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
            panel.directoryURL = settings.settings.folder
            panel.prompt = "Trim"
            panel.message = "Choose the recording to trim. The original is kept."
            guard panel.runModal() == .OK else { return }
            chosen = panel.url
        }
        guard let url = chosen else { return }
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
            Task { @MainActor in await self.deliverText(text) }
        }
    }

    func process(_ image: CGImage, action: CaptureAction, settings: CaptureSettings) {
        switch action {
        case .text:
            let text = (try? recognizer.text(in: image)) ?? ""
            Task { @MainActor in
                await self.deliverText(text)
                self.isCapturing = false
            }
        case .textJoined, .textMarkdown, .textTable:
            let lines = (try? recognizer.recognize(image)) ?? []
            let text: String
            switch action {
            case .textJoined: text = OCRText.joined(lines)
            case .textMarkdown: text = OCRText.markdown(lines)
            default: text = OCRText.csv(OCRText.table(lines))
            }
            Task { @MainActor in
                await self.deliverText(text)
                self.isCapturing = false
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
        case .record, .recordGIF, .scroll, .ruler, .pin, .recordScreen, .recordWindow, .recordApp, .pauseRecording, .stopRecording, .mirror, .menu, .trimRecording, .area, .previousArea, .chooser:
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
                    let screenshot = self.screenshotRequest(settings: settings)
                    self.editorStartStyle = screenshot.delivery.background.timing == .beforeEditor ? screenshot.background(legacy: CaptureExtraSettings.beautify, modifiersNow: .current) : nil
                    self.showEditor(picture) { finished in
                        Task { @MainActor in
                            if let finished { await self.deliver(finished, settings: settings, hidden: hidden, original: picture, edited: true) }
                            self.isCapturing = false
                        }
                    }
                } else {
                    // Every stage has run before the next capture may begin.
                    Task { @MainActor in
                        await self.deliver(picture, settings: settings, hidden: hidden)
                        self.isCapturing = false
                    }
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

    /// Hands a link to Link Routing, which opens it in the browser the person's rules choose. Set by the app; until then it opens the
    /// usual way.
    var routeLink: (URL) -> Void = { NSWorkspace.shared.open($0) }

    /// Shows the quick access card for a capture (the settings decide whether it gets one).
    func showCard(_ image: CGImage, file: URL?, recording: Bool, settings: CaptureSettings) {
        let overlay = CaptureOverlay.shared
        overlay.actions = overlayActions(settings: settings)
        overlay.isRecording = { [weak self] in self?.recording.isRecording ?? false }
        overlay.show(image, file: file, isRecording: recording)
    }

    /// Called when a recording or GIF has been saved: it is delivered as the After Capture choices for its kind say (copied, uploaded,
    /// linked, trimmed, given a card), in the same order as a screenshot.
    func recordingSaved(_ url: URL, settings: CaptureSettings? = nil) {
        let current = settings ?? self.settings.settings
        DispatchQueue.global(qos: .userInitiated).async {
            guard let frame = CaptureOverlay.thumbnail(forMovie: url) else { return }
            Task { @MainActor in
                // The thumbnail on the card can have the backdrop chosen for recordings (left out when Shift is held). The recording
                // itself is never touched: it is the file as it was written.
                var thumbnail = frame
                if let style = self.deliveryPolicy().background.recordingThumbnail(modifiers: .current), let styled = CaptureRenderer.beautified(frame, style) { thumbnail = styled }
                let kind: CaptureKind = url.pathExtension.lowercased() == "gif" ? .gif : .recording
                let steps = self.deliveryPolicy().steps(for: kind, settings: current)
                let actions = RecordingDelivery(service: self, file: url, thumbnail: thumbnail, settings: current)
                let report = await DeliveryPipeline.run(DeliveryJob(kind: kind, steps: steps, copyNeedsFile: true), actions: actions)
                if !actions.done.isEmpty || !report.messages.isEmpty { self.toast.show((actions.done + report.messages).joined(separator: ", ")) }
            }
        }
    }

    /// What the cards' buttons and keys do. Also what the menu-bar icon uses.
    func overlayActions(settings: CaptureSettings) -> CaptureOverlayActions {
        var actions = CaptureOverlayActions(
            edit: { [weak self] image in
                self?.showEditor(image) { finished in
                    guard let finished else { return }
                    Task { @MainActor in await self?.deliver(finished, settings: settings, hidden: 0, original: image, edited: true) }
                }
            },
            copyText: { [weak self] in self?.copyText(from: $0) },
            pin: { PinnedShots.shared.pin(NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height))) },
            save: { [weak self] image, format in self?.saveFile(image, format: format, folder: settings.folder) },
            message: { [weak self] text, isError in self?.toast.show(text, isError: isError) }
        )
        actions.saveInFolder = { [weak self] image, format, folder in self?.saveFile(image, format: format, folder: folder) }
        actions.sendToShelf = { [weak self] in self?.sendToShelf($0) }
        actions.openHistory = { [weak self] in self?.openHistory() }
        actions.openSettings = { [weak self] in self?.openSettings() }
        actions.runCommand = { [weak self] in self?.run(command: $0) }
        actions.captureFolder = { settings.folder }
        actions.recordingElapsed = { [weak self] in
            guard let self else { return nil }
            if self.recording.isRecording { return self.recording.recorder.elapsed }
            return self.systemRecordingStart.map { Date().timeIntervalSince($0) }
        }
        actions.savedAreas = { [weak self] in
            CaptureExtraSettings.modes.areas(layout: AreaPicker.currentLayout, frontApp: NSWorkspace.shared.frontmostApplication?.bundleIdentifier).map { ($0.name, $0.command) }
        }
        actions.hasMenuCapture = { [weak self] in self?.hasMenuCapture ?? false }
        actions.recordingKind = { [weak self] in
            switch self?.recordingKind {
            case .kriya: return .kriya
            case .macOS: return .macOS
            case nil: return .none
            }
        }
        actions.shortcutText = { command in
            settings.shortcuts.first { $0.command == command }.map { KeyNames.describe(keyCode: $0.keyCode, modifiers: $0.modifiers) }
        }
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
    /// untouched copy of an edited capture. `stem` is a name the person typed (without its extension); it gets the same "@2x" and the
    /// same counter on a clash as a made-up name would, and a stem that cannot be a file name falls back to the usual pattern.
    @discardableResult
    func save(_ image: CGImage, to folder: URL, now: Date = Date(), format: CaptureFormat = CaptureExtraSettings.format, original: Bool = false, stem: String? = nil) -> String? {
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let output = deliveryPolicy().output
            let scale = request?.backingScale ?? Self.pointerScale()
            let exists: (String) -> Bool = { manager.fileExists(atPath: folder.appendingPathComponent($0).path) }
            let suffix: (String) -> String = { output.retinaSuffix(for: $0, backingScale: scale, untouched: original) }
            // "@2x" goes on a Retina picture written at its full size, unless the name already has one.
            let name = stem.flatMap { FileNameEntry.finalName(typed: $0, ext: format.fileExtension, existing: exists, suffix: suffix) }
                ?? CaptureNaming.fileName(pattern: settings.settings.namePattern, date: now, app: frontApp, mode: original ? "original" : "capture", ext: format.fileExtension,
                                          existing: exists, suffix: suffix)
            // Converted to sRGB just before writing when that is asked for, in every format; the original kept beside an edit is not.
            guard let data = image.data(as: format, convertToSRGB: output.convertToSRGB && !original) else { return nil }
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
