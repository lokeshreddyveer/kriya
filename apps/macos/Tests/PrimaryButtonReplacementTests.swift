import XCTest
@testable import Kriya

final class ReplacementModelTests: XCTestCase {
    private func config(left: ReplacementTarget? = nil, right: ReplacementTarget? = nil) -> PrimaryButtonReplacementConfig {
        var c = PrimaryButtonReplacementConfig(); c.left = left; c.right = right; return c
    }

    func testOffByDefaultAndNothingToReplace() {
        XCTAssertFalse(PrimaryButtonReplacementStore(defaults: UserDefaults(suiteName: "repl.\(UUID().uuidString)")!).settings.enabled)
        XCTAssertEqual(config().issues, [.nothingToReplace])
        XCTAssertFalse(config().canArm)
        // A button replaced by itself is no replacement.
        XCTAssertFalse(config(left: .button(0)).replacesAnything)
        XCTAssertFalse(config(left: .action("")).replacesAnything)
    }

    func testAMouseThatCannotClickCannotBeArmed() {
        let c = config(left: .button(2), right: .button(3))
        XCTAssertFalse(c.keepsPrimaryClick)
        XCTAssertFalse(c.canArm)
        XCTAssertTrue(c.issues.contains(.losesPrimaryClick))
        let none = config(left: .action("x"), right: .action("y"))
        XCTAssertFalse(none.canArm)
    }

    func testSwapKeepsBothClicks() {
        let swap = config(left: .button(1), right: .button(0))
        XCTAssertTrue(swap.canArm)
        XCTAssertTrue(swap.keepsPrimaryClick); XCTAssertTrue(swap.keepsSecondaryClick)
        XCTAssertTrue(swap.issues.isEmpty)
    }

    func testLosingOnlyTheRightClickIsAWarningNotABlock() {
        let c = config(right: .button(2))
        XCTAssertTrue(c.canArm)
        XCTAssertEqual(c.issues, [.losesSecondaryClick])
    }

    func testSettingsRoundTripAndBadDataFallsBack() {
        let defaults = UserDefaults(suiteName: "repl.\(UUID().uuidString)")!
        let store = PrimaryButtonReplacementStore(defaults: defaults)
        var s = PrimaryButtonReplacementSettings()
        s.enabled = true
        s.config = config(left: .button(1), right: .action("abc"))
        store.settings = s
        XCTAssertEqual(store.settings, s)
        defaults.set(Data("junk".utf8), forKey: PrimaryButtonReplacementStore.key)
        XCTAssertFalse(store.settings.enabled)
    }

    func testEventConversion() {
        XCTAssertEqual(ReplacementEvents.converted(.leftMouseDown, toButton: 1), .rightMouseDown)
        XCTAssertEqual(ReplacementEvents.converted(.rightMouseUp, toButton: 0), .leftMouseUp)
        XCTAssertEqual(ReplacementEvents.converted(.leftMouseDragged, toButton: 3), .otherMouseDragged)
        XCTAssertNil(ReplacementEvents.converted(.mouseMoved, toButton: 1))
    }

    // MARK: Arming

    func testArmingNeedsTheConfirmingPressInFiveSeconds() {
        var a = ReplacementArming()
        let c = config(left: .button(1), right: .button(0))
        XCTAssertTrue(a.begin(config: c, now: 100))
        XCTAssertEqual(a.confirmButton, 0)
        XCTAssertEqual(a.remaining(now: 102), 3, accuracy: 0.001)
        XCTAssertFalse(a.physicalPress(1, now: 101), "the wrong button does not confirm")
        XCTAssertTrue(a.physicalPress(0, now: 103))
        XCTAssertTrue(a.isArmed)
    }

    func testNotConfirmingStopsIt() {
        var a = ReplacementArming()
        _ = a.begin(config: config(left: .button(1), right: .button(0)), now: 0)
        a.tick(now: 4.9)
        XCTAssertTrue(a.isCountingDown)
        a.tick(now: 5)
        XCTAssertEqual(a.state, .stopped(.confirmTimeout))
        XCTAssertFalse(a.physicalPress(0, now: 5.1))
    }

    func testConfirmButtonIsTheRightOneWhenOnlyItIsReplaced() {
        var a = ReplacementArming()
        XCTAssertTrue(a.begin(config: config(right: .button(2)), now: 0))
        XCTAssertEqual(a.confirmButton, 1)
    }

    func testCannotBeginTwiceOrWithABadConfig() {
        var a = ReplacementArming()
        XCTAssertFalse(a.begin(config: config(), now: 0))
        XCTAssertTrue(a.begin(config: config(left: .button(1), right: .button(0)), now: 0))
        XCTAssertFalse(a.begin(config: config(left: .button(1), right: .button(0)), now: 1))
    }

