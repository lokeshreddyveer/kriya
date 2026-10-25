import AppKit
import XCTest
@testable import Kriya

final class ScreenCaptureArgumentsTests: XCTestCase {
    private let out = URL(fileURLWithPath: "/tmp/x.png")

    func testEachModeAsksTheSystemToolForTheRightThing() {
        XCTAssertEqual(ScreenCaptureArguments.make(mode: .region, delay: 0, sound: false, output: out), ["-i", "-s", "-x", "-t", "png", "/tmp/x.png"])
        XCTAssertEqual(ScreenCaptureArguments.make(mode: .window, delay: 0, sound: true, output: out), ["-i", "-w", "-t", "png", "/tmp/x.png"])
        XCTAssertEqual(ScreenCaptureArguments.make(mode: .screen, delay: 5, sound: false, output: out), ["-x", "-T", "5", "-t", "png", "/tmp/x.png"])
        XCTAssertEqual(ScreenCaptureArguments.make(mode: .screen, delay: 999, sound: false, output: out).filter { $0 == "30" }.count, 1, "the wait is capped")
    }

    func testFileNamesSortByTimeAndNeverClash() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let first = ScreenCaptureArguments.fileName(for: date)
        XCTAssertTrue(first.hasPrefix("Kriya Capture 20"))
        XCTAssertTrue(first.hasSuffix(".png"))
        var taken: Set<String> = [first]
        let second = ScreenCaptureArguments.fileName(for: date) { taken.contains($0) }
        XCTAssertNotEqual(first, second)
        taken.insert(second)
        XCTAssertNotEqual(ScreenCaptureArguments.fileName(for: date) { taken.contains($0) }, second)
    }
}

final class CaptureSettingsTests: XCTestCase {
    private func suite() -> UserDefaults { UserDefaults(suiteName: "kriya-capture-tests-\(UUID().uuidString)")! }

    func testSettingsSurviveARestartAndAreKeptInRange() {
        let defaults = suite()
        let store = CaptureSettingsStore(defaults: defaults)
        store.update { $0.openEditor = true; $0.delaySeconds = 500; $0.folderPath = "/tmp/shots"; $0.redactWords = ["  Acme  ", "x", "Acme", "Jane Doe"] }
        let again = CaptureSettingsStore(defaults: defaults)
        XCTAssertTrue(again.settings.openEditor)
        XCTAssertEqual(again.settings.delaySeconds, 30)
        XCTAssertEqual(again.settings.folder.path, "/tmp/shots")
        XCTAssertEqual(again.settings.redactWords, ["Acme", "Jane Doe"], "trimmed, no duplicates, nothing too short")
        XCTAssertEqual(CaptureSettings().folder, CaptureSettings.defaultFolder)
    }

    func testShortcutsNeedModifiersAndCannotShareKeys() {
        let store = CaptureSettingsStore(defaults: suite())
        store.setShortcut("capture.region", keyCode: 20, modifiers: KeyModifiers.command | KeyModifiers.shift)
        store.setShortcut("capture.window", keyCode: 21, modifiers: 0)
        XCTAssertNil(store.shortcut(for: "capture.window"), "a shortcut with no modifier keys would take over typing")
        store.setShortcut("capture.screen", keyCode: 20, modifiers: KeyModifiers.command | KeyModifiers.shift)
        XCTAssertNil(store.shortcut(for: "capture.region"), "the newest takes the keys")
        XCTAssertNotNil(store.shortcut(for: "capture.screen"))
        store.setShortcut("capture.screen", keyCode: nil, modifiers: 0)
        XCTAssertTrue(store.settings.shortcuts.isEmpty)
        XCTAssertEqual(Set(CaptureSettings.commands.map(\.command)).count, CaptureSettings.commands.count)
    }

    func testDamagedSavedSettingsStartFresh() {
        let defaults = suite()
        defaults.set(Data("nonsense".utf8), forKey: "captureSettings.v1")
        XCTAssertEqual(CaptureSettingsStore(defaults: defaults).settings, CaptureSettings())
    }
}

final class RedactionTests: XCTestCase {
    private func found(_ text: String, _ options: Redaction.Options = Redaction.Options()) -> [String] {
        Redaction.sensitiveRanges(in: text, options: options).compactMap { Range($0, in: text).map { String(text[$0]) } }
    }

