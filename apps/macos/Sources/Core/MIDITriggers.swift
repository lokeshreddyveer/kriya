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
    /// The device it came from, when known.
    var device = ""

    /// Every message in a run of MIDI bytes. Notes off, clock and anything else are skipped; a note on with no force is a note off.
    static func parse(_ bytes: [UInt8]) -> [MIDIMessage] {
        var running: UInt8?
        return parse(bytes, running: &running)
    }

    /// The same, keeping the last status between calls: a device may send the status byte once and then only data (running
    /// status). Real-time bytes (clock and the like) do not end it; a malformed message or a system message does.
    static func parse(_ bytes: [UInt8], running: inout UInt8?) -> [MIDIMessage] {
        var out: [MIDIMessage] = []
        var i = 0
        while i < bytes.count {
            var status = bytes[i]
            var dataStart = i + 1
            if status < 0x80 {
                guard let last = running else { i += 1; continue }
                status = last
                dataStart = i
            } else if status >= 0xF0 {
                if status < 0xF8 { running = nil }
                i += 1
                continue
            } else {
                running = status
            }
            let family = status & 0xF0
            let need = (family == 0xC0 || family == 0xD0) ? 1 : 2
            guard dataStart + need <= bytes.count, bytes[dataStart..<dataStart + need].allSatisfy({ $0 < 0x80 }) else {
                running = nil
                i += 1
                continue
            }
            let channel = Int(status & 0x0F) + 1
            let first = Int(bytes[dataStart])
            let second = need == 2 ? Int(bytes[dataStart + 1]) : 0
            switch family {
            case 0x90 where second > 0: out.append(MIDIMessage(kind: .noteOn, channel: channel, number: first, value: second))
            case 0xB0: out.append(MIDIMessage(kind: .controlChange, channel: channel, number: first, value: second))
            case 0xC0: out.append(MIDIMessage(kind: .programChange, channel: channel, number: first, value: 0))
            default: break
            }
            i = dataStart + need
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
    /// Part of the device's name; nil or empty means any device.
    var device: String?

    var summary: String {
        "\(kind.title) \(number)\(channel.map { " on channel \($0)" } ?? "")"
    }

    func matches(_ message: MIDIMessage) -> Bool {
        guard enabled, message.kind == kind, message.number == number, channel == nil || channel == message.channel,
              message.value >= minValue, message.value <= maxValue else { return false }
        let wanted = (device ?? "").trimmingCharacters(in: .whitespaces)
        return wanted.isEmpty || message.device.lowercased().contains(wanted.lowercased())
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

    /// Other switched-on triggers that would fire for some of the same messages, so the person is told before two things happen at once.
    static func conflicts(of trigger: MIDITrigger, in all: [MIDITrigger]) -> [MIDITrigger] {
        all.filter { other in
            guard other.id != trigger.id, other.enabled, trigger.enabled, other.kind == trigger.kind, other.number == trigger.number else { return false }
            if let a = other.channel, let b = trigger.channel, a != b { return false }
            let da = (other.device ?? "").lowercased(), db = (trigger.device ?? "").lowercased()
            if !da.isEmpty, !db.isEmpty, !da.contains(db), !db.contains(da) { return false }
            return max(other.minValue, trigger.minValue) <= min(other.maxValue, trigger.maxValue)
        }
    }

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
        trigger.device = message.device.isEmpty ? nil : message.device
        trigger.name = "\(trigger.summary)"
        return trigger
    }
}
