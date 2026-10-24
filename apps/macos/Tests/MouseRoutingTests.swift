import XCTest
@testable import Kriya

/// The fixes from the Mouse & Trackpad review: auto-scroll that starts, one answer for a repeated rule, buttons held on two devices,
/// one order in which the drag tools, gestures, holds and double clicks take a button, and a device guess that admits when it is unsure.
final class MouseRoutingTests: XCTestCase {
    private func drag(_ change: (inout DragToolsConfig) -> Void = { _ in }) throws -> DragToolsConfig {
        let world = try TestWorld()
        defer { world.cleanUp() }
        var config = DragToolsStore(core: world.core).config
        config.scrollEnabled = false; config.autoScrollEnabled = false; config.followModifier = 0; config.doubleClicks = []; config.buttonScrolls = []
        change(&config)
        return config
    }

    // MARK: Auto-scroll alone starts the handler

    func testAutoScrollSwitchedOnByItselfStartsTheDragTools() throws {
        XCTAssertFalse(DragToolsActivation.needsEvents(try drag()))
        XCTAssertTrue(DragToolsActivation.needsEvents(try drag { $0.autoScrollEnabled = true }), "this was the bug: the setting saved and nothing listened")
        XCTAssertTrue(DragToolsActivation.needsEvents(try drag { $0.scrollEnabled = true }))
        XCTAssertTrue(DragToolsActivation.needsEvents(try drag { $0.followModifier = 1 }))
        XCTAssertTrue(DragToolsActivation.needsEvents(try drag { $0.doubleClicks = [DoubleClickBinding(button: 2, modifiers: 0, actionId: "a")] }))
        XCTAssertTrue(DragToolsActivation.needsEvents(try drag { $0.buttonScrolls = [ButtonScrollBinding(button: 2, upActionId: "a", downActionId: nil)] }))
    }

    func testTheDragToolsRunOnlyWhenAllowedAndOnlyWithMouseAndTrackpadOn() throws {
        let on = try drag { $0.autoScrollEnabled = true }
        XCTAssertTrue(DragToolsActivation.shouldRun(on, inputMonitoring: true, safeMode: false, mouseOn: true))
        XCTAssertFalse(DragToolsActivation.shouldRun(on, inputMonitoring: false, safeMode: false, mouseOn: true))
        XCTAssertFalse(DragToolsActivation.shouldRun(on, inputMonitoring: true, safeMode: true, mouseOn: true))
        XCTAssertFalse(DragToolsActivation.shouldRun(on, inputMonitoring: true, safeMode: false, mouseOn: false), "Mouse & Trackpad off means the drag tools are off")
        XCTAssertFalse(DragToolsActivation.shouldRun(try drag(), inputMonitoring: true, safeMode: false, mouseOn: true))
    }

    func testTheDragToolsDoNothingWhileMouseAndTrackpadIsOffForTheAppInFront() throws {
        let world = try TestWorld()
        defer { world.cleanUp() }
        let store = DragToolsStore(core: world.core)
        store.update { $0.autoScrollEnabled = true; $0.autoScrollButton = 2; $0.autoScrollModifier = 0 }
        var allowed = false
        let tools = DragTools(events: EventMonitor(), store: store, windowStore: WindowStore(core: world.core), run: { _ in }, isActive: { allowed })
        func middleDown() -> CGEvent { CGEvent(mouseEventSource: nil, mouseType: .otherMouseDown, mouseCursorPosition: .zero, mouseButton: .center)! }
        guard case .passThrough = tools.handle(.otherMouseDown, middleDown()) else { return XCTFail("an excluded app gets the click untouched") }
        allowed = true
        guard case .drop = tools.handle(.otherMouseDown, middleDown()) else { return XCTFail("allowed, the click starts auto-scroll") }
        tools.reset()
        allowed = false
        guard case .passThrough = tools.handle(.otherMouseDown, middleDown()) else { return XCTFail("and off again") }
    }

    // MARK: A repeated rule means the same thing everywhere

