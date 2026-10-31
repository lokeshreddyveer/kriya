import XCTest
@testable import Kriya

final class SelectorAidsTests: XCTestCase {
    func testBothOnIsTheDefault() {
        XCTAssertEqual(SelectorAids(), .both)
        let modes = CaptureModeSettings()
        XCTAssertTrue(modes.showCrosshair)
        XCTAssertTrue(modes.showMagnifier)
        XCTAssertEqual(modes.aids, .both)
    }

    func testBothOn() {
        let aids = SelectorAids.both
        XCTAssertEqual(aids.pointer(choosingArea: true), .crosshair)
        XCTAssertTrue(aids.magnifier(adjusting: false, pointerOnThisDisplay: true))
    }

    func testCrosshairOnly() {
        let aids = SelectorAids.crosshairOnly
        XCTAssertEqual(aids.pointer(choosingArea: true), .crosshair)
        XCTAssertFalse(aids.magnifier(adjusting: false, pointerOnThisDisplay: true))
    }

    func testMagnifierOnly() {
        let aids = SelectorAids.magnifierOnly
        XCTAssertEqual(aids.pointer(choosingArea: true), .arrow)
        XCTAssertTrue(aids.magnifier(adjusting: false, pointerOnThisDisplay: true))
    }

    func testBothOff() {
        let aids = SelectorAids.neither
        XCTAssertEqual(aids.pointer(choosingArea: true), .arrow)
        XCTAssertFalse(aids.magnifier(adjusting: false, pointerOnThisDisplay: true))
    }

    func testTheCrosshairIsOnlyForChoosingAnAreaWhateverTheSetting() {
        for aids in [SelectorAids.both, .crosshairOnly, .magnifierOnly, .neither] {
            XCTAssertEqual(aids.pointer(choosingArea: false), .arrow, "windows and displays are clicked with an arrow")
        }
    }

    func testTheMagnifierIsNeverDrawnWhileAdjustingOrOnAnotherDisplay() {
        for aids in [SelectorAids.both, .magnifierOnly] {
            XCTAssertFalse(aids.magnifier(adjusting: true, pointerOnThisDisplay: true))
            XCTAssertFalse(aids.magnifier(adjusting: false, pointerOnThisDisplay: false))
        }
    }

    func testTheFourCombinationsAreAllDifferent() {
        let all = [SelectorAids.both, .crosshairOnly, .magnifierOnly, .neither]
        XCTAssertEqual(Set(all.map { "\($0.showCrosshair)\($0.showMagnifier)" }).count, 4)
    }

    func testTheTwoSwitchesAreKeptSeparatelyAndOldSettingsHaveBothOn() throws {
        var modes = CaptureModeSettings()
        modes.showMagnifier = false
        XCTAssertEqual(modes.aids, .crosshairOnly)
        modes.aids = .magnifierOnly
        XCTAssertFalse(modes.showCrosshair)
        XCTAssertTrue(modes.showMagnifier)
        let back = try JSONDecoder().decode(CaptureModeSettings.self, from: JSONEncoder().encode(modes))
        XCTAssertEqual(back.aids, .magnifierOnly)
        let old = try JSONDecoder().decode(CaptureModeSettings.self, from: Data(#"{"display":"main","hideDesktopIcons":true}"#.utf8))
        XCTAssertEqual(old.aids, .both)
        XCTAssertTrue(old.hideDesktopIcons)
    }

    func testThePixelRulerDoesNotReadTheSelectorsSettings() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/Adapter/Capture")
        let ruler = try String(contentsOf: sources.appendingPathComponent("PixelRuler.swift"), encoding: .utf8)
        for name in ["SelectorAids", "showCrosshair", "showMagnifier", "CaptureExtraSettings.modes"] {
            XCTAssertFalse(ruler.contains(name), "the pixel ruler must not depend on \(name)")
        }
        let selector = try String(contentsOf: sources.appendingPathComponent("CaptureSelector.swift"), encoding: .utf8)
        XCTAssertTrue(selector.contains("model.aids"), "the selector reads them")
    }
}

final class CaptureMemoryTests: XCTestCase {
    private let a = RememberedWindow(bundleID: "com.apple.Safari", title: "Apple")
    private let b = RememberedWindow(bundleID: "com.apple.Notes", title: "Shopping")

    // MARK: Defaults and old settings

