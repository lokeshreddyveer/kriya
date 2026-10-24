import XCTest
@testable import Kriya

final class WindowAdditionsTests: XCTestCase {
    private func row(_ id: String, app: String = "App", title: String = "Doc", display: String = "Built-in", min: Bool = false, hidden: Bool = false, used: Int64 = 0, fav: Bool = false, front: Bool = false) -> WindowRow {
        WindowRow(id: id, appID: "com.\(app)", appName: app, title: title, display: display, isMinimized: min, isAppHidden: hidden, isFront: front, lastUsed: used, isFavorite: fav)
    }

    func testTheListPutsFavoritesFirstThenOpenThenMinimizedAndHidden() {
        let rows: [WindowRow] = [row("a", used: 1), row("b", used: 5), row("c", min: true, used: 9), row("d", used: 2, fav: true), row("e", hidden: true, used: 3)]
        let sections = WindowListOrder.sections(rows, query: "", grouping: .recent)
        XCTAssertEqual(sections.map(\.title), ["Favorites", "Open", "Minimized and hidden"])
        XCTAssertEqual(sections[1].rows.map(\.id), ["b", "a"], "most recently used first")
        XCTAssertEqual(sections[2].rows.map(\.id), ["c", "e"])
    }

    func testSearchFindsWindowsByAppTitleOrDisplayAndNeedsEveryWord() {
        let rows = [row("a", app: "Safari", title: "Swift forums"), row("b", app: "Mail", title: "Inbox", display: "Studio Display")]
        XCTAssertEqual(WindowListOrder.filter(rows, query: "swift safari").map(\.id), ["a"])
        XCTAssertEqual(WindowListOrder.filter(rows, query: "studio").map(\.id), ["b"])
        XCTAssertEqual(WindowListOrder.filter(rows, query: "swift mail").count, 0)
        XCTAssertEqual(WindowListOrder.filter(rows, query: "  ").count, 2)
    }

    func testGroupingByAppAndDisplayIsAlphabetical() {
        let rows = [row("a", app: "Zed", display: "B"), row("b", app: "Alpha", display: "A"), row("c", app: "Alpha", display: "B")]
        XCTAssertEqual(WindowListOrder.sections(rows, query: "", grouping: .app).map(\.title), ["Alpha", "Zed"])
        XCTAssertEqual(WindowListOrder.sections(rows, query: "", grouping: .display).map(\.title), ["A", "B"])
    }

    func testTheReasonNamesWhatMakesAWindowShown() {
        let fav = row("a", fav: true, front: true)
        let text = WindowListOrder.why(fav, query: "", rank: 0, clock: 0)
        XCTAssertTrue(text.contains("a favorite") && text.contains("in front"), text)
        let found = WindowListOrder.why(row("b", title: "Budget sheet", min: true), query: "budget", rank: 9, clock: 0)
        XCTAssertTrue(found.contains("minimized") && found.contains("“budget” is in its title"), found)
        XCTAssertTrue(WindowListOrder.why(row("c"), query: "", rank: 9, clock: 0).contains("open on Built-in"))
    }

    func testWhichDisplayAWindowIsOnFollowsItsMiddle() {
        let displays = [(name: "Left", full: Rect(x: 0, y: 0, width: 1000, height: 800)), (name: "Right", full: Rect(x: 1000, y: 0, width: 1000, height: 800))]
        XCTAssertEqual(WindowListOrder.displayName(for: Rect(x: 900, y: 100, width: 400, height: 300), displays: displays), "Right", "its middle is at 1100")
        XCTAssertEqual(WindowListOrder.displayName(for: Rect(x: 100, y: 100, width: 200, height: 200), displays: displays), "Left")
        XCTAssertEqual(WindowListOrder.displayName(for: nil, displays: displays), "Left")
    }

