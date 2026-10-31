import XCTest
import CoreGraphics
@testable import Kriya

final class CaptureDeliveryTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    private func picture(_ width: Int, _ height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    // MARK: Settings saved by earlier versions still load

    func testAnOldBackdropWithoutABorderLoads() throws {
        let style = try decode(CaptureBeautify.self, #"{"background":"ocean","padding":0.1,"corners":0.02,"shadow":false,"aspect":"wide"}"#)
        XCTAssertEqual(style.background, .ocean)
        XCTAssertEqual(style.padding, 0.1)
        XCTAssertFalse(style.shadow)
        XCTAssertFalse(style.borderEnabled)
        XCTAssertEqual(style.borderWidth, 1)
        XCTAssertEqual(style.borderColor, .border)
    }

    func testOldRecordingOptionsGetTheNewDefaults() throws {
        let options = try decode(RecordingOptions.self, #"{"systemAudio":false,"framesPerSecond":60,"webcam":true}"#)
        XCTAssertFalse(options.systemAudio)
        XCTAssertEqual(options.framesPerSecond, 60)
        XCTAssertTrue(options.webcam)
        XCTAssertFalse(options.dimScreen)
        XCTAssertFalse(options.doNotDisturb)
        XCTAssertEqual(options.maximumResolution, .original)
        XCTAssertEqual(options.outputScale, .native)
        XCTAssertFalse(options.monoAudio)
        XCTAssertFalse(options.showCountdown)
        XCTAssertEqual(options.audioTrackMode, .separate, "Kriya has always written the sound and the microphone in tracks of their own")
        XCTAssertEqual(options.gif, GIFOptions())
    }

    func testTheGIFDefaultsAreWhatKriyaAlwaysUsed() {
        let gif = GIFOptions()
        XCTAssertEqual(gif.frameRate, 10)
        XCTAssertEqual(gif.resolution.maxWidth, 720)
        XCTAssertEqual(gif.maximumDuration, 30, "300 pictures at 10 a second")
        XCTAssertEqual(gif.quality, 1)
        XCTAssertFalse(gif.optimize)
        XCTAssertEqual(gif.sanitized(), gif)
    }

    func testAnOldProfileLoadsWithNothingChosenForTheNewParts() throws {
        let json = #"{"id":"a","name":"Old","copyImage":true,"saveToFolder":false,"folderPath":"","openEditor":true,"redactAutomatically":false,"delaySeconds":3,"playSound":false,"includeCursor":true}"#
        let profile = try decode(CaptureProfile.self, json)
        XCTAssertNil(profile.screenshotSteps)
        XCTAssertNil(profile.recordingSteps)
        XCTAssertNil(profile.background)
        XCTAssertNil(profile.recordingOptions)
        XCTAssertEqual(profile.delaySeconds, 3)
    }

    func testAnEmptyOrDamagedPolicyLoadsAsTheDefault() throws {
        XCTAssertEqual(try decode(CaptureDeliveryPolicy.self, "{}"), CaptureDeliveryPolicy())
        let damaged = try decode(CaptureDeliveryPolicy.self, #"{"output":{"scale":"huge","convertToSRGB":true},"retention":{"captureHistoryDays":"many","screenshotFileDays":30},"pin":5}"#)
        XCTAssertTrue(damaged.output.convertToSRGB, "a field that can be read is kept")
        XCTAssertEqual(damaged.output.scale, .native, "a scale this version does not know is the default")
        XCTAssertEqual(damaged.retention.captureHistoryDays, 0)
        XCTAssertEqual(damaged.retention.screenshotFileDays, 30)
        XCTAssertEqual(damaged.pin, PinPolicy())
    }

    func testThePolicyIsSavedAndReadBackFromTheGivenPreferences() throws {
        let suite = "kriya.test.delivery.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CaptureDeliveryStore(defaults: defaults)
        XCTAssertEqual(store.policy, CaptureDeliveryPolicy(), "nothing saved reads as the default")
        var policy = CaptureDeliveryPolicy()
        policy.output.scale = .oneX
        policy.recording = { var s = DeliverySteps(); s.upload = true; return s }()
        policy.pin.shadow = false
        store.policy = policy
        XCTAssertEqual(CaptureDeliveryStore(defaults: defaults).policy, policy)
    }

    // MARK: What happens after a capture

    func testWithNothingChosenTheStepsFollowTheOlderOptions() {
        var settings = CaptureSettings()
        settings.copyImage = false; settings.saveToFolder = true; settings.openEditor = true
        let policy = CaptureDeliveryPolicy()
        let shot = policy.steps(for: .screenshot, settings: settings)
        XCTAssertFalse(shot.copy)
        XCTAssertTrue(shot.save)
        XCTAssertTrue(shot.annotate)
        let movie = policy.steps(for: .recording, settings: settings)
        XCTAssertFalse(movie.copy)
        XCTAssertTrue(movie.save)
        XCTAssertFalse(movie.annotate, "a recording is not opened in the picture editor")
    }

    func testStepsChosenForOneKindDoNotChangeTheOthers() {
        var policy = CaptureDeliveryPolicy()
        var gif = DeliverySteps(); gif.copy = true; gif.upload = true; gif.pin = true
        policy.gif = gif
        let settings = CaptureSettings()
        XCTAssertTrue(policy.steps(for: .gif, settings: settings).upload)
        XCTAssertFalse(policy.steps(for: .gif, settings: settings).pin, "pinning is for pictures")
        XCTAssertFalse(policy.steps(for: .recording, settings: settings).upload)
        XCTAssertFalse(policy.steps(for: .screenshot, settings: settings).upload)
    }

    func testStepsNeverThrowTheCaptureAway() {
        var none = DeliverySteps(); none.copy = false; none.save = false; none.upload = false
        XCTAssertTrue(none.normalized(for: .screenshot).copy)
        XCTAssertTrue(none.normalized(for: .recording).save)
        var onlyUpload = none; onlyUpload.upload = true
        XCTAssertFalse(onlyUpload.normalized(for: .screenshot).copy, "an upload keeps it")
        var trim = DeliverySteps(); trim.trim = true
        XCTAssertFalse(trim.normalized(for: .screenshot).trim)
        XCTAssertTrue(trim.normalized(for: .recording).trim)
    }

    func testEveryActionHasAKind() {
        XCTAssertEqual(CaptureKind.of(.normal), .screenshot)
        XCTAssertEqual(CaptureKind.of(.text), .ocr)
        XCTAssertEqual(CaptureKind.of(.record), .recording)
        XCTAssertEqual(CaptureKind.of(.recordScreen), .recording)
        XCTAssertEqual(CaptureKind.of(.stopRecording), .recording)
        XCTAssertEqual(CaptureKind.of(.recordGIF), .gif)
        for action in CaptureAction.allCases { _ = CaptureKind.of(action) }
    }

    func testARequestKeepsThePolicyItBeganWith() {
        var policy = CaptureDeliveryPolicy()
        policy.output.convertToSRGB = true
        let request = CaptureRequest.make(mode: .region, action: .recordGIF, settings: CaptureSettings(), policy: policy, modifiers: [.shift, .option], backingScale: 0.5)
        policy.output.convertToSRGB = false
        XCTAssertEqual(request.kind, .gif)
        XCTAssertTrue(request.delivery.output.convertToSRGB, "a change made while the capture runs does not reach it")
        XCTAssertEqual(request.modifiers, [.shift, .option])
        XCTAssertEqual(request.backingScale, 1, "a scale below 1 is not a screen")
    }

    // MARK: The backdrop

    private var ocean: CaptureBeautify { var s = CaptureBeautify(); s.background = .ocean; return s }
    private var forest: CaptureBeautify { var s = CaptureBeautify(); s.background = .forest; return s }

    func testWithNoPresetChosenTheOlderGlobalBackdropStillApplies() {
        let policy = BackgroundPolicy()
        XCTAssertEqual(policy.resolve(kind: .screenshot, legacy: ocean, modifiers: []), ocean)
        XCTAssertNil(policy.resolve(kind: .screenshot, legacy: CaptureBeautify(), modifiers: []))
        XCTAssertNil(policy.resolve(kind: .recording, legacy: ocean, modifiers: []), "the global backdrop was only ever for pictures")
    }

    func testAChosenPresetWinsOverTheGlobalBackdropAndNoneIsNone() {
        var policy = BackgroundPolicy()
        policy.screenshotPreset = "starter.forest"
        XCTAssertEqual(policy.resolve(kind: .screenshot, legacy: ocean, modifiers: [])?.background, .forest)
        policy.screenshotPreset = BackgroundPolicy.noneID
        XCTAssertNil(policy.resolve(kind: .screenshot, legacy: ocean, modifiers: []))
    }

    func testShiftLeavesTheBackdropOutOnlyWhenAllowed() {
        var policy = BackgroundPolicy()
        policy.screenshotPreset = "starter.ocean"
        XCTAssertNil(policy.resolve(kind: .screenshot, legacy: CaptureBeautify(), modifiers: [.shift]))
        XCTAssertNotNil(policy.resolve(kind: .screenshot, legacy: CaptureBeautify(), modifiers: [.option]))
        policy.skipWithShift = false
        XCTAssertNotNil(policy.resolve(kind: .screenshot, legacy: CaptureBeautify(), modifiers: [.shift]))
    }

    func testRecordingsUseTheirOwnPreset() {
        var policy = BackgroundPolicy()
        policy.screenshotPreset = "starter.ocean"
        policy.recordingPreset = "starter.sunset"
        XCTAssertEqual(policy.resolve(kind: .recording, legacy: CaptureBeautify(), modifiers: [])?.background, .sunset)
        XCTAssertEqual(policy.resolve(kind: .gif, legacy: CaptureBeautify(), modifiers: [])?.background, .sunset)
        XCTAssertEqual(policy.resolve(kind: .screenshot, legacy: CaptureBeautify(), modifiers: [])?.background, .ocean)
    }

    func testAPresetThatPointsAtNothingIsForgotten() {
        var policy = BackgroundPolicy()
        policy.screenshotPreset = "gone"
        policy.recordingPreset = "starter.forest"
        policy.presets.append(policy.presets[0])
        let clean = policy.sanitized()
        XCTAssertNil(clean.screenshotPreset)
        XCTAssertEqual(clean.recordingPreset, "starter.forest")
        XCTAssertEqual(Set(clean.presets.map(\.id)).count, clean.presets.count, "ids are unique")
        XCTAssertEqual(clean.resolve(kind: .screenshot, legacy: ocean, modifiers: []), ocean, "falls back to the global backdrop")
    }

    func testTheRequestReadsTheKeysHeldAtTheEnd() {
        var policy = CaptureDeliveryPolicy()
        policy.background.screenshotPreset = "starter.ocean"
        // Shift was held to start the capture (it is part of the shortcut) but is not held when the picture is delivered.
        let request = CaptureRequest.make(mode: .region, action: .normal, settings: CaptureSettings(), policy: policy, modifiers: [.shift])
        XCTAssertNotNil(request.background(legacy: CaptureBeautify(), modifiersNow: []))
        XCTAssertNil(request.background(legacy: CaptureBeautify(), modifiersNow: [.shift]))
    }

    // MARK: Output

    func testTheClipboardDefaultIsWhatKriyaAlwaysCopied() {
        XCTAssertEqual(OutputPolicy().clipboard, .image)
        XCTAssertTrue(OutputPolicy().isIdentity)
    }

    // MARK: Recording

    func testARecordingIsNeverLargerThanTheChosenResolution() {
        XCTAssertEqual(ResolutionLimit.original.fit(CGSize(width: 3456, height: 2234)), CGSize(width: 3456, height: 2234))
        XCTAssertEqual(ResolutionLimit.p1080.fit(CGSize(width: 3840, height: 2160)), CGSize(width: 1920, height: 1080))
        XCTAssertEqual(ResolutionLimit.p1080.fit(CGSize(width: 1280, height: 720)), CGSize(width: 1280, height: 720), "never enlarged")
        XCTAssertEqual(ResolutionLimit.p720.fit(CGSize(width: 1080, height: 1920)), CGSize(width: 720, height: 1280), "by the shorter side")
    }

    func testRecordedSizesStayEven() {
        var options = RecordingOptions()
        XCTAssertEqual(options.recordedSize(pixels: CGSize(width: 2879, height: 1799), backingScale: 2), CGSize(width: 2880, height: 1800))
        options.outputScale = .oneX
        XCTAssertEqual(options.recordedSize(pixels: CGSize(width: 2880, height: 1800), backingScale: 2), CGSize(width: 1440, height: 900))
        options.maximumResolution = .p720
        XCTAssertEqual(options.recordedSize(pixels: CGSize(width: 2880, height: 1800), backingScale: 2), CGSize(width: 1152, height: 720))
    }

    func testGIFSettingsAreHeldToWhatCanBeMade() {
        var gif = GIFOptions()
        gif.frameRate = 999; gif.quality = 9; gif.maximumDuration = 99_999
        let clean = gif.sanitized()
        XCTAssertTrue(GIFOptions.frameRates.contains(clean.frameRate))
        XCTAssertEqual(clean.quality, 1)
        XCTAssertEqual(clean.maximumDuration, GIFOptions.durationRange.upperBound)
        var options = RecordingOptions()
        options.gif = gif
        XCTAssertEqual(options.sanitized(hdrAvailable: false).gif, clean)
    }

    // MARK: Profiles

    func testAProfileCarriesEachKindsStepsTheBackdropAndTheRecordingOptions() {
        var settings = CaptureSettings()
        var recording = RecordingOptions(); recording.microphone = true; recording.maximumResolution = .p720
        settings.recording = recording
        var policy = CaptureDeliveryPolicy()
        policy.background.screenshotPreset = "starter.sunset"
        let profile = CaptureProfile.from(settings, policy: policy, legacyBackdrop: CaptureBeautify(), named: "Talk")
        XCTAssertEqual(profile.background?.background, .sunset)
        XCTAssertEqual(profile.recordingOptions?.maximumResolution, .p720)
        XCTAssertNotNil(profile.screenshotSteps)
        XCTAssertNotNil(profile.recordingSteps)
        XCTAssertNotNil(profile.gifSteps)
    }

    func testUsingAProfilePutsItsBackdropAndStepsInThePolicyAndNothingElse() {
        var policy = CaptureDeliveryPolicy()
        policy.pin.shadow = false
        policy.pin.opacity = 0.5
        policy.retention.captureHistoryDays = 7
        var profile = CaptureProfile.starters[0]
        profile.background = forest
        var upload = DeliverySteps(); upload.upload = true
        profile.recordingSteps = upload
        let applied = profile.applied(to: policy)
        XCTAssertEqual(applied.background.resolve(kind: .screenshot, legacy: CaptureBeautify(), modifiers: [])?.background, .forest)
        XCTAssertTrue(applied.recording?.upload == true)
        XCTAssertNil(applied.screenshot, "a choice the profile does not hold is left alone")
        XCTAssertFalse(applied.pin.shadow)
        XCTAssertEqual(applied.pin.opacity, 0.5, "the profile does not touch how pins look")
        XCTAssertEqual(applied.retention.captureHistoryDays, 7, "how long captures are kept is not part of a profile")
    }

    func testAProfileWithNoBackdropTurnsTheBackdropOffOnPurpose() {
        var policy = CaptureDeliveryPolicy()
        policy.background.screenshotPreset = "starter.ocean"
        var profile = CaptureProfile.starters[1]
        profile.background = CaptureBeautify()
        let applied = profile.applied(to: policy)
        XCTAssertNil(applied.background.resolve(kind: .screenshot, legacy: ocean, modifiers: []), "not even the older global backdrop")
    }

    func testUsingTheSameProfileTwiceDoesNotPileUpPresets() {
        var profile = CaptureProfile.starters[0]
        profile.background = ocean
        let once = profile.applied(to: CaptureDeliveryPolicy())
        let twice = profile.applied(to: once)
        XCTAssertEqual(once.background.presets.count, twice.background.presets.count)
        XCTAssertEqual(twice.background.presets.filter { $0.id.hasPrefix(BackgroundPolicy.profilePrefix) }.count, 1)
    }

    func testAProfileKeepsShortcutsAndWordsToHideAndTakesRecordingOptions() {
        var settings = CaptureSettings()
        settings.shortcuts = [CaptureShortcut(command: "capture.region", keyCode: 20, modifiers: 1)]
        settings.redactWords = ["secret"]
        var profile = CaptureProfile.starters[2]
        var recording = RecordingOptions(); recording.doNotDisturb = true
        profile.recordingOptions = recording
        let applied = profile.applied(to: settings)
        XCTAssertEqual(applied.shortcuts, settings.shortcuts)
        XCTAssertEqual(applied.redactWords, ["secret"])
        XCTAssertTrue(applied.recording.doNotDisturb)
        XCTAssertEqual(CaptureProfile.starters[0].applied(to: settings).recording, settings.recording, "a profile with no recording options leaves them")
    }

    func testTheStarterProfilesLeaveThePolicyAsItWas() {
        let policy = CaptureDeliveryPolicy()
        for profile in CaptureProfile.starters { XCTAssertEqual(profile.applied(to: policy), policy) }
    }

    // MARK: Backup, reset, diagnostics

    func testThePolicyIsRegisteredSoBackupResetAndDiagnosticsSeeIt() throws {
        let entry = try XCTUnwrap(SettingsRegistry.entries.first { $0.key == CaptureDeliveryStore.key })
        XCTAssertEqual(entry.kind, .setting, "it travels in a backup")
        XCTAssertEqual(entry.area, "capture", "and a reset of capture clears it")
        XCTAssertTrue(try XCTUnwrap(FeatureReset.areas.first { $0.id == "capture" }).keys.contains(CaptureDeliveryStore.key))
    }

    // MARK: The picture

    func testNothingAskedLeavesThePictureAlone() {
        let image = picture(40, 20)
        XCTAssertTrue(CaptureRenderer.written(image, output: OutputPolicy(), backingScale: 2) === image)
    }

    func testAskingForOneXHalvesARetinaPicture() {
        var output = OutputPolicy()
        output.scale = .oneX
        let out = CaptureRenderer.written(picture(40, 20), output: output, backingScale: 2)
        XCTAssertEqual(out.width, 20)
        XCTAssertEqual(out.height, 10)
    }

    func testAskingForSRGBWritesTheProfile() {
        var output = OutputPolicy()
        output.convertToSRGB = true
        let out = CaptureRenderer.written(picture(8, 8), output: output, backingScale: 1)
        XCTAssertEqual(out.colorSpace?.name as String?, CGColorSpace.sRGB as String)
    }

    func testTheBorderIsNotDrawnByTheSizeAndProfileStep() {
        var output = OutputPolicy()
        output.border = CaptureBorder(enabled: true, width: 3)
        let plain = picture(10, 10)
        XCTAssertTrue(CaptureRenderer.written(plain, output: output, backingScale: 1) === plain, "the border is drawn on its own canvas, by the backdrop step")
        XCTAssertFalse(output.isIdentity)
    }
}
