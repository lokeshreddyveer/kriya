import Foundation

/// Something that happened to the sound devices or the apps.
enum SoundEvent: Equatable {
    case deviceConnected(name: String)
    case deviceDisconnected(name: String)
    case appLaunched(bundleID: String)
    case appQuit(bundleID: String)
}

enum SoundTrigger: Codable, Equatable {
    case deviceConnected(contains: String)
    case deviceDisconnected(contains: String)
    case appLaunched(bundleID: String)
    case appQuit(bundleID: String)

    func matches(_ event: SoundEvent) -> Bool {
        switch (self, event) {
        case (.deviceConnected(let s), .deviceConnected(let name)), (.deviceDisconnected(let s), .deviceDisconnected(let name)):
            return !s.isEmpty && name.lowercased().contains(s.lowercased())
        case (.appLaunched(let a), .appLaunched(let b)), (.appQuit(let a), .appQuit(let b)):
            return a == b
        default: return false
        }
    }

    var title: String {
        switch self {
        case .deviceConnected(let s): return "\(s) connects"
        case .deviceDisconnected(let s): return "\(s) disconnects"
        case .appLaunched(let id): return "\(id) opens"
        case .appQuit(let id): return "\(id) quits"
        }
    }
}

enum SoundAction: Codable, Equatable {
    case useOutput(nameContains: String)
    case useInput(nameContains: String)
    case muteMic(Bool)
    case muteSound(Bool)
    case setVolume(percent: Int)
    /// Connects a paired Bluetooth audio device whose name contains this.
    case connectBluetooth(nameContains: String)
    case disconnectBluetooth(nameContains: String)

    var title: String {
        switch self {
        case .useOutput(let s): return "play sound on \(s)"
        case .useInput(let s): return "use the \(s) microphone"
        case .muteMic(let on): return on ? "mute the microphone" : "unmute the microphone"
        case .muteSound(let on): return on ? "mute the sound" : "unmute the sound"
        case .setVolume(let p): return "set the volume to \(p)%"
        case .connectBluetooth(let s): return "connect \(s)"
        case .disconnectBluetooth(let s): return "disconnect \(s)"
        }
    }
}

struct SoundRule: Codable, Equatable, Identifiable {
    var id = UUID().uuidString
    var trigger: SoundTrigger
    var action: SoundAction
    var enabled = true

    var summary: String { "When \(trigger.title), \(action.title)" }
}

enum SoundRules {
    /// What to do for an event, in the order the rules are listed.
    static func actions(for event: SoundEvent, rules: [SoundRule]) -> [SoundAction] {
        rules.filter { $0.enabled && $0.trigger.matches(event) }.map(\.action)
    }

    /// The events between two lists of names (devices or running apps).
    static func difference(old: Set<String>, new: Set<String>) -> (added: [String], removed: [String]) {
        (new.subtracting(old).sorted(), old.subtracting(new).sorted())
    }
}


/// A named set of sound changes to turn on together, such as for a meeting or a presentation.
struct SoundMode: Codable, Equatable, Identifiable {
    var id = UUID().uuidString
    var name: String
    var symbol = "speaker.wave.2"
    var actions: [SoundAction]

    /// Two to start with. They set only the volume, since device names differ; add the headset and microphone for your Mac.
    static let starters: [SoundMode] = [
        SoundMode(id: "meeting", name: "Meeting", symbol: "person.2.wave.2", actions: [.muteSound(false), .setVolume(percent: 60)]),
        SoundMode(id: "presentation", name: "Presentation", symbol: "play.rectangle", actions: [.muteSound(false), .setVolume(percent: 80)]),
    ]
}

/// How the sound was before Kriya changed it, so it can be put back.
struct SoundSnapshot: Codable, Equatable {
    var outputName: String?
    var inputName: String?
    var volumePercent: Int?
    var soundMuted: Bool?
    var micMuted: Bool?

    /// What to do to bring it back, in an order that works: the devices first, then the volume and mutes of the restored output.
    var restoreActions: [SoundAction] {
        var actions: [SoundAction] = []
        if let outputName, !outputName.isEmpty { actions.append(.useOutput(nameContains: outputName)) }
        if let inputName, !inputName.isEmpty { actions.append(.useInput(nameContains: inputName)) }
        if let volumePercent { actions.append(.setVolume(percent: min(max(volumePercent, 0), 100))) }
        if let soundMuted { actions.append(.muteSound(soundMuted)) }
        if let micMuted { actions.append(.muteMic(micMuted)) }
        return actions
    }
}

/// The sound devices that came and went, newest first, kept so a flaky headset or a dock shows its pattern.
struct DeviceHistory: Codable, Equatable {
    struct Event: Codable, Equatable, Identifiable {
        var id = UUID().uuidString
        var name: String
        var connected: Bool
        var at: Date
    }

    static let capacity = 100
    private(set) var events: [Event] = []

    mutating func record(_ name: String, connected: Bool, at date: Date = Date()) {
        events.insert(Event(name: name, connected: connected, at: date), at: 0)
        if events.count > Self.capacity { events.removeLast(events.count - Self.capacity) }
    }

    mutating func clear() { events = [] }

    /// How many times a device came back after going away: a high number is a flaky connection.
    func reconnects(of name: String) -> Int {
        events.filter { $0.name == name && $0.connected }.count - (events.contains { $0.name == name } ? 1 : 0)
    }
}