    func testStopAlwaysWorksAndPauseNeedsRearming() {
        var a = ReplacementArming()
        let c = config(left: .button(1), right: .button(0))
        _ = a.begin(config: c, now: 0); _ = a.physicalPress(0, now: 1)
        a.pause()
        XCTAssertEqual(a.state, .paused)
        XCTAssertTrue(a.begin(config: c, now: 10), "resuming is a fresh confirmation")
        a.stop(.escapeThreeTimes)
        XCTAssertEqual(a.state, .stopped(.escapeThreeTimes))
        a.stop(.switchedOff)
        XCTAssertEqual(a.state, .off)
        XCTAssertFalse(a.isArmed)
    }

    func testEscapeThreeTimesQuickly() {
        var e = EscapeTriplePress()
        XCTAssertFalse(e.press(at: 0)); XCTAssertFalse(e.press(at: 0.5)); XCTAssertTrue(e.press(at: 1.0))
        XCTAssertFalse(e.press(at: 1.1))
        var slow = EscapeTriplePress()
        XCTAssertFalse(slow.press(at: 0)); XCTAssertFalse(slow.press(at: 1)); XCTAssertFalse(slow.press(at: 2.2))
    }

    func testRageClicking() {
        var r = RageClickDetector()
        for i in 0..<7 { XCTAssertFalse(r.press(at: Double(i) * 0.1)) }
        XCTAssertTrue(r.press(at: 0.8))
        var calm = RageClickDetector()
        for i in 0..<20 { XCTAssertFalse(calm.press(at: Double(i) * 1.0)) }
    }

    func testEveryStopHasAMessage() {
        let all: [ReplacementStop] = [.confirmTimeout, .escapeThreeTimes, .rageClicking, .safeMode, .permissionLost, .sleep, .displaysChanged, .eventTapFailed, .switchedOff, .quit]
        XCTAssertTrue(all.allSatisfy { !$0.message.isEmpty })
    }
}

private final class FakeHUD: ReplacementHUDShowing {
    var shown: [String] = []
    var hidden = 0
    func show(_ text: String) { shown.append(text) }
    func hide() { hidden += 1 }
}

final class ReplacementControllerTests: XCTestCase {
    private var clock = 100.0
    private var ran: [String] = []
    private var released: [UInt32] = []
    private var physicallyDown = true

    private func make(_ config: PrimaryButtonReplacementConfig, enabled: Bool = true) -> (PrimaryButtonReplacementController, FakeHUD) {
        let defaults = UserDefaults(suiteName: "replctl.\(UUID().uuidString)")!
        var s = PrimaryButtonReplacementSettings()
        s.enabled = enabled; s.config = config
        PrimaryButtonReplacementStore(defaults: defaults).settings = s
        let hud = FakeHUD()
        let c = PrimaryButtonReplacementController(events: EventMonitor(), defaults: defaults, run: { [unowned self] in self.ran.append($0) }, hud: hud, now: { [unowned self] in self.clock }, releaseButton: { [unowned self] in self.released.append($0) }, physicalIsDown: { [unowned self] _ in self.physicallyDown }, watchEventTap: false)
        c.refresh(allowed: true)
        return (c, hud)
    }