    func testFavoritesToggleByAppAndTitleWords() {
        var list: [PinnedWindow] = []
        list = WindowFavorites.toggled(appID: "com.a", title: "Notes", in: list)
        XCTAssertTrue(WindowFavorites.isFavorite(appID: "com.a", title: "Notes", in: list))
        XCTAssertFalse(WindowFavorites.isFavorite(appID: "com.b", title: "Notes", in: list))
        list = WindowFavorites.toggled(appID: "com.a", title: "Notes", in: list)
        XCTAssertTrue(list.isEmpty)
        let anyWindow = PinnedWindow(appID: "com.a", titleContains: "")
        XCTAssertTrue(anyWindow.matches(appID: "com.a", title: "whatever"), "no words means any window of the app")
        for i in 0..<(WindowFavorites.maxCount + 5) { list = WindowFavorites.toggled(appID: "com.x\(i)", title: "t", in: list) }
        XCTAssertEqual(list.count, WindowFavorites.maxCount)
    }

    func testADoubleTapOfOneModifierFires() {
        var d = ModifierTapDetector()
        XCTAssertNil(d.flagsChanged(["option"], at: 0.00))
        XCTAssertNil(d.flagsChanged([], at: 0.08))
        XCTAssertNil(d.flagsChanged(["option"], at: 0.20))
        XCTAssertEqual(d.flagsChanged([], at: 0.27), "option")
    }

    func testSlowTapsOtherKeysAndOtherModifiersDoNotFire() {
        var slow = ModifierTapDetector()
        _ = slow.flagsChanged(["shift"], at: 0); _ = slow.flagsChanged([], at: 0.6)      // held too long to be a tap
        _ = slow.flagsChanged(["shift"], at: 0.7)
        XCTAssertNil(slow.flagsChanged([], at: 0.75))

        var typed = ModifierTapDetector()
        _ = typed.flagsChanged(["command"], at: 0); typed.keyPressed(); _ = typed.flagsChanged([], at: 0.1)   // Command-C
        _ = typed.flagsChanged(["command"], at: 0.2)
        XCTAssertNil(typed.flagsChanged([], at: 0.25), "the first press was a shortcut")

        var mixed = ModifierTapDetector()
        _ = mixed.flagsChanged(["option"], at: 0); _ = mixed.flagsChanged([], at: 0.05)
        _ = mixed.flagsChanged(["shift"], at: 0.1)
        XCTAssertNil(mixed.flagsChanged([], at: 0.15), "a different key between")

        var chord = ModifierTapDetector()
        _ = chord.flagsChanged(["option"], at: 0); _ = chord.flagsChanged(["option", "shift"], at: 0.02); _ = chord.flagsChanged(["option"], at: 0.05)
        XCTAssertNil(chord.flagsChanged([], at: 0.08), "two keys together is not a tap")

        var late = ModifierTapDetector()
        _ = late.flagsChanged(["control"], at: 0); _ = late.flagsChanged([], at: 0.05)
        _ = late.flagsChanged(["control"], at: 1.0)
        XCTAssertNil(late.flagsChanged([], at: 1.05), "too long between the taps")
    }

    func testAppLayoutTriggersFireForTheRightEvent() {
        let launch = AppLayoutTrigger(appID: "com.a", command: "window.left_half", when: .launch)
        let first = AppLayoutTrigger(appID: "com.a", command: "window.right_half", when: .firstActivation)
        let every = AppLayoutTrigger(appID: "com.a", command: "window.maximize", when: .everyActivation)
        let other = AppLayoutTrigger(appID: "com.b", command: "window.center", when: .launch)
        let all = [launch, first, every, other]
        XCTAssertEqual(AppLayoutTrigger.firing(all, appID: "com.a", launched: true, isFirstActivation: false).map(\.command), ["window.left_half"])
        XCTAssertEqual(AppLayoutTrigger.firing(all, appID: "com.a", launched: false, isFirstActivation: true).map(\.command), ["window.right_half", "window.maximize"])
        XCTAssertEqual(AppLayoutTrigger.firing(all, appID: "com.a", launched: false, isFirstActivation: false).map(\.command), ["window.maximize"])
        XCTAssertTrue(AppLayoutTrigger.firing(all, appID: "com.c", launched: true, isFirstActivation: true).isEmpty)
    }