    func testPrivateLookingTextIsFound() {
        XCTAssertEqual(found("Write to jane.doe@example.com today"), ["jane.doe@example.com"])
        XCTAssertEqual(found("Server at 192.168.1.20 is up"), ["192.168.1.20"])
        XCTAssertEqual(found("Card 4111 1111 1111 1111 expires soon"), ["4111 1111 1111 1111"])
        XCTAssertEqual(found("Call +91 98765 43210 now"), ["+91 98765 43210"])
        XCTAssertTrue(found("token ghp_16C7e42F292c6912E7710c838347Ae178B4a here").contains("ghp_16C7e42F292c6912E7710c838347Ae178B4a"))
        XCTAssertEqual(found("Mention Acme Corp and acme", Redaction.Options(extraWords: ["Acme"])).count, 2, "any capitalisation")
    }

    func testOrdinaryTextIsLeftAlone() {
        XCTAssertTrue(found("Meeting notes for Tuesday at 3pm in room 12").isEmpty)
        XCTAssertTrue(found("Version 1.2.3 released on 2026-10-22").isEmpty, "a date is not a phone number")
        XCTAssertTrue(found("999.999.999.999 is not an address").isEmpty)
        XCTAssertTrue(found("Total 1234 5678 9012 3456").isEmpty, "digits that are not a card number")
        XCTAssertTrue(found("an-ordinary-long-hyphenated-sentence-fragment").isEmpty)
    }

    func testKindsCanBeTurnedOff() {
        XCTAssertTrue(found("jane@example.com", Redaction.Options(emails: false)).isEmpty)
        XCTAssertFalse(found("jane@example.com", Redaction.Options(phones: false, addresses: false, cards: false, tokens: false)).isEmpty)
    }

    func testChecks() {
        XCTAssertTrue(Redaction.luhn([4, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1]))
        XCTAssertFalse(Redaction.luhn([4, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 2]))
        XCTAssertFalse(Redaction.luhn([1, 2, 3]))
        XCTAssertTrue(Redaction.ipv4("10.0.0.255"))
        XCTAssertFalse(Redaction.ipv4("10.0.0.256"))
        XCTAssertTrue(Redaction.isDate("2026-10-22"))
        XCTAssertFalse(Redaction.isDate("98765 43210"))
    }

    func testTheBoxesCoverTheWordsAMatchIsMadeOf() {
        let card = RecognizedLine(words: [
            RecognizedWord(text: "Card", box: CGRect(x: 0.1, y: 0.2, width: 0.08, height: 0.03)),
            RecognizedWord(text: "4111", box: CGRect(x: 0.2, y: 0.2, width: 0.06, height: 0.03)),
            RecognizedWord(text: "1111", box: CGRect(x: 0.27, y: 0.2, width: 0.06, height: 0.03)),
            RecognizedWord(text: "1111", box: CGRect(x: 0.34, y: 0.2, width: 0.06, height: 0.03)),
            RecognizedWord(text: "1111", box: CGRect(x: 0.41, y: 0.2, width: 0.06, height: 0.03)),
        ])
        let mail = RecognizedLine(words: [RecognizedWord(text: "me@example.org", box: CGRect(x: 0.1, y: 0.5, width: 0.3, height: 0.03))])
        let plain = RecognizedLine(words: [RecognizedWord(text: "Nothing", box: CGRect(x: 0.1, y: 0.8, width: 0.1, height: 0.03))])
        let boxes = Redaction.plan([card, mail, plain], padding: 0)
        XCTAssertEqual(boxes.count, 2)
        let cardBox = boxes[0]
        XCTAssertEqual(cardBox.minX, 0.2, accuracy: 0.001, "starts at the first number, not at the word before it")
        XCTAssertEqual(cardBox.maxX, 0.47, accuracy: 0.001)
        XCTAssertEqual(boxes[1].minY, 0.5, accuracy: 0.001)
        XCTAssertTrue(Redaction.plan([plain]).isEmpty)
        let padded = Redaction.plan([mail], padding: 0.01)[0]
        XCTAssertLessThan(padded.minX, 0.1)
    }
}

