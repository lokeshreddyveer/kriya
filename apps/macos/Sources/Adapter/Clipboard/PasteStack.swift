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
final class Speaker {
    private let synthesizer = AVSpeechSynthesizer()
    private let toast = Toast()

    func toggle() {
        if synthesizer.isSpeaking { stop(); return }
        let text = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else {
            toast.show("There is no text on the clipboard to read", isError: true)
            return
        }
        // Long text is cut so one command never talks for many minutes by accident.
        synthesizer.speak(AVSpeechUtterance(string: String(text.prefix(8000))))
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }
}
