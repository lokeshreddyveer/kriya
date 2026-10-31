import Foundation

/// The sound made when a capture is taken.
enum CaptureSound: String, Codable, CaseIterable, Identifiable {
    /// Silence, whatever else is set.
    case none
    /// macOS's own screenshot sound.
    case system
    /// A camera shutter made by Kriya, so it is always there.
    case camera
    /// A sound file the person chose.
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "None"
        case .system: return "macOS screenshot sound"
        case .camera: return "Camera shutter"
        case .custom: return "A file I choose…"
        }
    }
}

/// Which sound, and the file for a custom one. Whether a sound plays at all is the older "Play the camera sound" switch.
struct SoundPolicy: Codable, Equatable {
    var choice: CaptureSound = .system
    var customPath = ""

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        choice = c.value(.choice, CaptureSound.system)
        customPath = c.value(.customPath, "")
    }

    var customURL: URL? { CaptureSoundFile.url(for: customPath) }
}

enum CaptureSoundFile {
    static let allowedExtensions: Set<String> = ["aif", "aiff", "wav", "caf", "mp3", "m4a"]

    /// The file for a path the person chose, or nil if the path is empty or is not a kind of sound file Kriya plays.
    static func url(for path: String) -> URL? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, allowedExtensions.contains((trimmed as NSString).pathExtension.lowercased()) else { return nil }
        return URL(fileURLWithPath: trimmed)
    }
}

/// What to try, in order, to make the sound: the first that works is the one heard. A sound that is not there (a deleted file, a
/// system sound a later macOS dropped) falls back to the next, and the last resort is the system beep, so a capture is never silent
/// by accident when a sound was asked for.
enum CaptureSoundPlan {
    enum Step: Equatable {
        case custom(URL), system, camera, beep

        /// The sound this step makes, for telling the person which one played.
        var sound: CaptureSound {
            switch self {
            case .custom: return .custom
            case .system: return .system
            case .camera: return .camera
            case .beep: return .system
            }
        }

        var name: String {
            switch self {
            case .custom: return "your sound file"
            case .system: return "the macOS screenshot sound"
            case .camera: return "the camera shutter"
            case .beep: return "the system beep"
            }
        }
    }

    static func steps(for policy: SoundPolicy) -> [Step] {
        switch policy.choice {
        case .none: return []
        case .system: return [.system, .camera, .beep]
        case .camera: return [.camera, .system, .beep]
        case .custom: return (policy.customURL.map { [Step.custom($0)] } ?? []) + [.camera, .system, .beep]
        }
    }
}

/// Plays one step. The real one uses the Mac's sound; a check supplies its own.
protocol CaptureSoundBackend: AnyObject {
    /// Whether the sound started.
    func play(_ step: CaptureSoundPlan.Step) -> Bool
}

/// What happened when a sound was asked for.
struct CaptureSoundOutcome: Equatable {
    enum Result: Equatable {
        /// No sound was wanted: it is off, or "None" is chosen.
        case silent
        case played(CaptureSoundPlan.Step)
        /// Every way of making a sound failed.
        case failed
    }

    var result: Result
    /// The sound that was chosen but could not be played, when something else was played instead.
    var skipped: [CaptureSoundPlan.Step] = []

    /// A sentence for the person, or nil when all went as chosen.
    var message: String? {
        switch result {
        case .silent: return nil
        case .failed: return "No sound could be played. Check the Mac's output volume and the sound file."
        case .played(let step):
            guard let first = skipped.first else { return nil }
            return "Could not play \(first.name), so \(step.name) was played instead."
        }
    }
}

/// The one place the capture sound is made. Settings, the capture itself and the Preview button all go through `play`.
final class CaptureSoundPlayer {
    let backend: CaptureSoundBackend

    init(backend: CaptureSoundBackend) { self.backend = backend }

    /// The sound for a capture. Nothing is played when sounds are off, or when "None" is chosen.
    @discardableResult
    func play(enabled: Bool, policy: SoundPolicy) -> CaptureSoundOutcome {
        guard enabled else { return CaptureSoundOutcome(result: .silent) }
        return run(policy)
    }

    /// The Preview button: plays the chosen sound even while capture sounds are switched off, so it can be heard before turning them on.
    @discardableResult
    func preview(policy: SoundPolicy) -> CaptureSoundOutcome { run(policy) }

    private func run(_ policy: SoundPolicy) -> CaptureSoundOutcome {
        let steps = CaptureSoundPlan.steps(for: policy)
        guard !steps.isEmpty else { return CaptureSoundOutcome(result: .silent) }
        var skipped: [CaptureSoundPlan.Step] = []
        for step in steps {
            if backend.play(step) { return CaptureSoundOutcome(result: .played(step), skipped: skipped) }
            skipped.append(step)
        }
        return CaptureSoundOutcome(result: .failed, skipped: skipped)
    }
}

/// A camera shutter, made from nothing: two short clicks, each a burst of noise that dies away over a low thump. The same every time.
enum ShutterSynth {
    static let sampleRate = 44_100

    /// 16-bit mono samples between -1 and 1.
    static func samples() -> [Float] {
        let total = Int(Double(sampleRate) * 0.16)
        var out = [Float](repeating: 0, count: total)
        var seed: UInt32 = 0x1234_5678
        func noise() -> Float {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return Float(Int32(bitPattern: seed)) / Float(Int32.max)
        }
        // (start, length) in seconds: the shutter opening, then closing.
        for (start, length, level) in [(0.0, 0.030, Float(0.85)), (0.075, 0.045, Float(0.6))] {
            let first = Int(start * Double(sampleRate))
            let count = Int(length * Double(sampleRate))
            for i in 0..<count where first + i < total {
                let t = Float(i) / Float(count)
                let envelope = exp(-6 * t)
                let thump = sin(2 * Float.pi * 170 * Float(i) / Float(sampleRate)) * 0.35
                out[first + i] += (noise() * 0.65 + thump) * envelope * level
            }
        }
        let peak = max(out.map { abs($0) }.max() ?? 1, 0.0001)
        return out.map { $0 / peak * 0.8 }
    }

    /// The samples as a WAV file, which the system plays from memory.
    static func wav() -> Data {
        let pcm = samples().map { Int16(max(-1, min(1, $0)) * Float(Int16.max)) }
        var data = Data()
        func append32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = pcm.count * 2
        data.append(contentsOf: Array("RIFF".utf8)); append32(UInt32(36 + bytes)); data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append32(16); append16(1); append16(1)
        append32(UInt32(sampleRate)); append32(UInt32(sampleRate * 2)); append16(2); append16(16)
        data.append(contentsOf: Array("data".utf8)); append32(UInt32(bytes))
        for sample in pcm { append16(UInt16(bitPattern: sample)) }
        return data
    }
}
