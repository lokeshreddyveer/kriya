import CoreAudio
import Foundation

/// Keeps the sound on the best device as devices come and go. The person ranks their outputs (and inputs); when the one in use is
/// unplugged or disconnects, the best one still connected takes over, and when a better one reconnects it can take over again.
/// It acts only when the list of connected devices changes, so a device chosen by hand is never overridden.
final class DevicePriorityRunner: ObservableObject {
    static let shared = DevicePriorityRunner()
    private static let outputKey = "soundDevices.priority.v1"
    private static let inputKey = "soundDevices.inputPriority.v1"
    private static let enabledKey = "soundDevices.priorityEnabled"
    private static let switchBackKey = "soundDevices.switchBack"

    /// Output devices, best first, by unique name.
    @Published var outputPriority: [String] { didSet { UserDefaults.standard.set(outputPriority, forKey: Self.outputKey) } }
    @Published var inputPriority: [String] { didSet { UserDefaults.standard.set(inputPriority, forKey: Self.inputKey) } }
    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: Self.enabledKey); FeatureActivity.shared.changed("soundDevices", enabled ? "Turned on" : "Turned off"); enabled ? start() : stop() }
    }
    /// Whether a better device that reconnects takes over from the one in use.
    @Published var switchBack: Bool { didSet { UserDefaults.standard.set(switchBack, forKey: Self.switchBackKey) } }
    /// What the runner did last, for the Sound screen.
    @Published private(set) var lastAction: String?

    private let audio = AudioControl.shared
    private var started = false
    private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var pending: DispatchWorkItem?
    private var state: [Bool: Kind] = [:]

    /// What was true the last time the devices were settled, for one direction (output or input).
    private struct Kind {
        var connected: Set<String>
        var inUse: String?
    }

    private init() {
        let defaults = UserDefaults.standard
        outputPriority = defaults.stringArray(forKey: Self.outputKey) ?? []
        inputPriority = defaults.stringArray(forKey: Self.inputKey) ?? []
        enabled = defaults.bool(forKey: Self.enabledKey)
        switchBack = defaults.object(forKey: Self.switchBackKey) as? Bool ?? true
    }

    var isActive: Bool { started }

    func start() {
        guard enabled, !started else { return }
        started = true
        for input in [false, true] { state[input] = snapshot(input: input) }
        let system = AudioObjectID(kAudioObjectSystemObject)
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultInputDevice] {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.changed() }
            if AudioObjectAddPropertyListenerBlock(system, &address, DispatchQueue.main, block) == noErr { listeners.append((address, block)) }
        }
    }

    func stop() {
        guard started else { return }
        started = false
        let system = AudioObjectID(kAudioObjectSystemObject)
        for (address, block) in listeners {
            var a = address
            AudioObjectRemovePropertyListenerBlock(system, &a, DispatchQueue.main, block)
        }
        listeners = []
        pending?.cancel(); pending = nil
    }

    // MARK: Reacting

    private func snapshot(input: Bool) -> Kind {
        let devices = audio.devices().filter { input ? $0.isInput : $0.isOutput }
        let current = audio.defaultDevice(input: input).flatMap { audio.uid(of: $0) }
        return Kind(connected: Set(devices.map(\.uid)), inUse: current)
    }

    /// Devices announce a change in bursts (a Bluetooth headset adds several), so this waits a moment and then looks once.
    private func changed() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.settle() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func settle() {
        for input in [false, true] {
            let before = state[input] ?? snapshot(input: input)
            var now = snapshot(input: input)
            let list = input ? inputPriority : outputPriority
            if before.connected == now.connected {
                // Nothing came or went: whatever is in use now was chosen, by the person or by an app, and stays.
                state[input] = now
                continue
            }
            // The device in use before the change is the one that matters, even though macOS may already have moved on.
            if let reaction = DevicePolicy.reaction(previous: before.connected, now: now.connected, current: before.inUse, priority: list, switchBack: switchBack),
               reaction.switchTo != now.inUse, let target = audio.device(uid: reaction.switchTo) {
                if audio.setDefault(target) {
                    now.inUse = reaction.switchTo
                    let name = DeviceNames.shared.name(for: target)
                    lastAction = reaction.why == .inUseWentAway ? "Moved the sound to \(name), the best device still connected." : "\(name) is back, so the sound is on it again."
                    FeatureActivity.shared.changed("soundDevices", lastAction ?? "")
                }
            }
            state[input] = now
        }
    }

    // MARK: The lists

    func add(_ uid: String, input: Bool) {
        if input { inputPriority = DevicePolicy.adding(uid, to: inputPriority) } else { outputPriority = DevicePolicy.adding(uid, to: outputPriority) }
    }

    func remove(_ uid: String, input: Bool) {
        if input { inputPriority = DevicePolicy.removing(uid, from: inputPriority) } else { outputPriority = DevicePolicy.removing(uid, from: outputPriority) }
    }

    func move(_ uid: String, by offset: Int, input: Bool) {
        if input { inputPriority = DevicePolicy.moving(uid, by: offset, in: inputPriority) } else { outputPriority = DevicePolicy.moving(uid, by: offset, in: outputPriority) }
    }
}
