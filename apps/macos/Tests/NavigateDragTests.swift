import XCTest
@testable import Kriya

final class NavigateDragModelTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
    private func session(at p: CGPoint = CGPoint(x: 500, y: 400)) -> NavigateDragSession { NavigateDragSession(startPoint: p, displayID: 1, bounds: bounds) }

    func testDirectionNeedsDistanceAndDominance() {
        XCTAssertNil(NavigateDragSession.direction(travel: CGPoint(x: 5, y: 0), threshold: 14, dominance: 1.3))
        XCTAssertNil(NavigateDragSession.direction(travel: CGPoint(x: 20, y: 18), threshold: 14, dominance: 1.3))
        XCTAssertEqual(NavigateDragSession.direction(travel: CGPoint(x: -30, y: 5), threshold: 14, dominance: 1.3), .left)
        XCTAssertEqual(NavigateDragSession.direction(travel: CGPoint(x: 3, y: 30), threshold: 14, dominance: 1.3), .down)
        XCTAssertEqual(NavigateDragSession.direction(travel: CGPoint(x: 3, y: -30), threshold: 14, dominance: 1.3), .up)
    }

    func testVerticalDragScrollsAndKeepsScrolling() {
        var s = session()
        let config = NavigateDragConfig()
        var effects = s.move(dx: 0, dy: 20, config: config)
        XCTAssertEqual(s.phase, .tracking)
        XCTAssertTrue(effects.contains(.scroll(dx: 0, dy: 20)))
        effects = s.move(dx: 0, dy: 5, config: config)
        XCTAssertTrue(effects.contains(.scroll(dx: 0, dy: 5)))
    }

    func testReverseAndSpeedApply() {
        var s = session()
        var config = NavigateDragConfig()
        config.reverseScroll = true; config.speed = 2
        let effects = s.move(dx: 0, dy: 20, config: config)
        XCTAssertTrue(effects.contains(.scroll(dx: 0, dy: -40)))
    }

    func testSidewaysDragGoesBackOnce() {
        var s = session()
        let config = NavigateDragConfig()
        let effects = s.move(dx: -30, dy: 0, config: config)
        XCTAssertTrue(effects.contains(.run(.back)))
        XCTAssertEqual(s.phase, .fired)
        XCTAssertTrue(s.move(dx: -30, dy: 0, config: config).filter { if case .run = $0 { return true }; return false }.isEmpty)
    }

    func testRightIsForward() {
        var s = session()
        XCTAssertTrue(s.move(dx: 30, dy: 0, config: NavigateDragConfig()).contains(.run(.forward)))
    }

    func testPointerStaysInsideTheDisplay() {
        var s = session(at: CGPoint(x: 995, y: 5))
        _ = s.move(dx: 500, dy: -500, config: NavigateDragConfig())
        XCTAssertEqual(s.currentPoint, CGPoint(x: 999, y: 0))
    }

    func testReleaseWithoutDragIsAClick() {
        var s = session()
        _ = s.move(dx: 2, dy: 1, config: NavigateDragConfig())
        XCTAssertEqual(s.end(), [.click])
        XCTAssertEqual(s.phase, .finished)
    }

    func testReleaseAfterDragIsNotAClick() {
        var s = session()
        _ = s.move(dx: 0, dy: 40, config: NavigateDragConfig())
        XCTAssertEqual(s.end(), [])
    }

    func testCancelNeverClicksAndEndsTheSession() {
        var s = session()
        s.cancel()
        XCTAssertEqual(s.phase, .cancelled)
        XCTAssertEqual(s.end(), [])
        XCTAssertEqual(s.move(dx: 0, dy: 50, config: NavigateDragConfig()), [])
    }

    func testRotateAndMismatchedActionsDoNothing() {
        var config = NavigateDragConfig()
        config.mapping[.up] = .rotate
        config.mapping[.down] = .backForward
        XCTAssertEqual(config.warnings.count, 2)
        var s = session()
        let effects = s.move(dx: 0, dy: -30, config: config)
        XCTAssertEqual(s.phase, .fired)
        XCTAssertFalse(effects.contains { if case .run = $0 { return true }; return false })
        XCTAssertEqual(config.sanitized().action(for: .down), NavigateDragAction.none)
    }

    func testRestorePoint() {
        var s = session()
        _ = s.move(dx: 0, dy: 40, config: NavigateDragConfig())
        XCTAssertEqual(s.restorePoint(returnsToStart: true), CGPoint(x: 500, y: 400))
        XCTAssertEqual(s.restorePoint(returnsToStart: false), CGPoint(x: 500, y: 440))
    }

    func testSanitizedHoldsButtonToCapturableOnes() {
        var c = NavigateDragConfig()
        c.button = 0; c.threshold = .nan; c.maxSeconds = 9_999; c.speed = -3
        let out = c.sanitized()
        XCTAssertEqual(out.button, 2)
        XCTAssertEqual(out.threshold, 14)
        XCTAssertEqual(out.maxSeconds, NavigateDragConfig.secondsRange.upperBound)
        XCTAssertEqual(out.speed, NavigateDragConfig.speedRange.lowerBound)
    }

    func testSettingsAreOffByDefaultAndRoundTrip() {
        let defaults = UserDefaults(suiteName: "navdrag.test.\(UUID().uuidString)")!
        let store = NavigateDragStore(defaults: defaults)
        XCTAssertFalse(store.settings.enabled)
        var s = NavigateDragSettings()
        s.enabled = true
        s.config.mapping[.up] = .zoom
        s.config.button = 4
        store.settings = s
        XCTAssertEqual(store.settings, s)
    }

    func testBadSavedDataFallsBack() {
        let defaults = UserDefaults(suiteName: "navdrag.test.\(UUID().uuidString)")!
        defaults.set(Data("nonsense".utf8), forKey: NavigateDragStore.key)
        XCTAssertFalse(NavigateDragStore(defaults: defaults).settings.enabled)
    }
}

