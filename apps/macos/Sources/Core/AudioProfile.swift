import Foundation

/// The volume each sound device was last left at, by name, so it comes back at that level when it reconnects.
struct DeviceVolumes: Codable, Equatable {
    static let capacity = 60
    private(set) var levels: [String: Int] = [:]

    mutating func remember(_ name: String, percent: Int) {
        guard !name.isEmpty else { return }
        if levels[name] == nil, levels.count >= Self.capacity, let drop = levels.keys.sorted().first { levels[drop] = nil }
        levels[name] = min(max(percent, 0), 100)
    }

    func level(for name: String) -> Int? { levels[name] }
    mutating func forget(_ name: String) { levels[name] = nil }
    mutating func clear() { levels = [:] }
}

/// Everything the sound rules hold, in one file that can be saved and loaded on another Mac.
struct AudioProfile: Codable, Equatable {
    static let currentVersion = 1
    static let limit = 200

    enum Problem: Error, Equatable, LocalizedError {
        case unreadable, newer(Int), tooLarge
        var errorDescription: String? {
            switch self {
            case .unreadable: return "That file is not a Kriya sound profile."
            case .newer(let v): return "That profile was made by a newer Kriya (format \(v)). Update Kriya to read it."
            case .tooLarge: return "That profile holds too many rules or modes."
            }
        }
    }

    var version = AudioProfile.currentVersion
    var rules: [SoundRule] = []
    var modes: [SoundMode] = []
    var deviceVolumes: DeviceVolumes = DeviceVolumes()

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    /// Reads a profile, refusing a file from a newer format or one that is far too large. Volumes are kept between 0 and 100.
    static func decode(_ data: Data) throws -> AudioProfile {
        guard data.count < 1_000_000, var profile = try? JSONDecoder().decode(AudioProfile.self, from: data) else { throw Problem.unreadable }
        guard profile.version <= currentVersion else { throw Problem.newer(profile.version) }
        guard profile.rules.count <= limit, profile.modes.count <= limit else { throw Problem.tooLarge }
        func clamp(_ action: SoundAction) -> SoundAction {
            if case .setVolume(let p) = action { return .setVolume(percent: min(max(p, 0), 100)) }
            return action
        }
        for i in profile.rules.indices { profile.rules[i].action = clamp(profile.rules[i].action) }
        for i in profile.modes.indices { profile.modes[i].actions = profile.modes[i].actions.map(clamp) }
        var volumes = DeviceVolumes()
        for (name, percent) in profile.deviceVolumes.levels { volumes.remember(name, percent: percent) }
        profile.deviceVolumes = volumes
        return profile
    }
}

/// A plain test tone for checking the speakers, left and right.
enum ToneGenerator {
    static let range: ClosedRange<Double> = 20...20_000

    /// A sine wave with a short fade at each end so it does not click. Amplitude stays low; this is for checking, not for volume.
    static func samples(frequency: Double, seconds: Double, sampleRate: Double = 44_100, amplitude: Double = 0.25) -> [Float] {
        let hz = min(max(frequency.isFinite ? frequency : 440, range.lowerBound), range.upperBound)
        let length = min(max(seconds.isFinite ? seconds : 1, 0.1), 5)
        let gain = min(max(amplitude.isFinite ? amplitude : 0.25, 0), 0.5)
        let count = Int(length * sampleRate)
        let fade = max(1, Int(0.01 * sampleRate))
        return (0..<count).map { i in
            let envelope = min(1, Double(i) / Double(fade), Double(count - 1 - i) / Double(fade))
            return Float(sin(2 * .pi * hz * Double(i) / sampleRate) * gain * max(0, envelope))
        }
    }
}

/// Cutting a recording down to part of it.
enum RecordingTrim {
    /// The part to keep, or nil when it is empty or outside the recording. An end past the recording is the end.
    static func range(start: Double, end: Double, duration: Double) -> (start: Double, end: Double)? {
        guard start.isFinite, end.isFinite, duration.isFinite, duration > 0 else { return nil }
        let from = max(start, 0), to = min(end, duration)
        return to - from >= 0.1 ? (from, to) : nil
    }

    /// "75", "1:15" or "1:15.5" as seconds.
    static func seconds(from text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var total = 0.0
        for part in parts {
            guard let value = Double(part), value >= 0, value.isFinite else { return nil }
            total = total * 60 + value
        }
        return total
    }
}
