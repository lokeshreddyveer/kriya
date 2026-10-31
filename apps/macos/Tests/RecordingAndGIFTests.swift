import XCTest
import AVFoundation
import ImageIO
import CoreVideo
@testable import Kriya

final class RecordingSettingsTests: XCTestCase {
    private func size(_ options: RecordingOptions, _ w: CGFloat, _ h: CGFloat, scale: CGFloat = 2) -> CGSize {
        options.recordedSize(pixels: CGSize(width: w, height: h), backingScale: scale)
    }

    // MARK: The new options and older files

    func testTheDefaultsChangeNothing() {
        let options = RecordingOptions()
        XCTAssertFalse(options.dimScreen)
        XCTAssertFalse(options.showCountdown)
        XCTAssertFalse(options.monoAudio)
        XCTAssertEqual(options.maximumResolution, .original)
        XCTAssertEqual(options.outputScale, .native)
        XCTAssertEqual(size(options, 3456, 2234), CGSize(width: 3456, height: 2234))
        XCTAssertEqual(options.systemAudioChannels, 2)
        XCTAssertEqual(options.countdown(selfTimer: 0), 0)
        XCTAssertEqual(options.countdown(selfTimer: 5), 5)
    }

    func testAnOlderFileLoadsAndTheNewOptionsAreSavedAndDamagedOnesAreIgnored() throws {
        let old = try JSONDecoder().decode(RecordingOptions.self, from: Data(#"{"framesPerSecond":60,"microphone":true}"#.utf8))
        XCTAssertEqual(old.framesPerSecond, 60)
        XCTAssertEqual(old.outputScale, .native)
        var options = RecordingOptions()
        options.dimScreen = true; options.showCountdown = true; options.monoAudio = true; options.maximumResolution = .p1080; options.outputScale = .oneX
        XCTAssertEqual(try JSONDecoder().decode(RecordingOptions.self, from: JSONEncoder().encode(options)), options)
        let damaged = try JSONDecoder().decode(RecordingOptions.self, from: Data(#"{"maximumResolution":"huge","outputScale":3,"monoAudio":"yes"}"#.utf8))
        XCTAssertEqual(damaged.maximumResolution, .original)
        XCTAssertEqual(damaged.outputScale, .native)
        XCTAssertFalse(damaged.monoAudio)
    }

    // MARK: Mono and the countdown

    func testMonoMixesTheMacsSoundToOneChannel() {
        var options = RecordingOptions()
        XCTAssertEqual(options.systemAudioChannels, 2)
        options.monoAudio = true
        XCTAssertEqual(options.systemAudioChannels, 1)
    }

    func testTheCountdownIsAtLeastThreeSecondsOrTheSelfTimersLongerTime() {
        var options = RecordingOptions()
        options.showCountdown = true
        XCTAssertEqual(options.countdown(selfTimer: 0), 3)
        XCTAssertEqual(options.countdown(selfTimer: 1), 3)
        XCTAssertEqual(options.countdown(selfTimer: 10), 10)
        options.showCountdown = false
        XCTAssertEqual(options.countdown(selfTimer: 0), 0, "off, only the self-timer counts")
    }

    // MARK: Size: clamped to the display and the encoder, scaled before export

    func testOneXBringsARetinaScreenToPointsBeforeItIsRecorded() {
        var options = RecordingOptions()
        options.outputScale = .oneX
        XCTAssertEqual(size(options, 2880, 1800), CGSize(width: 1440, height: 900))
        XCTAssertEqual(size(options, 1920, 1080, scale: 1), CGSize(width: 1920, height: 1080), "an ordinary screen is not shrunk")
    }

    func testTheLimitOnlyShrinksAndNeverEnlargesBeyondTheDisplay() {
        var options = RecordingOptions()
        options.maximumResolution = .p1080
        XCTAssertEqual(size(options, 3840, 2160), CGSize(width: 1920, height: 1080))
        XCTAssertEqual(size(options, 1280, 720), CGSize(width: 1280, height: 720), "a smaller display stays as it is")
    }

    func testScalingToOneXComesBeforeTheLimit() {
        var options = RecordingOptions()
        options.outputScale = .oneX
        options.maximumResolution = .p1080
        XCTAssertEqual(size(options, 2880, 1800), CGSize(width: 1440, height: 900), "already under 1080 high once at points")
        XCTAssertEqual(size(options, 5120, 2880), CGSize(width: 2560, height: 1440).applyingLimit(1080), "points first, then the limit")
    }

    func testTheEncoderLimitIsRespectedWhateverIsAsked() {
        let options = RecordingOptions()
        let big = size(options, 7680, 4320, scale: 1)
        XCTAssertLessThanOrEqual(max(big.width, big.height), 4096, "H.264 stops at 4096")
        XCTAssertEqual(big.width / big.height, 7680.0 / 4320.0, accuracy: 0.01, "the shape is kept")
        var hdr = RecordingOptions()
        hdr.hdr = true
        XCTAssertEqual(size(hdr, 7680, 4320, scale: 1), CGSize(width: 7680, height: 4320), "HEVC goes up to 8192")
        let huge = size(hdr, 16384, 8192, scale: 1)
        XCTAssertLessThanOrEqual(max(huge.width, huge.height), 8192)
    }

    func testTheEncoderLimitFitsOnlyWhatIsTooBig() {
        XCTAssertEqual(EncoderLimit.fit(CGSize(width: 3000, height: 2000), hevc: false), CGSize(width: 3000, height: 2000))
        XCTAssertEqual(EncoderLimit.fit(CGSize(width: 8192, height: 4096), hevc: false), CGSize(width: 4096, height: 2048))
        XCTAssertEqual(EncoderLimit.largestSide(hevc: true), 8192)
    }

    func testSizesAreAlwaysEvenAndAtLeastTwo() {
        let options = RecordingOptions()
        for (w, h) in [(2879.0, 1799.0), (1.0, 1.0), (3.0, 5.0), (1001.0, 333.0)] {
            let s = size(options, CGFloat(w), CGFloat(h), scale: 1)
            XCTAssertEqual(Int(s.width) % 2, 0, "\(w)x\(h)")
            XCTAssertEqual(Int(s.height) % 2, 0, "\(w)x\(h)")
            XCTAssertGreaterThanOrEqual(s.width, 2)
            XCTAssertGreaterThanOrEqual(s.height, 2)
        }
        XCTAssertEqual(size(options, 0, 0), CGSize(width: 2, height: 2), "nothing to record is still a valid size")
    }

    // MARK: Dimming only the displays not being recorded

    func testOnlyTheDisplaysNotBeingRecordedAreDimmed() {
        XCTAssertEqual(RecordingDim.displaysToDim(all: [1, 2, 3], recorded: 2), [1, 3])
        XCTAssertEqual(RecordingDim.displaysToDim(all: [1, 2], recorded: 1), [2])
    }

    func testNothingIsDimmedWithOneDisplayOrWhenTheRecordedOneIsNotKnown() {
        XCTAssertEqual(RecordingDim.displaysToDim(all: [1], recorded: 1), [], "dimming the only display would dim the recording")
        XCTAssertEqual(RecordingDim.displaysToDim(all: [1, 2], recorded: nil), [], "a guess could darken the recording")
        XCTAssertEqual(RecordingDim.displaysToDim(all: [1, 2], recorded: 9), [], "a display that is not connected")
        XCTAssertEqual(RecordingDim.displaysToDim(all: [], recorded: nil), [])
    }

    // MARK: The screen always comes back

    func testTheDimmingIsTakenAwayAndCanBeTakenAwayAgain() throws {
        let dim = ScreenDim()
        let displays = ScreenDim.connectedDisplays()
        try XCTSkipIf(displays.isEmpty, "needs a display")
        dim.show(on: [displays[0]])
        XCTAssertTrue(dim.isShowing)
        XCTAssertEqual(dim.dimmedDisplays, [displays[0]])
        dim.hide()
        XCTAssertFalse(dim.isShowing)
        dim.hide()
        XCTAssertFalse(dim.isShowing, "hiding twice is harmless")
    }

    func testAnUnknownDisplayDimsNothingAndShowingAgainReplacesTheLast() throws {
        let dim = ScreenDim()
        dim.show(on: [0xDEAD_BEEF])
        XCTAssertFalse(dim.isShowing)
        let displays = ScreenDim.connectedDisplays()
        try XCTSkipIf(displays.isEmpty, "needs a display")
        dim.show(on: [displays[0]])
        dim.show(on: [])
        XCTAssertFalse(dim.isShowing, "a new request replaces the old one")
    }

    func testDroppingTheDimmerPutsTheScreenBack() throws {
        let displays = ScreenDim.connectedDisplays()
        try XCTSkipIf(displays.isEmpty, "needs a display")
        func dimmers() -> Int { NSApp.windows.filter { $0.isVisible && $0.level == .screenSaver && $0.ignoresMouseEvents && $0.backgroundColor.alphaComponent > 0.3 }.count }
        let before = dimmers()
        autoreleasepool {
            let dim = ScreenDim()
            dim.show(on: [displays[0]])
            XCTAssertGreaterThan(dimmers(), before)
        }
        XCTAssertEqual(dimmers(), before, "dropping it puts the screen back")
    }
}

private extension CGSize {
    /// The size fitted to a limit on its shorter side, as the recorder does.
    func applyingLimit(_ limit: CGFloat) -> CGSize {
        let shorter = min(width, height)
        guard shorter > limit else { return self }
        return CGSize(width: (width * limit / shorter).rounded(), height: (height * limit / shorter).rounded())
    }
}

// MARK: - GIFs

final class GIFPlanTests: XCTestCase {
    // MARK: The options

    func testTheDefaultsAreWhatKriyaAlwaysDid() {
        let o = GIFOptions()
        XCTAssertEqual(o.frameRate, 10)
        XCTAssertEqual(o.resolution, .medium)
        XCTAssertEqual(o.quality, 1)
        XCTAssertFalse(o.optimize)
        XCTAssertEqual(o.maximumDuration, 30)
        XCTAssertEqual(o.colourLevels, 256, "every colour kept")
        XCTAssertEqual(o.frameDelay, 0.1, accuracy: 0.0001)
    }

    func testEverySettingIsKeptAndANullDurationMeansAllOfIt() throws {
        let o = GIFOptions(frameRate: 15, resolution: .large, quality: 0.5, optimize: true, maximumDuration: nil)
        let back = try JSONDecoder().decode(GIFOptions.self, from: JSONEncoder().encode(o))
        XCTAssertEqual(back, o)
        XCTAssertNil(back.maximumDuration, "all of it survives a save")
        XCTAssertEqual(try JSONDecoder().decode(GIFOptions.self, from: Data("{}".utf8)).maximumDuration, 30, "missing means the usual")
        XCTAssertEqual(try JSONDecoder().decode(GIFOptions.self, from: Data(#"{"maximumDuration":"x"}"#.utf8)).maximumDuration, 30, "damaged means the usual, not no limit")
        XCTAssertEqual(try JSONDecoder().decode(GIFOptions.self, from: Data(#"{"resolution":"gigantic","frameRate":"fast"}"#.utf8)), GIFOptions())
    }

    func testValuesAreHeldToWhatCanBeMade() {
        let wild = GIFOptions(frameRate: 999, resolution: .original, quality: -5, optimize: true, maximumDuration: 0).sanitized()
        XCTAssertEqual(wild.frameRate, 30)
        XCTAssertEqual(wild.quality, 0.1, accuracy: 0.0001)
        XCTAssertEqual(wild.maximumDuration, 1)
        XCTAssertEqual(GIFOptions(quality: .nan, maximumDuration: .nan).sanitized().quality, 1)
        XCTAssertEqual(GIFOptions(maximumDuration: .nan).sanitized().maximumDuration, 30)
        XCTAssertEqual(GIFOptions(frameRate: 12).sanitized().frameRate, 10)
        XCTAssertEqual(GIFOptions(maximumDuration: 9_999).sanitized().maximumDuration, 600)
    }

    func testEveryFrameRateHasADelayBrowsersWillShow() {
        for rate in GIFOptions.frameRates {
            let delay = GIFOptions(frameRate: rate).frameDelay
            XCTAssertGreaterThanOrEqual(delay, 0.02, "\(rate)")
            XCTAssertEqual(delay * 100, (delay * 100).rounded(), accuracy: 0.0001, "whole hundredths: \(rate)")
        }
    }

    func testLowerQualityMeansFewerColoursInSteps() {
        XCTAssertEqual(GIFOptions(quality: 0.1).colourLevels, 8)
        XCTAssertEqual(GIFOptions(quality: 1).colourLevels, 256)
        XCTAssertLessThan(GIFOptions(quality: 0.4).colourLevels, GIFOptions(quality: 0.8).colourLevels)
    }

    func testTheColourTableKeepsTheEndsAndReducesTheSteps() {
        let full = GIFColour.table(levels: 256)
        XCTAssertEqual(full, (0..<256).map { UInt8($0) })
        let four = GIFColour.table(levels: 4)
        XCTAssertEqual(four[0], 0)
        XCTAssertEqual(four[255], 255)
        XCTAssertEqual(Set(four).count, 4)
        XCTAssertEqual(GIFColour.table(levels: 1).count, 256, "never fewer than two")
        XCTAssertEqual(Set(GIFColour.table(levels: 1)).count, 2)
    }

    // MARK: Size

    func testResolutionLimitsTheWidthAndKeepsTheShape() {
        XCTAssertEqual(GIFResolution.small.outputSize(for: CGSize(width: 1920, height: 1080)), CGSize(width: 480, height: 270))
        XCTAssertEqual(GIFResolution.medium.outputSize(for: CGSize(width: 2880, height: 1800)), CGSize(width: 720, height: 450))
        XCTAssertEqual(GIFResolution.large.outputSize(for: CGSize(width: 1000, height: 500)), CGSize(width: 1000, height: 500), "never enlarged")
        XCTAssertEqual(GIFResolution.original.outputSize(for: CGSize(width: 4000, height: 3000)), CGSize(width: 4000, height: 3000))
        XCTAssertEqual(GIFResolution.allCases.map(\.maxWidth), [480, 720, 1280, nil])
    }

    // MARK: Which moments

    func testPicturesAreSpacedAtTheFrameRateFromTheStart() {
        let times = GIFPlan.frameTimes(duration: 2, options: GIFOptions(frameRate: 5, maximumDuration: nil))
        XCTAssertEqual(times.first, 0)
        XCTAssertEqual(times[1], 0.2, accuracy: 0.0001)
        XCTAssertLessThan(times.last ?? 9, 2)
        XCTAssertEqual(times.count, 10)
    }

    func testTheMaximumDurationCutsTheGIFShort() {
        let times = GIFPlan.frameTimes(duration: 120, options: GIFOptions(frameRate: 10, maximumDuration: 5))
        XCTAssertEqual(times.count, 51)
        XCTAssertLessThanOrEqual(times.last ?? 99, 5.0001)
        let whole = GIFPlan.frameTimes(duration: 12, options: GIFOptions(frameRate: 10, maximumDuration: nil))
        XCTAssertGreaterThan(whole.count, 100, "no limit uses the whole recording")
    }

    func testAShortRecordingIsNotPaddedAndNothingMakesNoGIF() {
        XCTAssertEqual(GIFPlan.frameTimes(duration: 0.5, options: GIFOptions(frameRate: 10)).count, 5)
        XCTAssertTrue(GIFPlan.frameTimes(duration: 0, options: GIFOptions()).isEmpty)
        XCTAssertTrue(GIFPlan.frameTimes(duration: .infinity, options: GIFOptions()).isEmpty)
        XCTAssertTrue(GIFPlan.frameTimes(duration: -3, options: GIFOptions()).isEmpty)
    }

    func testThereIsAHardLimitOnPictures() {
        let times = GIFPlan.frameTimes(duration: 100_000, options: GIFOptions(frameRate: 30, maximumDuration: nil))
        XCTAssertLessThanOrEqual(times.count, GIFOptions.hardFrameLimit)
    }

    func testMemoryLimitsHowManyPicturesALargeGIFCanHave() {
        XCTAssertGreaterThan(GIFPlan.memoryFrameLimit(for: CGSize(width: 720, height: 405)), 1_000)
        XCTAssertLessThan(GIFPlan.memoryFrameLimit(for: CGSize(width: 2880, height: 1800)), 100)
        XCTAssertGreaterThanOrEqual(GIFPlan.memoryFrameLimit(for: CGSize(width: 100_000, height: 100_000)), 1)
        XCTAssertLessThanOrEqual(GIFPlan.memoryFrameLimit(for: CGSize(width: 2, height: 2)), GIFOptions.hardFrameLimit)
    }

    // MARK: Merging repeated pictures

    func testRepeatedPicturesAreMergedAndTheTimeIsKept() {
        let plan = GIFPlan.collapse(repeats: [false, true, true, false, true, false], delay: 0.1)
        XCTAssertEqual(plan.map(\.index), [0, 3, 5])
        XCTAssertEqual(plan.map(\.delay).map { ($0 * 10).rounded() }, [3, 2, 1])
        XCTAssertEqual(plan.map(\.delay).reduce(0, +), 0.6, accuracy: 0.0001, "the length of the GIF does not change")
    }

    func testNothingIsMergedWhenNothingRepeatsOrWhenNotAsked() {
        XCTAssertEqual(GIFPlan.collapse(repeats: [false, false, false], delay: 0.1).count, 3)
        XCTAssertEqual(GIFPlan.all(count: 4, delay: 0.2).map(\.index), [0, 1, 2, 3])
        XCTAssertTrue(GIFPlan.all(count: 0, delay: 0.2).isEmpty)
        XCTAssertTrue(GIFPlan.collapse(repeats: [], delay: 0.1).isEmpty)
        XCTAssertEqual(GIFPlan.collapse(repeats: [true, true], delay: 0.1).count, 1, "a first picture that claims to repeat still starts the GIF")
    }

    func testTwoFramesAreTheSameWhenTheyAreAlmostIdentical() {
        let a = [UInt8](repeating: 100, count: GIFFrameSignature.width * GIFFrameSignature.height)
        var noisy = a
        noisy[0] = 160
        var different = a.map { $0 &+ 40 }
        XCTAssertTrue(GIFFrameSignature.same(a, a))
        XCTAssertTrue(GIFFrameSignature.same(a, noisy), "a blinking cursor is not a new picture")
        XCTAssertFalse(GIFFrameSignature.same(a, different))
        different = []
        XCTAssertFalse(GIFFrameSignature.same(a, different))
        XCTAssertFalse(GIFFrameSignature.same([], []))
    }

    // MARK: Disk space

    func testThereMustBeRoomForTheEstimateAndAMargin() {
        let estimate: Int64 = 50 * 1_024 * 1_024
        XCTAssertNil(GIFDisk.problem(estimated: estimate, free: estimate + GIFDisk.margin + 1))
        let problem = GIFDisk.problem(estimated: estimate, free: 10 * 1_024 * 1_024)
        XCTAssertNotNil(problem)
        XCTAssertTrue(problem?.contains("may not be room") == true)
        XCTAssertTrue(problem?.hasSuffix(".") == true)
        XCTAssertNil(GIFDisk.problem(estimated: estimate, free: nil), "space that cannot be read is not a reason to refuse")
    }

    func testWhileMakingItStopsWhenTheDiskIsNearlyFull() {
        XCTAssertTrue(GIFDisk.isTooLow(free: 1_000))
        XCTAssertFalse(GIFDisk.isTooLow(free: GIFDisk.margin))
        XCTAssertFalse(GIFDisk.isTooLow(free: nil))
    }

    func testTheEstimateGrowsWithSizeFramesAndQuality() {
        let small = GIFPlan.estimatedBytes(frames: 100, size: CGSize(width: 480, height: 270), options: GIFOptions())
        XCTAssertGreaterThan(GIFPlan.estimatedBytes(frames: 200, size: CGSize(width: 480, height: 270), options: GIFOptions()), small)
        XCTAssertGreaterThan(GIFPlan.estimatedBytes(frames: 100, size: CGSize(width: 960, height: 540), options: GIFOptions()), small)
        XCTAssertLessThan(GIFPlan.estimatedBytes(frames: 100, size: CGSize(width: 480, height: 270), options: GIFOptions(quality: 0.1)), small)
        XCTAssertEqual(GIFPlan.estimatedBytes(frames: 0, size: CGSize(width: 480, height: 270), options: GIFOptions()), 0)
    }

    func testEveryOutcomeHasASentence() {
        XCTAssertEqual(GIFOutcome.cancelled.message, "GIF cancelled.")
        XCTAssertTrue(GIFOutcome.saved(frames: 1, bytes: 2_048, note: nil).message.hasPrefix("GIF saved: 1 picture,"))
        XCTAssertTrue(GIFOutcome.saved(frames: 3, bytes: 2_048, note: "It was shortened.").message.hasSuffix("It was shortened."))
        XCTAssertEqual(GIFOutcome.failed("No room.").message, "No room.")
    }
}

// MARK: - Making a real GIF

final class GIFExporterTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("kriya-gif-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: folder) }

    /// A small movie of `seconds` at 10 pictures a second. `vary` makes every picture different; otherwise every picture is the same.
    private func movie(seconds: Double, vary: Bool) throws -> URL {
        let url = folder.appendingPathComponent("test-\(UUID().uuidString).mov")
        let width = 128, height = 96, fps: Int32 = 10
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let count = Int(seconds * Double(fps))
        for i in 0..<count {
            while !input.isReadyForMoreMediaData { usleep(1_000) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, try XCTUnwrap(adaptor.pixelBufferPool), &buffer)
            let pixels = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixels))
            let value = UInt8(vary ? (i * 23) % 250 : 120)
            memset(base, Int32(value), CVPixelBufferGetBytesPerRow(pixels) * height)
            CVPixelBufferUnlockBaseAddress(pixels, [])
            XCTAssertTrue(adaptor.append(pixels, withPresentationTime: CMTime(value: Int64(i), timescale: fps)))
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        XCTAssertEqual(writer.status, .completed)
        return url
    }

    private func frameCount(_ url: URL) -> Int {
        CGImageSourceCreateWithURL(url as CFURL, nil).map { CGImageSourceGetCount($0) } ?? 0
    }

    private let plenty: (URL) -> Int64? = { _ in 50_000_000_000 }

    func testAMovieBecomesAGIFWithEveryPictureAndProgress() async throws {
        let source = try movie(seconds: 1, vary: true)
        let out = folder.appendingPathComponent("out.gif")
        var seen: [Double] = []
        let outcome = await GIFExporter.convert(movie: source, to: out, options: GIFOptions(frameRate: 10, maximumDuration: nil), progress: { seen.append($0) }, freeBytes: plenty)
        guard case .saved(let frames, let bytes, _) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertGreaterThanOrEqual(frames, 8)
        XCTAssertEqual(frameCount(out), frames)
        XCTAssertGreaterThan(bytes, 0)
        XCTAssertEqual(seen.last, 1)
        XCTAssertEqual(seen, seen.sorted(), "progress only moves forward")
        XCTAssertTrue(seen.allSatisfy { (0...1).contains($0) })
    }

    func testTheFrameRateChoosesHowManyPictures() async throws {
        let source = try movie(seconds: 1, vary: true)
        let slow = folder.appendingPathComponent("slow.gif"), fast = folder.appendingPathComponent("fast.gif")
        _ = await GIFExporter.convert(movie: source, to: slow, options: GIFOptions(frameRate: 5, maximumDuration: nil), freeBytes: plenty)
        _ = await GIFExporter.convert(movie: source, to: fast, options: GIFOptions(frameRate: 10, maximumDuration: nil), freeBytes: plenty)
        XCTAssertGreaterThan(frameCount(fast), frameCount(slow))
    }

    func testTheMaximumDurationUsesOnlyTheStartOfTheRecording() async throws {
        let source = try movie(seconds: 2, vary: true)
        let short = folder.appendingPathComponent("short.gif"), whole = folder.appendingPathComponent("whole.gif")
        _ = await GIFExporter.convert(movie: source, to: short, options: GIFOptions(frameRate: 10, maximumDuration: 1), freeBytes: plenty)
        _ = await GIFExporter.convert(movie: source, to: whole, options: GIFOptions(frameRate: 10, maximumDuration: nil), freeBytes: plenty)
        XCTAssertLessThan(frameCount(short), frameCount(whole))
    }

    func testMergingMakesAStillScreenOnePicture() async throws {
        let still = try movie(seconds: 1, vary: false)
        let merged = folder.appendingPathComponent("merged.gif"), plain = folder.appendingPathComponent("plain.gif")
        let a = await GIFExporter.convert(movie: still, to: merged, options: GIFOptions(optimize: true, maximumDuration: nil), freeBytes: plenty)
        let b = await GIFExporter.convert(movie: still, to: plain, options: GIFOptions(optimize: false, maximumDuration: nil), freeBytes: plenty)
        guard case .saved(let mergedFrames, _, _) = a, case .saved(let plainFrames, _, _) = b else { return XCTFail("\(a) \(b)") }
        XCTAssertEqual(mergedFrames, 1, "every picture was the same")
        XCTAssertGreaterThan(plainFrames, 5)
        XCTAssertEqual(frameCount(merged), 1)
    }

    func testMergingKeepsPicturesThatChange() async throws {
        let moving = try movie(seconds: 1, vary: true)
        let out = folder.appendingPathComponent("moving.gif")
        let outcome = await GIFExporter.convert(movie: moving, to: out, options: GIFOptions(optimize: true, maximumDuration: nil), freeBytes: plenty)
        guard case .saved(let frames, _, _) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertGreaterThan(frames, 5)
    }

    func testCancellingBeforeStartingLeavesNothing() async throws {
        let source = try movie(seconds: 1, vary: true)
        let out = folder.appendingPathComponent("cancelled.gif")
        let outcome = await GIFExporter.convert(movie: source, to: out, isCancelled: { true }, freeBytes: plenty)
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
    }

    func testCancellingPartWayRemovesWhatWasWritten() async throws {
        let source = try movie(seconds: 2, vary: true)
        let out = folder.appendingPathComponent("midway.gif")
        var asked = 0
        let outcome = await GIFExporter.convert(movie: source, to: out, options: GIFOptions(maximumDuration: nil), isCancelled: { asked += 1; return asked > 6 }, freeBytes: plenty)
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path), "nothing is left behind")
        XCTAssertEqual(asked, 7, "asked before each picture, and it stopped at once")
    }

    func testWithoutRoomItSaysSoBeforeStartingAndWritesNothing() async throws {
        let source = try movie(seconds: 1, vary: true)
        let out = folder.appendingPathComponent("noroom.gif")
        let outcome = await GIFExporter.convert(movie: source, to: out, freeBytes: { _ in 1_000 })
        guard case .failed(let reason) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(reason.contains("may not be room"), reason)
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
    }

    func testIfTheDiskFillsWhileMakingItStopsAndRemovesIt() async throws {
        let source = try movie(seconds: 1, vary: true)
        let out = folder.appendingPathComponent("filling.gif")
        var reads = 0
        let outcome = await GIFExporter.convert(movie: source, to: out, options: GIFOptions(maximumDuration: nil), freeBytes: { _ in
            reads += 1
            return reads == 1 ? 50_000_000_000 : 1_000      // room at first, then none
        })
        guard case .failed(let reason) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(reason.contains("nearly full"), reason)
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path), "the partial GIF is not kept")
    }

    func testAnUnreadableMovieFailsWithASentence() async {
        let outcome = await GIFExporter.convert(movie: folder.appendingPathComponent("missing.mov"), to: folder.appendingPathComponent("x.gif"), freeBytes: plenty)
        guard case .failed(let reason) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(reason.contains("could not be read"), reason)
    }

    func testLowerQualityReducesTheColours() async throws {
        let source = try movie(seconds: 1, vary: true)
        let rich = folder.appendingPathComponent("rich.gif"), poor = folder.appendingPathComponent("poor.gif")
        _ = await GIFExporter.convert(movie: source, to: rich, options: GIFOptions(quality: 1, maximumDuration: nil), freeBytes: plenty)
        _ = await GIFExporter.convert(movie: source, to: poor, options: GIFOptions(quality: 0.1, maximumDuration: nil), freeBytes: plenty)
        XCTAssertEqual(frameCount(rich), frameCount(poor), "the same pictures, with fewer colours")
        let image = try XCTUnwrap(CGImageSourceCreateWithURL(poor as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        let posterised = GIFExporter.posterized(image, levels: 8)
        XCTAssertEqual(posterised.width, image.width)
        XCTAssertTrue(GIFExporter.posterized(image, levels: 256) === image, "full colour is returned as it is")
    }
}
