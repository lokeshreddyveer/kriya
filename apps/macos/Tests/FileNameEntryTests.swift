import XCTest
import AppKit
@testable import Kriya

final class FileNameEntryTests: XCTestCase {
    // MARK: Which characters are allowed

    func testASensibleNameIsAccepted() {
        for name in ["Screenshot", "Meeting notes 2026", "Café – menu", "日本語の名前", "a.b.c", "100%"] {
            XCTAssertNil(FileNameEntry.problem(typed: name, ext: "png"), name)
        }
    }

    func testForbiddenCharactersAreRefusedWithTheCharacterNamed() {
        XCTAssertEqual(FileNameEntry.problem(typed: "a/b", ext: "png"), "A file name cannot contain “/”. Take it out or use another character.")
        XCTAssertEqual(FileNameEntry.problem(typed: "10:30 meeting", ext: "png"), "A file name cannot contain “:”. Take it out or use another character.")
        XCTAssertNotNil(FileNameEntry.problem(typed: "tab\there", ext: "png"))
        XCTAssertNotNil(FileNameEntry.problem(typed: "bell\u{7}", ext: "png"))
        XCTAssertNotNil(FileNameEntry.problem(typed: "nul\u{0}", ext: "png"))
    }

    func testAnEmptyNameADotNameAndALongNameAreRefused() {
        XCTAssertEqual(FileNameEntry.problem(typed: "", ext: "png"), "Type a name for the file.")
        XCTAssertEqual(FileNameEntry.problem(typed: "   ", ext: "png"), "Type a name for the file.")
        XCTAssertEqual(FileNameEntry.problem(typed: ".png", ext: "png"), "Type a name for the file.", "only the extension")
        XCTAssertNotNil(FileNameEntry.problem(typed: ".hidden", ext: "png"))
        XCTAssertNotNil(FileNameEntry.problem(typed: "..", ext: "png"))
        XCTAssertNotNil(FileNameEntry.problem(typed: String(repeating: "a", count: FileNameEntry.maxStem + 1), ext: "png"))
        XCTAssertNil(FileNameEntry.problem(typed: String(repeating: "a", count: FileNameEntry.maxStem), ext: "png"))
    }

    func testEveryProblemIsAWholeSentence() {
        for typed in ["", "a/b", "a:b", ".x", String(repeating: "x", count: 500), "t\tt"] {
            let problem = FileNameEntry.problem(typed: typed, ext: "png")
            XCTAssertNotNil(problem, typed)
            XCTAssertTrue(problem?.hasSuffix(".") == true, problem ?? "")
        }
    }

    // MARK: The name the file gets

    func testTheTypedExtensionIsNotDoubled() {
        XCTAssertEqual(FileNameEntry.finalName(typed: "Shot.png", ext: "png"), "Shot.png")
        XCTAssertEqual(FileNameEntry.finalName(typed: "Shot.PNG", ext: "png"), "Shot.png")
        XCTAssertEqual(FileNameEntry.finalName(typed: "Shot", ext: "png"), "Shot.png")
        XCTAssertEqual(FileNameEntry.finalName(typed: "Shot.jpg", ext: "png"), "Shot.jpg.png", "another extension is part of the name")
        XCTAssertEqual(FileNameEntry.finalName(typed: "  Shot  ", ext: "heic"), "Shot.heic")
    }

    func testAnInvalidNameHasNoFinalName() {
        XCTAssertNil(FileNameEntry.finalName(typed: "a/b", ext: "png"))
        XCTAssertNil(FileNameEntry.finalName(typed: "", ext: "png"))
    }

    func testASuffixGoesBeforeTheExtension() {
        XCTAssertEqual(FileNameEntry.finalName(typed: "Shot", ext: "png", suffix: { _ in "@2x" }), "Shot@2x.png")
        XCTAssertEqual(FileNameEntry.finalName(typed: "Shot.png", ext: "png", suffix: { _ in "@2x" }), "Shot@2x.png")
    }

    func testATakenNameGetsACounterAndTheSuffixStaysLast() {
        let taken: Set<String> = ["Shot.png", "Shot 2.png"]
        XCTAssertEqual(FileNameEntry.finalName(typed: "Shot", ext: "png", existing: { taken.contains($0) }), "Shot 3.png")
        let takenRetina: Set<String> = ["Shot@2x.png"]
        XCTAssertEqual(FileNameEntry.finalName(typed: "Shot", ext: "png", existing: { takenRetina.contains($0) }, suffix: { _ in "@2x" }), "Shot 2@2x.png")
    }