/// The pointer freeze, overlay and poster are replaced by recorders, so nothing here holds the real pointer.
private final class FakeFreeze: PointerFreezing {
    var isFrozen = false
    var restores: [CGPoint?] = []
    var forced: (() -> Void)?
    func freeze(at point: CGPoint, maxSeconds: Double, onForcedRelease: @escaping () -> Void) { isFrozen = true; forced = onForcedRelease }
    func restore(at point: CGPoint?) { isFrozen = false; restores.append(point) }
}

private final class FakeOverlay: VirtualPointerShowing {
    func show(at point: CGPoint, anchor: CGPoint) {}
    func move(to point: CGPoint) {}
    func hide() {}
}

private final class FakePoster: NavigateActionPosting {
    var scrolls: [(Double, Double, ScrollPhase)] = []
    var zooms: [Double] = []
    var commands: [NavigateDragCommand] = []
    var clicks: [UInt32] = []
    func scroll(dx: Double, dy: Double, phase: ScrollPhase, at point: CGPoint) { scrolls.append((dx, dy, phase)) }
    func zoom(_ amount: Double, at point: CGPoint) { zooms.append(amount) }
    func run(_ command: NavigateDragCommand) { commands.append(command) }
    func click(button: UInt32, at point: CGPoint) { clicks.append(button) }
}

final class NavigateDragControllerTests: XCTestCase {
    private func make(claims: ButtonClaims = ButtonClaims()) -> (NavigateDragController, FakeFreeze, FakePoster) {
        let defaults = UserDefaults(suiteName: "navdrag.ctl.\(UUID().uuidString)")!
        var settings = NavigateDragSettings()
        settings.enabled = true
        NavigateDragStore(defaults: defaults).settings = settings
        let freeze = FakeFreeze(), poster = FakePoster()
        let controller = NavigateDragController(events: EventMonitor(), defaults: defaults, freeze: freeze, overlay: FakeOverlay(), poster: poster, mouseClaims: { _, _ in claims })
        return (controller, freeze, poster)
    }

