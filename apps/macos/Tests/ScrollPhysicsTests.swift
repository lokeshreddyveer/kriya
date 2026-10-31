import XCTest
@testable import Kriya

final class ScrollPhysicsEngineTests: XCTestCase {
    /// Runs the engine until it is idle (or `limit` steps), 8 ms at a time, collecting every frame.
    private func run(_ engine: inout ScrollPhysicsEngine, dt: Double = 8, limit: Int = 4_000) -> [ScrollFrame] {
        var all: [ScrollFrame] = []
        var steps = 0
        while engine.isActive, steps < limit { all += engine.step(dtMs: dt); steps += 1 }
        return all
    }

    private func total(_ frames: [ScrollFrame]) -> (dx: Double, dy: Double) { (frames.reduce(0) { $0 + $1.dx }, frames.reduce(0) { $0 + $1.dy }) }

    private func config(_ curve: ScrollCurve, momentum: Bool = false) -> ScrollPhysicsConfig {
        var c = ScrollPhysicsConfig(); c.curve = curve; c.momentum = momentum; return c
    }

    // MARK: Every curve arrives

    func testEveryCurveMovesExactlyTheDistanceAskedAndThenStops() {
        for curve in ScrollCurve.allCases {
            var e = ScrollPhysicsEngine(config: config(curve))
            e.push(dx: 0, dy: 300)
            let frames = run(&e)
            XCTAssertEqual(total(frames).dy, 300, accuracy: 0.001, "\(curve)")
            XCTAssertEqual(total(frames).dx, 0, accuracy: 0.001, "\(curve)")
            XCTAssertFalse(e.isActive, "\(curve)")
            XCTAssertLessThan(frames.count, 4_000, "\(curve) settled")
        }
    }

    func testBothDirectionsAndBothAxesArrive() {
        var e = ScrollPhysicsEngine(config: config(.criticallyDamped))
        e.push(dx: -120, dy: -250)
        let t = total(run(&e))
        XCTAssertEqual(t.dx, -120, accuracy: 0.001); XCTAssertEqual(t.dy, -250, accuracy: 0.001)
    }

    func testNoCurveEverOvershootsItsTarget() {
        for curve in ScrollCurve.allCases {
            var e = ScrollPhysicsEngine(config: config(curve))
            e.push(dx: 0, dy: 200)
            var position = 0.0
            while e.isActive { for f in e.step(dtMs: 8) { position += f.dy; XCTAssertLessThanOrEqual(position, 200.001, "\(curve)") } }
        }
    }

    func testExponentialIsFastAtFirstAndEasesOut() {
        var e = ScrollPhysicsEngine(config: config(.exponential))
        e.push(dx: 0, dy: 300)
        let frames = run(&e).filter { $0.dy != 0 }
        XCTAssertGreaterThan(frames.first!.dy, frames[frames.count / 2].dy)
        XCTAssertGreaterThan(frames[frames.count / 2].dy, frames[frames.count - 2].dy)
    }

    func testLinearMovesAtASteadySpeed() {
        var e = ScrollPhysicsEngine(config: config(.linear))
        e.push(dx: 0, dy: 300)
        let steps = run(&e).filter { $0.dy != 0 }.dropLast(2)
        let first = steps.first!.dy
        for s in steps { XCTAssertEqual(s.dy, first, accuracy: 0.01) }
    }

    func testTheSpringSettlesWithinAboutTheGlideTime() {
        var e = ScrollPhysicsEngine(config: config(.criticallyDamped))
        e.push(dx: 0, dy: 400)
        let ms = Double(run(&e).count) * 8
        XCTAssertLessThan(ms, e.config.glideMs * 4)
    }

    // MARK: Phases

    func testAGestureBeginsChangesAndEndsInThatOrder() {
        var e = ScrollPhysicsEngine(config: config(.exponential))
        e.push(dx: 0, dy: 200)
        let phases = run(&e).map(\.phase)
        XCTAssertEqual(phases.first, .began)
        XCTAssertEqual(phases.last, .ended)
        XCTAssertEqual(phases.filter { $0 == .began }.count, 1)
        XCTAssertEqual(phases.filter { $0 == .ended }.count, 1)
        XCTAssertTrue(phases.dropFirst().dropLast().allSatisfy { $0 == .changed })
        XCTAssertTrue(run(&e).isEmpty, "idle gives nothing")
    }

