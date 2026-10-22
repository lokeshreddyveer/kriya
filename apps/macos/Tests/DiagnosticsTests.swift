import XCTest
@testable import Kriya

final class SupportScrubberTests: XCTestCase {
    private func scrub(_ text: String) -> String {
        SupportScrubber.scrub(text, home: "/Users/janedoe", user: "janedoe", computerName: "Jane's MacBook Pro")
    }

    func testWhoAndWhereIsTakenOut() {
        let out = scrub("Opened /Users/janedoe/Documents/plans.txt for janedoe on Jane's MacBook Pro")
        XCTAssertFalse(out.contains("janedoe"))
        XCTAssertFalse(out.contains("Jane's"))
        XCTAssertTrue(out.contains("~/Documents/plans.txt"))
        XCTAssertTrue(out.contains("<this Mac>"))
        XCTAssertEqual(scrub("/Users/someoneelse/x"), "/Users/<user>/x", "any account's folder")
    }

    func testAddressesAndKeysAreTakenOut() {
        let out = scrub("mail jane@example.com from 10.0.0.12 at aa:bb:cc:dd:ee:ff key ghp_16C7e42F292c6912E7710c838347Ae178B4a done")
        XCTAssertTrue(out.contains("<email>"))
        XCTAssertTrue(out.contains("<address>"))
        XCTAssertTrue(out.contains("<hardware address>"))
        XCTAssertTrue(out.contains("<token>"))
        XCTAssertFalse(out.contains("ghp_16C7"))
        XCTAssertEqual(scrub("see https://example.com/page?session=abc123&user=jane now"), "see https://example.com/page?<removed> now")
        XCTAssertTrue(scrub("a long string aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa stays").contains("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"), "all letters is not a key")
    }

    func testOrdinaryReportTextIsLeftAlone() {
        let text = "Kriya 0.2.8 (15), macOS 27.0, arm64\nFeatures: Mouse on, running\nEvent tap: running, 4 subscribers, 120 events, avg 35 µs"
        XCTAssertEqual(scrub(text), text)
    }

    func testAShortOrEmptyNameDoesNotEatTheReport() {
        let out = SupportScrubber.scrub("a b ab", home: "/", user: "ab", computerName: "")
        XCTAssertEqual(out, "a b ab")
    }
}

final class InteractionTraceTests: XCTestCase {
    private func settle() { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }

    func testItRecordsNothingUntilStartedAndStopsByItself() {
        var clock = Date(timeIntervalSince1970: 1_000)
        let trace = InteractionTrace(now: { clock })
        trace.note("Shortcut", "Windows › left")
        settle()
        XCTAssertTrue(trace.entries.isEmpty, "off by default")
        trace.start()
        settle()
        XCTAssertTrue(trace.isOn)
        trace.note("Shortcut", "Windows › left_half")
        trace.note("Command", "window.maximize")
        settle()
        XCTAssertEqual(trace.entries.map(\.text), ["Windows › left_half", "window.maximize"])
        XCTAssertTrue(trace.text().contains("Shortcut: Windows › left_half"))
        clock = clock.addingTimeInterval(InteractionTrace.duration + 1)
        trace.note("Command", "too late")
        settle()
        XCTAssertFalse(trace.isOn)
        XCTAssertEqual(trace.entries.count, 2, "nothing after the time is up")
        trace.clear()
        settle()
        XCTAssertTrue(trace.entries.isEmpty)
    }

    func testItKeepsOnlyTheMostRecent() {
        let trace = InteractionTrace()
        trace.start()
        for index in 0..<(InteractionTrace.capacity + 25) { trace.note("Command", "c\(index)") }
        settle(); settle()
        XCTAssertEqual(trace.entries.count, InteractionTrace.capacity)
        XCTAssertEqual(trace.entries.last?.text, "c\(InteractionTrace.capacity + 24)")
        XCTAssertEqual(trace.entries.first?.text, "c25")
    }

    func testStoppingStopsRecording() {
        let trace = InteractionTrace()
        trace.start()
        settle()
        trace.stop()
        settle()
        trace.note("Command", "after")
        settle()
        XCTAssertTrue(trace.entries.isEmpty)
        XCTAssertFalse(trace.isOn)
    }
}

