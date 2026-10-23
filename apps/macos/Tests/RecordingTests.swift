import XCTest
@testable import Kriya

final class RecordingTests: XCTestCase {
    func testNothingPausedWritesTimesAsTheyCame() {
        var clock = PauseClock(frameDuration: 0.1)
        XCTAssertEqual(clock.video(at: 0), 0)
        XCTAssertEqual(clock.video(at: 0.1), 0.1)
        XCTAssertEqual(clock.audio(at: 0.15), 0.15)
    }

    func testAPauseIsCutOutAndTheNextFrameFollowsTheLastByOneFrame() throws {
        var clock = PauseClock(frameDuration: 0.1)
        _ = clock.video(at: 0)
        _ = clock.video(at: 1.0)
        clock.pause()
        XCTAssertNil(clock.video(at: 3.0), "frames while paused are dropped")
        XCTAssertNil(clock.audio(at: 3.0), "so is sound")
        clock.resume()
        XCTAssertNil(clock.audio(at: 9.0), "sound waits for the first frame after a pause")
        let first = try XCTUnwrap(clock.video(at: 10.0))
        XCTAssertEqual(first, 1.1, accuracy: 0.0001, "one frame after the last one written")
        XCTAssertEqual(try XCTUnwrap(clock.video(at: 10.5)), 1.6, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(clock.audio(at: 10.2)), 1.3, accuracy: 0.0001, "sound moves by the same amount")
    }

    func testPausingTwiceKeepsCuttingTime() throws {
        var clock = PauseClock(frameDuration: 0.5)
        _ = clock.video(at: 0)
        clock.pause(); clock.resume()
        let a = try XCTUnwrap(clock.video(at: 5))
        XCTAssertEqual(a, 0.5, accuracy: 0.0001)
        clock.pause(); clock.resume()
        let b = try XCTUnwrap(clock.video(at: 20))
        XCTAssertEqual(b, 1.0, accuracy: 0.0001)
    }

    func testSoundBeforeTheFirstFrameIsDropped() {
        let clock = PauseClock()
        XCTAssertNil(clock.audio(at: -0.2))
    }

    func testResumeWithoutPauseDoesNothing() {
        var clock = PauseClock(frameDuration: 0.1)
        _ = clock.video(at: 0)
        clock.resume()
        XCTAssertEqual(clock.video(at: 0.1), 0.1)
    }

    func testKeyLabelsShowModifiersAndNames() {
        XCTAssertEqual(KeystrokeLabel.label(keyCode: 21, characters: "4", modifiers: [.command, .shift]), "⇧⌘4")
        XCTAssertEqual(KeystrokeLabel.label(keyCode: 36, characters: "\r", modifiers: []), "Return")
        XCTAssertEqual(KeystrokeLabel.label(keyCode: 0, characters: "a", modifiers: []), "A")
        XCTAssertEqual(KeystrokeLabel.label(keyCode: 123, characters: nil, modifiers: [.option]), "⌥←")
        XCTAssertNil(KeystrokeLabel.label(keyCode: 0, characters: "a", modifiers: [], secureInput: true), "a password field is never shown")
        XCTAssertNil(KeystrokeLabel.label(keyCode: 200, characters: nil, modifiers: []))
    }

    func testRepeatedKeysAreCountedAndOldOnesFade() {
        var strip = KeystrokeStrip()
        strip.add("A", at: 0)
        strip.add("A", at: 0.2)
        strip.add("A", at: 0.4)
        XCTAssertEqual(strip.text(at: 0.5), "A ×3")
        strip.add("B", at: 0.6)
        XCTAssertEqual(strip.text(at: 0.7), "A ×3  B")
        XCTAssertEqual(strip.text(at: 2.1), "B", "A has faded")
        strip.prune(at: 5)
        XCTAssertEqual(strip.text(at: 5), "")
    }

    func testTheStripKeepsOnlyTheLastFew() {
        var strip = KeystrokeStrip()
        strip.capacity = 3
        for (index, key) in ["A", "B", "C", "D", "E"].enumerated() { strip.add(key, at: Double(index) * 0.01) }
        XCTAssertEqual(strip.text(at: 0.1), "C  D  E")
    }

    func testOptionsAreMadeUsable() {
        var options = RecordingOptions()
        options.framesPerSecond = 29
        options.hdr = true
        let fixed = options.sanitized(hdrAvailable: false)
        XCTAssertEqual(fixed.framesPerSecond, 30)
        XCTAssertFalse(fixed.hdr, "HDR is turned off where it is not available")
        XCTAssertTrue(options.sanitized(hdrAvailable: true).hdr)
        options.systemAudio = true
        options.microphone = true
        XCTAssertEqual(options.audioTrackCount, 2)
    }

    func testRecordingFileNamesDoNotClash() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let first = RecordingFileName.make(for: date)
        XCTAssertTrue(first.hasPrefix("Kriya Recording ") && first.hasSuffix(".mov"))
        XCTAssertNotEqual(RecordingFileName.make(for: date) { $0 == first }, first)
    }

    func testRecordingSettingsSavedBeforeTheRecorderStillLoad() throws {
        let old = #"{"copyImage":true,"saveToFolder":true,"folderPath":"","openEditor":false,"redactAutomatically":false,"delaySeconds":0,"playSound":false,"redactWords":[],"shortcuts":[]}"#
        let decoded = try JSONDecoder().decode(CaptureSettings.self, from: Data(old.utf8))
        XCTAssertEqual(decoded.recording, RecordingOptions())
    }

    func testBitRateStaysInASaneRange() {
        XCTAssertGreaterThanOrEqual(ScreenRecorder.bitRate(width: 320, height: 200, fps: 15, hdr: false), 2_000_000)
        XCTAssertLessThanOrEqual(ScreenRecorder.bitRate(width: 7680, height: 4320, fps: 60, hdr: true), 80_000_000)
    }
}
