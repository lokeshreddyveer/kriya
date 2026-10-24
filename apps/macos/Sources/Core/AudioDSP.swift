import Foundation

/// The ten equaliser bands, in hertz, and how far each can be moved.
enum EQBands {
    static let frequencies: [Float] = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    static let limit: Float = 12
    static let count = frequencies.count

    static func clamped(_ gains: [Float]) -> [Float] {
        var g = gains.prefix(count).map { min(max($0, -limit), limit) }
        while g.count < count { g.append(0) }
        return g
    }
}

struct BiquadCoefficients: Equatable {
    var b0: Float, b1: Float, b2: Float, a1: Float, a2: Float
    static let identity = BiquadCoefficients(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)

    /// A bell-shaped boost or cut around one frequency (the standard "peaking EQ" filter).
    static func peaking(frequency: Float, gainDB: Float, q: Float = 1.1, sampleRate: Float) -> BiquadCoefficients {
        guard abs(gainDB) > 0.01, sampleRate > 0, frequency < sampleRate * 0.45 else { return .identity }
        let a = powf(10, gainDB / 40)
        let w0 = 2 * Float.pi * frequency / sampleRate
        let alpha = sinf(w0) / (2 * q)
        let cosw = cosf(w0)
        let a0 = 1 + alpha / a
        return BiquadCoefficients(b0: (1 + alpha * a) / a0, b1: (-2 * cosw) / a0, b2: (1 - alpha * a) / a0, a1: (-2 * cosw) / a0, a2: (1 - alpha / a) / a0)
    }
}

/// What to do to one app's sound (or the whole system's): louder or softer, silent, shaped by the equaliser.
/// Runs on the audio thread, so it never allocates or waits.
final class AudioProcessor {
    static let maxChannels = 8

    private var lock = os_unfair_lock_s()
    private var coefficients = [BiquadCoefficients](repeating: .identity, count: EQBands.count)
    private var flat = true
    // One pair of memory cells per band, per channel.
    private var z1 = [Float](repeating: 0, count: EQBands.count * AudioProcessor.maxChannels)
    private var z2 = [Float](repeating: 0, count: EQBands.count * AudioProcessor.maxChannels)
    private var currentGain: Float = 1
    private var currentPreamp: Float = 1

    /// Set from any thread; read on the audio thread.
    var targetGain: Float = 1
    var muted = false
    /// Gain in front of the equaliser, from the preamp setting (1 is unchanged).
    var preampGain: Float = 1
    /// -1 all left, 0 centred, 1 all right.
    var balance: Float = 0
    /// A timed mute or turn-down on top of everything else; 1 does nothing.
    var tempGain: Float = 1
    /// Audio Unit effects that run before the equaliser. Set from the main thread, tried (never waited for) on the audio thread.
    private var chainLock = os_unfair_lock_s()
    private var chain: AudioUnitChain?

    func setChain(_ next: AudioUnitChain?) {
        os_unfair_lock_lock(&chainLock)
        chain = next
        os_unfair_lock_unlock(&chainLock)
    }
    /// Loudest sample in the last buffer, 0...1+, for the activity meter.
    private(set) var peak: Float = 0

    func setEQ(gains: [Float], sampleRate: Float) {
        let g = EQBands.clamped(gains)
        let c = zip(EQBands.frequencies, g).map { BiquadCoefficients.peaking(frequency: $0, gainDB: $1, sampleRate: sampleRate) }
        os_unfair_lock_lock(&lock)
        coefficients = c
        flat = g.allSatisfy { abs($0) < 0.01 }
        os_unfair_lock_unlock(&lock)
    }

    /// Treats `frames` frames of `channels` interleaved channels. Input and output may be the same memory.
    /// `firstChannel` says which channel of the whole stream the first one here is (for separate buffers per channel).
    func process(input: UnsafePointer<Float>, output: UnsafeMutablePointer<Float>, frames: Int, channels: Int, firstChannel: Int = 0) {
        guard frames > 0, channels > 0 else { return }
        var source = input
        if channels == 2, os_unfair_lock_trylock(&chainLock) {
            if let chain, !chain.isEmpty {
                if UnsafeRawPointer(input) != UnsafeRawPointer(output) { memcpy(output, input, frames * 2 * MemoryLayout<Float>.size) }
                chain.process(output, frames: frames)
                source = UnsafePointer(output)
            }
            os_unfair_lock_unlock(&chainLock)
        }
        let locked = os_unfair_lock_trylock(&lock)
        let useEQ = locked && !flat
        let start = currentGain
        let end = muted ? 0 : targetGain * tempGain
        currentGain = end
        let step = (end - start) / Float(frames)
        let preStart = currentPreamp
        let preEnd = preampGain
        currentPreamp = preEnd
        let preStep = (preEnd - preStart) / Float(frames)
        let sides = SoundBalance.gains(balance)
        var maxSample: Float = 0
        for frame in 0..<frames {
            let g = start + step * Float(frame)
            let pre = preStart + preStep * Float(frame)
            for ch in 0..<channels {
                let index = frame * channels + ch
                var x = source[index] * pre
                if useEQ {
                    let slot = min(firstChannel + ch, Self.maxChannels - 1)
                    for band in 0..<EQBands.count {
                        let c = coefficients[band]
                        if c == .identity { continue }
                        let s = band * Self.maxChannels + slot
                        let y = c.b0 * x + z1[s]
                        z1[s] = c.b1 * x - c.a1 * y + z2[s]
                        z2[s] = c.b2 * x - c.a2 * y
                        x = y
                    }
                }
                let channel = firstChannel + ch
                let side: Float = channel == 0 ? sides.left : (channel == 1 ? sides.right : 1)
                x = Self.softClip(x * g * side)
                maxSample = max(maxSample, abs(x))
                output[index] = x
            }
        }
        peak = maxSample
        if locked { os_unfair_lock_unlock(&lock) }
    }

