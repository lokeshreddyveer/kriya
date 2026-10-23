import Foundation

/// One message from a MIDI device, reduced to what a trigger can match.
struct MIDIMessage: Equatable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case noteOn, controlChange, programChange
        var id: String { rawValue }
        var title: String {
            switch self {
            case .noteOn: return "Note"
            case .controlChange: return "Knob or slider"
            case .programChange: return "Program"
            }
        }
    }

    var kind: Kind
    /// 1 to 16.
    var channel: Int
    /// The note, controller or program number, 0 to 127.
    var number: Int
    /// How hard or how far, 0 to 127 (a program change has none).
    var value: Int

    /// Every message in a run of MIDI bytes. Notes off, clock and anything else are skipped; a note on with no force is a note off.
    static func parse(_ bytes: [UInt8]) -> [MIDIMessage] {
        var out: [MIDIMessage] = []
        var i = 0
        while i < bytes.count {
            let status = bytes[i]
            guard status >= 0x80 else { i += 1; continue }
            let channel = Int(status & 0x0F) + 1
            switch status & 0xF0 {
            case 0x90, 0xB0:
                guard i + 2 < bytes.count, bytes[i + 1] < 0x80, bytes[i + 2] < 0x80 else { i += 1; continue }
                let isNote = status & 0xF0 == 0x90
                if !isNote || bytes[i + 2] > 0 { out.append(MIDIMessage(kind: isNote ? .noteOn : .controlChange, channel: channel, number: Int(bytes[i + 1]), value: Int(bytes[i + 2]))) }
                i += 3
            case 0xC0:
                guard i + 1 < bytes.count, bytes[i + 1] < 0x80 else { i += 1; continue }
                out.append(MIDIMessage(kind: .programChange, channel: channel, number: Int(bytes[i + 1]), value: 0))
                i += 2
            case 0x80, 0xA0, 0xE0: i += 3
            case 0xD0: i += 2
            default: i += 1
            }
        }
        return out
    }
}

/// What a MIDI trigger runs: a Kriya command, a saved action or a workflow, by id.
struct MIDITrigger: Codable, Equatable, Identifiable {
    enum Target: String, Codable, CaseIterable, Identifiable {
        case command, action, workflow
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    var id = UUID().uuidString
    var name = ""
    var kind = MIDIMessage.Kind.noteOn
    /// Nil means any channel.
    var channel: Int?
    var number = 60
    /// A knob only fires between these values; a note, from its minimum force.
    var minValue = 1
    var maxValue = 127
    var target = Target.workflow
    var targetID = ""
    var enabled = true

    var summary: String {
        "\(kind.title) \(number)\(channel.map { " on channel \($0)" } ?? "")"
    }

    func matches(_ message: MIDIMessage) -> Bool {
        enabled && message.kind == kind && message.number == number && (channel == nil || channel == message.channel)
            && message.value >= minValue && message.value <= maxValue
    }

    /// The request this trigger makes, or nil when its target id is not a valid name.
    var remoteCommand: RemoteCommand? {
        guard RemoteCommand.isValidID(targetID) else { return nil }
        switch target {
        case .command: return .command(targetID)
        case .action: return .action(targetID)
        case .workflow: return .workflow(targetID)
        }
    }
}

enum MIDITriggers {
    static let limit = 60
    /// A pad held down or a knob turned sends many messages; the same trigger is not fired again within this time.
    static let cooldown: TimeInterval = 0.25

    static func firing(for message: MIDIMessage, in triggers: [MIDITrigger]) -> [MIDITrigger] {
        triggers.filter { $0.matches(message) && $0.remoteCommand != nil }
    }

    /// A trigger made from a message just heard, for "learn".
    static func learned(from message: MIDIMessage) -> MIDITrigger {
        var trigger = MIDITrigger()
        trigger.kind = message.kind
        trigger.channel = message.channel
        trigger.number = message.number
        trigger.minValue = message.kind == .controlChange ? 0 : 1
        trigger.name = "\(trigger.summary)"
        return trigger
    }
}
