import XCTest
import CoreAudio
@testable import Kriya

/// The audio callback's handling of buffer layouts: one interleaved buffer, a separate buffer for each channel, a different width in
/// and out, and buffers bigger than the scratch space. Built from plain memory, so no sound device is needed.
@available(macOS 14.2, *)
final class AudioRenderTests: XCTestCase {
    private final class Buffers {
        let list: UnsafeMutableAudioBufferListPointer
        private var storage: [UnsafeMutablePointer<Float>] = []

        /// `channels` and `values` describe each buffer: its channel count and the constant it is filled with (per channel).
        init(_ layout: [(channels: Int, values: [Float])], frames: Int) {
            list = AudioBufferList.allocate(maximumBuffers: layout.count)
            for (i, spec) in layout.enumerated() {
                let data = UnsafeMutablePointer<Float>.allocate(capacity: max(frames * spec.channels, 1))
                for f in 0..<frames { for c in 0..<spec.channels { data[f * spec.channels + c] = spec.values.isEmpty ? 0 : spec.values[c % spec.values.count] } }
                storage.append(data)
                list[i] = AudioBuffer(mNumberChannels: UInt32(spec.channels), mDataByteSize: UInt32(frames * spec.channels * MemoryLayout<Float>.size), mData: data)
            }
        }

        func sample(buffer: Int, frame: Int, channel: Int) -> Float {
            let b = list[buffer]
            return b.mData!.assumingMemoryBound(to: Float.self)[frame * Int(b.mNumberChannels) + channel]
        }

        deinit { storage.forEach { $0.deallocate() }; free(list.unsafeMutablePointer) }
    }

    private func run(_ processor: AudioProcessor, input: Buffers, output: Buffers) {
        let scratch = UnsafeMutablePointer<Float>.allocate(capacity: AudioSession.scratchFrames * AudioProcessor.maxChannels)
        defer { scratch.deallocate() }
        // Twice, so the gain ramp that follows a change has settled.
        for _ in 0..<2 { AudioSession.render(processor: processor, scratch: scratch, inputs: input.list, outputs: output.list) }
    }

    func testSeparateBuffersForLeftAndRightKeepTheirOwnChannel() {
        let p = AudioProcessor()
        p.balance = 1   // all to the right
        let input = Buffers([(1, [0.5]), (1, [0.25])], frames: 256)
        let output = Buffers([(1, []), (1, [])], frames: 256)
        run(p, input: input, output: output)
        XCTAssertEqual(output.sample(buffer: 0, frame: 100, channel: 0), 0, accuracy: 1e-6, "the left buffer is the left channel, so balance silences it")
        XCTAssertEqual(output.sample(buffer: 1, frame: 100, channel: 0), 0.25, accuracy: 1e-6, "the right buffer keeps the right channel's sound, not the left's")
    }

    func testSeparateBuffersPassThroughUntouchedAtUnity() {
        let p = AudioProcessor()
        let input = Buffers([(1, [0.5]), (1, [-0.25])], frames: 128)
        let output = Buffers([(1, []), (1, [])], frames: 128)
        run(p, input: input, output: output)
        for f in [0, 50, 127] {
            XCTAssertEqual(output.sample(buffer: 0, frame: f, channel: 0), 0.5, accuracy: 1e-6)
            XCTAssertEqual(output.sample(buffer: 1, frame: f, channel: 0), -0.25, accuracy: 1e-6)
        }
    }

    func testInterleavedStereoStillWorks() {
        let p = AudioProcessor()
        p.balance = -1   // all to the left
        let input = Buffers([(2, [0.5, 0.25])], frames: 64)
        let output = Buffers([(2, [])], frames: 64)
        run(p, input: input, output: output)
        XCTAssertEqual(output.sample(buffer: 0, frame: 10, channel: 0), 0.5, accuracy: 1e-6)
        XCTAssertEqual(output.sample(buffer: 0, frame: 10, channel: 1), 0, accuracy: 1e-6)
    }

    func testStereoInterleavedToSeparateOutputBuffersSplitsTheChannels() {
        let p = AudioProcessor()
        let input = Buffers([(2, [0.5, 0.25])], frames: 64)
        let output = Buffers([(1, []), (1, [])], frames: 64)
        run(p, input: input, output: output)
        XCTAssertEqual(output.sample(buffer: 0, frame: 5, channel: 0), 0.5, accuracy: 1e-6, "left to the first buffer")
        XCTAssertEqual(output.sample(buffer: 1, frame: 5, channel: 0), 0.25, accuracy: 1e-6, "right to the second, not the left again")
    }

    func testMonoFillsBothSidesOfAStereoOutput() {
        let p = AudioProcessor()
        let input = Buffers([(1, [0.4])], frames: 64)
        let output = Buffers([(2, [])], frames: 64)
        run(p, input: input, output: output)
        XCTAssertEqual(output.sample(buffer: 0, frame: 5, channel: 0), 0.4, accuracy: 1e-6)
        XCTAssertEqual(output.sample(buffer: 0, frame: 5, channel: 1), 0.4, accuracy: 1e-6)
    }

    func testBuffersBiggerThanTheScratchSpaceAreProcessedWholeNotCut() {
        let frames = AudioSession.scratchFrames * 2 + 123
        let p = AudioProcessor()
        p.targetGain = 0.5
        // Interleaved stereo, in place.
        let a = Buffers([(2, [0.8])], frames: frames), aOut = Buffers([(2, [])], frames: frames)
        run(p, input: a, output: aOut)
        XCTAssertEqual(aOut.sample(buffer: 0, frame: frames - 1, channel: 1), 0.4, accuracy: 1e-5, "the last frame is processed, not zero-filled")
        // Separate buffers, through the scratch space in pieces.
        let q = AudioProcessor()
        q.targetGain = 0.5
        let b = Buffers([(1, [0.8]), (1, [0.8])], frames: frames), bOut = Buffers([(1, []), (1, [])], frames: frames)
        run(q, input: b, output: bOut)
        for f in [0, AudioSession.scratchFrames - 1, AudioSession.scratchFrames, AudioSession.scratchFrames * 2, frames - 1] {
            XCTAssertEqual(bOut.sample(buffer: 1, frame: f, channel: 0), 0.4, accuracy: 1e-5, "frame \(f)")
        }
    }

    func testAnOutputLongerThanTheInputEndsInSilence() {
        let p = AudioProcessor()
        let input = Buffers([(2, [0.5])], frames: 32)
        let output = Buffers([(1, []), (1, [])], frames: 64)   // different layout, so the general path
        for i in 0..<64 { output.list[0].mData!.assumingMemoryBound(to: Float.self)[i] = 9 }
        run(p, input: input, output: output)
        XCTAssertEqual(output.sample(buffer: 0, frame: 10, channel: 0), 0.5, accuracy: 1e-6)
        XCTAssertEqual(output.sample(buffer: 0, frame: 40, channel: 0), 0, "the rest is silence, not what was in the buffer")
    }
}
