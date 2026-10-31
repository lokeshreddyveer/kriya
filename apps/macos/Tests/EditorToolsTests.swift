import XCTest
import CoreGraphics
@testable import Kriya

// MARK: - 28: canvas expansion

final class CanvasExpansionTests: XCTestCase {
    private let image = CGRect(x: 0, y: 0, width: 200, height: 100)

    func testMarksInsideLeaveTheCanvasAlone() {
        let r = CanvasExpansion.canvas(imageRect: image, annotationBounds: CGRect(x: 10, y: 10, width: 50, height: 50), padding: 16)
        XCTAssertEqual(r.bounds, image); XCTAssertFalse(r.expanded); XCTAssertEqual(r.offset, .zero)
        XCTAssertEqual(CanvasExpansion.canvas(imageRect: image, annotationBounds: nil, padding: 16).bounds, image)
    }

    func testAMarkPastTheEdgeGrowsTheCanvasWithPaddingAndKeepsThePicture() {
        let r = CanvasExpansion.canvas(imageRect: image, annotationBounds: CGRect(x: 150, y: 20, width: 100, height: 30), padding: 10)
        XCTAssertEqual(r.bounds, image.union(CGRect(x: 150, y: 20, width: 100, height: 30)).insetBy(dx: -10, dy: -10))
        XCTAssertTrue(r.bounds.contains(image)); XCTAssertTrue(r.expanded)
        XCTAssertEqual(r.offset, CGPoint(x: 10, y: 10), "the picture sits that far in from the canvas's top left")
    }

    func testOnlyTheSidesThatNeedRoomGrowEnoughButAllGetPaddingAsTheFormulaSays() {
        let r = CanvasExpansion.canvas(imageRect: image, annotationBounds: CGRect(x: -30, y: 10, width: 40, height: 20), padding: 0)
        XCTAssertEqual(r.bounds.minX, -30); XCTAssertEqual(r.bounds.maxX, 200); XCTAssertEqual(r.bounds.minY, 0)
    }

    func testTheCanvasNeverPassesTheLimitAndAlwaysKeepsThePicture() {
        let r = CanvasExpansion.canvas(imageRect: image, annotationBounds: CGRect(x: 0, y: 0, width: 90_000, height: 90_000), padding: 50)
        XCTAssertLessThanOrEqual(r.bounds.width, CanvasExpansion.maxSide); XCTAssertLessThanOrEqual(r.bounds.height, CanvasExpansion.maxSide)
        XCTAssertTrue(r.bounds.contains(image))
        XCTAssertEqual(CanvasExpansion.canvas(imageRect: image, annotationBounds: CGRect(x: CGFloat.nan, y: 0, width: 1, height: 1), padding: 4).bounds, image)
    }

    func testMarksAreHeldToTheReachOrToThePicture() {
        XCTAssertEqual(CanvasExpansion.clamped(CGPoint(x: -9, y: 9), canGrow: false), CGPoint(x: 0, y: 1))
        XCTAssertEqual(CanvasExpansion.clamped(CGPoint(x: -9, y: 9), canGrow: true), CGPoint(x: -2, y: 3))
        XCTAssertEqual(CanvasExpansion.clamped(CGPoint(x: 0.4, y: .nan), canGrow: true), CGPoint(x: 0.4, y: 0))
    }

