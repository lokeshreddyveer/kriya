import XCTest
@testable import Kriya

final class MouseCoexistenceTests: XCTestCase {
    private func running(_ items: (String?, String?)...) -> [(bundleID: String?, name: String?)] { items.map { (bundleID: $0.0, name: $0.1) } }
    private let mos = CompetingTools.known.first { $0.name == "Mos" }!
    private let mmf = CompetingTools.known.first { $0.name == "Mac Mouse Fix" }!

    private func statuses(installed: [String] = [], running: [CompetingTool] = [], kriya: Set<MouseArea> = [], evidence: [String: Set<MouseArea>] = [:]) -> [CompetingToolStatus] {
        CoexistencePlan.statuses(installed: Set(installed), running: running, kriyaAreas: kriya, evidence: evidence)
    }

    func testToolsAreFoundByIdentifierOrName() {
        XCTAssertEqual(CompetingTools.detect(running: running(("com.nuebling.mac-mouse-fix.helper", nil))).map(\.name), ["Mac Mouse Fix"])
        XCTAssertEqual(CompetingTools.detect(running: running((nil, "LinearMouse"))).map(\.name), ["LinearMouse"])
        XCTAssertEqual(Set(CompetingTools.detect(running: running(("com.caldis.Mos", "Mos"), ("com.hegenberg.BetterTouchTool", nil))).map(\.name)), ["Mos", "BetterTouchTool"])
        XCTAssertTrue(CompetingTools.detect(running: running(("com.apple.finder", "Finder"), (nil, "Mosaic"))).isEmpty)
    }

    // MARK: Each fact is kept apart

    func testInstalledAndRunningAreSeparate() {
        let list = statuses(installed: ["Mos", "LinearMouse"], running: [mos])
        XCTAssertEqual(Set(list.map(\.tool.name)), ["Mos", "LinearMouse"])
        XCTAssertTrue(list.first { $0.tool.name == "Mos" }!.running)
        XCTAssertFalse(list.first { $0.tool.name == "LinearMouse" }!.running)
        XCTAssertEqual(list.first { $0.tool.name == "LinearMouse" }!.summary, "Installed, not open")
    }

    func testToolsThatAreNeitherInstalledNorOpenAreNotListed() {
        XCTAssertTrue(statuses().isEmpty)
    }

    func testAccessibilityIsNeverClaimed() {
        XCTAssertNil(statuses(running: [mos]).first!.accessibilityGranted)
    }

    func testOverlapNeedsBothToHandleTheSameArea() {
        XCTAssertTrue(statuses(running: [mos], kriya: [.scrolling]).first!.knownOverlappingConfiguration)
        XCTAssertFalse(statuses(running: [mos], kriya: []).first!.knownOverlappingConfiguration)
        XCTAssertFalse(statuses(installed: ["Mos"], running: [], kriya: [.scrolling]).first!.knownOverlappingConfiguration, "not open is not an overlap")
    }

    func testOnlySourceMetadataIsSurfacedAndNeverCalledProof() {
        let open = statuses(running: [mos], kriya: [.scrolling])
        let plain = CoexistencePlan.evaluate(statuses: open, settings: CoexistenceSettings(), kriyaChangesScrolling: true)
        XCTAssertTrue(plain.observedOverlaps.isEmpty, "being open proves nothing")
        let seen = statuses(running: [mos], kriya: [.scrolling], evidence: ["Mos": [.scrolling]])
        let proven = CoexistencePlan.evaluate(statuses: seen, settings: CoexistenceSettings(), kriyaChangesScrolling: true)
        XCTAssertEqual(proven.observedOverlaps, ["Mos"])
        XCTAssertTrue(proven.notes.contains { $0.contains("source metadata") && $0.contains("does not prove") })
        XCTAssertTrue(seen.first!.summary.contains("not proof"))
        // Evidence without Kriya being set to change scrolling is not a conflict.
        XCTAssertTrue(CoexistencePlan.evaluate(statuses: seen, settings: CoexistenceSettings(), kriyaChangesScrolling: false).observedOverlaps.isEmpty)
    }

    // MARK: How scrolling stands

    func testOwnershipStatesAndWhenTheyAreKnown() {
        func plan(_ list: [CompetingToolStatus], kriya: Bool) -> CoexistencePlan.Result { CoexistencePlan.evaluate(statuses: list, settings: CoexistenceSettings(), kriyaChangesScrolling: kriya) }
        XCTAssertEqual(plan([], kriya: false).ownership, .nothingConfigured)
        XCTAssertEqual(plan([], kriya: true).ownership, .kriyaConfigured)
        XCTAssertEqual(plan(statuses(running: [mos]), kriya: false).ownership, .otherUtilityDetected("Mos"))
        XCTAssertEqual(plan(statuses(running: [mos], kriya: [.scrolling]), kriya: true).ownership, .bothConfigured("Mos"))
        XCTAssertTrue(plan([], kriya: true).ownership.isKnown)
        XCTAssertFalse(plan(statuses(running: [mos]), kriya: false).ownership.isKnown)
        XCTAssertFalse(plan(statuses(running: [mos], kriya: [.scrolling]), kriya: true).ownership.isKnown)
    }