    private func mouse(_ type: CGEventType, _ button: Int64) -> CGEvent {
        let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: CGPoint(x: 5, y: 5), mouseButton: button == 0 ? .left : .right)!
        return e
    }

    private func isDrop(_ d: EventDisposition) -> Bool { if case .drop = d { return true }; return false }
    private func replaced(_ d: EventDisposition) -> CGEvent? { if case .replace(let e) = d { return e }; return nil }
    private var swap: PrimaryButtonReplacementConfig { var c = PrimaryButtonReplacementConfig(); c.left = .button(1); c.right = .button(0); return c }

    func testNothingHappensUntilItIsArmed() {
        let (c, _) = make(swap)
        defer { c.stop(.quit) }
        XCTAssertEqual(c.status, .off)
        let d = c.handle(.leftMouseDown, mouse(.leftMouseDown, 0))
        XCTAssertNil(replaced(d)); XCTAssertFalse(isDrop(d))
    }

    func testCountdownThenConfirmThenSwap() {
        let (c, hud) = make(swap)
        defer { c.stop(.quit) }
        XCTAssertNil(c.arm())
        let shownBy = Date().addingTimeInterval(1)
        while hud.shown.isEmpty, Date() < shownBy { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertFalse(hud.shown.isEmpty)
        // An ordinary click during the countdown is not replaced.
        XCTAssertNil(replaced(c.handle(.rightMouseDown, mouse(.rightMouseDown, 1))))
        // The confirming press is the physical left button; it and its release are swallowed.
        clock += 2
        XCTAssertTrue(isDrop(c.handle(.leftMouseDown, mouse(.leftMouseDown, 0))))
        XCTAssertTrue(isDrop(c.handle(.leftMouseUp, mouse(.leftMouseUp, 0))))
        // Now the left button arrives as a right click, and its release follows it.
        let down = replaced(c.handle(.leftMouseDown, mouse(.leftMouseDown, 0)))
        XCTAssertEqual(down?.type, .rightMouseDown)
        XCTAssertEqual(down?.getIntegerValueField(.mouseEventButtonNumber), 1)
        let up = replaced(c.handle(.leftMouseUp, mouse(.leftMouseUp, 0)))
        XCTAssertEqual(up?.type, .rightMouseUp)
        let right = replaced(c.handle(.rightMouseDown, mouse(.rightMouseDown, 1)))
        XCTAssertEqual(right?.type, .leftMouseDown)
        _ = c.handle(.rightMouseUp, mouse(.rightMouseUp, 1))
    }

    func testEscapeThreeTimesTurnsItOffAndIsNeverSwallowed() {
        let (c, _) = make(swap)
        XCTAssertNil(c.arm())
        clock += 1
        _ = c.handle(.leftMouseDown, mouse(.leftMouseDown, 0)); _ = c.handle(.leftMouseUp, mouse(.leftMouseUp, 0))
        for i in 0..<3 {
            clock += 0.2
            let esc = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true)!
            XCTAssertFalse(isDrop(c.handle(.keyDown, esc)), "press \(i)")
        }
        XCTAssertNil(replaced(c.handle(.leftMouseDown, mouse(.leftMouseDown, 0))))
        let deadline = Date().addingTimeInterval(1)
        func isStopped() -> Bool { if case .stopped = c.status { return true }; return false }
        while !isStopped(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(isStopped(), "status \(c.status)")
        c.stop(.quit)
    }

    func testAHeldReplacedButtonIsReleasedWhenItStops() {
        let (c, _) = make(swap)
        XCTAssertNil(c.arm())
        clock += 1
        _ = c.handle(.leftMouseDown, mouse(.leftMouseDown, 0)); _ = c.handle(.leftMouseUp, mouse(.leftMouseUp, 0))
        _ = c.handle(.leftMouseDown, mouse(.leftMouseDown, 0))     // becomes a right press, still held
        c.stop(.sleep)
        // While the physical button is still down nothing is released: that would cut short a hold that is still going on.
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertTrue(released.isEmpty, "no release while the physical button is still held")
        physicallyDown = false
        let deadline = Date().addingTimeInterval(2)
        while released.isEmpty, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertEqual(released, [1], "the one right press that the left button became is let go, once, after the physical release")
        // The release of the physical button now passes straight through: nothing is left claiming it.
        let d = c.handle(.leftMouseUp, mouse(.leftMouseUp, 0))
        XCTAssertNil(replaced(d)); XCTAssertFalse(isDrop(d))
    }

    func testActionTargetRunsOnPressAndSwallowsTheRest() {
        var cfg = PrimaryButtonReplacementConfig(); cfg.right = .action("do-it")
        let (c, _) = make(cfg)
        defer { c.stop(.quit) }
        XCTAssertNil(c.arm())
        clock += 1
        XCTAssertTrue(isDrop(c.handle(.rightMouseDown, mouse(.rightMouseDown, 1))))      // the confirmation
        _ = c.handle(.rightMouseUp, mouse(.rightMouseUp, 1))
        XCTAssertTrue(isDrop(c.handle(.rightMouseDown, mouse(.rightMouseDown, 1))))
        XCTAssertTrue(isDrop(c.handle(.rightMouseUp, mouse(.rightMouseUp, 1))))
        let deadline = Date().addingTimeInterval(1)
        while ran.isEmpty, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertEqual(ran, ["do-it"])
    }

    func testUnsafeConfigAndNotAllowedCannotBeArmed() {
        var cfg = PrimaryButtonReplacementConfig(); cfg.left = .button(2); cfg.right = .button(3)
        let (c, _) = make(cfg)
        defer { c.stop(.quit) }
        XCTAssertNotNil(c.arm())
        XCTAssertEqual(c.status, .off)
        let (d, _) = make(swap, enabled: false)
        XCTAssertNotNil(d.arm())
    }

    func testPauseAndTimeoutLeaveEverythingAlone() {
        let (c, _) = make(swap)
        defer { c.stop(.quit) }
        XCTAssertNil(c.arm())
        clock += 10
        // Unconfirmed: a press after the five seconds is not a confirmation.
        XCTAssertFalse(isDrop(c.handle(.leftMouseDown, mouse(.leftMouseDown, 0))))
        c.pause()
        let deadline = Date().addingTimeInterval(1)
        while c.status != .paused, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertEqual(c.status, .paused)
    }
}