    func testTheFirstOfTwoIdenticalRulesRunsAndTheSimulatorSaysTheSame() {
        var settings = defaultMouseSettings()
        settings.buttons = [
            ButtonRule(button: 3, modifiers: 0, actionId: "first", trigger: .click),
            ButtonRule(button: 3, modifiers: 0, actionId: "second", trigger: .click),
            ButtonRule(button: 3, modifiers: 0, actionId: "held", trigger: .hold),
            ButtonRule(button: 3, modifiers: 0, actionId: "held-again", trigger: .hold),
        ]
        let actions = ["first": Action.keyPress(keyCode: 1, modifiers: 0), "second": Action.keyPress(keyCode: 2, modifiers: 0),
                       "held": Action.keyPress(keyCode: 3, modifiers: 0), "held-again": Action.keyPress(keyCode: 4, modifiers: 0)]
        let compiled = CompiledMouse(settings: settings, actions: actions, neutral: defaultMouseSettings().vertical)
        let key = ButtonKey(button: 3, modifiers: 0)
        XCTAssertEqual(compiled.buttonActions[key], actions["first"], "the first click rule runs")
        XCTAssertEqual(compiled.holdActions[key], actions["held"], "the first hold rule runs")
        let result = RuleSimulator.simulate(settings, button: 3, modifiers: 0, held: false, actionName: { $0 })
        guard case .ambiguous(let ids) = result.outcome else { return XCTFail("two rules fit") }
        XCTAssertEqual(ids.first, "first", "and the simulator names that same one")
        XCTAssertTrue(result.notes.contains { $0.contains("first in the list is used") })
    }

    func testRulesThatRepeatAnEarlierOneAreFound() {
        let a = ButtonRule(button: 3, modifiers: 0, actionId: "a", trigger: .click)
        let b = ButtonRule(button: 3, modifiers: 0, actionId: "b", trigger: .click)
        let hold = ButtonRule(button: 3, modifiers: 0, actionId: "h", trigger: .hold)
        let other = ButtonRule(button: 4, modifiers: 0, actionId: "o", trigger: .click)
        let withKey = ButtonRule(button: 3, modifiers: 8, actionId: "k", trigger: .click)
        XCTAssertEqual(ButtonRuleCheck.shadowed([a, b, hold, other, withKey]), [1])
        XCTAssertEqual(ButtonRuleCheck.shadowed([a, hold, other, withKey]), [], "a click and a hold on one button are not a repeat")
        XCTAssertEqual(ButtonRuleCheck.shadowed([a, b, ButtonRule(button: 3, modifiers: 0, actionId: "c", trigger: .click)]), [1, 2])
    }

    func testAButtonRuleSaysWhenADragToolTakesTheButtonFirst() throws {
        let config = try drag { $0.scrollEnabled = true; $0.scrollButton = 2; $0.scrollModifier = 0; $0.autoScrollEnabled = true; $0.autoScrollButton = 3; $0.autoScrollModifier = 8
            $0.buttonScrolls = [ButtonScrollBinding(button: 4, upActionId: "a", downActionId: nil)] }
        XCTAssertTrue(DragToolsActivation.uses(config, button: 2, modifiers: 0))
        XCTAssertFalse(DragToolsActivation.uses(config, button: 2, modifiers: 8), "other keys held: not the same press")
        XCTAssertTrue(DragToolsActivation.uses(config, button: 3, modifiers: 8))
        XCTAssertTrue(DragToolsActivation.uses(config, button: 4, modifiers: 0), "a held button with the wheel takes the button whatever keys")
        XCTAssertFalse(DragToolsActivation.uses(config, button: 5, modifiers: 0))
        let note = RuleSimulator.simulate(defaultMouseSettings(), button: 2, modifiers: 0, held: false, dragToolsUseIt: true, actionName: { $0 })
        XCTAssertTrue(note.notes.contains { $0.contains("drag tool") })
    }

    // MARK: Two devices, one button

