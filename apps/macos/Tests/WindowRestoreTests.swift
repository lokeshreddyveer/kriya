import XCTest
@testable import Kriya

final class RestoreDiagnosisTests: XCTestCase {
    private let builtIn = DisplayInfo(id: "built-in", name: "Built-in Display", full: Rect(x: 0, y: 0, width: 1000, height: 800), area: Rect(x: 0, y: 0, width: 1000, height: 780), isMain: true)
    private let external = DisplayInfo(id: "external", name: "LG UltraFine", full: Rect(x: 1000, y: 0, width: 2000, height: 1000), area: Rect(x: 1000, y: 0, width: 2000, height: 1000), isMain: false)

    private func entry(_ app: String, _ title: String = "", display: String = "built-in") -> LayoutEntry {
        LayoutEntry(appId: app, title: title, displayId: display, frame: Rect(x: 0, y: 0, width: 0.5, height: 0.5))
    }

    private func report(entries: [LayoutEntry], matches: [Int?] = [], open: [(String, String)] = [], moved: [Bool] = [], opened: Set<Int> = [],
                        displays: [DisplayInfo]? = nil, facts: RestoreFacts = RestoreFacts()) -> RestoreReport {
        RestoreDiagnosis.build(
            layoutID: "L", layoutName: "Work", entries: entries, matches: matches, open: open.map { ($0.0, $0.1) }, moved: moved,
            opened: opened, displays: displays ?? [builtIn, external], facts: facts, appName: { $0.uppercased() }
        )
    }

    func testAWindowPutBackOnItsOwnDisplayIsPlaced() {
        let r = report(entries: [entry("a", "Doc")], matches: [0], open: [("a", "Doc")], moved: [true])
        XCTAssertEqual(r.results[0].status, .placed(display: "Built-in Display"))
        XCTAssertFalse(r.results[0].matchedByAppOnly)
        XCTAssertTrue(r.isClean)
        XCTAssertEqual(r.summary, "1 of 1 window restored")
    }

    func testAWindowWhoseDisplayIsGoneSaysWhereItWent() {
        let gone = entry("a", "Doc", display: "unplugged")
        let toMain = report(entries: [gone], matches: [0], open: [("a", "Doc")], moved: [true])
        XCTAssertEqual(toMain.results[0].status, .movedToMainDisplay(display: "Built-in Display"))
        XCTAssertEqual(toMain.onMainDisplay.count, 1)
        XCTAssertFalse(toMain.isClean, "the person should know it is not where it was saved")
        XCTAssertTrue(toMain.results[0].explanation.contains("main display"))
        // With no display marked main, it goes to the first one, and says which.
        let other = DisplayInfo(id: "x", name: "Side Display", full: external.full, area: external.area, isMain: false)
        let elsewhere = report(entries: [gone], matches: [0], open: [("a", "Doc")], moved: [true], displays: [other])
        XCTAssertEqual(elsewhere.results[0].status, .placedOnOtherDisplay(display: "Side Display"))
        XCTAssertEqual(elsewhere.onOtherDisplay.count, 1)
    }

    func testAWindowTakenByAppAloneSaysSo() {
        let r = report(entries: [entry("a", "Old title")], matches: [0], open: [("a", "New title")], moved: [true])
        XCTAssertTrue(r.results[0].matchedByAppOnly)
        XCTAssertTrue(r.results[0].explanation.contains("No window had the saved title"))
    }

    func testAWindowThatWouldNotMoveIsReportedNotCountedAsRestored() {
        let r = report(entries: [entry("a", "Doc")], matches: [0], open: [("a", "Doc")], moved: [false])
        XCTAssertEqual(r.results[0].status, .couldNotMove)
        XCTAssertTrue(r.results[0].needsAttention)
        XCTAssertEqual(r.placed.count, 0)
        XCTAssertTrue(r.results[0].canChooseReplacement)
    }