    /// Passes quiet sound untouched and bends loud peaks smoothly under 1, so boosting past 100% does not crackle.
    static func softClip(_ x: Float) -> Float {
        let knee: Float = 0.8
        let a = abs(x)
        if a <= knee { return x }
        let over = (a - knee) / (1 - knee)
        let shaped = knee + (1 - knee) * (over / (1 + over))
        return x < 0 ? -shaped : shaped
    }
}

/// Ready-made equaliser shapes, in decibels for each of the ten bands.
enum EQPreset: String, CaseIterable, Identifiable, Codable {
    case flat, bassBoost, trebleBoost, vocal, smallSpeakers, loudness, headphones, lateNight
    var id: String { rawValue }

    var title: String {
        switch self {
        case .flat: return "Flat"
        case .bassBoost: return "Bass Boost"
        case .trebleBoost: return "Treble Boost"
        case .vocal: return "Voice"
        case .smallSpeakers: return "Small Speakers (Magic Boost)"
        case .loudness: return "Loudness"
        case .headphones: return "Headphones"
        case .lateNight: return "Late Night"
        }
    }

    var gains: [Float] {
        switch self {
        case .flat: return [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        case .bassBoost: return [6, 5, 4, 2, 0, 0, 0, 0, 0, 0]
        case .trebleBoost: return [0, 0, 0, 0, 0, 1, 3, 5, 6, 6]
        case .vocal: return [-3, -2, -1, 1, 3, 4, 3, 1, 0, -1]
        case .smallSpeakers: return [5, 5, 4, 2, 0, 0, 1, 2, 3, 2]
        case .loudness: return [5, 4, 2, 0, -1, -1, 0, 2, 4, 5]
        case .headphones: return [3, 2, 1, 0, 0, -1, 0, 1, 2, 1]
        case .lateNight: return [-4, -3, -1, 1, 2, 3, 2, 0, -2, -3]
        }
    }

    /// The preset these gains match, if any.
    static func matching(_ gains: [Float]) -> EQPreset? {
        let g = EQBands.clamped(gains)
        return allCases.first { zip($0.gains, g).allSatisfy { abs($0 - $1) < 0.05 } }
    }
}

/// What one app (or the whole system) is set to. The default does nothing, and an app set to the default is left alone.
struct AppAudioSettings: Codable, Equatable {
    /// 1 is unchanged; 0...4 (up to 400%).
    var volume: Double = 1
    var muted = false
    /// UIDs of the output devices. Empty means the Mac's current output. More than one plays on all of them at once.
    var outputs: [String] = []
    var eq: [Float] = EQPreset.flat.gains
    /// Gain in front of the equaliser, in decibels, -12...12.
    var preamp: Float = 0
    /// -1 all left, 0 centred, 1 all right.
    var balance: Float = 0
    /// Plays the sound without the equaliser, preamp and balance, keeping them set for later.
    var effectsBypassed = false
    /// Adds the small-speaker shaping and a little gain, for laptop and monitor speakers.
    var magicBoost = false
    /// Audio Unit effects, in the order they run after the built-in ones.
    var plugins: [PluginRef] = []

    static let maxVolume = 4.0

    init() {}

    // Settings saved before the preamp, balance and bypass existed have no such keys; they load as unchanged.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        volume = try c.decodeIfPresent(Double.self, forKey: .volume) ?? 1
        muted = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        outputs = try c.decodeIfPresent([String].self, forKey: .outputs) ?? []
        eq = try c.decodeIfPresent([Float].self, forKey: .eq) ?? EQPreset.flat.gains
        preamp = try c.decodeIfPresent(Float.self, forKey: .preamp) ?? 0
        balance = try c.decodeIfPresent(Float.self, forKey: .balance) ?? 0
        effectsBypassed = try c.decodeIfPresent(Bool.self, forKey: .effectsBypassed) ?? false
        magicBoost = try c.decodeIfPresent(Bool.self, forKey: .magicBoost) ?? false
        plugins = try c.decodeIfPresent([PluginRef].self, forKey: .plugins) ?? []
    }

    /// Whether the equaliser, preamp and balance all do nothing.
    var effectsAreFlat: Bool { eq.allSatisfy { abs($0) < 0.01 } && abs(preamp) < 0.05 && abs(balance) < 0.01 && !magicBoost && plugins.isEmpty }

    var isDefault: Bool { abs(volume - 1) < 0.005 && !muted && outputs.isEmpty && effectsAreFlat }

    var clamped: AppAudioSettings {
        var s = self
        s.volume = min(max(volume, 0), Self.maxVolume)
        s.eq = EQBands.clamped(eq)
        s.preamp = min(max(preamp, -SoundPreamp.limit), SoundPreamp.limit)
        s.balance = min(max(balance, -1), 1)
        return s
    }
}

/// A named set of settings that can be given to any app.
struct AppAudioProfile: Codable, Equatable, Identifiable {
    var id = UUID().uuidString
    var name: String
    var settings: AppAudioSettings
}