    func testTheSuffixSeesTheTypedNameSoItCanSkipOnesThatHaveItAlready() {
        let suffix: (String) -> String = { $0.contains("@2x") ? "" : "@2x" }
        XCTAssertEqual(FileNameEntry.finalName(typed: "icon@2x", ext: "png", suffix: suffix), "icon@2x.png")
        XCTAssertEqual(FileNameEntry.finalName(typed: "icon", ext: "png", suffix: suffix), "icon@2x.png")
    }

    func testTheSuggestedNameIsTheOneThePatternGives() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let stem = CaptureNaming.stem(pattern: "{app} {n}", date: date, app: "Safari", mode: "capture")
        XCTAssertEqual(stem, "Safari 1")
        XCTAssertEqual(CaptureNaming.fileName(pattern: "{app} {n}", date: date, app: "Safari", mode: "capture", ext: "png"), stem + ".png")
        XCTAssertTrue(CaptureNaming.stem(pattern: nil, date: date, app: nil, mode: "capture").hasPrefix("Kriya Capture "))
    }

    // MARK: What the sheet shows

    func testThePreviewFollowsWhatIsTyped() {
        var model = FileNameEntryModel(typed: "Release notes", ext: "png")
        XCTAssertEqual(model.preview, "Saved as: Release notes.png")
        XCTAssertTrue(model.canSave)
        XCTAssertNil(model.note)
        model.typed = "Release/notes"
        XCTAssertEqual(model.preview, "A file name cannot contain “/”. Take it out or use another character.")
        XCTAssertFalse(model.canSave, "Save is off while the name cannot be used")
        XCTAssertNil(model.finalName)
        model.typed = ""
        XCTAssertFalse(model.canSave)
    }

    func testThePreviewSaysWhenTheNameHadToChange() {
        let taken: Set<String> = ["Shot.png"]
        let model = FileNameEntryModel(typed: "Shot", ext: "png", existing: { taken.contains($0) })
        XCTAssertEqual(model.preview, "Saved as: Shot 2.png")
        XCTAssertEqual(model.note, "A file called “Shot.png” is already there, so this one gets a number.")
        let retina = FileNameEntryModel(typed: "Shot", ext: "png", suffix: { _ in "@2x" })
        XCTAssertEqual(retina.preview, "Saved as: Shot@2x.png")
        XCTAssertEqual(retina.note, "“@2x” is added for a Retina picture at full size.")
    }

    func testThePreviewIsExactlyWhatWillBeWritten() {
        let taken: Set<String> = ["a.png", "a 2.png"]
        let suffix: (String) -> String = { _ in "@2x" }
        for typed in ["a", "a.png", "b", "  c  "] {
            let model = FileNameEntryModel(typed: typed, ext: "png", existing: { taken.contains($0) }, suffix: suffix)
            XCTAssertEqual(model.preview, "Saved as: " + (FileNameEntry.finalName(typed: typed, ext: "png", existing: { taken.contains($0) }, suffix: suffix) ?? ""), typed)
        }
    }
}

