import AppKit
import CoreAudio

/// Runs the sound rules: watches for sound devices coming and going and for apps opening and quitting, and does what the
/// matching rules say.
final class SoundRuleRunner: ObservableObject {
    private static let key = "soundRules.v1"
    private static let modesKey = "soundModes.v1"
    private static let historyKey = "soundDeviceHistory.v1"
    private static let snapshotKey = "soundSnapshot.v1"
    private static let snapshotTimeKey = "soundSnapshotTime.v1"
    /// A remembered state older than this is not trusted: the person has probably changed the sound since.
    static let snapshotMaxAge: TimeInterval = 4 * 3600
    @Published var rules: [SoundRule] { didSet { save() } }
    /// Meeting, presentation and any the person made: turned on together, and turned off to put the sound back.
    @Published var modes: [SoundMode] { didSet { if let data = try? JSONEncoder().encode(modes) { defaults.set(data, forKey: Self.modesKey) } } }
    @Published private(set) var activeModeID: String?
    @Published private(set) var history: DeviceHistory { didSet { if let data = try? JSONEncoder().encode(history) { defaults.set(data, forKey: Self.historyKey) } } }
    /// How the sound was before Kriya first changed it; kept so "Put the sound back" has something to put back.
    @Published private(set) var snapshot: SoundSnapshot? {
        didSet {
            if let data = snapshot.flatMap({ try? JSONEncoder().encode($0) }) {
                defaults.set(data, forKey: Self.snapshotKey)
                defaults.set(Date(), forKey: Self.snapshotTimeKey)
            } else {
                defaults.removeObject(forKey: Self.snapshotKey)
                defaults.removeObject(forKey: Self.snapshotTimeKey)
            }
        }
    }

    /// Remembers how the sound is now, unless it was remembered recently (then that earlier state is the one to go back to).
    private func rememberSoundIfNeeded() {
        let age = defaults.object(forKey: Self.snapshotTimeKey).flatMap { $0 as? Date }.map { Date().timeIntervalSince($0) }
        if snapshot == nil || (age ?? .infinity) > Self.snapshotMaxAge { snapshot = currentSnapshot() }
    }

    private let audio = AudioControl.shared
    private let toast = Toast()
    private var knownDevices: Set<String> = []
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        rules = (defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([SoundRule].self, from: $0) }) ?? []
        modes = defaults.data(forKey: Self.modesKey).flatMap { try? JSONDecoder().decode([SoundMode].self, from: $0) } ?? SoundMode.starters
        history = defaults.data(forKey: Self.historyKey).flatMap { try? JSONDecoder().decode(DeviceHistory.self, from: $0) } ?? DeviceHistory()
        snapshot = defaults.data(forKey: Self.snapshotKey).flatMap { try? JSONDecoder().decode(SoundSnapshot.self, from: $0) }
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
        let now = Set(audio.devices().map(\.name))
        let change = SoundRules.difference(old: knownDevices, new: now)
        knownDevices = now
        // The history is kept whether or not there are rules, so a flaky device shows its pattern.
        for name in change.added { history.record(name, connected: true) }
        for name in change.removed { history.record(name, connected: false) }
        guard rules.contains(where: { $0.enabled }) else { return }
        for name in change.added { handle(.deviceConnected(name: name)) }
        for name in change.removed { handle(.deviceDisconnected(name: name)) }
    }

    func clearHistory() { history.clear() }

    // MARK: Modes

    /// How the sound is right now, for putting it back later.
    func currentSnapshot() -> SoundSnapshot {
        let output = audio.defaultDevice(input: false)
        let input = audio.defaultDevice(input: true)
        let name: (AudioDeviceID?) -> String? = { id in id.flatMap { id in audio.devices().first { $0.id == id }?.name } }
        return SoundSnapshot(
            outputName: name(output), inputName: name(input),
            volumePercent: output.flatMap { audio.volume(of: $0) }.map { Int(($0 * 100).rounded()) },
            soundMuted: output.flatMap { audio.isMuted($0) }, micMuted: input.flatMap { audio.isMuted($0, input: true) }
        )
    }

    /// Turns a mode on: remembers how the sound was (unless it was already remembered), then does what the mode says.
    func apply(_ mode: SoundMode) {
        rememberSoundIfNeeded()
        activeModeID = mode.id
        AuditLog.shared.record(.setting, "Sound mode “\(mode.name)” on")
        for action in mode.actions { perform(action, delay: 0) }
        toast.show("\(mode.name) mode on")
    }

    /// Puts the sound back how it was before Kriya changed it (a mode or a rule), and forgets the remembered state.
    func putSoundBack() {
        guard let snapshot else { toast.show("Kriya has not changed the sound."); return }
        for action in snapshot.restoreActions { perform(action, delay: 0, remember: false) }
        self.snapshot = nil
        activeModeID = nil
        AuditLog.shared.record(.setting, "Sound put back how it was")
        toast.show("Sound put back")
    }

    func toggle(_ mode: SoundMode) {
        if activeModeID == mode.id { putSoundBack() } else { apply(mode) }
    }

    func handle(_ event: SoundEvent) {
        for action in SoundRules.actions(for: event, rules: rules) { perform(action) }
    }

    /// `delay` gives a newly connected device a moment to be ready; a mode or a restore acts at once, in order. `remember` notes
    /// how the sound was before the first change, for "Put the sound back".
    private func perform(_ action: SoundAction, delay: TimeInterval = 1.0, remember: Bool = true) {
        if remember { rememberSoundIfNeeded() }
        switch action {
        case .useOutput(let name):
            let work = { [self] in
                if let device = audio.devices().first(where: { $0.isOutput && $0.name.lowercased().contains(name.lowercased()) }), audio.setDefault(device) { toast.show("Sound output: \(device.name)") }
            }
            if delay > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work) } else { work() }
        case .useInput(let name):
            let work = { [self] in
                if let device = audio.devices().first(where: { $0.isInput && $0.name.lowercased().contains(name.lowercased()) }), audio.setDefault(device) { toast.show("Microphone: \(device.name)") }
            }
            if delay > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work) } else { work() }
        case .connectBluetooth(let name), .disconnectBluetooth(let name):
            let connect: Bool
            if case .connectBluetooth = action { connect = true } else { connect = false }
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                guard let peer = BluetoothAudio.peer(named: name, in: BluetoothAudio.paired()) else {
                    DispatchQueue.main.async { self.toast.show("No paired Bluetooth device named “\(name)”.", isError: true) }
                    return
                }
                let ok = BluetoothAudio.set(connected: connect, address: peer.address)
                DispatchQueue.main.async { self.toast.show(ok ? "\(connect ? "Connected" : "Disconnected") \(peer.name)" : "Could not \(connect ? "connect" : "disconnect") \(peer.name).", isError: !ok) }
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
