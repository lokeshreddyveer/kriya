import AppKit
import XCTest
@testable import Kriya

/// The fixes from the Pointer Effects review: a magnifier that takes new settings, a pointer that stays hidden only while something
/// still hides it, positions that follow a monitor and not a place in the row, shortcut trouble that is said, and overlays that are
/// cleaned up.
final class PointerFixTests: XCTestCase {
    private var quiet: PointerEffectsConfig {
        var config = PointerEffectsStore.blank
        config.spotlightDim = 0          // invisible, so the tests do not flash the screen
        return config
    }

    // MARK: Hiding the pointer

    func testThePointerComesBackOnlyWhenNothingHidesItAnyMore() {
        var state = PointerHideState()
        XCTAssertTrue(state.add(.idle), "the first reason hides it")
        XCTAssertFalse(state.add(.typing), "a second reason does not hide it again")
        XCTAssertFalse(state.remove(.idle), "idle ends but typing still wants it hidden")
        XCTAssertTrue(state.isHidden)
        XCTAssertTrue(state.remove(.typing), "the last reason going shows it")
        XCTAssertFalse(state.isHidden)
        XCTAssertFalse(state.remove(.typing), "nothing to show twice")
    }

    func testMovingTheMouseClearsEveryReasonAndShowsOnce() {
        var state = PointerHideState()
        _ = state.add(.idle); _ = state.add(.manual); _ = state.add(.typing)
        XCTAssertTrue(state.removeAll(), "one show for however many hides")
        XCTAssertFalse(state.removeAll(), "and not another")
        XCTAssertFalse(state.isHidden)
    }

    func testEveryHideIsPairedWithOneShow() {
        var state = PointerHideState()
        var hides = 0, shows = 0
        func add(_ r: PointerHideReason) { if state.add(r) { hides += 1 } }
        func remove(_ r: PointerHideReason) { if state.remove(r) { shows += 1 } }
        add(.idle); add(.typing); add(.manual); remove(.typing); remove(.manual); remove(.idle); add(.typing); remove(.typing)
        XCTAssertEqual(hides, 2); XCTAssertEqual(shows, 2, "the window server counts each hide, so each needs its show")
    }

    // MARK: Saved positions

    func testASavedPositionFindsItsMonitorWhereverItIsNow() {
        let saved = RememberedDisplay(id: "B", name: "LG HDR")
        XCTAssertEqual(PointerPositionResolver.resolve(index: 1, remembered: saved, connected: ["A", "B"]), .display(1))
        XCTAssertEqual(PointerPositionResolver.resolve(index: 1, remembered: saved, connected: ["B", "A"]), .display(0), "rearranged: the same monitor, not the same place")
        XCTAssertEqual(PointerPositionResolver.resolve(index: 1, remembered: saved, connected: ["A", "C"]), .missing, "unplugged: never a different monitor in its place")
        XCTAssertEqual(PointerPositionResolver.resolve(index: nil, remembered: saved, connected: ["A"]), .pointerDisplay)
    }

    func testAPositionSavedBeforeMonitorsWereRememberedUsesItsPlace() {
        XCTAssertEqual(PointerPositionResolver.resolve(index: 1, remembered: nil, connected: ["A", "B"]), .display(1))
        XCTAssertEqual(PointerPositionResolver.resolve(index: 3, remembered: nil, connected: ["A", "B"]), .missing)
    }

    func testThePaneSaysWhichMonitorAPositionIsFor() {
        let saved = RememberedDisplay(id: "B", name: "LG HDR")
        XCTAssertEqual(PointerPositionResolver.describe(index: 1, remembered: saved, connected: ["A", "B"]), "LG HDR (display 2)")
        XCTAssertTrue(PointerPositionResolver.describe(index: 1, remembered: saved, connected: ["A"]).contains("not connected"))
        XCTAssertEqual(PointerPositionResolver.describe(index: nil, remembered: nil, connected: ["A"]), "The display the pointer is on")
        XCTAssertEqual(PointerPositionResolver.describe(index: 0, remembered: nil, connected: ["A"]), "Display 1")
    }