final class PerformanceTimelineTests: XCTestCase {
    func testASampleIsTheChangeSinceTheLastReading() {
        var before = EventMonitor.Stats()
        before.eventsHandled = 100; before.slowHandlers = 2; before.tapRecoveries = 1
        var after = before
        after.eventsHandled = 160; after.slowHandlers = 3; after.p95Microseconds = 80; after.tapRecoveries = 1
        let sample = PerformanceTimeline.sample(from: before, to: after, at: Date())
        XCTAssertEqual(sample.events, 60)
        XCTAssertEqual(sample.slowHandlers, 1)
        XCTAssertEqual(sample.recoveries, 0)
        XCTAssertEqual(sample.p95Microseconds, 80)
        XCTAssertEqual(PerformanceTimeline.sample(from: after, to: before, at: Date()).events, 0, "numbers that were reset never go negative")
    }

    func testOnlyTheLatestSamplesAreKept() {
        let timeline = PerformanceTimeline()
        for index in 0..<(PerformanceTimeline.capacity + 10) {
            timeline.append(PerformanceTimeline.Sample(time: Date(), events: index, p95Microseconds: 1, slowHandlers: 0, recoveries: 0))
        }
        XCTAssertEqual(timeline.samples.count, PerformanceTimeline.capacity)
        XCTAssertEqual(timeline.samples.first?.events, 10)
    }

    func testTheSparklineStaysInsideItsBox() {
        let path = Sparkline(values: [0, 50, 100, 25]).path(in: CGRect(x: 0, y: 0, width: 100, height: 40))
        XCTAssertLessThanOrEqual(path.boundingRect.maxY, 40.001)
        XCTAssertGreaterThanOrEqual(path.boundingRect.minY, -0.001)
        XCTAssertEqual(path.boundingRect.width, 100, accuracy: 0.01)
        XCTAssertTrue(Sparkline(values: [5]).path(in: CGRect(x: 0, y: 0, width: 10, height: 10)).isEmpty)
    }
}

final class KeyboardHealthTests: XCTestCase {
    func testSecureInputNamesTheAppHoldingIt() {
        let on = SecureInput.parse(enabled: true, session: ["kCGSSessionSecureInputPID": 321], appName: { $0 == 321 ? "Terminal" : nil })
        XCTAssertEqual(on, SecureInputStatus(enabled: true, pid: 321, appName: "Terminal"))
        let unnamed = SecureInput.parse(enabled: true, session: [:], appName: { _ in "x" })
        XCTAssertEqual(unnamed, SecureInputStatus(enabled: true, pid: nil, appName: nil))
        XCTAssertEqual(SecureInput.parse(enabled: false, session: ["kCGSSessionSecureInputPID": 5], appName: { _ in "x" }), SecureInputStatus(enabled: false, pid: nil, appName: nil))
        XCTAssertEqual(SecureInput.parse(enabled: true, session: ["kCGSSessionSecureInputPID": NSNumber(value: 77)], appName: { _ in nil }).pid, 77)
        XCTAssertNil(SecureInput.parse(enabled: true, session: ["kCGSSessionSecureInputPID": 0], appName: { _ in nil }).pid)
    }

    func testReleasingModifiersSendsAKeyUpForEachAndMarksThemAsKriyas() {
        var posted: [CGEvent] = []
        ModifierReset.run { posted.append($0) }
        XCTAssertEqual(posted.count, ModifierReset.keyCodes.count)
        for event in posted {
            XCTAssertTrue([.keyUp, .flagsChanged].contains(event.type), "a modifier key's release is reported as a change of modifiers")
            XCTAssertEqual(event.getIntegerValueField(.eventSourceUserData), EventMonitor.syntheticMarker)
            XCTAssertTrue(event.flags.isEmpty)
        }
        XCTAssertEqual(Set(posted.map { $0.getIntegerValueField(.keyboardEventKeycode) }), Set(ModifierReset.keyCodes.map(Int64.init)))
    }
}

