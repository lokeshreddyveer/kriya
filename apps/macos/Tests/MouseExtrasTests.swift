import XCTest
@testable import Kriya

final class HoldTrackerTests: XCTestCase {
    private let origin = CGPoint(x: 10, y: 20)

    func testAPressHeldLongEnoughRunsOnceAndItsReleaseIsSwallowed() {
        let tracker = HoldTracker<String>()
        let id = tracker.press(button: 3, location: origin, flags: [], nowMs: 1_000, holdMs: 350, payload: "hold")
        XCTAssertTrue(tracker.isTracking)
        XCTAssertNil(tracker.fireIfDue(id: id, nowMs: 1_349), "one millisecond early")
        XCTAssertEqual(tracker.fireIfDue(id: id, nowMs: 1_350), "hold", "on the dot")
        XCTAssertNil(tracker.fireIfDue(id: id, nowMs: 1_900), "it runs once")
        guard case .afterHold = tracker.release(button: 3) else { return XCTFail("the release belongs to the hold") }
        XCTAssertFalse(tracker.isTracking)
    }

    func testAPressLetGoSoonerIsAnOrdinaryClickAndNeverRunsTheHold() {
        let tracker = HoldTracker<String>()
        let id = tracker.press(button: 3, location: origin, flags: [.maskCommand], nowMs: 1_000, holdMs: 350, payload: "hold")
        guard case .early(let at, let flags, let payload) = tracker.release(button: 3) else { return XCTFail("a quick release is a click") }
        XCTAssertEqual(at, origin, "the click goes where the press was")
        XCTAssertTrue(flags.contains(.maskCommand), "with the keys that were held")
        XCTAssertEqual(payload, "hold")
        XCTAssertNil(tracker.fireIfDue(id: id, nowMs: 5_000), "a late timer for a press that is gone does nothing")
    }

    func testAButtonThatIsNotBeingTrackedIsLeftAlone() {
        let tracker = HoldTracker<String>()
        guard case .notTracked = tracker.release(button: 5) else { return XCTFail("nothing to do") }
        XCTAssertFalse(tracker.isTracking)
    }

    func testTwoButtonsAreTrackedSeparatelyAndATimerOnlyAnswersForItsOwnPress() {
        let tracker = HoldTracker<String>()
        let first = tracker.press(button: 3, location: origin, flags: [], nowMs: 0, holdMs: 300, payload: "side")
        let second = tracker.press(button: 4, location: origin, flags: [], nowMs: 100, holdMs: 300, payload: "other side")
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(tracker.fireIfDue(id: first, nowMs: 300), "side")
        XCTAssertNil(tracker.fireIfDue(id: second, nowMs: 399))
        XCTAssertEqual(tracker.fireIfDue(id: second, nowMs: 400), "other side")
        guard case .early = tracker.release(button: 99) else { return }
    }

    func testPressingAgainAfterAHoldStartsFresh() {
        let tracker = HoldTracker<String>()
        let first = tracker.press(button: 3, location: origin, flags: [], nowMs: 0, holdMs: 200, payload: "a")
        XCTAssertEqual(tracker.fireIfDue(id: first, nowMs: 250), "a")
        _ = tracker.release(button: 3)
        let again = tracker.press(button: 3, location: origin, flags: [], nowMs: 1_000, holdMs: 200, payload: "a")
        XCTAssertNil(tracker.fireIfDue(id: again, nowMs: 1_100))
        guard case .early = tracker.release(button: 3) else { return XCTFail("a quick second press is a click") }
    }

    func testCancellingForgetsEverythingAndRunsNothing() {
        let tracker = HoldTracker<String>()
        let id = tracker.press(button: 3, location: origin, flags: [], nowMs: 0, holdMs: 100, payload: "x")
        tracker.cancel()
        XCTAssertFalse(tracker.isTracking)
        XCTAssertNil(tracker.fireIfDue(id: id, nowMs: 500))
        guard case .notTracked = tracker.release(button: 3) else { return XCTFail("the sleep or stop dropped the press") }
    }

    func testAClockThatWentBackwardsDoesNotRunAHold() {
        let tracker = HoldTracker<String>()
        let id = tracker.press(button: 3, location: origin, flags: [], nowMs: 5_000, holdMs: 100, payload: "x")
        XCTAssertNil(tracker.fireIfDue(id: id, nowMs: 4_000))
    }
}