    func testEachReasonForNotFindingAWindowIsTold() {
        var facts = RestoreFacts()
        facts.runningApps = ["hidden", "mini", "empty", "twice", "excluded"]
        facts.hiddenApps = ["hidden"]
        facts.minimizedWindows = ["mini": 2]
        facts.excludedApps = ["excluded"]
        let entries = [entry("closed"), entry("opening"), entry("hidden"), entry("mini"), entry("empty"), entry("twice", "one"), entry("twice", "two"), entry("excluded")]
        let r = report(entries: entries, matches: [5], open: [("twice", "one")], moved: [true], opened: [1], facts: facts)
        let status = r.results.map(\.status)
        XCTAssertEqual(status[0], .appNotRunning)
        XCTAssertEqual(status[1], .opening)
        XCTAssertEqual(status[2], .appHidden)
        XCTAssertEqual(status[3], .onlyMinimized(2))
        XCTAssertEqual(status[4], .noWindow)
        XCTAssertEqual(status[5], .placed(display: "Built-in Display"))
        XCTAssertEqual(status[6], .notEnoughWindows(open: 1))
        XCTAssertEqual(status[7], .appExcluded)
        // An app being opened is not a problem yet; the rest are.
        XCTAssertEqual(r.needAttention.count, 6)
        XCTAssertEqual(r.appsNotRunning.map(\.id), [0, 1])
        XCTAssertEqual(r.notFound.count, 6)
        XCTAssertTrue(r.summary.hasPrefix("1 of 8 windows restored, 1 opening, 6 need a look"), r.summary)
    }

    func testEveryExplanationIsReadable() {
        let all: [RestoreEntryResult.Status] = [
            .placed(display: "A"), .placedOnOtherDisplay(display: "B"), .movedToMainDisplay(display: "C"), .couldNotMove, .opening,
            .appNotRunning, .appHidden, .appExcluded, .onlyMinimized(1), .onlyMinimized(3), .noWindow, .notEnoughWindows(open: 2),
        ]
        for status in all {
            let result = RestoreEntryResult(id: 0, appID: "a", appName: "App", title: "", status: status)
            XCTAssertFalse(result.explanation.isEmpty)
            XCTAssertEqual(result.label, "App", "no title, so only the app")
        }
    }

    func testAnEmptyOrCleanReportHasNothingToLookAt() {
        XCTAssertTrue(report(entries: []).isClean)
        let clean = report(entries: [entry("a")], matches: [0], open: [("a", "")], moved: [true])
        XCTAssertTrue(clean.needAttention.isEmpty)
    }
}

final class GroupGeometryTests: XCTestCase {
    private let a = DisplayInfo(id: "a", name: "A", full: Rect(x: 0, y: 0, width: 1000, height: 800), area: Rect(x: 0, y: 0, width: 1000, height: 800), isMain: true)
    private let b = DisplayInfo(id: "b", name: "B", full: Rect(x: 1000, y: 0, width: 2000, height: 1000), area: Rect(x: 1000, y: 0, width: 2000, height: 1000), isMain: false)

    private func pair() -> [LayoutEntry] {
        [
            LayoutEntry(appId: "x", title: "left", displayId: "a", frame: Rect(x: 0, y: 0, width: 0.5, height: 1)),
            LayoutEntry(appId: "y", title: "right", displayId: "a", frame: Rect(x: 0.5, y: 0, width: 0.5, height: 1)),
        ]
    }

