import XCTest
@testable import Kriya

final class ButtonChordTests: XCTestCase {
    private func chord(_ buttons: [UInt32], _ phase: ButtonPhase = .down, mods: UInt64 = 0) -> ButtonChord {
        ButtonChord(pressedButtons: Set(buttons), modifiers: mods, phase: phase)
    }
    private func rule(_ buttons: [UInt32], _ phase: ButtonPhase = .down, mods: UInt64 = 0, action: String = "a") -> ButtonChordRule {
        ButtonChordRule(chord: chord(buttons, phase, mods: mods), actionId: action)
    }
    private func drag(scroll button: UInt32 = 2, mods: UInt64 = 0) -> DragToolsConfig {
        DragToolsConfig(scrollEnabled: true, scrollButton: button, scrollModifier: mods, scrollInvert: false, scrollSpeed: 1, momentum: true,
                        momentumKeep: 0.94, followModifier: 0, doubleClicks: [], doubleClickMs: 300, buttonScrolls: [],
                        autoScrollEnabled: false, autoScrollButton: 2, autoScrollModifier: 0, autoScrollSpeed: 1)
    }
    private func kinds(_ c: [ChordConflict]) -> Set<ChordConflict.Kind> { Set(c.map(\.kind)) }

    // MARK: Model

    func testChordNeedsTwoToFourKnownButtons() {
        XCTAssertFalse(chord([0]).isValid)
        XCTAssertTrue(chord([0, 1]).isValid)
        XCTAssertFalse(chord([0, 1, 2, 3, 4]).isValid)
        XCTAssertFalse(chord([0, 99]).isValid)
    }

    func testSettingsOffByDefaultRoundTripAndSanitize() {
        let defaults = UserDefaults(suiteName: "chords.\(UUID().uuidString)")!
        let store = ButtonChordStore(defaults: defaults)
        XCTAssertFalse(store.settings.enabled)
        var s = ButtonChordSettings()
        s.enabled = true
        s.rules = [rule([2, 3]), rule([0])]
        s.holdMs = 99_999
        store.settings = s
        let back = store.settings
        XCTAssertEqual(back.rules.count, 1)
        XCTAssertEqual(back.holdMs, 3000)
        XCTAssertTrue(back.enabled)
    }

    func testBadSavedDataFallsBack() {
        let defaults = UserDefaults(suiteName: "chords.\(UUID().uuidString)")!
        defaults.set(Data("x".utf8), forKey: ButtonChordStore.key)
        XCTAssertFalse(ButtonChordStore(defaults: defaults).settings.enabled)
    }

    // MARK: Conflicts

    func testDuplicateAndPrefix() {
        let c = ButtonChordConflicts.find(rules: [rule([2, 3]), rule([2, 3]), rule([2, 3, 4])])
        XCTAssertTrue(c.contains { $0.kind == .duplicate && $0.index == 1 && $0.other == 0 })
        XCTAssertTrue(c.contains { $0.kind == .prefix && $0.index == 2 })
        XCTAssertFalse(c.contains { $0.kind == .duplicate && $0.index == 0 })
    }

    func testDifferentPhaseOrKeysIsNotDuplicate() {
        let c = ButtonChordConflicts.find(rules: [rule([2, 3], .down), rule([2, 3], .hold), rule([2, 3], mods: KeyModifiers.option)])
        XCTAssertFalse(kinds(c).contains(.duplicate))
    }

    func testSharedButtonIsInformationOnly() {
        let c = ButtonChordConflicts.find(rules: [rule([2, 3], mods: 1), rule([2, 4], mods: 1)])
        XCTAssertTrue(kinds(c).contains(.sharedButton(2)))
        XCTAssertEqual(c.filter { if case .sharedButton = $0.kind { return true }; return false }.first?.severity, .info)
    }

    func testDragToolConflictNeedsSameKeys() {
        XCTAssertTrue(kinds(ButtonChordConflicts.find(rules: [rule([2, 3])], drag: drag())).contains(.dragTool(2)))
        XCTAssertFalse(kinds(ButtonChordConflicts.find(rules: [rule([2, 3], mods: KeyModifiers.option)], drag: drag())).contains(.dragTool(2)))
    }