final class HoldRuleCompilingTests: XCTestCase {
    func testClickRulesAndHoldRulesAreKeptApartAndANormalPresetHasNoHolds() {
        var settings = defaultMouseSettings()
        settings.buttons = [
            ButtonRule(button: 3, modifiers: 0, actionId: "click", trigger: .click),
            ButtonRule(button: 3, modifiers: 0, actionId: "hold", trigger: .hold),
            ButtonRule(button: 4, modifiers: 0, actionId: "missing", trigger: .hold),
        ]
        settings.holdMs = 500
        let compiled = CompiledMouse(settings: settings, actions: ["click": .noop, "hold": .noop], neutral: defaultMouseSettings().vertical)
        let key = ButtonKey(button: 3, modifiers: 0)
        XCTAssertNotNil(compiled.buttonActions[key])
        XCTAssertNotNil(compiled.holdActions[key])
        XCTAssertEqual(compiled.holdActions.count, 1, "a rule whose action no longer exists is left out")
        XCTAssertEqual(compiled.holdMs, 500)

        var plain = defaultMouseSettings()
        plain.buttons = [ButtonRule(button: 3, modifiers: 0, actionId: "click", trigger: .click)]
        let ordinary = CompiledMouse(settings: plain, actions: ["click": .noop], neutral: defaultMouseSettings().vertical)
        XCTAssertTrue(ordinary.holdActions.isEmpty, "without hold rules no press is ever held back, so clicks behave as before")
        XCTAssertEqual(ordinary.buttonActions.count, 1)
    }
}

final class AutoScrollTests: XCTestCase {
    func testEscapeStopsItAndIsTakenOtherKeysAreLeftAlone() {
        let auto = AutoScroll()
        var reasons: [AutoScroll.StopReason] = []
        auto.onStop = { reasons.append($0) }
        XCTAssertFalse(auto.key(AutoScroll.escapeKeyCode), "Escape means nothing to it while it is off")
        auto.start(at: CGPoint(x: 100, y: 100))
        XCTAssertTrue(auto.isActive)
        XCTAssertFalse(auto.key(36), "Return is not its business")
        XCTAssertFalse(auto.key(0))
        XCTAssertTrue(auto.isActive)
        XCTAssertTrue(auto.key(AutoScroll.escapeKeyCode), "Escape is taken, so it does not also close something")
        XCTAssertFalse(auto.isActive)
        XCTAssertEqual(reasons, [.escape])
    }

    func testAClickStopsItAndIsTakenButOnlyWhileItIsRunning() {
        let auto = AutoScroll()
        var reasons: [AutoScroll.StopReason] = []
        auto.onStop = { reasons.append($0) }
        XCTAssertFalse(auto.click(), "a click while it is off is an ordinary click")
        auto.start(at: .zero)
        XCTAssertTrue(auto.click())
        XCTAssertFalse(auto.click(), "the next click is ordinary again")
        XCTAssertEqual(reasons, [.click])
    }

    func testTheWheelStopsItAndGoesThrough() {
        let auto = AutoScroll()
        var reasons: [AutoScroll.StopReason] = []
        auto.onStop = { reasons.append($0) }
        auto.wheel()
        XCTAssertTrue(reasons.isEmpty)
        auto.start(at: .zero)
        auto.wheel()
        XCTAssertFalse(auto.isActive)
        XCTAssertEqual(reasons, [.wheel])
    }

    func testStoppingTwiceTellsOnlyOnce() {
        let auto = AutoScroll()
        var count = 0
        auto.onStop = { _ in count += 1 }
        auto.start(at: .zero)
        auto.stop(.toggled)
        auto.stop(.toggled)
        XCTAssertEqual(count, 1)
    }

    func testTheContentMovesAgainstThePointerAndNothingHappensInsideTheDeadZone() {
        let auto = AutoScroll()
        XCTAssertTrue(auto.step(pointer: CGPoint(x: 500, y: 500), seconds: 0.008, speed: 1) == (0, 0), "not running")
        auto.start(at: CGPoint(x: 400, y: 400))
        let still = auto.step(pointer: CGPoint(x: 405, y: 396), seconds: 0.008, speed: 1)
        XCTAssertEqual(still.dx, 0); XCTAssertEqual(still.dy, 0)
        let down = auto.step(pointer: CGPoint(x: 400, y: 500), seconds: 0.008, speed: 1)
        XCTAssertLessThan(down.dy, 0, "the pointer below the start reads on, so the content moves up")
        XCTAssertEqual(down.dx, 0)
        let up = auto.step(pointer: CGPoint(x: 400, y: 300), seconds: 0.008, speed: 1)
        XCTAssertEqual(up.dy, -down.dy, accuracy: 1e-9)
        let right = auto.step(pointer: CGPoint(x: 500, y: 400), seconds: 0.008, speed: 1)
        XCTAssertLessThan(right.dx, 0)
        let farther = auto.step(pointer: CGPoint(x: 400, y: 700), seconds: 0.008, speed: 1)
        XCTAssertLessThan(farther.dy, down.dy, "further away is faster")
        let slower = auto.step(pointer: CGPoint(x: 400, y: 500), seconds: 0.008, speed: 0.5)
        XCTAssertEqual(slower.dy * 2, down.dy, accuracy: 1e-9)
    }

