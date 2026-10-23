import AVFoundation

/// Plays a short test tone out of the left, the right or both speakers, to check the sound and the balance.
final class ToneRunner {
    enum Side: String, CaseIterable, Identifiable {
        case left = "Left", both = "Both", right = "Right"
        var id: String { rawValue }
        var pan: Float { self == .left ? -1 : (self == .right ? 1 : 0) }
    }

    static let shared = ToneRunner()
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var attached = false

    func play(frequency: Double = 440, seconds: Double = 1, side: Side = .both) {
        let rate = 44_100.0
        let samples = ToneGenerator.samples(frequency: frequency, seconds: seconds, sampleRate: rate)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let left = buffer.floatChannelData?[0], let right = buffer.floatChannelData?[1] else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for (i, value) in samples.enumerated() {
            left[i] = side == .right ? 0 : value
            right[i] = side == .left ? 0 : value
        }
        if !attached {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            attached = true
        }
        player.stop()
        if !engine.isRunning { try? engine.start() }
        player.scheduleBuffer(buffer, at: nil, options: .interrupts)
        player.play()
    }
}