    func testTheSameButtonHeldOnTwoDevicesIsTwoPresses() {
        let tracker = HoldTracker<String>()
        let origin = CGPoint(x: 5, y: 5)
        let mouseA = tracker.press(device: "A", button: 3, location: origin, flags: [], nowMs: 0, holdMs: 300, payload: "from A")
        let mouseB = tracker.press(device: "B", button: 3, location: origin, flags: [], nowMs: 50, holdMs: 300, payload: "from B")
        XCTAssertNotEqual(mouseA, mouseB)
        XCTAssertEqual(tracker.fireIfDue(id: mouseA, nowMs: 300), "from A", "A's press was not overwritten by B's")
        guard case .afterHold = tracker.release(device: "A", button: 3) else { return XCTFail("A's release belongs to A's hold") }
        guard case .early(_, _, let payload) = tracker.release(device: "B", button: 3) else { return XCTFail("B let go early: a click") }
        XCTAssertEqual(payload, "from B")
        XCTAssertFalse(tracker.isTracking)
    }

    func testAReleaseAttributedToAnotherDeviceStillEndsThePress() {
        let tracker = HoldTracker<String>()
        tracker.press(device: "A", button: 3, location: .zero, flags: [], nowMs: 0, holdMs: 300, payload: "a")
        guard case .early = tracker.release(device: "", button: 3) else { return XCTFail("the guess changed between press and release; the press must still end") }
        XCTAssertFalse(tracker.isTracking, "so its hold rule cannot run after the button was let go")
        guard case .notTracked = tracker.release(device: "A", button: 3) else { return XCTFail("nothing left") }
    }

    func testSwallowedReleasesAreKeptPerDeviceToo() {
        var set = DeviceButtonSet()
        set.insert(button: 3, device: "A"); set.insert(button: 3, device: "B")
        XCTAssertTrue(set.remove(button: 3, device: "B"))
        XCTAssertFalse(set.isEmpty, "A's is still waiting")
        XCTAssertTrue(set.remove(button: 3, device: "unknown"), "a release from an unrecognised device ends the one that is left")
        XCTAssertTrue(set.isEmpty)
        XCTAssertFalse(set.remove(button: 3, device: "A"))
    }

    // MARK: Which device

    func testTwoDevicesActiveTogetherIsNotGuessed() {
        let window: UInt64 = 300_000_000
        XCTAssertEqual(DeviceAttribution.resolve(ages: ["mouse": 10_000_000], maxAge: window), .device("mouse"))
        XCTAssertEqual(DeviceAttribution.resolve(ages: ["mouse": 10_000_000, "pad": 250_000_000], maxAge: window), .ambiguous)
        XCTAssertEqual(DeviceAttribution.resolve(ages: ["mouse": 10_000_000, "pad": 900_000_000], maxAge: window), .device("mouse"), "the other went quiet")
        XCTAssertEqual(DeviceAttribution.resolve(ages: ["pad": 900_000_000], maxAge: window), .none)
        XCTAssertEqual(DeviceAttribution.resolve(ages: [:], maxAge: window), .none)
    }

    func testTheTrackerFallsBackToTheDefaultWhenItIsNotSure() {
        let tracker = DeviceActivityTracker()
        XCTAssertNil(tracker.currentDeviceID())
        tracker.simulateActivity(deviceID: "mouse")
        XCTAssertEqual(tracker.currentDeviceID(), "mouse")
        XCTAssertEqual(tracker.attribution(maxAgeNs: DeviceActivityTracker.testWindowNs), .device("mouse"))
        tracker.simulateActivity(deviceIDs: ["mouse", "pad"])
        XCTAssertNil(tracker.currentDeviceID(), "two at once: the general settings, not a guess")
        XCTAssertEqual(tracker.attribution(), .ambiguous)
    }

    // MARK: One order for everything that wants a button