final class DeviceContextTests: XCTestCase {
    private func preset(_ id: String, _ name: String) -> MousePreset {
        MousePreset(id: id, name: name, isBuiltin: false, settings: defaultMouseSettings())
    }

    private func explain(_ assignments: [MouseAssignment], app: String? = "com.app.a", secure: SecureInputStatus = SecureInputStatus(enabled: false, pid: nil, appName: nil), remap: Bool = false, rules: [RemapRule] = []) -> [DeviceContextLine] {
        DeviceContext.explain(
            devices: [(id: "dev1", name: "MX Master")], presets: [preset("default", "Default"), preset("gaming", "Gaming"), preset("work", "Work")],
            assignments: assignments, defaultPresetID: "default", frontAppID: app, frontAppName: app, remapRules: rules, remapEnabled: remap, secureInput: secure
        )
    }

    private func detail(_ lines: [DeviceContextLine], _ id: String) -> String { lines.first { $0.id == id }?.detail ?? "" }

    func testTheMostSpecificChoiceWinsAndTheReasonSaysWhy() {
        XCTAssertTrue(detail(explain([]), "device-dev1").contains("“Default”"))
        XCTAssertTrue(detail(explain([]), "device-dev1").contains("default"))
        let forDevice = MouseAssignment(id: "1", deviceId: "dev1", appId: nil, presetId: "gaming")
        let forApp = MouseAssignment(id: "2", deviceId: nil, appId: "com.app.a", presetId: "work")
        let both = MouseAssignment(id: "3", deviceId: "dev1", appId: "com.app.a", presetId: "gaming")
        XCTAssertTrue(detail(explain([forDevice]), "device-dev1").contains("Gaming") && detail(explain([forDevice]), "device-dev1").contains("for this device"))
        XCTAssertTrue(detail(explain([forDevice, forApp]), "device-dev1").contains("Work"), "the app beats the device")
        XCTAssertTrue(detail(explain([forDevice, forApp, both]), "device-dev1").contains("device in"), "both beats either")
        XCTAssertTrue(detail(explain([forApp], app: "com.other"), "device-dev1").contains("Default"), "another app")
    }

    func testRemappingAndSecureInputAreExplained() {
        XCTAssertEqual(detail(explain([]), "remap"), "Off.")
        let rule = RemapRule(id: "r", name: "Caps to Escape", enabled: true, keyCode: 57, modifiers: 0, appIds: ["com.app.a"], tap: nil, hold: nil, doubleTap: nil, chordWith: [], keyboard: nil)
        XCTAssertTrue(detail(explain([], remap: true, rules: [rule]), "remap").contains("1 rule applies here: Caps to Escape"))
        XCTAssertTrue(detail(explain([], app: "com.other", remap: true, rules: [rule]), "remap").contains("no rule"))
        let secure = SecureInputStatus(enabled: true, pid: 1, appName: "Terminal")
        XCTAssertTrue(detail(explain([], secure: secure), "secure").contains("Terminal"))
        XCTAssertTrue(explain([]).first { $0.id == "secure" } == nil)
    }
}

final class InputTesterFormatTests: XCTestCase {
    func testWhatIsShown() {
        XCTAssertEqual(InputTesterFormat.button(2, down: true), "Middle button pressed")
        XCTAssertEqual(InputTesterFormat.button(3, down: false), "Button 4 released")
        XCTAssertEqual(InputTesterFormat.scroll(deltaX: 0, deltaY: 3, smooth: false), "Wheel: up 3.0")
        XCTAssertEqual(InputTesterFormat.scroll(deltaX: -2, deltaY: -1, smooth: true), "Smooth scroll: down 1.0, right 2.0")
        XCTAssertEqual(InputTesterFormat.scroll(deltaX: 0, deltaY: 0, smooth: true), "Smooth scroll: no movement")
        XCTAssertEqual(InputTesterFormat.modifiers([]), "No modifier keys held")
        XCTAssertTrue(InputTesterFormat.modifiers([.command, .shift]).hasPrefix("Held:"))
        XCTAssertTrue(InputTesterFormat.key(0, flags: [.command]).contains("code 0"))
    }
}