final class CaptureRendererTests: XCTestCase {
    private func image(width: Int = 100, height: Int = 60, color: (UInt8, UInt8, UInt8) = (255, 255, 255)) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: CGFloat(color.0) / 255, green: CGFloat(color.1) / 255, blue: CGFloat(color.2) / 255, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // A bright stripe down the middle, so a mosaic has something to change.
        context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        context.fill(CGRect(x: width / 2 - 2, y: 0, width: 4, height: height))
        return context.makeImage()!
    }

    /// The colour at a point measured from the top left.
    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
        let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = context.data!.assumingMemoryBound(to: UInt8.self)
        // A bitmap's memory starts at its top row, so a point measured from the top left is that many rows in.
        let offset = y * context.bytesPerRow + x * 4
        return (Int(data[offset]), Int(data[offset + 1]), Int(data[offset + 2]))
    }

    func testHidingCoversOnlyTheChosenPlaces() throws {
        let result = try XCTUnwrap(CaptureRenderer.hide(image(), rects: [CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.3)]))
        XCTAssertEqual(result.width, 100)
        XCTAssertEqual(result.height, 60)
        XCTAssertEqual(pixel(result, 20, 12).r, 13, accuracy: 3, "covered")
        XCTAssertEqual(pixel(result, 80, 50).r, 255, "left alone")
        XCTAssertEqual(pixel(result, 20, 50).r, 255, "below the box is left alone")
    }

    func testHidingAnythingOutsideThePictureIsHarmless() {
        XCTAssertNotNil(CaptureRenderer.hide(image(), rects: [CGRect(x: 0.9, y: 0.9, width: 0.5, height: 0.5), .zero]))
        XCTAssertNotNil(CaptureRenderer.hide(image(), rects: []))
    }

    func testAMosaicChangesTheRegionAndNothingElse() throws {
        let original = image()
        let result = try XCTUnwrap(CaptureRenderer.render(original, annotations: [Annotation(kind: .blur, start: CGPoint(x: 0.3, y: 0.1), end: CGPoint(x: 0.7, y: 0.9))]))
        XCTAssertEqual(result.width, original.width)
        // The stripe at x=50 is inside the region, and the mosaic blends it into its neighbours.
        XCTAssertNotEqual(pixel(result, 50, 30).r, pixel(original, 50, 30).r)
        XCTAssertEqual(pixel(result, 5, 30).r, 255, "outside the region")
        XCTAssertEqual(pixel(result, 95, 55).b, pixel(original, 95, 55).b)
    }

    func testMarksAreDrawnWhereTheyAreAskedFor() throws {
        let marks = [
            Annotation(kind: .highlight, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0.2, y: 0.2), color: .yellow),
            Annotation(kind: .box, start: CGPoint(x: 0.6, y: 0.6), end: CGPoint(x: 0.9, y: 0.9), color: .red),
            Annotation(kind: .arrow, start: CGPoint(x: 0.1, y: 0.8), end: CGPoint(x: 0.4, y: 0.8), color: .green),
            Annotation(kind: .text("Hi"), start: CGPoint(x: 0.1, y: 0.4), end: CGPoint(x: 0.1, y: 0.4), color: .white),
        ]
        let result = try XCTUnwrap(CaptureRenderer.render(image(width: 200, height: 120), annotations: marks))
        XCTAssertEqual(result.width, 200)
        let highlighted = pixel(result, 10, 10)
        XCTAssertLessThan(highlighted.b, 240, "yellow over white lowers blue")
        XCTAssertLessThan(pixel(result, 100, 4).r, 255, "blue stripe untouched by the highlight is still not white")
        XCTAssertLessThan(pixel(result, 120, 90).g, 150, "the box's left edge is red")
        XCTAssertLessThan(pixel(result, 150, 90).g, 255 + 1)
        XCTAssertEqual(pixel(result, 150, 90).g, 255, "inside the box is untouched")
        XCTAssertLessThan(pixel(result, 50, 96).r, 200, "the arrow's shaft is green")
        XCTAssertEqual(pixel(result, 190, 5).r, 255, "elsewhere is untouched")
    }

    func testAPictureWithNoMarksComesBackTheSame() throws {
        let original = image()
        let same = try XCTUnwrap(CaptureRenderer.render(original, annotations: []))
        XCTAssertEqual(pixel(same, 50, 30).b, pixel(original, 50, 30).b)
        XCTAssertNotNil(original.pngData)
    }
}