    func testTheOrderIsExcludedDragGestureHoldDoubleClickRuleThenMacOS() {
        func winner(_ change: (inout ButtonClaims) -> Void) -> InputLayer { var c = ButtonClaims(); change(&c); return InputPrecedence.winner(c) }
        XCTAssertEqual(winner { _ in }, .native)
        XCTAssertEqual(winner { $0.click = true }, .buttonRule)
        XCTAssertEqual(winner { $0.click = true; $0.doubleClick = true }, .doubleClick)
        XCTAssertEqual(winner { $0.doubleClick = true; $0.hold = true }, .hold)
        XCTAssertEqual(winner { $0.hold = true; $0.gesture = true }, .gesture)
        XCTAssertEqual(winner { $0.gesture = true; $0.dragCapture = true }, .dragCapture)
        XCTAssertEqual(winner { $0.dragCapture = true; $0.excluded = true }, .excluded)
        XCTAssertEqual(InputLayer.allCases.sorted(), InputLayer.allCases)
        for layer in InputLayer.allCases { XCTAssertFalse(layer.title.isEmpty) }
    }

    func testADoubleClickRuleGivesWayToAGestureOrHoldRuleOnTheSameButton() {
        XCTAssertTrue(InputPrecedence.doubleClickMayAct(ButtonClaims()))
        XCTAssertTrue(InputPrecedence.doubleClickMayAct(ButtonClaims(click: true)), "it beats an ordinary button rule")
        XCTAssertFalse(InputPrecedence.doubleClickMayAct(ButtonClaims(gesture: true)))
        XCTAssertFalse(InputPrecedence.doubleClickMayAct(ButtonClaims(hold: true)))
        XCTAssertFalse(InputPrecedence.doubleClickMayAct(ButtonClaims(excluded: true)))
    }

    func testTheMouseRulesReportWhatTheyWantFromAButton() throws {
        let world = try TestWorld()
        defer { world.cleanUp() }
        let devices = DeviceRegistry(core: world.core)
        let profiles = ProfileStore(core: world.core)
        let library = ActionLibrary(core: world.core)
        let store = MouseStore(core: world.core, library: library, devices: devices, profiles: profiles)
        store.start()
        let claims = store.claims(button: 3, modifiers: 0, device: nil)
        XCTAssertFalse(claims.excluded); XCTAssertFalse(claims.hold); XCTAssertFalse(claims.click)
    }

    // MARK: The drag tools and the mouse rules take events in a fixed order

    func testTheDragToolsComeBeforeTheMouseRulesAndBothBeforeEveryoneElse() {
        var order: [Int] = []
        for priority in [0, EventMonitor.mousePriority, 0, EventMonitor.dragToolsPriority, EventMonitor.mousePriority] {
            order.insert(priority, at: EventMonitor.insertionIndex(existing: order, priority: priority))
        }
        XCTAssertEqual(order, [20, 10, 10, 0, 0], "drag tools, then the mouse rules, then the others in the order they came")
        XCTAssertGreaterThan(EventMonitor.dragToolsPriority, EventMonitor.mousePriority)
        XCTAssertEqual(EventMonitor.insertionIndex(existing: [], priority: 0), 0)
        XCTAssertEqual(EventMonitor.insertionIndex(existing: [0, 0], priority: 0), 2, "equal priorities keep their order")
    }

    // MARK: Permissions

    func testEveryMissingPermissionIsNamedWithWhatItIsFor() {
        let both = MousePermissionNote.message(missing: [.inputMonitoring, .accessibility])
        XCTAssertTrue(both.contains("Input Monitoring")); XCTAssertTrue(both.contains("Accessibility"))
        XCTAssertTrue(both.contains("scrolling")); XCTAssertTrue(both.contains("windows"))
        XCTAssertTrue(MousePermissionNote.message(missing: [.inputMonitoring]).contains("Input Monitoring"))
        XCTAssertFalse(MousePermissionNote.message(missing: [.inputMonitoring]).contains("Accessibility"))
        XCTAssertEqual(MousePermissionNote.message(missing: []), "Your changes are saved, but they only take effect while the feature is on and allowed.")
    }
}