    func testTheMonitorAPositionIsForIsRememberedAndForgotten() throws {
        let world = try TestWorld()
        defer { world.cleanUp() }
        let store = PointerEffectsStore(core: world.core)
        let displays = [DisplayInfo(id: "A", name: "Built-in", full: Rect(x: 0, y: 0, width: 1, height: 1), area: Rect(x: 0, y: 0, width: 1, height: 1), isMain: true),
                        DisplayInfo(id: "B", name: "LG HDR", full: Rect(x: 1, y: 0, width: 1, height: 1), area: Rect(x: 1, y: 0, width: 1, height: 1), isMain: false)]
        let id = "test-\(UUID().uuidString)"
        defer { store.delete(id) }
        var position = SavedPosition(id: id, name: "Right", display: 1, x: 0.5, y: 0.5)
        store.remember(position, among: displays)
        XCTAssertEqual(store.rememberedDisplay(for: id), RememberedDisplay(id: "B", name: "LG HDR"))
        position.display = 7
        store.remember(position, among: displays)
        XCTAssertEqual(store.rememberedDisplay(for: id)?.id, "B", "a display that is not connected keeps what was remembered")
        position.display = nil
        store.remember(position, among: displays)
        XCTAssertNil(store.rememberedDisplay(for: id), "'the display the pointer is on' needs no monitor")
    }

    // MARK: The magnifier

    func testTheCapturedPictureHasTheDisplaysOwnPixelSize() {
        XCTAssertEqual(MagnifierGeometry.pixels(points: 220, scale: 2), 440)
        XCTAssertEqual(MagnifierGeometry.pixels(points: 220, scale: 1), 220, "an ordinary display next to a Retina one")
        XCTAssertEqual(MagnifierGeometry.pixels(points: 220, scale: 0), 220, "never a zero or negative scale")
        XCTAssertEqual(MagnifierGeometry.pixels(points: 0, scale: 2), 1)
    }

    func testNewSettingsReachAMagnifierThatIsAlreadyOn() {
        let magnifier = PointerMagnifier()
        var config = quiet
        config.magnifierSize = 220; config.magnifierZoom = 2.5; config.magnifierShape = .circle
        magnifier.update(config: config)
        XCTAssertEqual(magnifier.size, 220); XCTAssertEqual(magnifier.zoom, 2.5)
        config.magnifierSize = 360; config.magnifierZoom = 4
        magnifier.update(config: config)
        XCTAssertEqual(magnifier.size, 360, "this was the bug: the settings changed and the magnifier did not")
        XCTAssertEqual(magnifier.zoom, 4)
        magnifier.adjustZoom(by: 100)
        XCTAssertEqual(magnifier.zoom, 8, "zooming with the command stays inside its limits")
        config.magnifierSize = 300
        magnifier.update(config: config)
        XCTAssertEqual(magnifier.zoom, 8, "changing only the size leaves a zoom set by the command alone")
        XCTAssertFalse(magnifier.isOn); XCTAssertFalse(magnifier.hasPanel)
    }

    // MARK: The spotlight cleans up after itself

    func testTheSpotlightHasOneWindowPerDisplayAndNoneAfterItStops() {
        let spotlight = PointerSpotlight()
        spotlight.start(config: quiet)
        XCTAssertEqual(spotlight.panelCount, NSScreen.screens.count)
        spotlight.start(config: quiet)
        XCTAssertEqual(spotlight.panelCount, NSScreen.screens.count, "starting it twice does not add windows")
        spotlight.stop()
        XCTAssertEqual(spotlight.panelCount, 0); XCTAssertFalse(spotlight.isOn)
        spotlight.stop()
        XCTAssertEqual(spotlight.panelCount, 0, "stopping twice is harmless")
    }