    private func solid(_ w: Int, _ h: Int) -> CGImage {
        let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(CGColor(gray: 0.5, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return c.makeImage()!
    }

    func testRenderingGrowsTheExportNotTheSource() throws {
        let source = solid(100, 100)
        let mark = Annotation(kind: .box, start: CGPoint(x: 0.5, y: 0.5), end: CGPoint(x: 1.6, y: 0.9))
        let plain = try XCTUnwrap(CaptureRenderer.render(source, annotations: [mark]))
        XCTAssertEqual(plain.width, 100, "off: the picture's own size")
        let grown = try XCTUnwrap(CaptureRenderer.render(source, annotations: [mark], expandPadding: 8))
        XCTAssertGreaterThan(grown.width, 160)
        XCTAssertEqual(source.width, 100); XCTAssertEqual(source.height, 100)
        let inside = Annotation(kind: .box, start: CGPoint(x: 0.2, y: 0.2), end: CGPoint(x: 0.4, y: 0.4))
        XCTAssertEqual(try XCTUnwrap(CaptureRenderer.render(source, annotations: [inside], expandPadding: 8)).width, 100, "nothing outside: no growth")
    }

    func testTheProjectKeepsMarksOutsideOnlyWhenExpandedAndNeverChangesThePicture() throws {
        let wild = CaptureProject(image: Data([1]), marks: [.init(kind: "box", text: nil, number: nil, points: [[-1, 0.5], [2.5, 0.5]], color: "red")], canvasExpanded: true)
        XCTAssertEqual(try XCTUnwrap(CaptureProject.decode(try XCTUnwrap(wild.encoded()))).marks[0].points, [[-1, 0.5], [2.5, 0.5]])
        var plain = wild; plain.canvasExpanded = nil
        XCTAssertEqual(try XCTUnwrap(CaptureProject.decode(try XCTUnwrap(plain.encoded()))).marks[0].points, [[0, 0.5], [1, 0.5]])
        XCTAssertEqual(try XCTUnwrap(CaptureProject.decode(try XCTUnwrap(wild.encoded()))).image, Data([1]))
    }

    func testThePreferencesAreKeptAndPaddingIsHeld() throws {
        var p = EditorPreferences(); p.autoExpandCanvas = true; p.expandPadding = 24
        XCTAssertEqual(try JSONDecoder().decode(EditorPreferences.self, from: JSONEncoder().encode(p)), p)
        XCTAssertEqual(try JSONDecoder().decode(EditorPreferences.self, from: Data(#"{"expandPadding":9999}"#.utf8)).expandPadding, 200)
        XCTAssertFalse(EditorPreferences().autoExpandCanvas)
    }
}

// MARK: - 29: editor commands

final class EditorCommandRegistryTests: XCTestCase {
    func testEveryCommandHasATitleAndTheRequestedOnesExist() {
        XCTAssertEqual(Set(EditorCommand.allCases.map(\.rawValue)), ["save", "saveAs", "upload", "print", "copy", "duplicate", "addFile", "addClipboardImage", "undo", "redo", "restoreDefaults"])
        XCTAssertTrue(EditorCommand.allCases.allSatisfy { !$0.title.isEmpty })
        XCTAssertEqual(Set(EditorCommand.allCases.map(\.title)).count, EditorCommand.allCases.count)
    }

    func testDefaultKeysAreUniqueUsableAndRestoreDefaultsHasNone() {
        let registry = EditorCommandRegistry()
        XCTAssertTrue(registry.clashes.isEmpty)
        for command in EditorCommand.allCases where command != .restoreDefaults { XCTAssertTrue(registry.key(for: command)?.isUsable == true, "\(command)") }
        XCTAssertNil(registry.key(for: .restoreDefaults))
        XCTAssertEqual(registry.key(for: .save)?.display, "⌘S"); XCTAssertEqual(registry.key(for: .saveAs)?.display, "⇧⌘S")
    }

    func testAKeyCanBeChangedAndTakenKeysAndBareLettersAreRefused() {
        var r = EditorCommandRegistry()
        XCTAssertNil(r.set(EditorKey("k", [.command]), for: .save))
        XCTAssertEqual(r.key(for: .save)?.display, "⌘K")
        XCTAssertEqual(r.command(for: EditorKey("k", [.command])), .save)
        XCTAssertEqual(r.set(EditorKey("u", [.command]), for: .save), .takenBy(.upload))
        XCTAssertEqual(r.set(EditorKey("x", []), for: .save), .notUsable, "a plain letter would take over typing")
        XCTAssertEqual(r.set(EditorKey("k", [.command]), for: .restoreDefaults), .noKeyForThis)
        XCTAssertEqual(r.key(for: .save)?.display, "⌘K", "a refused change changes nothing")
    }

    func testRestoreDefaultsPutsEveryKeyBackAndGivingTheDefaultKeepsNoOverride() {
        var r = EditorCommandRegistry()
        r.set(EditorKey("k", [.command]), for: .save); r.set(EditorKey("j", [.command]), for: .print)
        XCTAssertEqual(r.overrides.count, 2)
        r.restoreDefaults()
        XCTAssertEqual(r, EditorCommandRegistry())
        r.set(EditorKey("s", [.command]), for: .save)
        XCTAssertTrue(r.overrides.isEmpty)
    }

    func testDamagedOverridesAreDropped() {
        let r = EditorCommandRegistry(overrides: [.save: EditorKey("a", []), .restoreDefaults: EditorKey("r", [.command])])
        XCTAssertTrue(r.overrides.isEmpty)
        let clash = EditorCommandRegistry(overrides: [.save: EditorKey("p", [.command])])
        XCTAssertEqual(clash.clashes, [[.print, .save]])
    }

    func testWhileTypingOnlyTextCommandsAreLeftToTheTextAndTheRestDoNothing() {
        let r = EditorCommandRegistry()
        for c in EditorCommand.allCases {
            let o = r.outcome(c, editingText: true, canUndo: true, canRedo: true, hasMarks: true)
            XCTAssertEqual(o, c.isStandardTextCommand ? .leaveToText : .disabled, "\(c)")
        }
        XCTAssertEqual(Set(EditorCommand.allCases.filter(\.isStandardTextCommand)), [.copy, .undo, .redo])
    }

    func testNotTypingEverythingRunsExceptWhatCannotBeDone() {
        let r = EditorCommandRegistry()
        XCTAssertEqual(r.outcome(.save, editingText: false, canUndo: false, canRedo: false, hasMarks: false), .run)
        XCTAssertEqual(r.outcome(.undo, editingText: false, canUndo: false, canRedo: true, hasMarks: true), .unavailable("There is nothing to undo."))
        XCTAssertEqual(r.outcome(.redo, editingText: false, canUndo: true, canRedo: false, hasMarks: true), .unavailable("There is nothing to redo."))
        XCTAssertEqual(r.outcome(.duplicate, editingText: false, canUndo: true, canRedo: true, hasMarks: false), .unavailable("There is no mark to duplicate."))
        XCTAssertEqual(r.outcome(.duplicate, editingText: false, canUndo: true, canRedo: true, hasMarks: true), .run)
    }

    func testTheShortcutsAreThePersonsOwnPreferenceAndSurviveSaving() throws {
        var p = EditorPreferences()
        var r = p.commandRegistry; r.set(EditorKey("k", [.command, .shift]), for: .upload); p.commandRegistry = r
        let back = try JSONDecoder().decode(EditorPreferences.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(back.commandRegistry.key(for: .upload)?.display, "⇧⌘K")
        XCTAssertEqual(try JSONDecoder().decode(EditorPreferences.self, from: Data(#"{"shortcutOverrides":5}"#.utf8)).commandRegistry, EditorCommandRegistry())
    }
}

// MARK: - 30: tools

final class EditorToolTests: XCTestCase {
    private func box(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat, _ kind: Annotation.Kind = .box) -> Annotation {
        Annotation(kind: kind, start: CGPoint(x: x1, y: y1), end: CGPoint(x: x2, y: y2))
    }

    func testEveryToolHasALabelAHelpLineAndASymbol() {
        for tool in CaptureEditorModel.Tool.allCases {
            XCTAssertFalse(tool.symbol.isEmpty, tool.rawValue); XCTAssertGreaterThan(tool.help.count, 8)
            XCTAssertTrue(tool.accessibilityName.hasPrefix("\(tool.rawValue) tool."))
        }
        XCTAssertTrue(["Spotlight", "Filled Box", "Crop", "Resize", "Move"].allSatisfy { name in CaptureEditorModel.Tool.allCases.contains { $0.rawValue == name } })
        XCTAssertFalse(CaptureEditorModel.Tool.move.drawsMark); XCTAssertTrue(CaptureEditorModel.Tool.spotlight.drawsMark); XCTAssertTrue(CaptureEditorModel.Tool.filledBox.drawsMark)
    }

    // MARK: Codable representation

    func testSpotlightAndFilledBoxSurviveAProject() throws {
        for (kind, name) in [(Annotation.Kind.spotlight, "spotlight"), (.filledBox, "filledBox")] {
            let mark = box(0.1, 0.2, 0.5, 0.6, kind)
            XCTAssertEqual(mark.mark.kind, name)
            let back = try XCTUnwrap(Annotation(mark: mark.mark))
            XCTAssertEqual(back.kind, kind); XCTAssertEqual(back.start, mark.start); XCTAssertEqual(back.end, mark.end)
        }
        let project = CaptureProject(image: Data([1]), resizeWidth: 640)
        XCTAssertEqual(try XCTUnwrap(CaptureProject.decode(try XCTUnwrap(project.encoded()))).resizeWidth, 640)
        XCTAssertEqual(try XCTUnwrap(CaptureProject.decode(try XCTUnwrap(CaptureProject(image: Data([1]), resizeWidth: 99_999_999).encoded()))).resizeWidth, 16_384)
        XCTAssertNil(try XCTUnwrap(CaptureProject.decode(try XCTUnwrap(CaptureProject(image: Data([1])).encoded()))).resizeWidth, "older projects have none")
    }

    // MARK: Renderers

    private func solid(_ w: Int, _ h: Int) -> CGImage {
        let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(CGColor(gray: 1, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: w, height: h)); return c.makeImage()!
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

    func testFilledBoxFillsItsPlaceWithTheColour() throws {
        let out = try XCTUnwrap(CaptureRenderer.render(solid(100, 100), annotations: [Annotation(kind: .filledBox, start: CGPoint(x: 0.2, y: 0.2), end: CGPoint(x: 0.6, y: 0.6), color: .black)]))
        XCTAssertLessThan(pixel(out, 40, 40)[0], 30); XCTAssertEqual(pixel(out, 90, 90), [255, 255, 255])
    }

    func testSpotlightDarkensOutsideAndLeavesInsideAlone() throws {
        let out = try XCTUnwrap(CaptureRenderer.render(solid(100, 100), annotations: [box(0.3, 0.3, 0.7, 0.7, .spotlight)]))
        XCTAssertEqual(pixel(out, 50, 50), [255, 255, 255]); XCTAssertLessThan(pixel(out, 5, 5)[0], 200)
        XCTAssertFalse(Annotation(kind: .spotlight, start: .zero, end: CGPoint(x: 1, y: 1)).canHaveShadow)
    }

    func testResizeKeepsTheShapeAndNeverChangesTheSource() {
        let src = solid(400, 200)
        let out = CaptureRenderer.resized(src, toWidth: 100)
        XCTAssertEqual(out.width, 100); XCTAssertEqual(out.height, 50); XCTAssertEqual(src.width, 400)
        XCTAssertTrue(CaptureRenderer.resized(src, toWidth: 400) === src)
        XCTAssertEqual(ResizeRules.size(of: CGSize(width: 300, height: 100), width: 150), CGSize(width: 150, height: 50))
        XCTAssertEqual(ResizeRules.width(from: 100, factor: 0.00001), 16); XCTAssertEqual(ResizeRules.width(from: 100, factor: 1e9), 16_384)
        XCTAssertEqual(ResizeRules.width(from: 100, factor: .nan), 100)
        XCTAssertEqual(ResizeRules.factor(forDrag: 0.1), 1.1, accuracy: 0.0001); XCTAssertGreaterThan(ResizeRules.factor(forDrag: -5), 0)
    }

    // MARK: Undo for every tool

    func testHistoryUndoesAndRedoesEveryKindOfEdit() {
        var h = EditorHistory()
        let a = box(0.1, 0.1, 0.4, 0.4), b = box(0.5, 0.5, 0.8, 0.8, .filledBox)
        h.perform(.added(a)); h.perform(.added(b))
        let moved = MarkGeometry(start: CGPoint(x: 0.6, y: 0.6), end: CGPoint(x: 0.9, y: 0.9), points: [])
        h.perform(.moved(id: b.id, from: MarkGeometry(b), to: moved))
        h.perform(.cropped(old: nil, new: CGRect(x: 0, y: 0, width: 0.5, height: 0.5)))
        h.perform(.resized(old: nil, new: 300))
        h.perform(.removed(a, at: 0))
        XCTAssertEqual(h.document.marks.map(\.id), [b.id]); XCTAssertEqual(h.document.crop?.width, 0.5); XCTAssertEqual(h.document.resizeWidth, 300)
        h.undo(); XCTAssertEqual(h.document.marks.map(\.id), [a.id, b.id], "the removed mark is back where it was")
        h.undo(); XCTAssertNil(h.document.resizeWidth)
        h.undo(); XCTAssertNil(h.document.crop)
        h.undo(); XCTAssertEqual(h.document.marks[1].start, b.start)
        h.redo(); XCTAssertEqual(h.document.marks[1].start, moved.start)
        h.undo(); h.undo(); h.undo(); h.undo()
        XCTAssertTrue(h.document.marks.isEmpty); XCTAssertFalse(h.canUndo); XCTAssertFalse(h.undo())
        XCTAssertTrue(h.canRedo)
        h.perform(.added(a))
        XCTAssertFalse(h.canRedo, "a new edit ends what could be done again")
    }

    func testBulkReplaceIsOneUndoStep() {
        var h = EditorHistory()
        let a = box(0, 0, 0.1, 0.1); var shadowed = a; shadowed.shadow = AnnotationShadow(enabled: true)
        h.perform(.added(a)); h.perform(.replaced(old: [a], new: [shadowed]))
        XCTAssertTrue(h.document.marks[0].shadow.enabled)
        h.undo(); XCTAssertFalse(h.document.marks[0].shadow.enabled)
    }

    // MARK: Move/select: mouse

    func testAClickSelectsTheTopmostMarkUnderIt() throws {
        let below = box(0.1, 0.1, 0.6, 0.6), above = box(0.3, 0.3, 0.8, 0.8)
        let hit = try XCTUnwrap(MoveSession.begin(at: CGPoint(x: 0.4, y: 0.4), in: [below, above]))
        XCTAssertEqual(hit.mark.id, above.id, "later marks are drawn on top")
        XCTAssertEqual(MoveSession.begin(at: CGPoint(x: 0.15, y: 0.15), in: [below, above])?.mark.id, below.id)
        XCTAssertNil(MoveSession.begin(at: CGPoint(x: 0.95, y: 0.95), in: [below, above]))
    }

    func testLinesPensTextAndNumbersCanBeHit() {
        let line = box(0.1, 0.1, 0.9, 0.9, .line)
        XCTAssertTrue(line.isHit(at: CGPoint(x: 0.5, y: 0.5))); XCTAssertFalse(line.isHit(at: CGPoint(x: 0.9, y: 0.1)))
        let pen = Annotation(kind: .pen, start: CGPoint(x: 0.1, y: 0.5), end: CGPoint(x: 0.9, y: 0.5), points: [CGPoint(x: 0.1, y: 0.5), CGPoint(x: 0.9, y: 0.5)])
        XCTAssertTrue(pen.isHit(at: CGPoint(x: 0.5, y: 0.505))); XCTAssertFalse(pen.isHit(at: CGPoint(x: 0.5, y: 0.7)))
        XCTAssertTrue(Annotation(kind: .text("Hi"), start: CGPoint(x: 0.2, y: 0.2), end: CGPoint(x: 0.2, y: 0.2)).isHit(at: CGPoint(x: 0.25, y: 0.22)))
        XCTAssertTrue(Annotation(kind: .number(1), start: CGPoint(x: 0.5, y: 0.5), end: CGPoint(x: 0.5, y: 0.5)).isHit(at: CGPoint(x: 0.51, y: 0.5)))
    }

    func testDraggingMovesByTheDragAndIsHeldInsideThePicture() throws {
        let mark = box(0.2, 0.2, 0.4, 0.4)
        let session = try XCTUnwrap(MoveSession.begin(at: CGPoint(x: 0.3, y: 0.3), in: [mark])).session
        let g = session.geometry(at: CGPoint(x: 0.4, y: 0.35), for: mark, canGrow: false)
        XCTAssertEqual(g.start.x, 0.3, accuracy: 0.0001); XCTAssertEqual(g.start.y, 0.25, accuracy: 0.0001)
        let far = session.geometry(at: CGPoint(x: 5, y: 5), for: mark, canGrow: false)
        XCTAssertEqual(far.end.x, 1, accuracy: 0.0001); XCTAssertEqual(far.end.y, 1, accuracy: 0.0001)
        let out = session.geometry(at: CGPoint(x: 5, y: 5), for: mark, canGrow: true)
        XCTAssertEqual(out.end.x, 3, accuracy: 0.0001, "with a growing canvas it may go out to the reach")
    }

    // MARK: Model: one drag is one undo, keys, selection

    func testADragIsOneUndoStepAndRecordsNothingUntilItEnds() {
        let model = CaptureEditorModel(image: solid(50, 50), preferences: EditorPreferences())
        let mark = box(0.2, 0.2, 0.4, 0.4); model.add(mark)
        model.beginMove(at: CGPoint(x: 0.3, y: 0.3))
        XCTAssertEqual(model.selectedID, mark.id)
        for x in stride(from: 0.31, through: 0.5, by: 0.05) { model.dragMove(to: CGPoint(x: x, y: 0.3)) }
        XCTAssertEqual(model.annotations[0].start, mark.start, "not recorded yet")
        XCTAssertNotEqual(model.livePreview?.marks[0].start, mark.start, "but it is shown")
        model.endMove()
        XCTAssertNil(model.livePreview); XCTAssertNotEqual(model.annotations[0].start, mark.start)
        model.undo()
        XCTAssertEqual(model.annotations[0].start, mark.start); XCTAssertEqual(model.history.undoStack.count, 1)
    }

    func testClickingOnNothingSelectsNothingAndAClickWithoutADragRecordsNothing() {
        let model = CaptureEditorModel(image: solid(50, 50), preferences: EditorPreferences())
        model.add(box(0.2, 0.2, 0.4, 0.4))
        model.beginMove(at: CGPoint(x: 0.3, y: 0.3)); model.endMove()
        XCTAssertEqual(model.history.undoStack.count, 1, "only the add")
        model.beginMove(at: CGPoint(x: 0.9, y: 0.9))
        XCTAssertNil(model.selectedID)
    }

    func testKeysNudgeDeleteDeselectAndAreIgnoredByOtherTools() {
        let model = CaptureEditorModel(image: solid(50, 50), preferences: EditorPreferences())
        let mark = box(0.2, 0.2, 0.4, 0.4); model.add(mark)
        model.tool = .box
        XCTAssertFalse(model.handleKey("left", shift: false), "not the Move tool")
        model.tool = .move
        XCTAssertFalse(model.handleKey("left", shift: false), "nothing selected")
        model.beginMove(at: CGPoint(x: 0.3, y: 0.3)); model.endMove()
        XCTAssertTrue(model.handleKey("right", shift: false))
        XCTAssertEqual(model.annotations[0].start.x, 0.202, accuracy: 0.0001)
        XCTAssertTrue(model.handleKey("down", shift: true))
        XCTAssertEqual(model.annotations[0].start.y, 0.22, accuracy: 0.0001)
        XCTAssertTrue(model.handleKey("delete", shift: false))
        XCTAssertTrue(model.annotations.isEmpty); XCTAssertNil(model.selectedID)
        model.undo(); XCTAssertEqual(model.annotations.count, 1, "the deleted mark comes back")
        model.beginMove(at: CGPoint(x: 0.3, y: 0.3)); model.endMove()
        XCTAssertTrue(model.handleKey("escape", shift: false)); XCTAssertNil(model.selectedID)
    }

    func testResizeKeysAndCropKeys() {
        let model = CaptureEditorModel(image: solid(400, 200), preferences: EditorPreferences())
        model.tool = .resize
        XCTAssertTrue(model.handleKey("+", shift: false)); XCTAssertEqual(model.resizeWidth, 440)
        XCTAssertTrue(model.handleKey("-", shift: false)); XCTAssertEqual(model.resizeWidth, 400)
        XCTAssertTrue(model.handleKey("0", shift: false)); XCTAssertNil(model.resizeWidth)
        XCTAssertFalse(model.handleKey("x", shift: false))
        model.resize(byFactor: 0.5); XCTAssertEqual(model.finished()?.width, 200)
        model.undo(); XCTAssertEqual(model.finished()?.width, 400)
        model.tool = .crop
        XCTAssertFalse(model.handleKey("escape", shift: false), "no crop to clear")
        model.setCrop(CGRect(x: 0, y: 0, width: 0.5, height: 0.5))
        XCTAssertEqual(model.finished()?.width, 200)
        XCTAssertTrue(model.handleKey("escape", shift: false)); XCTAssertNil(model.crop)
        model.undo(); XCTAssertNotNil(model.crop)
    }

    func testDuplicateCopiesTheLastMarkAndUndoTakesItBack() {
        let model = CaptureEditorModel(image: solid(50, 50), preferences: EditorPreferences())
        model.duplicateLastMark(); XCTAssertTrue(model.annotations.isEmpty)
        model.add(box(0.2, 0.2, 0.4, 0.4))
        model.duplicateLastMark()
        XCTAssertEqual(model.annotations.count, 2); XCTAssertEqual(model.selectedID, model.annotations[1].id)
        XCTAssertNotEqual(model.annotations[0].id, model.annotations[1].id)
        XCTAssertGreaterThan(model.annotations[1].start.x, model.annotations[0].start.x)
        model.undo(); XCTAssertEqual(model.annotations.count, 1); XCTAssertNil(model.selectedID)
    }

    func testReplacingThePictureStartsClean() {
        let model = CaptureEditorModel(image: solid(50, 50), preferences: EditorPreferences())
        model.add(box(0, 0, 0.5, 0.5)); model.replaceImage(solid(80, 40))
        XCTAssertEqual(model.image.width, 80); XCTAssertTrue(model.annotations.isEmpty); XCTAssertFalse(model.canUndo)
    }

    func testTheFinishedPictureUsesMarksCropResizeAndExpansionInOrder() throws {
        var p = EditorPreferences(); p.autoExpandCanvas = true; p.expandPadding = 0
        let model = CaptureEditorModel(image: solid(100, 100), preferences: p)
        model.add(box(0.5, 0.5, 1.6, 0.9))
        XCTAssertGreaterThan(try XCTUnwrap(model.finished()).width, 150, "grew for the mark")
        model.setResizeWidth(60); XCTAssertEqual(model.finished()?.width, 60)
    }
}
