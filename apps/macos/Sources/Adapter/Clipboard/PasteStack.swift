import AppKit
import AVFoundation

/// Paste several copied items one after another. While it is on, everything copied is added to a line, and each ⌘V pastes
/// the next one in the order they were copied.
final class PasteStack: ObservableObject {
    private typealias Saved = [[NSPasteboard.PasteboardType: Data]]

    private let events: EventMonitor
    private let toast = Toast()
    private var token: EventMonitor.Token?
    private var timer: Timer?
    private var queue: [Saved] = []       // main thread
    private var lastCount = NSPasteboard.general.changeCount
    private let lock = NSLock()
    private var pasting = false           // guarded by lock: ⌘V with something waiting in the line

    init(events: EventMonitor) {
        self.events = events
    }

    @Published private(set) var active = false
    var isOn: Bool { token != nil }

    func toggle() {
        isOn ? stop() : start()
    }

    func start() {
        guard token == nil else { return }
        queue.removeAll()
        lastCount = NSPasteboard.general.changeCount
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.poll() }
        token = events.subscribe(owner: "clipboard.stack", events: [.keyDown], mode: .active) { [weak self] _, event in
            self?.keyDown(event) ?? .passThrough
        }
        active = true
        toast.show("Paste stack on: copy several things, then paste them in order")
    }

    func stop() {
        if let token { events.unsubscribe(token) }
        token = nil
        timer?.invalidate()
        timer = nil
        queue.removeAll()
        active = false
        toast.show("Paste stack off")
    }

    /// Adds whatever was just copied to the end of the line.
    private func poll() {
        let board = NSPasteboard.general
        guard board.changeCount != lastCount else { return }
        lastCount = board.changeCount
        let saved: Saved = (board.pasteboardItems ?? []).map { item in
            var copy: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types { if let data = item.data(forType: type) { copy[type] = data } }
            return copy
        }
        guard !saved.isEmpty else { return }
        queue.append(saved)
        toast.show("Added: \(queue.count) in the stack")
    }

    /// ⌘V: the next item in the line is put on the clipboard just before the paste goes through.
    private func keyDown(_ event: CGEvent) -> EventDisposition {
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let mods = KeyModifiers.bits(from: event.flags) & ~KeyModifiers.function
        guard code == 9, mods == KeyModifiers.command, event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return .passThrough }
        // Taken on the main thread, synchronously, so the clipboard is ready before the app reads it.
        let take = { [self] in
            guard !queue.isEmpty else { return }
            let next = queue.removeFirst()
            let board = NSPasteboard.general
            board.clearContents()
            for item in next {
                let pasteboardItem = NSPasteboardItem()
                for (type, data) in item { pasteboardItem.setData(data, forType: type) }
                board.writeObjects([pasteboardItem])
            }
            lastCount = board.changeCount
            if queue.isEmpty { toast.show("That was the last one") } else { toast.show("\(queue.count) more in the stack") }
        }
        if Thread.isMainThread { take() } else { DispatchQueue.main.sync(execute: take) }
        return .passThrough
    }
}

/// Reads text aloud with the system voice. Asked again while speaking, it stops.
final class Speaker: ObservableObject {
    private static let voiceKey = "speech.voice", rateKey = "speech.rate", pitchKey = "speech.pitch"
    private let synthesizer = AVSpeechSynthesizer()
    private let toast = Toast()

    /// The chosen voice's identifier. Empty means the system voice.
    @Published var voiceID: String { didSet { UserDefaults.standard.set(voiceID, forKey: Self.voiceKey) } }
    /// 0...1 on the system's own scale; the default is about 0.5.
    @Published var rate: Double { didSet { UserDefaults.standard.set(rate, forKey: Self.rateKey) } }
    @Published var pitch: Double { didSet { UserDefaults.standard.set(pitch, forKey: Self.pitchKey) } }

    init() {
        let d = UserDefaults.standard
        voiceID = d.string(forKey: Self.voiceKey) ?? ""
        rate = d.object(forKey: Self.rateKey) as? Double ?? Double(AVSpeechUtteranceDefaultSpeechRate)
        pitch = d.object(forKey: Self.pitchKey) as? Double ?? 1
    }

    /// The voices installed, the ones in the person's language first, better voices before plainer ones.
    static func voices() -> [AVSpeechSynthesisVoice] {
        let mine = Locale.current.language.languageCode?.identifier ?? "en"
        return AVSpeechSynthesisVoice.speechVoices().sorted { a, b in
            let am = a.language.hasPrefix(mine), bm = b.language.hasPrefix(mine)
            if am != bm { return am }
            if a.quality.rawValue != b.quality.rawValue { return a.quality.rawValue > b.quality.rawValue }
            return a.name < b.name
        }
    }

    func speak(_ text: String) {
        let utterance = AVSpeechUtterance(string: String(text.prefix(8000)))
        if !voiceID.isEmpty, let voice = AVSpeechSynthesisVoice(identifier: voiceID) { utterance.voice = voice }
        utterance.rate = Float(min(max(rate, Double(AVSpeechUtteranceMinimumSpeechRate)), Double(AVSpeechUtteranceMaximumSpeechRate)))
        utterance.pitchMultiplier = Float(min(max(pitch, 0.5), 2))
        synthesizer.speak(utterance)
    }

    func preview() {
        synthesizer.stopSpeaking(at: .immediate)
        speak("This is how Kriya will read text aloud to you.")
    }

    func toggle() {
        if synthesizer.isSpeaking { stop(); return }
        let text = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else {
            toast.show("There is no text on the clipboard to read", isError: true)
            return
        }
        // Long text is cut so one command never talks for many minutes by accident.
        speak(text)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }
}