    func testAnOddClockStepScrollsNothing() {
        let auto = AutoScroll()
        auto.start(at: .zero)
        XCTAssertTrue(auto.step(pointer: CGPoint(x: 0, y: 300), seconds: 0, speed: 1) == (0, 0))
        XCTAssertTrue(auto.step(pointer: CGPoint(x: 0, y: 300), seconds: -1, speed: 1) == (0, 0))
        XCTAssertTrue(auto.step(pointer: CGPoint(x: 0, y: 300), seconds: 30, speed: 1) == (0, 0), "after a long stall it does not jump the page")
    }
}

final class DeviceStatusTests: XCTestCase {
    private func source(_ name: String, current: Int, max: Int = 100, charging: Bool = false, type: String? = nil, transport: String? = nil) -> [String: Any] {
        var d: [String: Any] = ["Name": name, "Current Capacity": current, "Max Capacity": max, "Is Charging": charging]
        if let type { d["Type"] = type }
        if let transport { d["Transport Type"] = transport }
        return d
    }

    func testOnlyAccessoriesAreReadNotTheMacsOwnBattery() {
        let readings = DeviceBattery.parse([
            source("InternalBattery-0", current: 80, type: "InternalBattery"),
            source("Magic Mouse", current: 40, charging: true, transport: "Bluetooth"),
            source("Odd", current: 5, max: 0),
            ["Name": "No capacity"],
            ["Current Capacity": 50],
            source("Half", current: 50, max: 200),
            source("Over", current: 300, max: 100),
        ])
        XCTAssertEqual(readings.map(\.name), ["Magic Mouse", "Half", "Over"])
        XCTAssertEqual(readings[0], BatteryReading(name: "Magic Mouse", percent: 40, charging: true))
        XCTAssertEqual(readings[1].percent, 25)
        XCTAssertEqual(readings[2].percent, 100, "never over a hundred")
    }

    func testADeviceGetsItsOwnReadingOrSaysUnavailable() {
        let readings = [BatteryReading(name: "Magic Mouse", percent: 62, charging: false), BatteryReading(name: "Magic Keyboard", percent: 90, charging: true)]
        XCTAssertEqual(DeviceBattery.state(forDeviceNamed: ["Magic Mouse"], readings: readings), .level(percent: 62, charging: false))
        XCTAssertEqual(DeviceBattery.state(forDeviceNamed: ["magic  mouse"], readings: readings), .level(percent: 62, charging: false), "case and spacing")
        XCTAssertEqual(DeviceBattery.state(forDeviceNamed: ["Jane's Magic Mouse 2"], readings: readings), .level(percent: 62, charging: false), "a longer name that holds it")
        XCTAssertEqual(DeviceBattery.state(forDeviceNamed: ["Logitech USB Receiver"], readings: readings), .unavailable, "a device that reports nothing says so")
        XCTAssertEqual(DeviceBattery.state(forDeviceNamed: ["Mouse"], readings: readings), .unavailable, "too short to be sure")
        XCTAssertEqual(DeviceBattery.state(forDeviceNamed: ["Magic Mouse"], readings: []), .unavailable)
        XCTAssertEqual(DeviceBattery.state(forDeviceNamed: [], readings: readings), .unavailable)
    }

    func testTwoThatCouldBeTheSameDeviceAreNeverGuessed() {
        let readings = [BatteryReading(name: "Magic Mouse", percent: 10, charging: false), BatteryReading(name: "Magic Mouse", percent: 90, charging: false)]
        XCTAssertEqual(DeviceBattery.state(forDeviceNamed: ["Magic Mouse"], readings: readings), .unavailable)
        let loose = [BatteryReading(name: "Magic Mouse 2", percent: 10, charging: false), BatteryReading(name: "Magic Mouse 3", percent: 90, charging: false)]
        XCTAssertEqual(DeviceBattery.state(forDeviceNamed: ["Magic Mouse"], readings: loose), .unavailable)
    }

    func testTheWordsForEachState() {
        XCTAssertEqual(DeviceStatusText.battery(.level(percent: 40, charging: false), connection: .wireless), "Battery 40%")
        XCTAssertEqual(DeviceStatusText.battery(.level(percent: 40, charging: true), connection: .wireless), "Battery 40%, charging")
        XCTAssertEqual(DeviceStatusText.battery(.unavailable, connection: .wired), "Battery: not reported by this device")
        XCTAssertEqual(DeviceStatusText.battery(.unavailable, connection: .builtIn), "Built in")
        let now = Date()
        XCTAssertEqual(DeviceStatusText.lastUsed(now.addingTimeInterval(-2), now: now), "Last used just now")
        XCTAssertNil(DeviceStatusText.lastUsed(nil))
        XCTAssertTrue(DeviceStatusText.reconnected(now.addingTimeInterval(-300), now: now)?.contains("settings came back by themselves") == true)
        XCTAssertNil(DeviceStatusText.reconnected(nil))
    }