    private func mouse(_ type: CGEventType, button: Int64 = 2, at p: CGPoint = CGPoint(x: 300, y: 300), dx: Double = 0, dy: Double = 0) -> CGEvent {
        let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .center)!
        e.setIntegerValueField(.mouseEventButtonNumber, value: button)
        e.setDoubleValueField(.mouseEventDeltaX, value: dx)
        e.setDoubleValueField(.mouseEventDeltaY, value: dy)
        return e
    }

    private func isDrop(_ d: EventDisposition) -> Bool { if case .drop = d { return true }; return false }

    func testDisabledOrNotAllowedLeavesEverythingAlone() {
        let (controller, freeze, _) = make()
        // Not allowed yet: refresh was never given permission.
        XCTAssertFalse(isDrop(controller.handle(.otherMouseDown, mouse(.otherMouseDown))))
        XCTAssertFalse(freeze.isFrozen)
    }

    func testScrollDragFreezesScrollsAndReleases() {
        let (controller, freeze, poster) = make()
        controller.refresh(allowed: true)
        defer { controller.stop() }
        XCTAssertTrue(isDrop(controller.handle(.otherMouseDown, mouse(.otherMouseDown))))
        XCTAssertTrue(freeze.isFrozen)
        XCTAssertTrue(isDrop(controller.handle(.otherMouseDragged, mouse(.otherMouseDragged, dy: 30))))
        XCTAssertEqual(poster.scrolls.first?.2, .began)
        _ = controller.handle(.otherMouseDragged, mouse(.otherMouseDragged, dy: 10))
        XCTAssertEqual(poster.scrolls.last?.2, .changed)
        XCTAssertTrue(isDrop(controller.handle(.otherMouseUp, mouse(.otherMouseUp))))
        XCTAssertEqual(poster.scrolls.last?.2, .ended)
        XCTAssertFalse(freeze.isFrozen)
        XCTAssertEqual(freeze.restores.last ?? nil, CGPoint(x: 300, y: 300))
        XCTAssertTrue(poster.clicks.isEmpty)
        XCTAssertFalse(controller.isCapturing)
    }

    func testClickWithoutDragIsSentOn() {
        let (controller, freeze, poster) = make()
        controller.refresh(allowed: true)
        defer { controller.stop() }
        _ = controller.handle(.otherMouseDown, mouse(.otherMouseDown))
        _ = controller.handle(.otherMouseUp, mouse(.otherMouseUp))
        XCTAssertEqual(poster.clicks, [2])
        XCTAssertFalse(freeze.isFrozen)
    }

    func testSidewaysDragRunsBackOnce() {
        let (controller, _, poster) = make()
        controller.refresh(allowed: true)
        defer { controller.stop() }
        _ = controller.handle(.otherMouseDown, mouse(.otherMouseDown))
        _ = controller.handle(.otherMouseDragged, mouse(.otherMouseDragged, dx: -40))
        _ = controller.handle(.otherMouseDragged, mouse(.otherMouseDragged, dx: -40))
        _ = controller.handle(.otherMouseUp, mouse(.otherMouseUp))
        XCTAssertEqual(poster.commands, [.back])
        XCTAssertTrue(poster.clicks.isEmpty)
    }

    func testEscapeCancelsWithoutClickAndGivesPointerBack() {
        let (controller, freeze, poster) = make()
        controller.refresh(allowed: true)
        defer { controller.stop() }
        _ = controller.handle(.otherMouseDown, mouse(.otherMouseDown))
        _ = controller.handle(.otherMouseDragged, mouse(.otherMouseDragged, dy: 40))
        let esc = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true)!
        XCTAssertTrue(isDrop(controller.handle(.keyDown, esc)))
        XCTAssertFalse(freeze.isFrozen)
        XCTAssertEqual(poster.scrolls.last?.2, .cancelled)
        // The button's own release is still taken, and does not click.
        _ = controller.handle(.otherMouseUp, mouse(.otherMouseUp))
        XCTAssertTrue(poster.clicks.isEmpty)
    }

    func testForcedReleaseStopsTheDrag() {
        let (controller, freeze, poster) = make()
        controller.refresh(allowed: true)
        defer { controller.stop() }
        _ = controller.handle(.otherMouseDown, mouse(.otherMouseDown))
        _ = controller.handle(.otherMouseDragged, mouse(.otherMouseDragged, dy: 40))
        freeze.forced?()
        XCTAssertFalse(controller.isCapturing)
        XCTAssertEqual(poster.scrolls.last?.2, .cancelled)
        // Motion after the safety net let go is not swallowed.
        XCTAssertFalse(isDrop(controller.handle(.otherMouseDragged, mouse(.otherMouseDragged, dy: 5))))
    }

    func testOtherButtonsAndClaimedButtonsAreLeftAlone() {
        let (controller, freeze, _) = make()
        controller.refresh(allowed: true)
        defer { controller.stop() }
        XCTAssertFalse(isDrop(controller.handle(.otherMouseDown, mouse(.otherMouseDown, button: 3))))
        XCTAssertFalse(freeze.isFrozen)

        let (claimed, claimedFreeze, _) = make(claims: ButtonClaims(excluded: false, dragCapture: true))
        claimed.refresh(allowed: true)
        defer { claimed.stop() }
        XCTAssertFalse(isDrop(claimed.handle(.otherMouseDown, mouse(.otherMouseDown))))
        XCTAssertFalse(claimedFreeze.isFrozen)
    }

    func testOwnSyntheticEventsAreNeverCaptured() {
        let (controller, freeze, _) = make()
        controller.refresh(allowed: true)
        defer { controller.stop() }
        let e = mouse(.otherMouseDown)
        e.setIntegerValueField(.eventSourceUserData, value: EventMonitor.syntheticMarker)
        XCTAssertFalse(isDrop(controller.handle(.otherMouseDown, e)))
        XCTAssertFalse(freeze.isFrozen)
    }

    func testStopWhileCapturingGivesPointerBack() {
        let (controller, freeze, _) = make()
        controller.refresh(allowed: true)
        _ = controller.handle(.otherMouseDown, mouse(.otherMouseDown))
        XCTAssertTrue(freeze.isFrozen)
        controller.stop()
        XCTAssertFalse(freeze.isFrozen)
        XCTAssertFalse(controller.isCapturing)
    }
}
