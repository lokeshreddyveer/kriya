import AppKit
import AVFoundation
import Speech

/// Speak, and the words are typed into the app you are in. It listens only between the two presses of its shortcut, uses the
/// Mac's on-device recogniser, and keeps nothing.
final class DictationService: ObservableObject {
    static let serverKey = "dictation.allowServer"
    static let languageKey = "dictation.language"
    static let maxSeconds: TimeInterval = 120

    @Published private(set) var isListening = false
    @Published var allowServer: Bool { didSet { UserDefaults.standard.set(allowServer, forKey: Self.serverKey) } }
    @Published var language: String { didSet { UserDefaults.standard.set(language, forKey: Self.languageKey) } }

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?
    private var transcript = ""
    private var stopWork: DispatchWorkItem?
    /// True from the first press until listening has begun or been refused, so a second press during a permission prompt does nothing.
    private var starting = false
    private let hud = DictationHUD()
    private let toast = Toast()
    /// Types the finished text into the app in front. Set by the app.
    var insert: (String) -> Void = { _ in }

    init() {
        allowServer = UserDefaults.standard.bool(forKey: Self.serverKey)
        language = UserDefaults.standard.string(forKey: Self.languageKey) ?? Locale.current.identifier
    }

    static func languages() -> [Locale] {
        SFSpeechRecognizer.supportedLocales().sorted { ($0.localizedString(forIdentifier: $0.identifier) ?? "") < ($1.localizedString(forIdentifier: $1.identifier) ?? "") }
    }

    func toggle() { isListening ? stop() : start() }

    func start() {
        guard !isListening, !starting else { return }
        starting = true
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                guard status == .authorized else { self?.starting = false; self?.toast.show("Allow Speech Recognition for Kriya in System Settings › Privacy & Security.", isError: true); return }
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    DispatchQueue.main.async {
                        guard granted else { self?.starting = false; self?.toast.show("Allow the Microphone for Kriya in System Settings › Privacy & Security.", isError: true); return }
                        self?.begin()
                    }
                }
            }
        }
    }

    private func begin() {
        defer { starting = false }
        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language)) ?? SFSpeechRecognizer()
        guard let recognizer, recognizer.isAvailable else { toast.show("Speech recognition is not available right now.", isError: true); return }
        if !recognizer.supportsOnDeviceRecognition && !allowServer {
            toast.show("On-device dictation is not available for this language. You can allow Apple's servers in Settings › Sound, but your speech would then leave this Mac.", isError: true)
            return
        }
        self.recognizer = recognizer
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        self.request = request
        transcript = ""
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in request.append(buffer) }
        do { engine.prepare(); try engine.start() } catch { toast.show("The microphone could not be started.", isError: true); cleanup(); return }
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let result {
                    self.transcript = result.bestTranscription.formattedString
                    self.hud.update(self.transcript)
                    if result.isFinal { self.finish() }
                }
                if error != nil, self.isListening { self.finish() }
            }
        }
        isListening = true
        hud.show("Listening…")
        let work = DispatchWorkItem { [weak self] in self?.stop() }
        stopWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.maxSeconds, execute: work)
    }

    /// Ends the recording; the text is typed once the recogniser has finished with what it heard.
    func stop() {
        guard isListening else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        // If the recogniser does not call back, finish with what it has.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in if self?.isListening == true { self?.finish() } }
    }

    private func finish() {
        guard isListening else { return }
        let text = DictationText.process(transcript)
        cleanup()
        guard !text.isEmpty else { toast.show("Nothing was heard."); return }
        insert(text)
    }

    private func cleanup() {
        stopWork?.cancel(); stopWork = nil
        if engine.isRunning { engine.stop(); engine.inputNode.removeTap(onBus: 0) }
        task?.cancel(); task = nil
        request = nil
        isListening = false
        hud.hide()
    }
}

/// A small pill that shows what is being heard.
final class DictationHUD {
    private var panel: NSPanel?
    private let label = NSTextField(labelWithString: "")

    func show(_ text: String) {
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 44), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false; p.backgroundColor = .clear; p.level = .floating; p.hasShadow = true; p.ignoresMouseEvents = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.applyPopupPrivacy()
            let box = NSVisualEffectView(frame: p.contentView!.bounds)
            box.material = .hudWindow; box.state = .active; box.wantsLayer = true; box.layer?.cornerRadius = 22; box.layer?.masksToBounds = true
            let dot = NSView(frame: NSRect(x: 16, y: 17, width: 10, height: 10)); dot.wantsLayer = true; dot.layer?.backgroundColor = NSColor.systemRed.cgColor; dot.layer?.cornerRadius = 5
            label.frame = NSRect(x: 36, y: 12, width: 370, height: 20)
            label.font = .systemFont(ofSize: 14, weight: .medium); label.lineBreakMode = .byTruncatingHead
            box.addSubview(dot); box.addSubview(label)
            p.contentView = box
            panel = p
        }
        label.stringValue = text
        if let screen = NSScreen.main, let p = panel {
            p.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - 210, y: screen.visibleFrame.minY + 90))
            p.orderFrontRegardless()
        }
    }

    func update(_ text: String) { label.stringValue = text.isEmpty ? "Listening…" : text }
    func hide() { panel?.orderOut(nil) }
}