    func testThePointerWrapsOnlyWhereAskedAndOnlyWhenMovingOut() {
        let area = (minX: 0.0, minY: 0.0, maxX: 3000.0, maxY: 1000.0)
        XCTAssertNil(PointerWrapMode.wrapped((x: 0, y: 500), moving: (dx: -5, dy: 0), area: area, mode: .off))
        let left = PointerWrapMode.wrapped((x: 0.4, y: 500), moving: (dx: -5, dy: 0), area: area, mode: .horizontal)
        XCTAssertEqual(left?.x, 2997); XCTAssertEqual(left?.y, 500)
        let right = PointerWrapMode.wrapped((x: 2999.5, y: 500), moving: (dx: 5, dy: 0), area: area, mode: .horizontal)
        XCTAssertEqual(right?.x, 3)
        XCTAssertNil(PointerWrapMode.wrapped((x: 0.4, y: 500), moving: (dx: 5, dy: 0), area: area, mode: .horizontal), "moving away from the edge")
        XCTAssertNil(PointerWrapMode.wrapped((x: 500, y: 0.2), moving: (dx: 0, dy: -4), area: area, mode: .horizontal), "top edge needs the all-edges mode")
        XCTAssertEqual(PointerWrapMode.wrapped((x: 500, y: 0.2), moving: (dx: 0, dy: -4), area: area, mode: .both)?.y, 997)
    }

    func testThrowingKeepsTheSizeAndStopsInsideTheArea() {
        let area = Rect(x: 0, y: 25, width: 1440, height: 875)
        let current = Rect(x: 400, y: 300, width: 600, height: 400)
        let left = WindowThrow.frame(current: current, area: area, gap: 8, dx: -1, dy: 0)
        XCTAssertEqual(left.x, 8); XCTAssertEqual(left.y, 300); XCTAssertEqual(left.width, 600); XCTAssertEqual(left.height, 400)
        let corner = WindowThrow.frame(current: current, area: area, gap: 0, dx: 1, dy: 1)
        XCTAssertEqual(corner.x, 840); XCTAssertEqual(corner.y, 500)
        let big = WindowThrow.frame(current: Rect(x: 0, y: 0, width: 2000, height: 100), area: area, gap: 0, dx: 1, dy: 0)
        XCTAssertGreaterThanOrEqual(big.x, 0, "never pushed off the left of the display")
    }

    func testReflowFindsTheSpaceBesideASnappedWindow() {
        let area = Rect(x: 0, y: 25, width: 1440, height: 875)
        let leftHalf = Rect(x: 0, y: 25, width: 720, height: 875)
        let r = WindowReflow.remaining(anchor: leftHalf, area: area, gap: 8)
        XCTAssertEqual(r?.x, 728); XCTAssertEqual(r?.width, 712); XCTAssertEqual(r?.height, 875)
        let rightThird = Rect(x: 960, y: 25, width: 480, height: 875)
        XCTAssertEqual(WindowReflow.remaining(anchor: rightThird, area: area, gap: 0)?.width, 960)
        let top = Rect(x: 0, y: 25, width: 1440, height: 400)
        XCTAssertEqual(WindowReflow.remaining(anchor: top, area: area, gap: 0)?.y, 425)
        XCTAssertNil(WindowReflow.remaining(anchor: Rect(x: 300, y: 200, width: 600, height: 400), area: area, gap: 0), "a floating window leaves no clear side")
        XCTAssertNil(WindowReflow.remaining(anchor: Rect(x: 0, y: 25, width: 1400, height: 875), area: area, gap: 0), "nothing left beside it")
    }
}

final class AppMenuFavoriteTests: XCTestCase {
    func testAMenuItemIsAddedAndRemovedByItsPath() {
        var list: [AppMenuFavorite] = []
        list = AppMenuFavorite.toggled(appID: "com.a", path: ["Edit", "Find", "Find Next"], in: list)
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].title, "Find Next"); XCTAssertEqual(list[0].detail, "Edit › Find")
        list = AppMenuFavorite.toggled(appID: "com.a", path: ["Edit", "Find", "Find Previous"], in: list)
        XCTAssertEqual(list.count, 2, "a different item")
        list = AppMenuFavorite.toggled(appID: "com.a", path: ["Edit", "Find", "Find Next"], in: list)
        XCTAssertEqual(list.map(\.title), ["Find Previous"])
        XCTAssertEqual(AppMenuFavorite.toggled(appID: "com.a", path: [], in: []).count, 0, "an empty path is nothing")
    }
}