    func testNothingClaimsToKnowWhoOwnsTheWheelWhenAnotherToolIsOpen() {
        let r = CoexistencePlan.evaluate(statuses: statuses(running: [mos], kriya: [.scrolling]), settings: CoexistenceSettings(), kriyaChangesScrolling: true)
        XCTAssertTrue(r.notes.contains { $0.contains("not known") })
        XCTAssertTrue(r.notes.contains { $0.contains("may also change scrolling") })
    }

    func testKriyaStepsAsideByDefaultAsAPrecaution() {
        let open = statuses(running: [mos], kriya: [.scrolling])
        XCTAssertTrue(CoexistencePlan.evaluate(statuses: open, settings: CoexistenceSettings(), kriyaChangesScrolling: true).yieldsScrolling)
        var off = CoexistenceSettings(); off.yieldScrollingToOthers = false
        XCTAssertFalse(CoexistencePlan.evaluate(statuses: open, settings: off, kriyaChangesScrolling: true).yieldsScrolling)
        XCTAssertFalse(CoexistencePlan.evaluate(statuses: statuses(running: [mos]), settings: CoexistenceSettings(), kriyaChangesScrolling: false).yieldsScrolling)
        XCTAssertFalse(CoexistencePlan.evaluate(statuses: statuses(installed: ["Mos"]), settings: CoexistenceSettings(), kriyaChangesScrolling: true).yieldsScrolling, "installed but not open")
    }

    func testOtherAreasAndSeveralToolsAreExplained() {
        let r = CoexistencePlan.evaluate(statuses: statuses(running: [mmf, mos], kriya: [.scrolling]), settings: CoexistenceSettings(), kriyaChangesScrolling: true)
        XCTAssertTrue(r.notes.contains { $0.contains("Mac Mouse Fix can also handle") && $0.contains("buttons") })
        XCTAssertTrue(r.notes.contains { $0.contains("Several mouse tools") })
        XCTAssertFalse(r.notes.contains { $0.hasPrefix("Mos can also handle") })
    }

    func testSettingsDefaultOnAndRoundTrip() {
        let defaults = UserDefaults(suiteName: "coex.\(UUID().uuidString)")!
        let store = CoexistenceStore(defaults: defaults)
        XCTAssertTrue(store.settings.yieldScrollingToOthers)
        var s = CoexistenceSettings(); s.yieldScrollingToOthers = false
        store.settings = s
        XCTAssertFalse(store.settings.yieldScrollingToOthers)
        defaults.set(Data("x".utf8), forKey: CoexistenceStore.key)
        XCTAssertTrue(store.settings.yieldScrollingToOthers)
    }
}

final class MousePassThroughTests: XCTestCase {
    func testOnlyMouseEventsCountAsMouse() {
        for t in [CGEventType.leftMouseDown, .rightMouseUp, .otherMouseDragged, .mouseMoved, .scrollWheel] { XCTAssertTrue(EventMonitor.isMouseEvent(t), "\(t)") }
        for t in [CGEventType.keyDown, .keyUp, .flagsChanged] { XCTAssertFalse(EventMonitor.isMouseEvent(t), "\(t)") }
    }

    func testThreeTimeoutsInTenSecondsEngageThePause() {
        let s: UInt64 = 1_000_000_000
        XCTAssertFalse(EventMonitor.tooManyTimeouts([0, 4 * s], now: 5 * s))
        XCTAssertTrue(EventMonitor.tooManyTimeouts([0, 4 * s, 8 * s], now: 9 * s))
        XCTAssertFalse(EventMonitor.tooManyTimeouts([0, 4 * s, 20 * s], now: 21 * s), "spread over more than ten seconds")
    }

    func testManualPauseAndResume() {
        let monitor = EventMonitor()
        monitor.setMouseRulesPaused(true)
        let deadline = Date().addingTimeInterval(1)
        while !monitor.mouseRulesPaused, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(monitor.mouseRulesPaused)
        XCTAssertFalse(monitor.pausedAutomatically)
        XCTAssertNil(monitor.pauseReason)
        monitor.setMouseRulesPaused(false)
        while monitor.mouseRulesPaused, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertFalse(monitor.mouseRulesPaused)
    }
}