    private func assertRect(_ rect: Rect, _ x: Double, _ y: Double, _ w: Double, _ h: Double, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(rect.x, x, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(rect.y, y, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(rect.width, w, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(rect.height, h, accuracy: 1e-9, file: file, line: line)
    }

    func testAGroupKeepsItsShapeWhenFittedIntoAHalf() {
        let moved = GroupGeometry.fit(entries: pair(), displays: [a, b], target: b, region: .leftHalf)
        XCTAssertEqual(moved.map(\.displayId), ["b", "b"])
        assertRect(moved[0].frame, 0, 0, 0.25, 1)
        assertRect(moved[1].frame, 0.25, 0, 0.25, 1)
        XCTAssertEqual(moved.map(\.title), ["left", "right"], "only the places change")
    }

    func testTheRegionsCoverTheirPartOfTheDisplay() {
        let whole = GroupGeometry.fit(entries: pair(), displays: [a, b], target: b, region: .whole)
        assertRect(whole[0].frame, 0, 0, 0.5, 1)
        assertRect(whole[1].frame, 0.5, 0, 0.5, 1)
        let right = GroupGeometry.fit(entries: pair(), displays: [a, b], target: b, region: .rightHalf)
        assertRect(right[0].frame, 0.5, 0, 0.25, 1)
        let top = GroupGeometry.fit(entries: pair(), displays: [a, b], target: b, region: .topHalf)
        assertRect(top[0].frame, 0, 0, 0.5, 0.5)
        let bottom = GroupGeometry.fit(entries: pair(), displays: [a, b], target: b, region: .bottomHalf)
        assertRect(bottom[1].frame, 0.5, 0.5, 0.5, 0.5)
    }

    func testKeepingTheSizeCentersTheGroupWithoutScalingIt() {
        let moved = GroupGeometry.fit(entries: pair(), displays: [a, b], target: b, region: .keepSize)
        // The group is 1000 x 800 points; the new display is 2000 x 1000.
        assertRect(moved[0].frame, 0.25, 0.1, 0.25, 0.8)
        assertRect(moved[1].frame, 0.5, 0.1, 0.25, 0.8)
    }

    func testAGroupLargerThanTheTargetIsShrunkToFit() {
        let small = DisplayInfo(id: "s", name: "S", full: Rect(x: 0, y: 0, width: 500, height: 400), area: Rect(x: 0, y: 0, width: 500, height: 400), isMain: false)
        let moved = GroupGeometry.fit(entries: pair(), displays: [a, small], target: small, region: .keepSize)
        for item in moved {
            XCTAssertLessThanOrEqual(item.frame.x + item.frame.width, 1.0000001)
            XCTAssertLessThanOrEqual(item.frame.y + item.frame.height, 1.0000001)
            XCTAssertGreaterThanOrEqual(item.frame.x, -1e-9)
        }
    }

    func testWindowsFromTwoDisplaysAreGatheredOntoOne() {
        var entries = pair()
        entries.append(LayoutEntry(appId: "z", title: "far", displayId: "b", frame: Rect(x: 0, y: 0, width: 0.25, height: 0.5)))
        let moved = GroupGeometry.fit(entries: entries, displays: [a, b], target: a, region: .whole)
        XCTAssertEqual(Set(moved.map(\.displayId)), ["a"])
        for item in moved {
            XCTAssertGreaterThanOrEqual(item.frame.x, -1e-9)
            XCTAssertLessThanOrEqual(item.frame.x + item.frame.width, 1.0000001)
        }
    }

    func testAnEntryFromADisplayThatIsGoneIsTreatedAsOnTheMainOne() {
        var entries = pair()
        entries[0].displayId = "unplugged"
        let moved = GroupGeometry.fit(entries: entries, displays: [a, b], target: b, region: .leftHalf)
        assertRect(moved[0].frame, 0, 0, 0.25, 1)
    }

    func testOneWindowAndNoWindowsAreHandled() {
        XCTAssertTrue(GroupGeometry.fit(entries: [], displays: [a], target: a, region: .whole).isEmpty)
        let single = [LayoutEntry(appId: "x", title: "", displayId: "a", frame: Rect(x: 0.2, y: 0.2, width: 0.3, height: 0.3))]
        let moved = GroupGeometry.fit(entries: single, displays: [a, b], target: b, region: .whole)
        assertRect(moved[0].frame, 0, 0, 1, 1)
    }

    func testAGroupRoundTripsThroughTheStoreAndIsNamedAsAGroup() throws {
        let world = try TestWorld()
        defer { world.cleanUp() }
        let store = WindowStore(core: world.core)
        store.saveLayout(SavedLayout(id: "G1", name: "Development setup", displayKey: "d", isAuto: false, createdAt: 1, entries: pair(), unplaced: .leave, launchMissing: true, isGroup: true))
        store.saveLayout(SavedLayout(id: "L1", name: "Plain", displayKey: "d", isAuto: false, createdAt: 2, entries: pair(), unplaced: .leave, launchMissing: false, isGroup: false))
        XCTAssertEqual(store.layouts.filter(\.isGroup).map(\.name), ["Development setup"])
        let group = try XCTUnwrap(store.layouts.first { $0.id == "G1" })
        XCTAssertEqual(store.title(forCommand: store.layoutCommand(group)), "Group: Development setup")
        let layout = try XCTUnwrap(store.layouts.first { $0.id == "L1" })
        XCTAssertEqual(store.title(forCommand: store.layoutCommand(layout)), "Layout: Plain")
    }
}
