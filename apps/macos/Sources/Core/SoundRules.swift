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

    var title: String {
        switch self {
        case .useOutput(let s): return "play sound on \(s)"
        case .useInput(let s): return "use the \(s) microphone"
        case .muteMic(let on): return on ? "mute the microphone" : "unmute the microphone"
        case .muteSound(let on): return on ? "mute the sound" : "unmute the sound"
        case .setVolume(let p): return "set the volume to \(p)%"
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
