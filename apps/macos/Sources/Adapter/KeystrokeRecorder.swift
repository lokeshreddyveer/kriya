import AppKit
import SwiftUI

/// Listens to the keyboard while a recording is on, and keeps only the key codes and modifiers, in order. It does not look at
/// what the keys type, never writes anything down, and stops the moment the sheet closes.
final class KeystrokeRecorder: ObservableObject {
    @Published private(set) var keys: [RecordedKey] = []
    @Published private(set) var clicks: [RecordedClick] = []
    @Published private(set) var isRecording = false
    /// Whether mouse clicks are kept too. Only where they land and with which button, never what is under them.
    var includeClicks = false
    private var clickToken: EventMonitor.Token?

    private let events: EventMonitor
    private var token: EventMonitor.Token?
    private var started = Date()

    init(events: EventMonitor) { self.events = events }

    func start() {
        guard token == nil else { return }
        keys = []
        clicks = []
        started = Date()
        isRecording = true
        startClicks()
        token = events.subscribe(owner: "actions.record", events: [.keyDown], mode: .listenOnly) { [weak self] _, event in
            guard let self, event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return .passThrough }
            let code = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
            let mods = KeyModifiers.bits(from: event.flags) & ~KeyModifiers.function
            let at = Date().timeIntervalSince(self.started)
            DispatchQueue.main.async {
                guard self.isRecording, self.keys.count < KeystrokeRecording.maxSteps + 5 else { return }
                self.keys.append(RecordedKey(keyCode: code, modifiers: mods, time: at))
            }
            return .passThrough
        }
    }

    func stop() {
        if let token { events.unsubscribe(token) }
        if let clickToken { events.unsubscribe(clickToken) }
        clickToken = nil
        token = nil
        isRecording = false
    }

    func clear() { keys = []; clicks = [] }

    private func startClicks() {
        guard includeClicks, clickToken == nil else { return }
        clickToken = events.subscribe(owner: "actions.record.clicks", events: [.leftMouseDown, .rightMouseDown], mode: .listenOnly) { [weak self] type, event in
            guard let self else { return .passThrough }
            let point = event.location
            let right = type == .rightMouseDown
            let count = Int(event.getIntegerValueField(.mouseEventClickState))
            let at = Date().timeIntervalSince(self.started)
            DispatchQueue.main.async {
                // A click on Kriya's own recorder window (Stop, Cancel) is not part of what is being recorded.
                guard self.isRecording, !NSApp.isActive, self.clicks.count < KeystrokeRecording.maxSteps else { return }
                let frame = AXWindow.focused()?.frame?.cg
                self.clicks.append(RecordedClick.make(point: point, window: frame, right: right, count: count, time: at))
            }
            return .passThrough
        }
    }
}