final class AskForNameFlowTests: XCTestCase {
    private var folder: URL!
    private var board: NSPasteboard!
    private var service: ScreenCaptureService!
    private var asked: [(suggested: String, ext: String, folder: URL)] = []

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("kriya-name-\(UUID().uuidString)")
        board = NSPasteboard(name: NSPasteboard.Name("kriya-name-\(UUID().uuidString)"))
        let store = CaptureSettingsStore(defaults: UserDefaults(suiteName: "kriya-name-\(UUID().uuidString)")!)
        store.update { $0.folderPath = folder.path; $0.copyImage = true; $0.saveToFolder = true }
        service = ScreenCaptureService(settings: store)
        service.pasteboard = board
        service.hasPermission = { true }
        var policy = CaptureDeliveryPolicy()
        policy.output.askForName = true
        service.deliveryPolicy = { policy }
        asked = []
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        board.releaseGlobally()
    }

    private func picture() -> CGImage {
        let context = CGContext(data: nil, width: 8, height: 6, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.1, green: 0.4, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 6))
        return context.makeImage()!
    }

    /// Delivers a picture as a capture does, and waits for it to be handled.
    private func deliver() {
        let handled = expectation(description: "delivered")
        service.process(picture(), action: .normal, settings: service.settings.settings)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { handled.fulfill() }
        wait(for: [handled], timeout: 5)
    }

    private func files() -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted() }

    func testTheTypedNameIsUsedForTheFile() {
        service.askForFileName = { [unowned self] suggested, ext, folder, _ in asked.append((suggested, ext, folder)); return "My screenshot" }
        deliver()
        XCTAssertEqual(files(), ["My screenshot.png"])
        XCTAssertEqual(asked.count, 1)
        XCTAssertEqual(asked.first?.ext, "png")
        XCTAssertEqual(asked.first?.folder.path, folder.path)
        XCTAssertTrue(asked.first?.suggested.hasPrefix("Kriya Capture ") == true, "it starts from the usual name")
    }

    func testNotSavingSkipsOnlyTheFileAndTheCopyStillHappens() {
        service.askForFileName = { _, _, _, _ in nil }
        deliver()
        XCTAssertTrue(files().isEmpty, "nothing was saved")
        XCTAssertNotNil(board.data(forType: .png), "the copy does not depend on saving")
    }

    func testAFileModeCopyStillWorksWhenTheFileWasNotSaved() throws {
        var policy = CaptureDeliveryPolicy()
        policy.output.askForName = true
        policy.output.clipboard = .file
        service.deliveryPolicy = { policy }
        service.askForFileName = { _, _, _, _ in nil }
        deliver()
        XCTAssertTrue(files().isEmpty)
        let url = try XCTUnwrap((board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])?.first, "a file was written for the copy")
        XCTAssertFalse(url.path.hasPrefix(folder.path), "not in the capture folder")
        try? FileManager.default.removeItem(at: url)
    }

    func testANameThatIsTakenGetsACounterRatherThanReplacingTheFile() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data([1]).write(to: folder.appendingPathComponent("Notes.png"))
        service.askForFileName = { _, _, _, _ in "Notes" }
        deliver()
        XCTAssertEqual(files(), ["Notes 2.png", "Notes.png"])
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("Notes.png")), Data([1]), "the first was not replaced")
    }

    func testNothingIsAskedWhenTheSettingIsOffOrSavingIsOff() {
        var off = CaptureDeliveryPolicy()
        off.output.askForName = false
        service.deliveryPolicy = { off }
        service.askForFileName = { [unowned self] s, e, f, _ in asked.append((s, e, f)); return "x" }
        deliver()
        XCTAssertTrue(asked.isEmpty)
        XCTAssertEqual(files().count, 1)
        try? FileManager.default.removeItem(at: folder)
        var on = CaptureDeliveryPolicy()
        on.output.askForName = true
        service.deliveryPolicy = { on }
        service.settings.update { $0.saveToFolder = false }
        deliver()
        XCTAssertTrue(asked.isEmpty, "no file is saved, so there is no name to ask for")
    }

    func testTheSuffixForARetinaPictureIsPassedToTheSheetAndUsed() {
        var policy = CaptureDeliveryPolicy()
        policy.output.askForName = true
        policy.output.includeRetinaSuffix = true
        service.deliveryPolicy = { policy }
        var seen = ""
        service.askForFileName = { _, _, _, suffix in seen = suffix("Plan"); return "Plan" }
        deliver()
        XCTAssertTrue(seen == "" || seen == "@2x", "the suffix follows the display the test runs on: \(seen)")
        XCTAssertEqual(files().count, 1)
        XCTAssertTrue(files()[0].hasPrefix("Plan"))
    }

    func testAnInvalidTypedNameFallsBackToTheUsualPatternInsteadOfLosingTheCapture() {
        service.askForFileName = { _, _, _, _ in "bad/name" }
        deliver()
        XCTAssertEqual(files().count, 1, "the capture is still saved")
        XCTAssertTrue(files()[0].hasPrefix("Kriya Capture "))
    }

    func testTheSettingIsOffByDefaultAndKept() throws {
        XCTAssertFalse(OutputPolicy().askForName)
        var policy = CaptureDeliveryPolicy()
        policy.output.askForName = true
        let back = try JSONDecoder().decode(CaptureDeliveryPolicy.self, from: JSONEncoder().encode(policy))
        XCTAssertTrue(back.output.askForName)
    }
}