    func testMomentumBeginsContinuesAndEndsAfterTheGesture() {
        var e = ScrollPhysicsEngine(config: config(.exponential, momentum: true))
        e.push(dx: 0, dy: 600)
        let frames = run(&e)
        let momentum = frames.filter { $0.momentum != .none }
        XCTAssertFalse(momentum.isEmpty)
        XCTAssertEqual(momentum.first?.momentum, .began)
        XCTAssertEqual(momentum.last?.momentum, .ended)
        XCTAssertTrue(momentum.dropFirst().dropLast().allSatisfy { $0.momentum == .changed })
        let endedAt = frames.firstIndex { $0.phase == .ended }!, beganAt = frames.firstIndex { $0.momentum == .began }!
        XCTAssertLessThan(endedAt, beganAt, "the finger lifts before momentum starts")
        XCTAssertEqual(momentum.last?.dy, 0); XCTAssertFalse(momentum.last?.isMomentumCancel ?? true, "a natural stop is not a cancel")
        XCTAssertGreaterThan(total(frames).dy, 600, "momentum carried it further")
    }

    func testMomentumSlowsDownAndStops() {
        var e = ScrollPhysicsEngine(config: config(.exponential, momentum: true))
        e.push(dx: 0, dy: 800)
        let moving = run(&e).filter { $0.momentum == .changed || $0.momentum == .began }.map { abs($0.dy) }
        XCTAssertGreaterThan(moving.first!, moving.last!)
        XCTAssertTrue(zip(moving, moving.dropFirst()).allSatisfy { $0 >= $1 - 0.0001 }, "never speeds up")
    }

    func testNoMomentumWhenSwitchedOffOrForPreciseScrolling() {
        var off = ScrollPhysicsEngine(config: config(.exponential, momentum: false))
        off.push(dx: 0, dy: 800)
        XCTAssertTrue(run(&off).allSatisfy { $0.momentum == .none })
        var precise = ScrollPhysicsEngine(config: config(.exponential, momentum: true))
        precise.push(dx: 0, dy: 800, precise: true)
        XCTAssertTrue(run(&precise).allSatisfy { $0.momentum == .none }, "precise scrolling stops where it was going")
    }

    func testATinyScrollHasNoMomentum() {
        var e = ScrollPhysicsEngine(config: config(.exponential, momentum: true))
        e.push(dx: 0, dy: 1)
        XCTAssertTrue(run(&e).allSatisfy { $0.momentum == .none })
    }

    // MARK: Cancelling momentum

    func testNewInputDuringMomentumSendsTheExplicitCancelFirst() {
        var e = ScrollPhysicsEngine(config: config(.exponential, momentum: true))
        e.push(dx: 0, dy: 800)
        var guardSteps = 0
        while e.state != .momentum, guardSteps < 2_000 { _ = e.step(dtMs: 8); guardSteps += 1 }
        for _ in 0..<5 { _ = e.step(dtMs: 8) }
        XCTAssertEqual(e.state, .momentum)
        let frames = e.push(dx: 0, dy: 100)
        XCTAssertEqual(frames.count, 1)
        XCTAssertTrue(frames[0].isMomentumCancel)
        XCTAssertEqual(frames[0].momentum, .ended); XCTAssertTrue(frames[0].isEmpty)
        XCTAssertEqual(e.state, .gesture)
        XCTAssertEqual(e.step(dtMs: 8).first?.phase, .began, "and a new gesture starts")
    }

    func testCancellingAGestureSendsACancelledPhaseAndMomentumSendsTheMomentumCancel() {
        var e = ScrollPhysicsEngine(config: config(.exponential, momentum: true))
        e.push(dx: 0, dy: 500)
        _ = e.step(dtMs: 8)
        let g = e.cancel()
        XCTAssertEqual(g, [ScrollFrame(dx: 0, dy: 0, phase: .cancelled, momentum: .none)])
        XCTAssertFalse(e.isActive); XCTAssertEqual(e.remainingY, 0)
        e.push(dx: 0, dy: 800)
        var spins = 0
        while e.state == .gesture, spins < 5_000 { _ = e.step(dtMs: 8); spins += 1 }
        XCTAssertEqual(e.state, .momentum, "a fast spin carries on as momentum")
        let m = e.cancel()
        XCTAssertEqual(m.count, 1); XCTAssertTrue(m[0].isMomentumCancel); XCTAssertEqual(m[0].momentum, .ended)
        XCTAssertFalse(e.isActive)
        XCTAssertTrue(e.cancel().isEmpty, "nothing to cancel when idle")
    }

    func testCancellingBeforeAnythingWasPostedPostsNothing() {
        var e = ScrollPhysicsEngine()
        e.push(dx: 0, dy: 200)
        XCTAssertTrue(e.cancel().isEmpty, "no gesture had begun, so there is nothing to cancel")
    }

    // MARK: Input handling

