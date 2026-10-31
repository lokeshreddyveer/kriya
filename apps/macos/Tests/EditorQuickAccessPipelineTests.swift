import XCTest
import CoreGraphics
@testable import Kriya

// MARK: - 27: annotation shadows

final class AnnotationShadowTests: XCTestCase {
    private func canvas(_ size: Int = 120) -> CGImage {
        let c = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(CGColor(gray: 1, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: size, height: size))
        return c.makeImage()!
    }

    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> [Int] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { raw in
            CGContext(data: raw.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                .draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        let i = (y * image.width + x) * 4
        return [Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2])]
    }

    private func box(shadow: AnnotationShadow) -> Annotation {
        Annotation(kind: .box, start: CGPoint(x: 0.3, y: 0.3), end: CGPoint(x: 0.6, y: 0.6), color: .red, shadow: shadow)
    }

    func testByDefaultThereIsNoShadow() {
        XCTAssertFalse(AnnotationShadow().enabled)
        XCTAssertFalse(Annotation(kind: .box, start: .zero, end: CGPoint(x: 1, y: 1)).shadow.enabled)
    }

    func testAShadowDarkensThePictureBesideTheMarkAndNoShadowLeavesItWhite() throws {
        let plain = try XCTUnwrap(CaptureRenderer.render(canvas(), annotations: [box(shadow: AnnotationShadow())]))
        let shadowed = try XCTUnwrap(CaptureRenderer.render(canvas(), annotations: [box(shadow: AnnotationShadow(enabled: true, blur: 4, opacity: 0.8, offset: CGSize(width: 0, height: 10)))]))
        // The box ends at 72 of 120 from the top; its shadow is 10 pixels further down, at 82.
        let below = pixel(shadowed, 60, 82), beforeBelow = pixel(plain, 60, 82)
        XCTAssertEqual(beforeBelow, [255, 255, 255])
        XCTAssertLessThan(below[0], 250, "the shadow is there")
    }

    func testTheShadowIsDrawnBeforeTheMarkSoTheMarkItselfIsUnchanged() throws {
        let plain = try XCTUnwrap(CaptureRenderer.render(canvas(), annotations: [box(shadow: AnnotationShadow())]))
        let shadowed = try XCTUnwrap(CaptureRenderer.render(canvas(), annotations: [box(shadow: AnnotationShadow(enabled: true, blur: 3, opacity: 0.9, offset: CGSize(width: 6, height: 6)))]))
        // The top edge of the box is a red stroke; it looks the same with and without the shadow.
        XCTAssertEqual(pixel(plain, 60, 36), pixel(shadowed, 60, 36))
    }

    func testBlocksThatHideAndMosaicsStayFlat() {
        XCTAssertFalse(Annotation(kind: .hide, start: .zero, end: CGPoint(x: 1, y: 1)).canHaveShadow)
        XCTAssertFalse(Annotation(kind: .blur, start: .zero, end: CGPoint(x: 1, y: 1)).canHaveShadow)
        XCTAssertTrue(Annotation(kind: .arrow, start: .zero, end: CGPoint(x: 1, y: 1)).canHaveShadow)
    }

    func testEveryKindOfMarkCanBeDrawnWithAShadowWithoutFailing() throws {
        let s = AnnotationShadow(enabled: true)
        for kind in [Annotation.Kind.box, .arrow, .highlight, .text("Hi"), .line, .ellipse, .number(2), .pen] {
            var m = Annotation(kind: kind, start: CGPoint(x: 0.2, y: 0.2), end: CGPoint(x: 0.7, y: 0.6), shadow: s)
            if kind == .pen { m.points = [CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.4, y: 0.5), CGPoint(x: 0.7, y: 0.6)] }
            XCTAssertNotNil(CaptureRenderer.render(canvas(), annotations: [m]), "\(kind)")
        }
    }

    func testAShadowIsKeptInAProjectAndOldProjectsHaveNone() throws {
        let marked = box(shadow: AnnotationShadow(enabled: true, blur: 9, opacity: 0.5, offset: CGSize(width: 3, height: 4)))
        let back = try XCTUnwrap(Annotation(mark: marked.mark))
        XCTAssertEqual(back.shadow, marked.shadow)
        XCTAssertNil(box(shadow: AnnotationShadow()).mark.shadow, "no shadow is not written")
        let old = try JSONDecoder().decode(CaptureProject.Mark.self, from: Data(#"{"kind":"box","points":[[0,0],[1,1]],"color":"red"}"#.utf8))
        XCTAssertNil(old.shadow)
        XCTAssertFalse(try XCTUnwrap(Annotation(mark: old)).shadow.enabled)
    }

    func testDamagedValuesAreHeldInRange() {
        let s = AnnotationShadow(enabled: true, blur: 999, opacity: -4, offset: CGSize(width: CGFloat.nan, height: 900)).sanitized()
        XCTAssertEqual(s.blur, 40)
        XCTAssertEqual(s.opacity, 0)
        XCTAssertEqual(s.offset.height, 40)
        XCTAssertEqual(s.offset.width, 0)
        XCTAssertEqual(try JSONDecoder().decode(AnnotationShadow.self, from: Data(#"{"blur":"x"}"#.utf8)), AnnotationShadow())
    }
}

// MARK: - 20, 21: editor

final class EditorPreferencesTests: XCTestCase {
    func testDefaultsChangeNothing() {
        let p = EditorPreferences()
        XCTAssertFalse(p.window.alwaysOnTop); XCTAssertFalse(p.window.showDockIcon)
        XCTAssertFalse(p.smoothPen); XCTAssertFalse(p.reverseArrowWithOption); XCTAssertFalse(p.showColourNames); XCTAssertFalse(p.remembersBackdropPanel)
        XCTAssertNil(p.startingBackdrop())
    }

    func testTheDockIconPolicyChangesOnlyWhenAskedForAndNeeded() {
        XCTAssertNil(EditorWindowRules.activationToSet(current: .accessory, showDockIcon: false))
        XCTAssertNil(EditorWindowRules.activationToSet(current: .regular, showDockIcon: true), "already has one")
        XCTAssertEqual(EditorWindowRules.activationToSet(current: .accessory, showDockIcon: true), .regular)
    }

    func testPreferencesAreSavedApartFromProjects() throws {
        let suite = "kriya.test.editor.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = EditorPreferencesStore(defaults: defaults)
        var p = EditorPreferences(); p.smoothPen = true; p.window.alwaysOnTop = true
        store.preferences = p
        XCTAssertEqual(EditorPreferencesStore(defaults: defaults).preferences, p)
        let project = CaptureProject(image: Data([1]))
        let text = String(decoding: try XCTUnwrap(project.encoded()), as: UTF8.self)
        for name in ["smoothPen", "alwaysOnTop", "reverseArrowWithOption"] { XCTAssertFalse(text.contains(name), "\(name) is not in a project file") }
        XCTAssertEqual(try JSONDecoder().decode(EditorPreferences.self, from: Data(#"{"smoothPen":"x"}"#.utf8)), EditorPreferences())
    }

    func testSmoothingKeepsTheEndsAndTheCountAndRemovesJitter() {
        let jagged = (0..<20).map { CGPoint(x: Double($0) / 19, y: 0.5 + ($0 % 2 == 0 ? 0.05 : -0.05)) }
        let smooth = PenSmoothing.smooth(jagged)
        XCTAssertEqual(smooth.count, jagged.count)
        XCTAssertEqual(smooth.first, jagged.first); XCTAssertEqual(smooth.last, jagged.last)
        func wobble(_ pts: [CGPoint]) -> Double { zip(pts, pts.dropFirst()).map { abs(Double($1.y - $0.y)) }.reduce(0, +) }
        XCTAssertLessThan(wobble(smooth), wobble(jagged) / 2)
        XCTAssertEqual(PenSmoothing.smooth([CGPoint.zero, CGPoint(x: 1, y: 1)]).count, 2)
    }

    func testOptionReversesAnArrowOnlyWhenSwitchedOn() {
        let a = CGPoint(x: 0.1, y: 0.1), b = CGPoint(x: 0.9, y: 0.9)
        var p = EditorPreferences()
        XCTAssertEqual(ArrowRules.ends(start: a, end: b, optionHeld: true, preferences: p).start, a)
        p.reverseArrowWithOption = true
        XCTAssertEqual(ArrowRules.ends(start: a, end: b, optionHeld: true, preferences: p).start, b)
        XCTAssertEqual(ArrowRules.ends(start: a, end: b, optionHeld: false, preferences: p).start, a)
    }

    func testTheBackdropPanelIsRememberedOnlyWhileOn() {
        var p = EditorPreferences()
        var style = CaptureBeautify(background: .ocean)
        style.shadow = false
        p.rememberBackdrop(style, shown: true)
        XCTAssertNil(p.startingBackdrop(), "off: nothing remembered")
        p.remembersBackdropPanel = true
        p.rememberBackdrop(style, shown: true)
        XCTAssertEqual(p.startingBackdrop()?.style, style)
        XCTAssertEqual(p.startingBackdrop()?.shown, true)
    }

    func testPreferencesAreRegistered() throws {
        XCTAssertNotNil(SettingsRegistry.entries.first { $0.key == EditorPreferencesStore.key })
    }
}

// MARK: - 22: Quick Access behaviour

final class QuickAccessBehaviourTests: XCTestCase {
    func testDefaultsKeepEverythingAsItWas() {
        let s = QuickAccessSettings()
        XCTAssertEqual(QuickAccessCard.afterDrag(s, optionHeld: false), .keepOpen)
        XCTAssertEqual(QuickAccessCard.afterUpload(s), .keepOpen)
        XCTAssertEqual(s.defaultSaveDestination.kind, .captureFolder)
    }

    func testCloseAfterDraggingAndOptionKeepsItOpen() {
        var s = QuickAccessSettings(); s.closeAfterDragging = true
        XCTAssertEqual(QuickAccessCard.afterDrag(s, optionHeld: false), .close)
        XCTAssertEqual(QuickAccessCard.afterDrag(s, optionHeld: true), .keepOpen)
        s.optionDragKeepsOpen = false
        XCTAssertEqual(QuickAccessCard.afterDrag(s, optionHeld: true), .close)
    }

    func testCloseAfterUpload() {
        var s = QuickAccessSettings(); s.closeAfterUpload = true
        XCTAssertEqual(QuickAccessCard.afterUpload(s), .close)
    }

    func testOptionPicksTheAlternateSaveDestination() {
        var s = QuickAccessSettings()
        s.defaultSaveDestination = SaveDestination(kind: .desktop)
        s.alternateSaveDestination = SaveDestination(kind: .ask)
        XCTAssertEqual(QuickAccessCard.destination(s, optionHeld: false).kind, .desktop)
        XCTAssertEqual(QuickAccessCard.destination(s, optionHeld: true).kind, .ask)
    }

    func testDestinationsResolveToPlaces() {
        let capture = URL(fileURLWithPath: "/c"), home = URL(fileURLWithPath: "/h")
        XCTAssertEqual(SaveDestination(kind: .captureFolder).place(captureFolder: capture, home: home), .folder(capture))
        XCTAssertEqual(SaveDestination(kind: .desktop).place(captureFolder: capture, home: home), .folder(URL(fileURLWithPath: "/h/Desktop", isDirectory: true)))
        XCTAssertEqual(SaveDestination(kind: .downloads).place(captureFolder: capture, home: home), .folder(URL(fileURLWithPath: "/h/Downloads", isDirectory: true)))
        XCTAssertEqual(SaveDestination(kind: .ask).place(captureFolder: capture, home: home), .ask)
        XCTAssertEqual(SaveDestination(kind: .custom, path: "/x/y").place(captureFolder: capture, home: home), .folder(URL(fileURLWithPath: "/x/y", isDirectory: true)))
        XCTAssertEqual(SaveDestination(kind: .custom).place(captureFolder: capture, home: home), .folder(capture), "a custom folder never chosen falls back")
    }

    func testOlderSettingsLoadAndNewOnesAreKept() throws {
        let old = try JSONDecoder().decode(QuickAccessSettings.self, from: Data(#"{"autoCloseSeconds":30,"position":"topRight"}"#.utf8))
        XCTAssertEqual(old.autoCloseSeconds, 30); XCTAssertEqual(old.position, .topRight); XCTAssertFalse(old.closeAfterUpload)
        var s = QuickAccessSettings(); s.closeAfterDragging = true; s.alternateSaveDestination = SaveDestination(kind: .custom, path: "/z")
        XCTAssertEqual(try JSONDecoder().decode(QuickAccessSettings.self, from: JSONEncoder().encode(s)), s)
    }
}

// MARK: - 23: window shots

final class WindowShotTests: XCTestCase {
    func testOlderChoicesMeanTheSameThingAsBefore() throws {
        for (look, style, shadow) in [(WindowLook.system, WindowShotStyle.system, false), (.windowOnly, .window, false), (.kriyaShadow, .window, true), (.background, .framed, true)] {
            let o = WindowShotOptions(look: look)
            XCTAssertEqual(o.style, style); XCTAssertEqual(o.shadow, shadow); XCTAssertEqual(o.look, look)
        }
        let modes = try JSONDecoder().decode(CaptureModeSettings.self, from: Data(#"{"windowLook":"kriyaShadow"}"#.utf8))
        XCTAssertEqual(modes.windowShot.style, .window)
        XCTAssertTrue(modes.windowShot.shadow)
        XCTAssertEqual(try JSONDecoder().decode(CaptureModeSettings.self, from: Data("{}".utf8)).windowShot, WindowShotOptions())
    }

    func testShiftInvertsTheTransparentBackgroundForOneCaptureOnlyForFramedWindows() {
        var o = WindowShotOptions(style: .framed, transparentBackground: false)
        XCTAssertTrue(o.effective(shiftHeld: true).transparentBackground)
        XCTAssertFalse(o.effective(shiftHeld: false).transparentBackground)
        o.transparentBackground = true
        XCTAssertFalse(o.effective(shiftHeld: true).transparentBackground)
        XCTAssertEqual(WindowShotOptions(style: .window).effective(shiftHeld: true), WindowShotOptions(style: .window))
        XCTAssertFalse(o.transparentBackground == o.effective(shiftHeld: true).transparentBackground && false)
    }

    func testResetDefaults() {
        var o = WindowShotOptions(style: .framed, transparentBackground: true, shadow: true, backdrop: .ocean)
        o.resetToDefaults()
        XCTAssertEqual(o, WindowShotOptions())
    }

    func testFramedOnABackdropGrowsAndTransparentAddsNoBackdrop() throws {
        let c = CGContext(data: nil, width: 60, height: 40, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(CGColor(gray: 0.5, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 60, height: 40))
        let image = c.makeImage()!
        let framed = CaptureLooks.apply(WindowShotOptions(style: .framed, backdrop: .ocean), shiftHeld: false, globalBackdropOn: false, to: image)
        XCTAssertGreaterThan(framed.width, 60)
        let transparent = CaptureLooks.apply(WindowShotOptions(style: .framed, transparentBackground: true), shiftHeld: false, globalBackdropOn: false, to: image)
        XCTAssertEqual(transparent.width, 60)
        let shifted = CaptureLooks.apply(WindowShotOptions(style: .framed, transparentBackground: true), shiftHeld: true, globalBackdropOn: false, to: image)
        XCTAssertGreaterThan(shifted.width, 60, "Shift put the backdrop back")
        XCTAssertEqual(CaptureLooks.apply(WindowShotOptions(style: .framed), shiftHeld: false, globalBackdropOn: true, to: image).width, 60, "never two backdrops")
    }
}

// MARK: - 24, 25: the pipeline

@MainActor
private final class RecordingActions: DeliveryActions {
    var calls: [DeliveryStage] = []
    var failUpload = false
    var saveReturnsNil = false
    var temporary = false
    var removed: [URL] = []
    var kept: URL?
    let file = URL(fileURLWithPath: "/tmp/kriya-test-file.png")

    func saveOutput(permanent: Bool) -> DeliveredFile? {
        calls.append(.saveTemporaryOutput)
        temporary = !permanent
        return saveReturnsNil ? nil : DeliveredFile(url: file, isTemporary: !permanent)
    }
    func copy(file: URL?) -> String? { calls.append(.copy); return nil }
    func upload(file: URL) async -> UploadResult { calls.append(.upload); return failUpload ? .failed("Upload failed.") : .uploaded(link: "https://x/y") }
    func copyLink(uploaded: String?, keptFile: URL?) -> String? { calls.append(.createLink); kept = keptFile; return uploaded ?? keptFile?.path }
    func openEditor() { calls.append(.openEditor) }
    func pin() { calls.append(.pin) }
    func showQuickAccessCard(keptFile: URL?) { calls.append(.createQuickAccessCard); kept = keptFile }
    func removeTemporary(_ files: [URL]) { calls.append(.removeTemporaryFiles); removed = files }
}

@MainActor
final class DeliveryPipelineTests: XCTestCase {
    private func everything(_ kind: CaptureKind = .screenshot) -> DeliverySteps {
        var s = DeliverySteps(); s.showQuickAccessCard = true; s.copy = true; s.save = false; s.upload = true; s.copyLink = true; s.annotate = true; s.pin = true; s.trim = true
        return s.normalized(for: kind)
    }

    func testTheStagesRunInTheFixedOrderWhateverWasChosen() async {
        let actions = RecordingActions()
        let report = await DeliveryPipeline.run(DeliveryJob(kind: .screenshot, steps: everything()), actions: actions)
        XCTAssertEqual(report.stages, [.saveTemporaryOutput, .copy, .upload, .createLink, .openEditor, .pin, .createQuickAccessCard, .removeTemporaryFiles])
        XCTAssertEqual(actions.calls, report.stages)
        XCTAssertEqual(report.stages, report.stages.sorted())
    }

    func testOnlyWhatWasChosenRuns() async {
        var s = DeliverySteps(); s.copy = true; s.save = false; s.showQuickAccessCard = false
        let actions = RecordingActions()
        let report = await DeliveryPipeline.run(DeliveryJob(kind: .screenshot, steps: s), actions: actions)
        XCTAssertEqual(report.stages, [.copy])
    }

    func testAKeptFileIsNeverRemovedAndATemporaryOneIs() async {
        var keep = DeliverySteps(); keep.save = true; keep.copy = true
        let a = RecordingActions()
        let r1 = await DeliveryPipeline.run(DeliveryJob(kind: .screenshot, steps: keep), actions: a)
        XCTAssertFalse(r1.stages.contains(.removeTemporaryFiles)); XCTAssertEqual(r1.keptFile, a.file)
        var temp = DeliverySteps(); temp.save = false; temp.copy = false; temp.upload = true
        let b = RecordingActions()
        let r2 = await DeliveryPipeline.run(DeliveryJob(kind: .screenshot, steps: temp), actions: b)
        XCTAssertEqual(r2.stages.last, .removeTemporaryFiles); XCTAssertEqual(b.removed, [b.file]); XCTAssertNil(r2.keptFile)
    }

    func testAFailedUploadDoesNotStopTheRest() async {
        let actions = RecordingActions(); actions.failUpload = true
        let report = await DeliveryPipeline.run(DeliveryJob(kind: .screenshot, steps: everything()), actions: actions)
        XCTAssertTrue(report.stages.contains(.createQuickAccessCard))
        XCTAssertTrue(report.messages.contains("Upload failed."))
    }

    func testNoFileMeansNoUploadAndSaysSo() async {
        let actions = RecordingActions(); actions.saveReturnsNil = true
        let report = await DeliveryPipeline.run(DeliveryJob(kind: .screenshot, steps: everything()), actions: actions)
        XCTAssertTrue(report.messages.contains("The output could not be written."))
        XCTAssertTrue(report.messages.contains("Nothing was uploaded: there was no file to upload."))
    }

    func testEachKindKeepsOnlyWhatMeansSomethingForIt() {
        var all = DeliverySteps(); all.annotate = true; all.pin = true; all.trim = true; all.save = false; all.showQuickAccessCard = true
        XCTAssertFalse(all.normalized(for: .screenshot).trim)
        let rec = all.normalized(for: .recording)
        XCTAssertFalse(rec.annotate); XCTAssertFalse(rec.pin); XCTAssertTrue(rec.trim); XCTAssertTrue(rec.save, "a recording is always kept")
        let text = all.normalized(for: .ocr)
        XCTAssertFalse(text.annotate || text.pin || text.trim || text.showQuickAccessCard)
        XCTAssertEqual(CaptureKind.of(.text), .ocr); XCTAssertEqual(CaptureKind.of(.textTable), .ocr)
    }

    func testSeparateValuesForEachKindAndTextDefaultsToCopyOnly() {
        var policy = CaptureDeliveryPolicy()
        var s = DeliverySteps(); s.upload = true
        policy.gif = s
        let settings = CaptureSettings()
        XCTAssertTrue(policy.steps(for: .gif, settings: settings).upload)
        XCTAssertFalse(policy.steps(for: .recording, settings: settings).upload)
        let text = policy.steps(for: .ocr, settings: settings)
        XCTAssertTrue(text.copy); XCTAssertFalse(text.save); XCTAssertFalse(text.showQuickAccessCard)
        let back = try? JSONDecoder().decode(CaptureDeliveryPolicy.self, from: JSONEncoder().encode(policy))
        XCTAssertEqual(back?.gif?.upload, true)
    }

    func testNothingNeedsAFileWhenOnlyCopyingAnImageAndAFileModeCopyDoes() {
        var s = DeliverySteps(); s.copy = true; s.save = false; s.showQuickAccessCard = false
        XCTAssertEqual(DeliveryPipeline.stages(for: DeliveryJob(kind: .screenshot, steps: s)), [.copy])
        XCTAssertEqual(DeliveryPipeline.stages(for: DeliveryJob(kind: .screenshot, steps: s, copyNeedsFile: true)), [.saveTemporaryOutput, .copy, .removeTemporaryFiles])
    }

    func testTheBackdropIsNotOnRecordingsOnlyTheirThumbnailsAndOcrHasNone() {
        var p = BackgroundPolicy(); p.recordingPreset = "starter.ocean"; p.screenshotPreset = "starter.sunset"
        XCTAssertEqual(p.recordingThumbnail(modifiers: [])?.background, .ocean)
        XCTAssertNil(p.recordingThumbnail(modifiers: [.shift]), "Shift skips it")
        XCTAssertNil(p.resolve(kind: .ocr, legacy: CaptureBeautify(background: .black), modifiers: []))
        p.exportOnly = true
        XCTAssertTrue(try! JSONDecoder().decode(BackgroundPolicy.self, from: JSONEncoder().encode(p)).exportOnly)
        XCTAssertFalse(BackgroundPolicy().exportOnly)
    }
}

// MARK: - 26: recording extras

private final class FakeFocus: FocusControlling {
    var state: DNDState
    var setCalls: [DNDState] = []
    var failSet = false
    init(_ state: DNDState) { self.state = state }
    func currentState() -> DNDState { state }
    func set(_ new: DNDState) -> Bool { setCalls.append(new); if failSet { return false }; state = new; return true }
}

final class RecordingExtrasTests: XCTestCase {
    private func defaults() throws -> (UserDefaults, String) {
        let suite = "kriya.test.focus.\(UUID().uuidString)"
        return (try XCTUnwrap(UserDefaults(suiteName: suite)), suite)
    }

    func testDoNotDisturbIsTurnedOnAndThenRestoredToOff() {
        let f = FakeFocus(.off)
        let t = FocusTransaction.begin(using: f)
        XCTAssertEqual(f.state, .on)
        XCTAssertEqual(t?.previousState, .off)
        XCTAssertEqual(t?.restore(using: f), true)
        XCTAssertEqual(f.state, .off)
    }

    func testIfItWasAlreadyOnNothingIsChangedAndItStaysOn() {
        let f = FakeFocus(.on)
        let t = FocusTransaction.begin(using: f)
        XCTAssertTrue(f.setCalls.isEmpty)
        t?.restore(using: f)
        XCTAssertEqual(f.state, .on)
        XCTAssertTrue(f.setCalls.isEmpty, "restoring what was already on changes nothing")
    }

    func testIfItCouldNotBeTurnedOnThereIsNoTransaction() {
        let f = FakeFocus(.off); f.failSet = true
        XCTAssertNil(FocusTransaction.begin(using: f))
    }

    func testAnUnknownStateIsRestoredToOffNeverLeftOn() {
        let f = FakeFocus(.unknown)
        let t = FocusTransaction.begin(using: f)
        XCTAssertEqual(t?.restoreTarget, .off)
        t?.restore(using: f)
        XCTAssertEqual(f.state, .off)
    }

    func testEveryEndOfARecordingRestoresIt() throws {
        let (d, suite) = try defaults(); defer { d.removePersistentDomain(forName: suite) }
        for _ in ["stop", "cancel", "error", "permission failure"] {
            let f = FakeFocus(.off)
            let focus = RecordingFocus(controller: f, store: FocusTransactionStore(defaults: d))
            XCTAssertNil(focus.begin())
            XCTAssertTrue(focus.isActive)
            focus.restore()
            XCTAssertEqual(f.state, .off)
            XCTAssertFalse(focus.isActive)
            focus.restore()
            XCTAssertEqual(f.setCalls, [.on, .off], "restoring again does nothing more")
            XCTAssertNil(FocusTransactionStore(defaults: d).pending)
        }
    }

    func testAQuitInTheMiddleIsPutRightAtTheNextStart() throws {
        let (d, suite) = try defaults(); defer { d.removePersistentDomain(forName: suite) }
        let f = FakeFocus(.off)
        let first = RecordingFocus(controller: f, store: FocusTransactionStore(defaults: d))
        XCTAssertNil(first.begin())
        XCTAssertEqual(f.state, .on)
        XCTAssertNotNil(FocusTransactionStore(defaults: d).pending, "written down at once")
        // Kriya quit here. The next run:
        let second = RecordingFocus(controller: f, store: FocusTransactionStore(defaults: d))
        XCTAssertTrue(second.recover())
        XCTAssertEqual(f.state, .off)
        XCTAssertFalse(second.recover(), "only once")
    }

    func testClicksAreShownOnlyWhenOnAndNotForAWindowRecordingUnlessAsked() {
        var o = ClickHighlightOptions()
        XCTAssertFalse(o.shows(for: .screen))
        o.enabled = true
        XCTAssertTrue(o.shows(for: .screen)); XCTAssertTrue(o.shows(for: .app))
        XCTAssertFalse(o.shows(for: .window))
        o.includeInWindowRecording = true
        XCTAssertTrue(o.shows(for: .window))
    }

    func testButtonsHaveTheirOwnColoursWhenToldApart() {
        var o = ClickHighlightOptions()
        XCTAssertNotEqual(o.colour(for: .left), o.colour(for: .right))
        o.distinguishButtons = false
        XCTAssertEqual(o.colour(for: .left), o.colour(for: .right))
    }

    func testTheClickOverlayCanBeShownAndAlwaysTakenAway() throws {
        try XCTSkipIf(NSScreen.screens.isEmpty, "needs a display")
        let overlay = ClickHighlightOverlay()
        var o = ClickHighlightOptions(); o.enabled = true
        overlay.show(options: o, source: .window)
        XCTAssertFalse(overlay.isShowing, "a window recording leaves it out")
        overlay.show(options: o, source: .screen)
        XCTAssertTrue(overlay.isShowing)
        overlay.hide(); overlay.hide()
        XCTAssertFalse(overlay.isShowing)
    }

    func testKeystrokeLabelsFollowTheStyleChosen() {
        var o = KeystrokeOptions()
        let mods: KeystrokeLabel.Modifiers = [.command, .shift]
        XCTAssertEqual(o.label(keyCode: 21, characters: "4", modifiers: mods, secureInput: false), "⇧⌘4")
        o.modifierLabels = .words
        XCTAssertEqual(o.label(keyCode: 21, characters: "4", modifiers: mods, secureInput: false), "Shift Cmd 4")
        XCTAssertEqual(o.label(keyCode: 0, characters: "a", modifiers: [], secureInput: false), "A")
    }

    func testPasswordFieldsAreHiddenUnlessThatIsTurnedOff() {
        var o = KeystrokeOptions()
        XCTAssertNil(o.label(keyCode: 0, characters: "a", modifiers: [], secureInput: true))
        o.hidePasswordFields = false
        XCTAssertEqual(o.label(keyCode: 0, characters: "a", modifiers: [], secureInput: true), "A")
    }

    func testKeystrokeSettingsAreHeldInRangeAndKept() throws {
        var o = KeystrokeOptions(); o.fadeSeconds = 99
        XCTAssertEqual(o.fade, 6)
        o.fadeSeconds = .nan
        XCTAssertEqual(o.fade, 1.6)
        o.fadeSeconds = 0
        XCTAssertEqual(o.fade, 0.5)
        o.position = .topCenter; o.theme = .light; o.size = .large
        XCTAssertEqual(try JSONDecoder().decode(KeystrokeOptions.self, from: JSONEncoder().encode(o)), o)
        XCTAssertEqual(try JSONDecoder().decode(KeystrokeOptions.self, from: Data(#"{"theme":"neon"}"#.utf8)), KeystrokeOptions())
        XCTAssertEqual(KeystrokeOptions.Size.allCases.map(\.fontSize), [18, 26, 38])
    }

    func testAudioTrackModeAndTheTrackCount() throws {
        var o = RecordingOptions(); o.systemAudio = true; o.microphone = true
        XCTAssertEqual(o.audioTrackMode, .separate)
        XCTAssertEqual(o.audioTrackCount, 2)
        o.audioTrackMode = .mixed
        XCTAssertEqual(o.audioTrackCount, 1)
        o.microphone = false
        XCTAssertEqual(o.audioTrackCount, 1)
        o.systemAudio = false
        XCTAssertEqual(o.audioTrackCount, 0)
        XCTAssertEqual(AudioTrackMode.allCases, [.separate, .mixed])
        XCTAssertEqual(try JSONDecoder().decode(RecordingOptions.self, from: Data(#"{"audioTrackMode":"weird"}"#.utf8)).audioTrackMode, .separate)
    }

    func testTheLastSelectionIsRevalidatedBeforeReuse() {
        let win = RememberedWindow(bundleID: "com.x", title: "Doc")
        let s = RecordingSelection(displayUUID: "D1", region: [10, 10, 200, 100], window: win)
        let sizes: [String: CGSize] = ["D1": CGSize(width: 1440, height: 900)]
        XCTAssertEqual(s.validated(displaySizes: sizes, windows: [win]), s)
        XCTAssertNil(s.validated(displaySizes: [:], windows: [win]).displayUUID, "the display was unplugged")
        XCTAssertNil(s.validated(displaySizes: [:], windows: [win]).region)
        XCTAssertNil(s.validated(displaySizes: sizes, windows: []).window, "the window was closed")
        XCTAssertEqual(s.validated(displaySizes: sizes, windows: nil).window, win, "unknown, so not guessed away")
        var big = s; big.region = [1400, 800, 200, 200]
        XCTAssertNil(big.validated(displaySizes: sizes, windows: [win]).region, "no longer fits the display")
        XCTAssertTrue(RecordingSelection().isEmpty)
    }

    func testTheFocusTransactionIsRegisteredAsMachineState() throws {
        XCTAssertEqual(try XCTUnwrap(SettingsRegistry.entries.first { $0.key == FocusTransactionStore.key }).kind, .machine)
    }
}