    func testHoldRuleButtonRuleAndDoubleClickConflicts() {
        let hold = ButtonRule(button: 3, modifiers: 0, actionId: "x", trigger: .hold)
        let click = ButtonRule(button: 2, modifiers: 0, actionId: "x", trigger: .click)
        let dbl = DoubleClickBinding(button: 4, modifiers: 0, actionId: "x")
        let c = ButtonChordConflicts.find(rules: [rule([2, 3, 4])], buttonRules: [hold, click], doubleClicks: [dbl])
        XCTAssertTrue(kinds(c).isSuperset(of: [.holdRule(3), .buttonRule(2), .doubleClick(4)]))
        XCTAssertEqual(ButtonChordConflicts.worst(c)[0], .error)
    }

    func testNativeClickIsAnErrorForLeftAndRightOnly() {
        let c = ButtonChordConflicts.find(rules: [rule([0, 2])])
        XCTAssertEqual(c.first { $0.kind == .nativeClick(0) }?.severity, .error)
        XCTAssertEqual(c.first { $0.kind == .nativeClick(2) }?.severity, .warning)
        // With keys held, a middle-and-side chord leaves clicks alone.
        XCTAssertFalse(kinds(ButtonChordConflicts.find(rules: [rule([2, 3], mods: KeyModifiers.option)])).contains(.nativeClick(2)))
    }

    func testCleanChordHasNoConflicts() {
        XCTAssertTrue(ButtonChordConflicts.find(rules: [rule([3, 4], mods: KeyModifiers.option)]).isEmpty)
    }

    // MARK: Matcher

    private func matcher(_ rules: [ButtonChordRule]) -> ButtonChordMatcher {
        var s = ButtonChordSettings()
        s.enabled = true
        s.rules = rules
        return ButtonChordMatcher(settings: s)
    }

    func testDownFiresWhenSecondButtonJoinsQuickly() {
        var m = matcher([rule([2, 3], action: "chord")])
        XCTAssertNil(m.press(2, modifiers: 0, at: 0))
        XCTAssertEqual(m.press(3, modifiers: 0, at: 50)?.actionId, "chord")
    }

    func testSlowSecondButtonIsNotAChordDown() {
        var m = matcher([rule([2, 3])])
        _ = m.press(2, modifiers: 0, at: 0)
        XCTAssertNil(m.press(3, modifiers: 0, at: 1_000))
    }

    func testWrongKeysOrExtraButtonsDoNotMatch() {
        var m = matcher([rule([2, 3], mods: KeyModifiers.option)])
        _ = m.press(2, modifiers: 0, at: 0)
        XCTAssertNil(m.press(3, modifiers: 0, at: 10))
        var n = matcher([rule([2, 3])])
        _ = n.press(2, modifiers: 0, at: 0); _ = n.press(3, modifiers: 0, at: 10)
        XCTAssertNil(n.press(4, modifiers: 0, at: 20))
    }

    func testUpAndClick() {
        var m = matcher([rule([2, 3], .up, action: "up"), rule([2, 3], .click, action: "click")])
        _ = m.press(2, modifiers: 0, at: 0); _ = m.press(3, modifiers: 0, at: 20)
        let out = m.release(3, modifiers: 0, at: 100)
        XCTAssertEqual(Set(out.map(\.actionId)), ["up", "click"])
        XCTAssertTrue(m.release(2, modifiers: 0, at: 120).isEmpty)
    }

    func testSlowReleaseIsNotAClick() {
        var m = matcher([rule([2, 3], .click)])
        _ = m.press(2, modifiers: 0, at: 0); _ = m.press(3, modifiers: 0, at: 20)
        XCTAssertTrue(m.release(3, modifiers: 0, at: 2_000).isEmpty)
    }

    func testDoubleClick() {
        var m = matcher([rule([2, 3], .doubleClick, action: "dbl")])
        _ = m.press(2, modifiers: 0, at: 0); _ = m.press(3, modifiers: 0, at: 10)
        XCTAssertTrue(m.release(3, modifiers: 0, at: 60).isEmpty)
        _ = m.press(3, modifiers: 0, at: 150)
        XCTAssertEqual(m.release(3, modifiers: 0, at: 200).first?.actionId, "dbl")
    }

    func testHoldFiresOnceAfterTheHoldTime() {
        var m = matcher([rule([2, 3], .hold, action: "hold")])
        _ = m.press(2, modifiers: 0, at: 0); _ = m.press(3, modifiers: 0, at: 10)
        XCTAssertNil(m.holdDue(modifiers: 0, at: 200))
        XCTAssertEqual(m.holdDue(modifiers: 0, at: 700)?.actionId, "hold")
        XCTAssertNil(m.holdDue(modifiers: 0, at: 900))
    }

