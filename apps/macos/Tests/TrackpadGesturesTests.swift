import XCTest
@testable import Kriya

private final class RecordingEmitter: TrackpadEventEmitter {
    var intents: [GestureIntent] = []
    func emit(_ intent: GestureIntent, at point: CGPoint) { intents.append(intent) }
}

final class TrackpadGesturesTests: XCTestCase {
    private let map: [NavigateDirection: GestureKind] = [
        .up: .twoFingerSwipe(.up), .down: .fourFingerPinch(zoomIn: false), .left: .missionControl, .right: .rotate,
    ]

    func testContinuousBeginsChangesEnds() {
        var r = GestureRecognizer(mapping: map)
        let first = r.move(dx: 0, dy: -20)
        XCTAssertEqual(first.map(\.phase), [.began, .changed])
        XCTAssertEqual(r.move(dx: 0, dy: -5).map(\.phase), [.changed])
        XCTAssertEqual(r.end().map(\.phase), [.ended])
        XCTAssertFalse(r.isRecognizing)
    }

    func testOneShotFiresOnceAndNothingAfter() {
        var r = GestureRecognizer(mapping: map)
        XCTAssertEqual(r.move(dx: -30, dy: 0).map(\.phase), [.began, .ended])
        XCTAssertTrue(r.move(dx: -30, dy: 0).isEmpty)
        XCTAssertTrue(r.end().isEmpty)
    }

    func testUnmappedDirectionDoesNothing() {
        var r = GestureRecognizer(mapping: [:])
        XCTAssertTrue(r.move(dx: 40, dy: 0).isEmpty)
        XCTAssertFalse(r.isRecognizing)
    }

    func testCancelProducesCancelOnlyForContinuous() {
        var r = GestureRecognizer(mapping: map)
        _ = r.move(dx: 0, dy: -20)
        XCTAssertEqual(r.cancel().map(\.phase), [.cancelled])
        var s = GestureRecognizer(mapping: map)
        _ = s.move(dx: -30, dy: 0)
        XCTAssertTrue(s.cancel().isEmpty)
    }

    func testRecognizerResetsForTheNextDrag() {
        var r = GestureRecognizer(mapping: map)
        _ = r.move(dx: 0, dy: -20); _ = r.end()
        XCTAssertEqual(r.move(dx: -30, dy: 0).first?.kind, .missionControl)
    }

    func testPolicyAllowsOneContinuousAtATime() {
        var p = GestureSafetyPolicy()
        XCTAssertNil(p.admit(GestureIntent(kind: .twoFingerSwipe(.up), phase: .began), now: 0))
        XCTAssertEqual(p.admit(GestureIntent(kind: .fourFingerPinch(zoomIn: true), phase: .began), now: 1), .anotherGestureRunning)
        XCTAssertNil(p.admit(GestureIntent(kind: .twoFingerSwipe(.up), phase: .cancelled), now: 2))
        XCTAssertNil(p.active)
    }

    func testPolicyRefusesOffUnavailableAndTooSoon() {
        var p = GestureSafetyPolicy(allowed: false)
        XCTAssertEqual(p.admit(GestureIntent(kind: .missionControl, phase: .began), now: 0), .off)
        p.allowed = true
        XCTAssertEqual(p.admit(GestureIntent(kind: .rotate, phase: .began), now: 0), .unavailable)
        XCTAssertNil(p.admit(GestureIntent(kind: .missionControl, phase: .began), now: 10))
        XCTAssertEqual(p.admit(GestureIntent(kind: .missionControl, phase: .began), now: 10.1), .tooSoon)
        XCTAssertNil(p.admit(GestureIntent(kind: .missionControl, phase: .began), now: 11))
    }

    func testChangeWithoutBeginIsRefusedAndTimeLimitApplies() {
        var p = GestureSafetyPolicy(maxSeconds: 5)
        XCTAssertEqual(p.admit(GestureIntent(kind: .twoFingerSwipe(.up), phase: .changed), now: 0), .notBegun)
        _ = p.admit(GestureIntent(kind: .twoFingerSwipe(.up), phase: .began), now: 0)
        XCTAssertEqual(p.admit(GestureIntent(kind: .twoFingerSwipe(.up), phase: .changed), now: 6), .tooLong)
        XCTAssertTrue(p.isExpired(now: 6))
    }

    func testServiceEmitsAndCancelsEverything() {
        let emitter = RecordingEmitter()
        var clock = 0.0
        let service = TrackpadGestureService(emitter: emitter, recognizer: GestureRecognizer(mapping: map), now: { clock })
        service.move(dx: 0, dy: -20, at: .zero)
        XCTAssertTrue(service.isActive)
        service.cancel()
        XCTAssertFalse(service.isActive)
        XCTAssertEqual(emitter.intents.map(\.phase), [.began, .changed, .cancelled])
        service.cancel()
        XCTAssertEqual(emitter.intents.count, 3)
        clock = 1
    }

    func testServiceCancelsAnExpiredGestureInsteadOfContinuing() {
        let emitter = RecordingEmitter()
        var clock = 0.0
        let service = TrackpadGestureService(emitter: emitter, recognizer: GestureRecognizer(mapping: map), policy: GestureSafetyPolicy(maxSeconds: 2), now: { clock })
        service.move(dx: 0, dy: -20, at: .zero)
        clock = 5
        service.move(dx: 0, dy: -5, at: .zero)
        XCTAssertEqual(emitter.intents.last?.phase, .cancelled)
        XCTAssertFalse(service.isActive)
    }

    func testTurningOffMidGestureCancelsIt() {
        let emitter = RecordingEmitter()
        let service = TrackpadGestureService(emitter: emitter, recognizer: GestureRecognizer(mapping: map), now: { 0 })
        service.move(dx: 0, dy: -20, at: .zero)
        service.setAllowed(false)
        XCTAssertEqual(emitter.intents.last?.phase, .cancelled)
        service.move(dx: 0, dy: -20, at: .zero)
        XCTAssertEqual(emitter.intents.last?.phase, .cancelled)
    }

    func testPerformSendsAOneShot() {
        let emitter = RecordingEmitter()
        let service = TrackpadGestureService(emitter: emitter, recognizer: GestureRecognizer(mapping: [:]), now: { 0 })
        service.perform(.appExpose, at: .zero)
        XCTAssertEqual(emitter.intents.map(\.phase), [.began, .ended])
    }
}
