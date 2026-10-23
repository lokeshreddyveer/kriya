import CoreMIDI
import Foundation

/// Listens to every MIDI device that is connected and runs the triggers that match. Off until turned on; it reads note, knob
/// and program messages only, and keeps nothing of what is played.
final class MIDITriggerRunner: ObservableObject {
    static let shared = MIDITriggerRunner()
    private static let key = "midiTriggers.v1"
    private static let enabledKey = "midiTriggers.enabled"

    @Published var triggers: [MIDITrigger] { didSet { if let data = try? JSONEncoder().encode(triggers) { UserDefaults.standard.set(data, forKey: Self.key) } } }
    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: Self.enabledKey); if enabled { start() } else { stop() } }
    }
    @Published private(set) var lastHeard: MIDIMessage?
    @Published private(set) var learning = false
    @Published private(set) var sources = 0

    private var client = MIDIClientRef()
    private var port = MIDIPortRef()
    private var running = false
    /// The names of the connected devices, by the number each was connected under.
    private var sourceNames: [Int: String] = [:]
    /// The last status byte heard from each device, for devices that send it only once.
    private var runningStatus: [Int: UInt8] = [:]
    private let statusLock = NSLock()
    private var lastFired: [String: Date] = [:]

    private init() {
        triggers = UserDefaults.standard.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([MIDITrigger].self, from: $0) } ?? []
        enabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    func start() {
        guard enabled, !running else { return }
        let ok = MIDIClientCreateWithBlock("Kriya" as CFString, &client) { [weak self] notification in
            // A device was plugged in or removed: listen to the ones there now.
            if notification.pointee.messageID == .msgSetupChanged { DispatchQueue.main.async { self?.connectSources() } }
        }
        guard ok == noErr else { Log.warning("MIDI", "Could not start MIDI"); return }
        let made = MIDIInputPortCreateWithBlock(client, "Kriya input" as CFString, &port) { [weak self] list, refCon in
            let source = Int(bitPattern: refCon)
            var bytes: [UInt8] = []
            for packet in list.unsafeSequence() {
                let length = Int(packet.pointee.length)
                withUnsafeBytes(of: packet.pointee.data) { bytes.append(contentsOf: $0.prefix(length)) }
            }
            self?.statusLock.lock()
            var running = self?.runningStatus[source]
            let messages = MIDIMessage.parse(bytes, running: &running)
            self?.runningStatus[source] = running
            self?.statusLock.unlock()
            if !messages.isEmpty {
                DispatchQueue.main.async {
                    for var m in messages { m.device = self?.sourceNames[source] ?? ""; self?.handle(m) }
                }
            }
        }
        guard made == noErr else { MIDIClientDispose(client); return }
        running = true
        connectSources()
    }

    func stop() {
        guard running else { return }
        MIDIPortDispose(port)
        MIDIClientDispose(client)
        running = false
        sources = 0
        learning = false
    }

    private func connectSources() {
        let count = MIDIGetNumberOfSources()
        var names: [Int: String] = [:]
        for i in 0..<count {
            let source = MIDIGetSource(i)
            var name: Unmanaged<CFString>?
            MIDIObjectGetStringProperty(source, kMIDIPropertyDisplayName, &name)
            names[i + 1] = name?.takeRetainedValue() as String? ?? "Device \(i + 1)"
            MIDIPortConnectSource(port, source, UnsafeMutableRawPointer(bitPattern: i + 1))
        }
        sourceNames = names
        statusLock.lock(); runningStatus = [:]; statusLock.unlock()
        sources = count
    }

    func learn() { learning = true }

    private func handle(_ message: MIDIMessage) {
        FeatureTimings.shared.measure("MIDI message") { handleNow(message) }
    }

    private func handleNow(_ message: MIDIMessage) {
        lastHeard = message
        if learning {
            learning = false
            if triggers.count < MIDITriggers.limit { triggers.append(MIDITriggers.learned(from: message)) }
            return
        }
        for trigger in MIDITriggers.firing(for: message, in: triggers) {
            if let last = lastFired[trigger.id], Date().timeIntervalSince(last) < MIDITriggers.cooldown { continue }
            lastFired[trigger.id] = Date()
            Log.info("MIDI", "Trigger \(trigger.summary) fired")
            if let command = trigger.remoteCommand { RemoteCommands.shared?.perform(command) }
        }
    }
}