    func testDragFiresOnceAndMayHoldBackButtons() {
        var m = matcher([rule([2, 3], .drag, action: "drag")])
        _ = m.press(2, modifiers: 0, at: 0); _ = m.press(3, modifiers: 0, at: 10)
        XCTAssertEqual(m.dragged(modifiers: 0)?.actionId, "drag")
        XCTAssertNil(m.dragged(modifiers: 0))
        XCTAssertTrue(matcher([rule([2, 3])]).mayBecomeChord(button: 2, modifiers: 0))
        XCTAssertFalse(matcher([rule([2, 3])]).mayBecomeChord(button: 5, modifiers: 0))
    }

    func testDisabledAndResetForgetEverything() {
        var s = ButtonChordSettings()
        s.rules = [rule([2, 3])]
        var off = ButtonChordMatcher(settings: s)
        _ = off.press(2, modifiers: 0, at: 0)
        XCTAssertNil(off.press(3, modifiers: 0, at: 10))
        var m = matcher([rule([2, 3])])
        _ = m.press(2, modifiers: 0, at: 0)
        m.reset()
        XCTAssertTrue(m.heldButtons.isEmpty)
        XCTAssertNil(m.press(3, modifiers: 0, at: 10))
    }
}

final class ButtonChordSafetyTests: XCTestCase {
    func testLeftOrRightWithNoKeysIsNeverRun() {
        var s = ButtonChordSettings()
        s.enabled = true
        s.rules = [
            ButtonChordRule(chord: ButtonChord(pressedButtons: [0, 2], modifiers: 0, phase: .down), actionId: "unsafe"),
            ButtonChordRule(chord: ButtonChord(pressedButtons: [0, 2], modifiers: KeyModifiers.option, phase: .down), actionId: "keys"),
            ButtonChordRule(chord: ButtonChord(pressedButtons: [3, 4], modifiers: 0, phase: .down), actionId: "side"),
        ]
        var m = ButtonChordMatcher(settings: s)
        _ = m.press(0, modifiers: 0, at: 0)
        XCTAssertNil(m.press(2, modifiers: 0, at: 10))
        m.reset()
        _ = m.press(3, modifiers: 0, at: 0)
        XCTAssertEqual(m.press(4, modifiers: 0, at: 10)?.actionId, "side")
        XCTAssertFalse(s.rules[0].isSafe)
        XCTAssertTrue(s.rules[1].isSafe)
    }
}

final class ButtonChordControllerTests: XCTestCase {
    private var clock: UInt64 = 0

    private func make(rules: [ButtonChordRule]) -> (ButtonChordController, () -> [String]) {
        let defaults = UserDefaults(suiteName: "chordctl.\(UUID().uuidString)")!
        var s = ButtonChordSettings()
        s.enabled = true
        s.rules = rules
        ButtonChordStore(defaults: defaults).settings = s
        var ran: [String] = []
        let lock = NSLock()
        let controller = ButtonChordController(events: EventMonitor(), defaults: defaults, run: { id in lock.lock(); ran.append(id); lock.unlock() }, now: { [unowned self] in self.clock })
        controller.refresh(allowed: true)
        return (controller, { lock.lock(); defer { lock.unlock() }; return ran })
    }

