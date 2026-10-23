import AppKit

/// Makes the keyboard volume keys work on outputs that ignore them (many monitors over HDMI or DisplayPort). It steps in only
/// when the current output has no volume of its own; otherwise the keys are left to macOS. The volume it sets is Kriya's
/// "All sound" level, which needs macOS 14.2.
final class VolumeKeys {
    static let enabledKey = "volumeKeys.enabled"
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    private let events: EventMonitor
    private let engine: AppAudioEngine
    private let audio = AudioControl.shared
    private let toast = Toast()
    private var token: EventMonitor.Token?

    init(events: EventMonitor, engine: AppAudioEngine) {
        self.events = events
        self.engine = engine
    }

    func start() {
        guard token == nil else { return }
        // The media keys arrive as system-defined events (type 14).
        token = events.subscribe(owner: "sound.volumekeys", events: [CGEventType(rawValue: 14)!], mode: .active) { [weak self] _, event in
            guard let self, Self.isEnabled, AppAudioEngine.isSupported, let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else { return .passThrough }
            let data = ns.data1
            let code = (data & 0xFFFF0000) >> 16
            let down = ((data & 0xFF00) >> 8) == 0xA
            guard [0, 1, 7].contains(code) else { return .passThrough }
            // Only when this output cannot change its own volume.
            guard let out = self.audio.defaultDevice(input: false), self.audio.volume(of: out) == nil else { return .passThrough }
            if down { DispatchQueue.main.async { self.press(code) } }
            return .drop
        }
    }

    func stop() {
        if let token { events.unsubscribe(token) }
        token = nil
    }

    private func press(_ code: Int) {
        let key = AppAudioEngine.systemKey
        let now = engine.current(key)
        switch code {
        case 7:
            engine.update(key) { $0.muted.toggle() }
            toast.show(now.muted ? "Sound on" : "Sound muted")
        default:
            let level = VolumeKeys.next(now.volume, up: code == 0)
            engine.update(key) { $0.volume = level; $0.muted = false }
            toast.show("Volume \(Int((level * 100).rounded()))%")
        }
    }

    /// One step of a sixteenth, kept between silent and the output's own full level.
    static func next(_ volume: Double, up: Bool) -> Double {
        let v = min(max(volume, 0), 1)
        let step = 1.0 / 16
        return min(max((v + (up ? step : -step)) * 16, 0), 16).rounded() / 16
    }
}