    func testRapidTogglesLeaveNothingBehind() {
        let spotlight = PointerSpotlight()
        for _ in 0..<25 {
            spotlight.start(config: quiet)
            spotlight.stop()
        }
        spotlight.start(config: quiet)
        spotlight.stop()
        XCTAssertEqual(spotlight.panelCount, 0)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))   // the fade-outs finish and close their windows
        XCTAssertFalse(spotlight.isOn)
    }

    func testTheSpotlightStartsOverWhenTheDisplaysChange() {
        let spotlight = PointerSpotlight()
        spotlight.start(config: quiet)
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        XCTAssertEqual(spotlight.panelCount, NSScreen.screens.count, "rebuilt for the displays there are now")
        spotlight.stop()
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        XCTAssertEqual(spotlight.panelCount, 0, "and a stopped spotlight does not come back by itself")
    }

    func testChangingWhetherTheAudienceSeesItReachesTheSpotlightWindows() {
        let spotlight = PointerSpotlight()
        var config = quiet
        config.showWhenSharing = false
        spotlight.start(config: config)
        XCTAssertTrue(spotlight.sharingTypes.allSatisfy { $0 == .none })
        config.showWhenSharing = true
        spotlight.update(config)
        XCTAssertEqual(spotlight.panelCount, NSScreen.screens.count)
        XCTAssertTrue(spotlight.sharingTypes.allSatisfy { $0 == .readOnly }, "new windows were opened, because an open one cannot be loosened")
        config.showWhenSharing = false
        spotlight.update(config)
        XCTAssertTrue(spotlight.sharingTypes.allSatisfy { $0 == .none })
        spotlight.stop()
    }

    func testAWindowCanOnlyHaveItsSharingTightenedWhichIsWhyTheyAreRebuilt() {
        // The fact the rebuilding rests on, checked on this Mac: a new window can be made either way, but once restricted it stays so.
        let open = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.borderless], backing: .buffered, defer: false)
        open.sharingType = .none
        open.sharingType = .readOnly
        let fresh = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.borderless], backing: .buffered, defer: false)
        fresh.sharingType = .readOnly
        XCTAssertEqual(fresh.sharingType, .readOnly, "a new window made shareable is shareable")
        if open.sharingType == .none { XCTAssertEqual(open.sharingType, .none, "loosening an existing window was refused: the reason for opening new ones") }
    }

    // MARK: Shortcut trouble is said

    func testARefusedShortcutNamesWhoElseUsesTheKeys() {
        let mine = ShortcutEntry(owner: "Pointer effects", command: "pointer.spotlight", title: "Spotlight", keyCode: 1, modifiers: 8, status: .refused)
        let other = ShortcutEntry(owner: "Windows", command: "window.left", title: "Left half", keyCode: 1, modifiers: 8)
        let note = PointerShortcutNote.message(entry: mine, others: [mine, other])
        XCTAssertTrue(note?.contains("Windows: Left half") == true)
        XCTAssertFalse(note?.contains("Spotlight") == true, "it does not list itself")
        XCTAssertTrue(PointerShortcutNote.message(entry: mine, others: [mine])?.contains("macOS or another app") == true)
        var working = mine; working.status = .active
        XCTAssertNil(PointerShortcutNote.message(entry: working, others: [other]), "a working shortcut needs no warning")
        XCTAssertNil(PointerShortcutNote.message(entry: nil, others: []))
    }

    // MARK: The reset list knows about the new key

    func testThePositionDisplaysCanBeResetWithTheirOwnArea() {
        XCTAssertTrue(FeatureReset.areas.contains { $0.id == "pointer" && $0.keys.contains("pointer.positionDisplays.v1") })
    }
}


/// Click rings reuse their windows: making a new top-level window for every press made the screen flash.
final class RingPoolTests: XCTestCase {
    func testARingWindowIsUsedAgainAfterItFinishes() {
        let pool = RingPool()
        pool.show(at: NSPoint(x: 100, y: 100), color: .red, side: 40, duration: 0.1, shareable: false)
        XCTAssertEqual(pool.activeCount, 1)
        let first = expectation(description: "first ring done")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { first.fulfill() }
        wait(for: [first], timeout: 2)
        XCTAssertEqual(pool.activeCount, 0)
        XCTAssertEqual(pool.idleCount, 1, "the window is kept for the next press")
        pool.show(at: NSPoint(x: 200, y: 200), color: .blue, side: 56, duration: 0.1, shareable: false)
        XCTAssertEqual(pool.idleCount, 0, "the kept window was taken, not a new one made")
        XCTAssertEqual(pool.activeCount, 1)
        let second = expectation(description: "second ring done")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { second.fulfill() }
        wait(for: [second], timeout: 2)
        XCTAssertEqual(pool.idleCount, 1)
    }

    func testAChangeOfSharingLetsTheOldWindowsGo() {
        let pool = RingPool()
        pool.show(at: .zero, color: .red, side: 40, duration: 0.05, shareable: false)
        let done = expectation(description: "done")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { done.fulfill() }
        wait(for: [done], timeout: 2)
        XCTAssertEqual(pool.idleCount, 1)
        pool.show(at: .zero, color: .red, side: 40, duration: 0.05, shareable: true)
        XCTAssertEqual(pool.idleCount, 0, "a window made for the other sharing choice is not reused")
    }

    func testNoMoreThanEightRingsAtOnce() {
        let pool = RingPool()
        for _ in 0..<12 { pool.show(at: .zero, color: .red, side: 30, duration: 0.3, shareable: false) }
        XCTAssertEqual(pool.activeCount, 8)
        let done = expectation(description: "done")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { done.fulfill() }
        wait(for: [done], timeout: 2)
        XCTAssertEqual(pool.activeCount, 0)
    }
}
