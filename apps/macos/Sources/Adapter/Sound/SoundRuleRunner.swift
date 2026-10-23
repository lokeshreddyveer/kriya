import AppKit
import CoreAudio

/// Runs the sound rules: watches for sound devices coming and going and for apps opening and quitting, and does what the
/// matching rules say.
final class SoundRuleRunner: ObservableObject {
    private static let key = "soundRules.v1"
    @Published var rules: [SoundRule] { didSet { save() } }

    private let audio = AudioControl.shared
    private let toast = Toast()
    private var knownDevices: Set<String> = []
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        rules = (defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([SoundRule].self, from: $0) }) ?? []
    }

    func start() {
        guard timer == nil else { return }
        knownDevices = Set(audio.devices().map(\.name))
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.checkDevices() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        let center = NSWorkspace.shared.notificationCenter
        observers = [
            center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] n in
                if let id = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier { self?.handle(.appLaunched(bundleID: id)) }
            },
            center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] n in
                if let id = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier { self?.handle(.appQuit(bundleID: id)) }
            },
        ]
    }

    func stop() {
        timer?.invalidate(); timer = nil
        for o in observers { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        observers = []
    }

    private func checkDevices() {
        guard rules.contains(where: { $0.enabled }) else { knownDevices = Set(audio.devices().map(\.name)); return }
        let now = Set(audio.devices().map(\.name))
        let change = SoundRules.difference(old: knownDevices, new: now)
        knownDevices = now
        for name in change.added { handle(.deviceConnected(name: name)) }
        for name in change.removed { handle(.deviceDisconnected(name: name)) }
    }

    func handle(_ event: SoundEvent) {
        for action in SoundRules.actions(for: event, rules: rules) { perform(action) }
    }

    private func perform(_ action: SoundAction) {
        switch action {
        case .useOutput(let name):
            // Give a newly connected device a moment to be ready.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [self] in
                if let device = audio.devices().first(where: { $0.isOutput && $0.name.lowercased().contains(name.lowercased()) }), audio.setDefault(device) { toast.show("Sound output: \(device.name)") }
            }
        case .useInput(let name):
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [self] in
                if let device = audio.devices().first(where: { $0.isInput && $0.name.lowercased().contains(name.lowercased()) }), audio.setDefault(device) { toast.show("Microphone: \(device.name)") }
            }
        case .muteMic(let on):
            if let d = audio.defaultDevice(input: true), audio.setMuted(on, device: d, input: true) { toast.show(on ? "Microphone muted" : "Microphone on") }
        case .muteSound(let on):
            if let d = audio.defaultDevice(input: false), audio.setMuted(on, device: d) { toast.show(on ? "Sound muted" : "Sound on") }
        case .setVolume(let percent):
            audio.set(percent: percent)
        }
    }

    private func save() { if let data = try? JSONEncoder().encode(rules) { defaults.set(data, forKey: Self.key) } }
}