    private func mouse(_ type: CGEventType, _ button: Int64) -> CGEvent {
        let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: CGPoint(x: 5, y: 5), mouseButton: .center)!
        e.setIntegerValueField(.mouseEventButtonNumber, value: button)
        return e
    }

    private func isDrop(_ d: EventDisposition) -> Bool { if case .drop = d { return true }; return false }

    func testChordRunsItsActionAndTakesBothButtons() {
        let rule = ButtonChordRule(chord: ButtonChord(pressedButtons: [3, 4], modifiers: 0, phase: .down), actionId: "act")
        let (c, ran) = make(rules: [rule])
        defer { c.stop() }
        clock = 0
        XCTAssertTrue(isDrop(c.handle(.otherMouseDown, mouse(.otherMouseDown, 3))))
        clock = 40
        XCTAssertTrue(isDrop(c.handle(.otherMouseDown, mouse(.otherMouseDown, 4))))
        XCTAssertTrue(isDrop(c.handle(.otherMouseUp, mouse(.otherMouseUp, 4))))
        XCTAssertTrue(isDrop(c.handle(.otherMouseUp, mouse(.otherMouseUp, 3))))
        let deadline = Date().addingTimeInterval(2)
        while ran().isEmpty, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertEqual(ran(), ["act"])
    }

    func testButtonsOutsideAnyChordPassStraightThrough() {
        let rule = ButtonChordRule(chord: ButtonChord(pressedButtons: [3, 4], modifiers: 0, phase: .down), actionId: "act")
        let (c, _) = make(rules: [rule])
        defer { c.stop() }
        XCTAssertFalse(isDrop(c.handle(.otherMouseDown, mouse(.otherMouseDown, 5))))
        XCTAssertFalse(isDrop(c.handle(.otherMouseUp, mouse(.otherMouseUp, 5))))
        XCTAssertFalse(isDrop(c.handle(.leftMouseDown, mouse(.leftMouseDown, 0))))
    }

    func testOwnReplayedPressesAreNeverHeldBackAgain() {
        let rule = ButtonChordRule(chord: ButtonChord(pressedButtons: [3, 4], modifiers: 0, phase: .down), actionId: "act")
        let (c, _) = make(rules: [rule])
        defer { c.stop() }
        let e = mouse(.otherMouseDown, 3)
        e.setIntegerValueField(.eventSourceUserData, value: ButtonChordController.replayMarker)
        XCTAssertFalse(isDrop(c.handle(.otherMouseDown, e)))
    }

    func testClaimedButtonIsLeftToItsOwner() {
        let defaults = UserDefaults(suiteName: "chordctl.\(UUID().uuidString)")!
        var s = ButtonChordSettings()
        s.enabled = true
        s.rules = [ButtonChordRule(chord: ButtonChord(pressedButtons: [3, 4], modifiers: 0, phase: .down), actionId: "act")]
        ButtonChordStore(defaults: defaults).settings = s
        let c = ButtonChordController(events: EventMonitor(), defaults: defaults, run: { _ in }, mouseClaims: { _, _ in ButtonClaims(dragCapture: true) })
        c.refresh(allowed: true)
        defer { c.stop() }
        XCTAssertFalse(isDrop(c.handle(.otherMouseDown, mouse(.otherMouseDown, 3))))
    }

    func testNotAllowedDoesNothing() {
        let rule = ButtonChordRule(chord: ButtonChord(pressedButtons: [3, 4], modifiers: 0, phase: .down), actionId: "act")
        let (c, _) = make(rules: [rule])
        defer { c.stop() }
        c.refresh(allowed: false)
        XCTAssertFalse(isDrop(c.handle(.otherMouseDown, mouse(.otherMouseDown, 3))))
    }
}

final class TrackpadGestureCommandTests: XCTestCase {
    private final class Recorder: TrackpadEventEmitter {
        var intents: [GestureIntent] = []
        func emit(_ intent: GestureIntent, at point: CGPoint) { intents.append(intent) }
    }

    func testEveryCommandIsUniqueAndNamed() {
        let ids = TrackpadGestureCommands.all.map(\.command)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertTrue(ids.allSatisfy { $0.hasPrefix("gesture.") })
        XCTAssertTrue(TrackpadGestureCommands.all.allSatisfy { $0.kind.isAvailable })
        XCTAssertTrue(WindowCommands.all.contains { $0.command == "gesture.mission_control" })
    }

    func testRunningASwipeBeginsMovesAndEnds() {
        let r = Recorder()
        let s = TrackpadGestureService(emitter: r, recognizer: GestureRecognizer(mapping: [:]), now: { 0 })
        s.run(.twoFingerSwipe(.up), at: .zero)
        XCTAssertEqual(r.intents.map(\.phase), [.began, .changed, .ended])
        XCTAssertEqual(r.intents[1].dy, -TrackpadGestureCommands.swipeDistance)
        XCTAssertFalse(s.isActive)
    }

    func testOneShotsHappenOnceAndRepeatsTooSoonAreRefused() {
        let r = Recorder()
        let s = TrackpadGestureService(emitter: r, recognizer: GestureRecognizer(mapping: [:]), now: { 0 })
        s.run(.missionControl, at: .zero)
        s.run(.missionControl, at: .zero)
        XCTAssertEqual(r.intents.filter { $0.phase == .began }.count, 1)
        XCTAssertTrue(s.refusals.contains(.tooSoon))
    }
}