    func testByDefaultItRemembersAndHoldsNothingYet() {
        let memory = CaptureMemory()
        XCTAssertTrue(memory.remembers)
        XCTAssertEqual(memory.recording, .screen)
        XCTAssertNil(memory.displayUUID)
        XCTAssertNil(memory.window)
        let modes = CaptureModeSettings()
        XCTAssertEqual(modes.memory, memory)
        XCTAssertEqual(modes.lastChoice, .area)
        XCTAssertEqual(modes.scrollMode, .automatic)
    }

    func testSettingsFromBeforeLoadAndDamagedMemoryIsTheDefault() throws {
        XCTAssertEqual(try JSONDecoder().decode(CaptureModeSettings.self, from: Data(#"{"lastChoice":"window","scrollMode":"manual"}"#.utf8)).memory, CaptureMemory())
        XCTAssertEqual(try JSONDecoder().decode(CaptureMemory.self, from: Data(#"{"remembers":"yes","recording":"warp","displayUUID":5,"window":"x"}"#.utf8)), CaptureMemory())
        let old = try JSONDecoder().decode(CaptureModeSettings.self, from: Data(#"{"lastChoice":"window","scrollMode":"manual"}"#.utf8))
        XCTAssertEqual(old.lastChoice, .window, "what was remembered before is still remembered")
        XCTAssertEqual(old.scrollMode, .manual)
    }

    func testEverythingIsKeptAcrossARestart() throws {
        var modes = CaptureModeSettings()
        modes.rememberChoice(.scrolling)
        modes.rememberScrollMode(.manual)
        modes.memory.rememberRecording(.recordWindow)
        modes.memory.rememberDisplay("ABC-123")
        modes.memory.rememberWindow(bundleID: a.bundleID, title: a.title)
        let back = try JSONDecoder().decode(CaptureModeSettings.self, from: JSONEncoder().encode(modes))
        XCTAssertEqual(back, modes)
        XCTAssertEqual(back.lastChoice, .scrolling)
        XCTAssertEqual(back.scrollMode, .manual)
        XCTAssertEqual(back.memory.recording, .window)
        XCTAssertEqual(back.memory.displayUUID, "ABC-123")
        XCTAssertEqual(back.memory.window, a)
    }

    // MARK: What is remembered

    func testTheKindOfRecordingFollowsTheActionStarted() {
        var memory = CaptureMemory()
        for (action, expected) in [(CaptureAction.recordWindow, RecordingChoice.window), (.recordApp, .app), (.recordGIF, .gif), (.recordScreen, .screen), (.record, .screen)] {
            memory.rememberRecording(action)
            XCTAssertEqual(memory.recording, expected, "\(action)")
        }
        memory.rememberRecording(.recordWindow)
        memory.rememberRecording(.normal)
        memory.rememberRecording(.scroll)
        XCTAssertEqual(memory.recording, .window, "something that is not a recording does not change it")
        XCTAssertNil(RecordingChoice.of(.pin))
    }

    func testEachRecordingKindHasItsCommand() {
        XCTAssertEqual(RecordingChoice.allCases.map(\.command), ["capture.rec.screen", "capture.rec.window", "capture.rec.app", "capture.gif"])
        for choice in RecordingChoice.allCases { XCTAssertTrue(CaptureSettings.commands.contains { $0.command == choice.command }, choice.command) }
    }

    func testTheRecordRowStartsTheKindOfRecordingUsedLast() {
        var modes = CaptureModeSettings()
        XCTAssertEqual(modes.command(for: .recordScreen), "capture.rec.screen")
        modes.memory.rememberRecording(.recordWindow)
        XCTAssertEqual(modes.command(for: .recordScreen), "capture.rec.window")
        modes.memory.rememberRecording(.recordApp)
        XCTAssertEqual(modes.command(for: .recordScreen), "capture.rec.app")
        modes.memory.rememberRecording(.recordGIF)
        XCTAssertEqual(modes.command(for: .recordScreen), "capture.rec.screen", "GIF has its own row")
        XCTAssertEqual(modes.command(for: .recordGIF), CaptureChoice.recordGIF.command)
        XCTAssertEqual(modes.command(for: .area), CaptureChoice.area.command)
    }

    func testTheChooserOpensOnTheLastChoiceOrAreaWhenNotRemembering() {
        var modes = CaptureModeSettings()
        modes.rememberChoice(.window)
        XCTAssertEqual(modes.chooserStart, .window)
        modes.memory.remembers = false
        XCTAssertEqual(modes.chooserStart, .area)
        modes.rememberChoice(.screen)
        XCTAssertEqual(modes.lastChoice, .window, "nothing new is remembered while it is off")
    }

    func testTheScrollingModeIsRememberedOnlyWhileRemembering() {
        var modes = CaptureModeSettings()
        modes.rememberScrollMode(.manual)
        XCTAssertEqual(modes.scrollMode, .manual)
        modes.memory.remembers = false
        modes.rememberScrollMode(.automatic)
        XCTAssertEqual(modes.scrollMode, .manual)
    }

    func testWhileOffNothingIsRememberedAndTheRecordRowIsTheScreen() {
        var modes = CaptureModeSettings()
        modes.memory.remembers = false
        modes.memory.rememberDisplay("X")
        modes.memory.rememberWindow(bundleID: a.bundleID, title: a.title)
        modes.memory.rememberRecording(.recordWindow)
        XCTAssertNil(modes.memory.displayUUID)
        XCTAssertNil(modes.memory.window)
        XCTAssertEqual(modes.memory.recording, .screen)
        XCTAssertEqual(modes.command(for: .recordScreen), "capture.rec.screen")
    }

    func testAWindowWithNoAppOrNoTitleIsNotWorthRemembering() {
        var memory = CaptureMemory()
        memory.rememberWindow(bundleID: nil, title: "Untitled")
        memory.rememberWindow(bundleID: "", title: "Untitled")
        memory.rememberWindow(bundleID: "com.x", title: "")
        XCTAssertNil(memory.window)
        memory.rememberWindow(bundleID: "com.x", title: "Doc")
        XCTAssertEqual(memory.window, RememberedWindow(bundleID: "com.x", title: "Doc"))
        memory.rememberDisplay(nil)
        XCTAssertNil(memory.displayUUID)
    }

    // MARK: Checking it is still true

    func testADisplayThatIsNotConnectedIsForgotten() {
        var memory = CaptureMemory()
        memory.rememberDisplay("DISPLAY-1")
        XCTAssertEqual(memory.validated(displays: ["DISPLAY-1", "DISPLAY-2"], windows: []).displayUUID, "DISPLAY-1")
        XCTAssertNil(memory.validated(displays: ["DISPLAY-2"], windows: []).displayUUID)
        XCTAssertNil(memory.validated(displays: [], windows: nil).displayUUID)
    }

    func testAWindowThatIsNotOpenIsForgottenAndOneThatIsOpenIsKept() {
        var memory = CaptureMemory()
        memory.window = a
        XCTAssertEqual(memory.validated(displays: [], windows: [a, b]).window, a)
        XCTAssertNil(memory.validated(displays: [], windows: [b]).window)
        XCTAssertNil(memory.validated(displays: [], windows: []).window)
        XCTAssertNil(memory.validated(displays: [], windows: [RememberedWindow(bundleID: a.bundleID, title: "Another page")]).window, "the same app with another title is another window")
    }

    func testWhenWhatIsOpenCannotBeKnownTheWindowIsKeptNotGuessedAway() {
        var memory = CaptureMemory()
        memory.window = a
        XCTAssertEqual(memory.validated(displays: [], windows: nil).window, a)
    }

    func testValidatingChangesOnlyWhatIsWrong() {
        var memory = CaptureMemory()
        memory.recording = .app
        memory.displayUUID = "GONE"
        memory.window = a
        let valid = memory.validated(displays: ["OTHER"], windows: [a])
        XCTAssertEqual(valid.recording, .app)
        XCTAssertEqual(valid.window, a)
        XCTAssertNil(valid.displayUUID)
        XCTAssertTrue(valid.remembers)
        XCTAssertEqual(valid.validated(displays: ["OTHER"], windows: [a]), valid, "checking again changes nothing")
    }

    func testTheRealDisplaysAreIdentifiedAndFoundAgain() {
        // On a Mac with a display, its identifier maps back to it; with none (a build machine without one) there is simply nothing.
        for uuid in DisplayIdentity.connectedUUIDs() {
            let id = DisplayIdentity.id(forUUID: uuid)
            XCTAssertNotNil(id, uuid)
            XCTAssertEqual(id.flatMap(DisplayIdentity.uuid(of:)), uuid)
        }
        XCTAssertNil(DisplayIdentity.id(forUUID: "00000000-0000-0000-0000-000000000000"))
    }
}