    func testOnlyADeviceThatWentAwayAndCameBackCountsAsReconnected() {
        var history = ConnectionHistory()
        let start = Date(timeIntervalSince1970: 1_000)
        history.connected("mouse", at: start)
        XCTAssertEqual(history.connectedAt["mouse"], start)
        XCTAssertNil(history.reconnectedAt["mouse"], "plugged in when Kriya started is not a reconnection")
        history.disconnected("mouse")
        XCTAssertNil(history.connectedAt["mouse"])
        history.connected("mouse", at: start.addingTimeInterval(60))
        XCTAssertEqual(history.reconnectedAt["mouse"], start.addingTimeInterval(60))
        history.connected("mouse", at: start.addingTimeInterval(90))
        XCTAssertEqual(history.reconnectedAt["mouse"], start.addingTimeInterval(60), "a second interface of the same device is not another reconnection")
        history.forget("mouse")
        XCTAssertNil(history.reconnectedAt["mouse"])
        history.connected("mouse", at: start)
        XCTAssertNil(history.reconnectedAt["mouse"])
    }

    func testARememberedDeviceThatIsNotHereShowsNoBatteryAndItsLastUse() throws {
        let world = try TestWorld()
        defer { world.cleanUp() }
        let record = DeviceRecord(
            id: "1:2:serial", name: "Magic Mouse", vendorId: 1, productId: 2, serial: "serial", transport: "Bluetooth", kind: .mouse,
            detectedConnection: .wireless, connectionOverride: nil, nickname: nil, firstSeen: 1, lastSeen: 2
        )
        try world.core.upsertDevice(device: record)
        let registry = DeviceRegistry(core: world.core)
        let used = Date(timeIntervalSince1970: 5_000)
        registry.batteryReader = { [BatteryReading(name: "Magic Mouse", percent: 70, charging: false)] }
        registry.lastUsedProvider = { $0 == "1:2:serial" ? used : nil }
        registry.activeDeviceID = { "1:2:serial" }
        registry.reload()
        let done = expectation(description: "status read")
        registry.refreshStatus()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { done.fulfill() }
        wait(for: [done], timeout: 5)
        let status = try XCTUnwrap(registry.statuses["1:2:serial"])
        XCTAssertEqual(status.battery, .unavailable, "it is not connected, so no battery is claimed")
        XCTAssertEqual(status.lastUsed, used)
        XCTAssertEqual(registry.displayName(forID: "1:2:serial"), "Magic Mouse")
        XCTAssertEqual(registry.activeDeviceName(), "Magic Mouse")
        XCTAssertNil(registry.displayName(forID: "unknown"))
    }
}

final class MouseTraceTests: XCTestCase {
    func testATraceLineNamesTheButtonWhatHappenedAndTheDeviceAndNothingElse() {
        let line = MouseFeature.traceText("released before the hold time, passed on as a click", button: 2, device: "MX Master 3S")
        XCTAssertEqual(line, "Middle button released before the hold time, passed on as a click (MX Master 3S)")
        XCTAssertEqual(MouseFeature.traceText("gesture up ran a rule", button: 3, device: nil), "Button 4 gesture up ran a rule")
    }

    func testNothingIsRecordedUnlessATraceWasStartedAndItEndsByItself() {
        var clock = Date(timeIntervalSince1970: 100)
        let trace = InteractionTrace(now: { clock })
        XCTAssertFalse(trace.isRecording)
        trace.note("Mouse", "Middle button held")
        trace.start()
        XCTAssertTrue(trace.isRecording)
        clock = clock.addingTimeInterval(InteractionTrace.duration + 1)
        XCTAssertFalse(trace.isRecording, "five minutes is the most")
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(trace.entries.isEmpty)
    }

    func testTheTesterShowsTheDeviceWhenItKnowsOne() {
        XCTAssertEqual(InputTesterFormat.attributed("Middle button pressed", device: "MX Master 3S"), "Middle button pressed  ·  MX Master 3S")
        XCTAssertEqual(InputTesterFormat.attributed("Middle button pressed", device: nil), "Middle button pressed")
        XCTAssertEqual(InputTesterFormat.attributed("Middle button pressed", device: ""), "Middle button pressed")
    }
}