    func testMoreInputExtendsTheGlideAndTheTotalIsTheSum() {
        var e = ScrollPhysicsEngine(config: config(.exponential))
        e.push(dx: 0, dy: 100); _ = e.step(dtMs: 8); _ = e.step(dtMs: 8)
        e.push(dx: 0, dy: 100)
        var sum = 0.0
        // What moved before the second push is not counted again: the total posted is the total asked.
        sum += run(&e).reduce(0) { $0 + $1.dy }
        XCTAssertGreaterThan(sum, 100)
    }

    func testTheOtherDirectionTurnsTheGlideRound() {
        var e = ScrollPhysicsEngine(config: config(.exponential))
        e.push(dx: 0, dy: 300); _ = e.step(dtMs: 8)
        let moved = e.remainingY
        e.push(dx: 0, dy: -100)
        XCTAssertEqual(e.remainingY, -100, "the rest of the old direction is dropped")
        XCTAssertLessThan(moved, 300)
    }

    func testNonsenseInputIsIgnored() {
        var e = ScrollPhysicsEngine()
        XCTAssertTrue(e.push(dx: .nan, dy: 5).isEmpty); XCTAssertFalse(e.isActive)
        XCTAssertTrue(e.push(dx: 0, dy: 0).isEmpty); XCTAssertFalse(e.isActive)
        XCTAssertTrue(e.push(dx: .infinity, dy: 0).isEmpty); XCTAssertFalse(e.isActive)
        XCTAssertTrue(e.step(dtMs: .nan).isEmpty); XCTAssertTrue(e.step(dtMs: -4).isEmpty)
    }

    func testAStalledStepIsCutSoItCannotBecomeOneHugeJump() {
        var a = ScrollPhysicsEngine(config: config(.linear)), b = ScrollPhysicsEngine(config: config(.linear))
        a.push(dx: 0, dy: 1_000); b.push(dx: 0, dy: 1_000)
        XCTAssertEqual(a.step(dtMs: 5_000).first?.dy ?? 0, b.step(dtMs: ScrollPhysicsEngine.longestStepMs).first?.dy ?? -1, accuracy: 0.0001)
    }

    func testVelocityIsTrackedWhileMoving() {
        var e = ScrollPhysicsEngine(config: config(.exponential))
        e.push(dx: 0, dy: 600)
        for _ in 0..<6 { _ = e.step(dtMs: 8) }
        XCTAssertGreaterThan(e.velocityY, 100); XCTAssertEqual(e.velocityX, 0, accuracy: 0.0001)
        XCTAssertEqual(e.speed, abs(e.velocityY), accuracy: 0.001)
    }