final class ScreenCaptureServiceTests: XCTestCase {
    private var folder: URL!
    private var board: NSPasteboard!
    private var service: ScreenCaptureService!
    private var calls: [[String]] = []

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("kriya-capture-\(UUID().uuidString)")
        board = NSPasteboard(name: NSPasteboard.Name("kriya-test-\(UUID().uuidString)"))
        let settings = CaptureSettingsStore(defaults: UserDefaults(suiteName: "kriya-capture-\(UUID().uuidString)")!)
        settings.update { $0.folderPath = folder.path }
        service = ScreenCaptureService(settings: settings)
        service.pasteboard = board
        service.hasPermission = { true }
        service.nativeSelectorEnabled = false       // these tests drive the stand-in screenshot tool, not the on-screen selector
        calls = []
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        board.releaseGlobally()
    }

    private func fakePicture(_ arguments: [String]) {
        calls.append(arguments)
        guard let path = arguments.last else { return }
        let context = CGContext(data: nil, width: 40, height: 30, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        try? context.makeImage()?.pngData?.write(to: URL(fileURLWithPath: path))
    }

    private func waitUntilDone() {
        let finished = expectation(description: "capture finished")
        func poll() {
            if service.isCapturing { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: poll) } else { finished.fulfill() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: poll)
        wait(for: [finished], timeout: 10)
    }

    func testACaptureIsCopiedAndSavedAndTemporaryFilesAreRemoved() throws {
        service.capturer = { [unowned self] in fakePicture($0) }
        service.capture(.screen)
        waitUntilDone()
        XCTAssertEqual(calls.count, 1)
        XCTAssertNotNil(board.data(forType: .png), "on the clipboard")
        let saved = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertEqual(saved.count, 1)
        XCTAssertTrue(saved[0].hasSuffix(".png"))
        let target = try XCTUnwrap(calls.first?.last)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target), "the working copy is removed")
        service.capture(.screen)
        waitUntilDone()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 2, "a second capture does not overwrite the first")
    }

    func testCopyingAndSavingCanBeTurnedOff() throws {
        service.settings.update { $0.copyImage = false; $0.saveToFolder = false }
        service.capturer = { [unowned self] in fakePicture($0) }
        service.capture(.region)
        waitUntilDone()
        XCTAssertNil(board.data(forType: .png))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    func testPressingEscapeDoesNothing() {
        service.capturer = { [unowned self] in calls.append($0) }   // takes no picture
        service.capture(.region)
        waitUntilDone()
        XCTAssertEqual(calls.count, 1)
        XCTAssertNil(board.data(forType: .png))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertFalse(service.isCapturing)
    }

    func testWithoutPermissionNothingIsCapturedAndPermissionIsRequested() {
        var asked = 0, explained = 0
        let saved = UserDefaults.standard.object(forKey: ScreenCaptureService.askedKey)
        defer { if let saved { UserDefaults.standard.set(saved, forKey: ScreenCaptureService.askedKey) } else { UserDefaults.standard.removeObject(forKey: ScreenCaptureService.askedKey) } }
        UserDefaults.standard.removeObject(forKey: ScreenCaptureService.askedKey)
        service.hasPermission = { false }
        service.requestPermission = { asked += 1 }
        service.onMissingPermission = { explained += 1 }
        service.capturer = { [unowned self] in fakePicture($0) }
        service.capture(.screen)
        XCTAssertEqual(asked, 1, "the first time macOS's own question is shown")
        XCTAssertEqual(explained, 0, "and nothing else competes with it")
        XCTAssertTrue(calls.isEmpty)
        XCTAssertFalse(service.isCapturing)
        service.capture(.screen)
        XCTAssertEqual(asked, 1, "macOS does not ask twice")
        XCTAssertEqual(explained, 1, "so the second time Kriya explains once, with the Settings button")
    }

    func testTheEditorGetsThePictureAndCancellingKeepsNothing() {
        service.settings.update { $0.openEditor = true }
        service.capturer = { [unowned self] in fakePicture($0) }
        var shown = 0
        service.showEditor = { _, done in shown += 1; done(nil) }
        service.capture(.region)
        waitUntilDone()
        XCTAssertEqual(shown, 1)
        XCTAssertNil(board.data(forType: .png))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "cancelled in the editor, so nothing is delivered")
    }

    // MARK: The macOS recorder is a managed process

    private func sleeper(_ ended: @escaping (Process) -> Void) throws -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep")
        p.arguments = ["30"]
        p.terminationHandler = ended
        try p.run()
        return p
    }

    private func wait(until condition: @escaping () -> Bool, _ message: String) {
        let done = expectation(description: message)
        func poll() { if condition() { done.fulfill() } else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: poll) } }
        DispatchQueue.main.async(execute: poll)
        wait(for: [done], timeout: 10)
    }

    func testKriyasStopEndsTheMacOSRecorderAndTheIconFollowsIt() throws {
        service.recorderLauncher = { [unowned self] _, ended in try sleeper(ended) }
        service.capture(.region, action: .record)
        wait(until: { self.service.systemRecorder != nil }, "recorder started")
        XCTAssertEqual(service.recordingKind, .macOS)
        XCTAssertTrue(service.isCapturing, "a second capture cannot start on top of it")
        XCTAssertEqual(service.overlayActions(settings: service.settings.settings).recordingKind(), .macOS)
        service.capture(.screen, action: .stopRecording)
        wait(until: { self.service.systemRecorder == nil && !self.service.isCapturing }, "recorder stopped")
        XCTAssertNil(service.recordingKind)
        XCTAssertEqual(service.overlayActions(settings: service.settings.settings).recordingKind(), .none)
    }

    func testPauseSaysMacOSCannotPauseAndStopWithNothingRunningSaysSo() throws {
        service.recorderLauncher = { [unowned self] _, ended in try sleeper(ended) }
        service.capture(.screen, action: .stopRecording)          // nothing is recording: no crash, no state
        XCTAssertNil(service.recordingKind)
        service.capture(.region, action: .record)
        wait(until: { self.service.systemRecorder != nil }, "recorder started")
        service.capture(.screen, action: .pauseRecording)          // macOS's recorder has no pause: it keeps running
        XCTAssertEqual(service.recordingKind, .macOS)
        service.capture(.screen, action: .stopRecording)
        wait(until: { self.service.systemRecorder == nil }, "recorder stopped")
    }

    func testARecorderThatCannotStartIsSaidAndLeavesNothingRunning() {
        struct Boom: LocalizedError { var errorDescription: String? { "no such program" } }
        service.recorderLauncher = { _, _ in throw Boom() }
        service.capture(.region, action: .record)
        XCTAssertFalse(service.isCapturing, "not left waiting for something that never started")
        XCTAssertNil(service.systemRecorder)
        XCTAssertNil(service.recordingKind)
    }

    func testCaptureCommandsAreRecognised() {
        service.hasPermission = { false }
        service.requestPermission = {}
        XCTAssertTrue(service.run(command: "capture.text"))
        XCTAssertFalse(service.run(command: "capture.upload"))
    }

    func testTextInAPictureIsRead() throws {
        let width = 600, height = 160
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(.white)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        NSAttributedString(string: "Hello Kriya", attributes: [.font: NSFont.systemFont(ofSize: 72), .foregroundColor: NSColor.black]).draw(at: CGPoint(x: 20, y: 40))
        NSGraphicsContext.restoreGraphicsState()
        let picture = try XCTUnwrap(context.makeImage())
        let text = try TextRecognizer().text(in: picture)
        try XCTSkipIf(text.isEmpty, "this Mac's text recognizer returned nothing for the test picture")
        XCTAssertTrue(text.lowercased().contains("hello"), text)
    }
}


