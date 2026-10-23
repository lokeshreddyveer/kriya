import XCTest
@testable import Kriya

final class AudioDSPTests: XCTestCase {
    private func sine(frequency: Float, rate: Float = 48_000, frames: Int = 24_000) -> [Float] {
        (0..<frames).map { 0.1 * sinf(2 * .pi * frequency * Float($0) / rate) }
    }

    private func run(_ p: AudioProcessor, _ input: [Float], channels: Int = 1) -> [Float] {
        var out = [Float](repeating: 0, count: input.count)
        input.withUnsafeBufferPointer { i in out.withUnsafeMutableBufferPointer { o in
            p.process(input: i.baseAddress!, output: o.baseAddress!, frames: input.count / channels, channels: channels)
        } }
        return out
    }

    private func rms(_ x: ArraySlice<Float>) -> Float { (x.map { $0 * $0 }.reduce(0, +) / Float(x.count)).squareRoot() }

    func testUnchangedByDefault() {
        let p = AudioProcessor()
        let x = sine(frequency: 440)
        let y = run(p, x)
        XCTAssertEqual(rms(y[1000...]), rms(x[1000...]), accuracy: 0.0005)
    }

    func testGainMuteAndRamp() {
        let p = AudioProcessor()
        p.targetGain = 0.5
        let y = run(p, [Float](repeating: 0.4, count: 4800))
        XCTAssertEqual(y.last!, 0.2, accuracy: 0.01)
        XCTAssertGreaterThan(y[0], 0.3, "it eases down instead of jumping")
        p.muted = true
        XCTAssertEqual(run(p, [Float](repeating: 0.4, count: 4800)).last!, 0, accuracy: 0.0001)
    }

    func testBoostNeverPassesFullScale() {
        let p = AudioProcessor()
        p.targetGain = 4
        let y = run(p, sine(frequency: 300).map { $0 * 9 })
        XCTAssertLessThanOrEqual(y.map { abs($0) }.max()!, 1.0)
    }

    func testPeakingFilterBoostsOnlyNearItsFrequency() {
        let p = AudioProcessor()
        var gains = [Float](repeating: 0, count: 10); gains[5] = 12   // 1 kHz
        p.setEQ(gains: gains, sampleRate: 48_000)
        let atCenter = run(p, sine(frequency: 1000))
        let p2 = AudioProcessor(); p2.setEQ(gains: gains, sampleRate: 48_000)
        let far = run(p2, sine(frequency: 62))
        let center = rms(atCenter[8000...]) / rms(sine(frequency: 1000)[8000...])
        let away = rms(far[8000...]) / rms(sine(frequency: 62)[8000...])
        XCTAssertEqual(20 * log10f(center), 12, accuracy: 1.0)
        XCTAssertEqual(20 * log10f(away), 0, accuracy: 0.6)
    }

    func testStereoChannelsKeepSeparateState() {
        let p = AudioProcessor()
        p.targetGain = 0.5
        let interleaved = (0..<2000).flatMap { _ in [Float(0.4), Float(0)] }
        let y = run(p, interleaved, channels: 2)
        XCTAssertEqual(y[y.count - 2], 0.2, accuracy: 0.01)
        XCTAssertEqual(y[y.count - 1], 0, accuracy: 0.0001)
    }

    func testPresetsAndSettings() {
        XCTAssertEqual(EQPreset.matching(EQPreset.vocal.gains), .vocal)
        XCTAssertNil(EQPreset.matching([1, 2, 3, 0, 0, 0, 0, 0, 0, 0]))
        XCTAssertTrue(AppAudioSettings().isDefault)
        var s = AppAudioSettings(); s.volume = 9
        XCTAssertEqual(s.clamped.volume, 4)
        s.volume = 1; s.outputs = ["x"]
        XCTAssertFalse(s.isDefault)
        XCTAssertEqual(EQBands.clamped([40, -40]).count, 10)
        XCTAssertEqual(EQBands.clamped([40, -40])[0], 12)
    }

    func testSoundRulesMatchEvents() {
        let rules = [
            SoundRule(trigger: .deviceConnected(contains: "airpods"), action: .useOutput(nameContains: "AirPods")),
            SoundRule(trigger: .appQuit(bundleID: "us.zoom.xos"), action: .muteMic(true)),
            SoundRule(trigger: .appQuit(bundleID: "us.zoom.xos"), action: .setVolume(percent: 30), enabled: false),
        ]
        XCTAssertEqual(SoundRules.actions(for: .deviceConnected(name: "Lokesh's AirPods Pro"), rules: rules), [.useOutput(nameContains: "AirPods")])
        XCTAssertEqual(SoundRules.actions(for: .appQuit(bundleID: "us.zoom.xos"), rules: rules), [.muteMic(true)])
        XCTAssertTrue(SoundRules.actions(for: .appLaunched(bundleID: "us.zoom.xos"), rules: rules).isEmpty)
        let d = SoundRules.difference(old: ["a", "b"], new: ["b", "c"])
        XCTAssertEqual(d.added, ["c"]); XCTAssertEqual(d.removed, ["a"])
    }
}