    func testSettingsAreHeldInRangeAndSaved() throws {
        var c = ScrollPhysicsConfig(); c.glideMs = .nan; c.pixelsPerLine = 99_999; c.momentumMs = 1; c.quickMultiplier = -3
        let s = c.sanitized()
        XCTAssertEqual(s.glideMs, 220); XCTAssertEqual(s.pixelsPerLine, 200); XCTAssertEqual(s.momentumMs, 80); XCTAssertEqual(s.quickMultiplier, 0.05)
        var settings = ScrollPhysicsSettings(); settings.enabled = true; settings.config.curve = .trackpadLike
        XCTAssertEqual(try JSONDecoder().decode(ScrollPhysicsSettings.self, from: JSONEncoder().encode(settings)), settings)
        XCTAssertFalse(try JSONDecoder().decode(ScrollPhysicsSettings.self, from: Data("{}".utf8)).enabled, "off unless switched on")
        XCTAssertEqual(try JSONDecoder().decode(ScrollPhysicsSettings.self, from: Data(#"{"config":{"curve":"bouncy"}}"#.utf8)).config.curve, .exponential)
        XCTAssertFalse(ScrollPhysicsSettings().enabled)
    }

    func testTheStoreKeepsTheSettingsAndIsRegistered() throws {
        let suite = "kriya.test.physics.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var s = ScrollPhysicsSettings(); s.enabled = true
        ScrollPhysicsStore(defaults: defaults).settings = s
        XCTAssertEqual(ScrollPhysicsStore(defaults: defaults).settings, s)
        XCTAssertNotNil(SettingsRegistry.entries.first { $0.key == ScrollPhysicsStore.key })
    }
}

final class ScrollTransformTests: XCTestCase {
    private func cfg() -> ScrollPhysicsConfig {
        var c = ScrollPhysicsConfig()
        c.quickModifier = KeyModifiers.option; c.preciseModifier = KeyModifiers.shift
        c.zoomModifier = KeyModifiers.command; c.rotateModifier = KeyModifiers.control
        return c
    }

    func testAPlainNotchIsOneStepOfTheConfiguredSize() {
        XCTAssertEqual(ScrollTransform.route(lineX: 0, lineY: 2, held: 0, swapAxes: false, config: cfg()), .scroll(dx: 0, dy: 80, precise: false))
    }

    func testQuickAndPreciseScaleTheStepAndPreciseWins() {
        XCTAssertEqual(ScrollTransform.route(lineX: 0, lineY: 1, held: KeyModifiers.option, swapAxes: false, config: cfg()), .scroll(dx: 0, dy: 160, precise: false))
        XCTAssertEqual(ScrollTransform.route(lineX: 0, lineY: 1, held: KeyModifiers.shift, swapAxes: false, config: cfg()), .scroll(dx: 0, dy: 10, precise: true))
        XCTAssertEqual(ScrollTransform.route(lineX: 0, lineY: 1, held: KeyModifiers.shift | KeyModifiers.option, swapAxes: false, config: cfg()), .scroll(dx: 0, dy: 10, precise: true))
    }

    func testZoomAndRotateTakeTheMovementInsteadOfScrolling() {
        XCTAssertEqual(ScrollTransform.route(lineX: 0, lineY: 3, held: KeyModifiers.command, swapAxes: false, config: cfg()), .zoom(3))
        XCTAssertEqual(ScrollTransform.route(lineX: 0, lineY: -2, held: KeyModifiers.control, swapAxes: false, config: cfg()), .rotate(-2))
        XCTAssertEqual(ScrollTransform.route(lineX: 0, lineY: 1, held: KeyModifiers.command, swapAxes: false, config: ScrollPhysicsConfig()), .scroll(dx: 0, dy: 40, precise: false), "no zoom keys set")
    }

    func testSidewaysTurnsUpAndDownIntoLeftAndRightAndInvertsApply() {
        var c = cfg()
        XCTAssertEqual(ScrollTransform.route(lineX: 0, lineY: 1, held: 0, swapAxes: true, config: c), .scroll(dx: 40, dy: 0, precise: false))
        c.horizontal = .invert; c.invertVertical = true
        XCTAssertEqual(ScrollTransform.route(lineX: 1, lineY: 1, held: 0, swapAxes: false, config: c), .scroll(dx: -40, dy: -40, precise: false))
        XCTAssertEqual(ScrollTransform.route(lineX: 0, lineY: 1, held: 0, swapAxes: true, config: c), .scroll(dx: -40, dy: 0, precise: false))
    }

    func testAKeyThatIsNotSetNeverMatches() {
        XCTAssertEqual(ScrollTransform.route(lineX: 0, lineY: 1, held: 0, swapAxes: false, config: ScrollPhysicsConfig()), .scroll(dx: 0, dy: 40, precise: false))
        XCTAssertEqual(ScrollTransform.route(lineX: 0, lineY: 1, held: KeyModifiers.shift | KeyModifiers.command, swapAxes: false, config: cfg()), .zoom(1), "all of the keys of a combination must be held")
    }

    func testInputKindsAreToldApartAndKriyasOwnAreNeverScrolledAgain() {
        let marker: Int64 = 0x4B52_4959
        XCTAssertEqual(ScrollInputKind.classify(isContinuous: false, userData: 0, marker: marker), .wheel)
        XCTAssertEqual(ScrollInputKind.classify(isContinuous: true, userData: 0, marker: marker), .continuous)
        XCTAssertEqual(ScrollInputKind.classify(isContinuous: false, userData: marker, marker: marker), .syntheticMomentum)
        XCTAssertEqual(ScrollInputKind.classify(isContinuous: true, userData: marker, marker: marker), .syntheticMomentum)
    }

    func testContinuousInputOnlyGetsDirectionAndZoomAndIsNeverGlided() {
        var c = cfg(); c.invertVertical = true
        XCTAssertEqual(ScrollTransform.continuous(dx: 3, dy: 5, held: 0, config: c), .scroll(dx: 3, dy: -5, precise: false))
        XCTAssertEqual(ScrollTransform.continuous(dx: 0, dy: 5, held: KeyModifiers.command, config: c), .zoom(5))
    }

    func testPhaseValuesMatchTheSystemsOwn() {
        XCTAssertEqual([ScrollPhase.began, .changed, .ended, .cancelled].map(\.rawValue), [1, 4, 8, 16])
        XCTAssertEqual([MomentumPhase.began, .changed, .ended].map(\.rawValue), [1, 4, 8])
    }

    func testCarryKeepsTheFractionAndFlushesTheLast() {
        var carry = ScrollCarry()
        var posted = 0
        for _ in 0..<12 { posted += Int(carry.take(dx: 0, dy: 0.25, flush: false).1) }
        XCTAssertEqual(posted, 3, "three whole pixels from three pixels worth in quarters (exact in binary, so no rounding drift)")
        XCTAssertEqual(carry.take(dx: 0, dy: 0, flush: true).1, 0)
        var c2 = ScrollCarry()
        XCTAssertEqual(c2.take(dx: 0, dy: 0.6, flush: false).1, 0)
        XCTAssertEqual(c2.take(dx: 0, dy: 0, flush: true).1, 1, "the last fraction is rounded, not dropped")
        XCTAssertEqual(c2.take(dx: 0, dy: 0, flush: true).1, 0)
    }
}

// MARK: - The driver, with a clock and a poster of our own

private final class ManualClock: FrameClock {
    var tick: ((Double) -> Void)?
    var running = false
    func start(_ tick: @escaping (Double) -> Void) { self.tick = tick; running = true }
    func stop() { tick = nil; running = false }
}

private final class CollectingPoster: ScrollPoster {
    struct Posted: Equatable { var dx: Int32; var dy: Int32; var phase: ScrollPhase; var momentum: MomentumPhase; var cancel: Bool }
    private let lock = NSLock()
    private var items: [Posted] = []
    var zooms: [Double] = []
    var posted: [Posted] { lock.lock(); defer { lock.unlock() }; return items }
    func post(dx: Int32, dy: Int32, frame: ScrollFrame, flags: CGEventFlags, location: CGPoint) {
        lock.lock(); items.append(Posted(dx: dx, dy: dy, phase: frame.phase, momentum: frame.momentum, cancel: frame.isMomentumCancel)); lock.unlock()
    }
    func zoom(_ amount: Double, flags: CGEventFlags, location: CGPoint) { lock.lock(); zooms.append(amount); lock.unlock() }
}

final class PhysicsScrollDriverTests: XCTestCase {
    private func drain(_ driver: PhysicsScrollDriver) {
        // Everything the driver does is on its own queue; a cancel is a barrier that comes back after what was queued before it.
        let done = expectation(description: "queue drained")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) { done.fulfill() }
        wait(for: [done], timeout: 2)
    }

    func testTheClockStartsWithInputRunsTheGestureAndStopsWhenIdle() {
        let clock = ManualClock(), poster = CollectingPoster()
        var c = ScrollPhysicsConfig(); c.momentum = false
        let driver = PhysicsScrollDriver(config: c, clock: clock, poster: poster)
        driver.push(dx: 0, dy: 200, precise: false, flags: [], location: .zero)
        drain(driver)
        XCTAssertTrue(clock.running)
        for _ in 0..<600 where clock.running { clock.tick?(8); usleep(300) }
        drain(driver)
        XCTAssertFalse(clock.running, "stops when there is nothing left to do")
        let posted = poster.posted
        XCTAssertEqual(posted.first?.phase, .began); XCTAssertEqual(posted.last?.phase, .ended)
        XCTAssertEqual(posted.reduce(0) { $0 + Int($1.dy) }, 200, "every pixel asked for was posted")
    }

    func testCancellingPostsTheCancelAndStopsTheClock() {
        let clock = ManualClock(), poster = CollectingPoster()
        let driver = PhysicsScrollDriver(config: ScrollPhysicsConfig(), clock: clock, poster: poster)
        driver.push(dx: 0, dy: 400, precise: false, flags: [], location: .zero)
        drain(driver)
        for _ in 0..<5 { clock.tick?(8); usleep(300) }
        drain(driver)
        driver.cancel()
        drain(driver)
        XCTAssertFalse(clock.running)
        XCTAssertEqual(poster.posted.last?.phase, .cancelled)
    }

    func testZoomIsPostedAsZoomNotScroll() {
        let poster = CollectingPoster()
        let driver = PhysicsScrollDriver(config: ScrollPhysicsConfig(), clock: ManualClock(), poster: poster)
        driver.zoom(2.5, flags: [], location: .zero)
        drain(driver)
        XCTAssertEqual(poster.zooms, [2.5]); XCTAssertTrue(poster.posted.isEmpty)
    }

    func testTheRealClockStartsAndStopsCleanly() {
        let clock = DisplayLinkClock()
        let ticked = expectation(description: "ticked")
        ticked.assertForOverFulfill = false
        clock.start { dt in XCTAssertGreaterThan(dt, 0); ticked.fulfill() }
        wait(for: [ticked], timeout: 2)
        clock.stop(); clock.stop()
    }
}