final class CameraStyleTests: XCTestCase {
    func testTheWindowSitsInTheChosenCornerWithAMargin() {
        let area = CGRect(x: 0, y: 0, width: 1000, height: 800)
        var style = CameraStyle(); style.size = .small
        style.corner = .bottomRight
        XCTAssertEqual(style.origin(in: area), CGPoint(x: 1000 - 140 - 30, y: 30))
        style.corner = .topLeft
        XCTAssertEqual(style.origin(in: area), CGPoint(x: 30, y: 800 - 140 - 30))
        style.corner = .bottomLeft
        XCTAssertEqual(style.origin(in: area), CGPoint(x: 30, y: 30))
        style.corner = .topRight
        XCTAssertEqual(style.origin(in: area), CGPoint(x: 1000 - 140 - 30, y: 800 - 140 - 30))
    }

    func testShapesRoundTheCornersAsTheirNamesSay() {
        var style = CameraStyle()
        style.shape = .circle; XCTAssertEqual(style.cornerRadius(side: 200), 100)
        style.shape = .square; XCTAssertEqual(style.cornerRadius(side: 200), 0)
        style.shape = .rounded; XCTAssertEqual(style.cornerRadius(side: 200), 36, accuracy: 0.001)
    }

    func testSizesGrowAndOldSavedOptionsStillLoad() throws {
        XCTAssertLessThan(CameraStyle.Size.small.side, CameraStyle.Size.medium.side)
        XCTAssertLessThan(CameraStyle.Size.medium.side, CameraStyle.Size.large.side)
        // Options saved before the camera had a style have no "cameraStyle" key and must still decode.
        let old = #"{"source":"screen","systemAudio":true,"microphone":false,"hdr":false,"framesPerSecond":30,"showCursor":true,"showKeystrokes":false,"webcam":true,"cameraID":""}"#
        let decoded = try JSONDecoder().decode(RecordingOptions.self, from: Data(old.utf8))
        XCTAssertEqual(decoded.cameraStyle, CameraStyle())
    }
}
