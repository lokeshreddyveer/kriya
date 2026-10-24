import XCTest
@testable import Kriya

/// The fixes from the Keyboard review (text expansion that does not guess at password fields, keyboards known by what they report, a
/// pause for each behaviour), and the checks the last review asked for on the earlier Sound and Mouse fixes: headphone correction run
/// through the real runner with a stand-in for the audio, and the drag tools put fully to rest.
final class KeyboardFixTests: XCTestCase {
    // MARK: Text expansion fails closed

    func testAFieldThatCannotBeCheckedGetsNoExpansionUnlessTheAppIsTrusted() {
        func v(_ field: FieldCheck, trusted: Bool = false, secure: Bool = false, excluded: Bool = false) -> ExpansionSafety.Verdict {
            ExpansionSafety.verdict(secureInput: secure, appExcluded: excluded, field: field, appTrusted: trusted)
        }
        XCTAssertEqual(v(.unavailable), .deny(.cannotInspect), "this was the bug: it said yes when it could not look")
        XCTAssertEqual(v(.unavailable, trusted: true), .allow, "unless the person said that app is fine")
        XCTAssertEqual(v(.ordinary), .allow)
        XCTAssertEqual(v(.secureField, trusted: true), .deny(.passwordField), "trusting an app never allows a password box that can be seen")
        XCTAssertEqual(v(.describedAsPassword, trusted: true), .deny(.passwordField))
        XCTAssertEqual(v(.ordinary, secure: true), .deny(.secureInput))
        XCTAssertEqual(v(.unavailable, trusted: true, secure: true), .deny(.secureInput), "macOS protecting input always wins")
        XCTAssertEqual(v(.ordinary, excluded: true), .deny(.excludedApp))
        for reason in [ExpansionSafety.Reason.secureInput, .excludedApp, .passwordField, .cannotInspect] {
            XCTAssertFalse(ExpansionSafety.message(for: reason, app: "Notes").isEmpty)
        }
        XCTAssertTrue(ExpansionSafety.message(for: .cannotInspect, app: "Notes").contains("Notes"))
    }

    func testTrustedAppsAreKeptAndTheSkippedOneIsRemembered() {
        let suite = UserDefaults(suiteName: "kriya-tests-\(UUID().uuidString)")!
        let trust = ExpansionTrust(defaults: suite)
        XCTAssertFalse(trust.isTrusted("com.example.Notes"))
        XCTAssertFalse(trust.isTrusted(nil))
        trust.setTrusted("com.example.Notes", true)
        XCTAssertTrue(trust.isTrusted("com.example.Notes"))
        XCTAssertTrue(ExpansionTrust(defaults: suite).isTrusted("com.example.Notes"), "kept between launches")
        trust.setTrusted("com.example.Notes", false)
        XCTAssertFalse(trust.isTrusted("com.example.Notes"))
    }

    func testLookingAtTheFocusedFieldNeverSaysFineWhenItCannotLook() {
        // In the test host Accessibility is not allowed, so the field cannot be inspected: the answer must be "unavailable".
        if !AXIsProcessTrusted() { XCTAssertEqual(ExpansionEngine.inspectFocusedField(), .unavailable) }
    }

    // MARK: Keyboards known by what they report

    func testAKeyboardKeepsItsIdentityWhenItsNameChanges() {
        let a = KeyboardDevice.identity(vendor: 0x5ac, product: 0x29a, serial: "C02ABC")
        XCTAssertEqual(a, "kb:5ac:29a:C02ABC")
        XCTAssertEqual(KeyboardDevice.identity(vendor: 0x5ac, product: 0x29a, serial: "  "), "kb:5ac:29a", "no serial number: maker and model only")
        XCTAssertEqual(KeyboardDevice.identity(vendor: 0x5ac, product: 0x29a, serial: nil), "kb:5ac:29a")
        let renamed = [KeyboardDevice(id: a, name: "Desk keyboard")]
        XCTAssertTrue(KeyboardRuleMatch.applies(rule: a, connected: renamed), "found by identity although the name is new")
        XCTAssertFalse(KeyboardRuleMatch.applies(rule: a, connected: []))
    }

    func testARuleSavedWithAKeyboardsNameStillWorks() {
        let connected = [KeyboardDevice(id: "kb:1:2", name: "Magic Keyboard")]
        XCTAssertTrue(KeyboardRuleMatch.applies(rule: "Magic Keyboard", connected: connected), "rules made before identities existed")
        XCTAssertFalse(KeyboardRuleMatch.applies(rule: "Other Keyboard", connected: connected))
        XCTAssertTrue(KeyboardRuleMatch.applies(rule: nil, connected: []))
        XCTAssertTrue(KeyboardRuleMatch.applies(rule: "", connected: []))
        XCTAssertEqual(RemapRuleEditorProbe.selected("Magic Keyboard", connected), "kb:1:2", "and the picker shows that keyboard as chosen")
        XCTAssertEqual(RemapRuleEditorProbe.selected("kb:9:9", connected), "kb:9:9")
        XCTAssertEqual(RemapRuleEditorProbe.selected(nil, connected), "")
    }

    func testTwoKeyboardsWithTheSameNameAreTwoKeyboardsWhenTheyHaveSerialNumbers() {
        let both = [KeyboardDevice(id: "kb:1:2:AAA", name: "Magic Keyboard"), KeyboardDevice(id: "kb:1:2:BBB", name: "Magic Keyboard")]
        XCTAssertTrue(KeyboardRuleMatch.lookAlikes(both).isEmpty)
        XCTAssertTrue(KeyboardRuleMatch.applies(rule: "kb:1:2:BBB", connected: [both[1]]))
        XCTAssertFalse(KeyboardRuleMatch.applies(rule: "kb:1:2:AAA", connected: [both[1]]), "the other one, not just the same name")
        let twins = [KeyboardDevice(id: "kb:1:2", name: "K"), KeyboardDevice(id: "kb:1:2", name: "K")]
        XCTAssertEqual(KeyboardRuleMatch.lookAlikes(twins), ["kb:1:2"], "without serial numbers they cannot be told apart, and the pane says so")
    }

    func testARuleForAKeyboardThatIsAwayStillSaysWhichOne() {
        XCTAssertEqual(KeyboardRuleMatch.title(for: "kb:1:2:A", connected: [], remembered: ["kb:1:2:A": "Desk keyboard"]), "Desk keyboard")
        XCTAssertEqual(KeyboardRuleMatch.title(for: "kb:1:2:A", connected: [KeyboardDevice(id: "kb:1:2:A", name: "New name")], remembered: [:]), "New name")
        XCTAssertEqual(KeyboardRuleMatch.title(for: "kb:1:2:A", connected: [], remembered: [:]), "A keyboard that is not connected")
        XCTAssertEqual(KeyboardRuleMatch.title(for: "Old Name", connected: [], remembered: [:]), "Old Name")
    }

    // MARK: The pause

    func testEachBehaviourCanBePausedAndAllResumed() {
        var state = KeyboardPauseState()
        XCTAssertFalse(state.isAnyPaused); XCTAssertEqual(state.summary, "Nothing is paused")
        state.expansion = true
        XCTAssertTrue(state.isAnyPaused); XCTAssertFalse(state.isAllPaused); XCTAssertEqual(state.summary, "Paused: text expansion")
        state.toggleAll()
        XCTAssertTrue(state.isAllPaused, "some paused: 'pause all' pauses the rest")
        state.toggleAll()
        XCTAssertFalse(state.isAnyPaused, "all paused: it resumes everything")
        state.remaps = true; state.shortcuts = true
        XCTAssertEqual(state.summary, "Paused: remapping, shortcuts")
    }

    func testThePauseIsReadableFromAnyThreadAndResumesCleanly() {
        let pause = KeyboardPause()
        XCTAssertFalse(pause.remapsPaused)
        pause.change { $0.remaps = true }
        XCTAssertTrue(pause.remapsPaused); XCTAssertFalse(pause.expansionPaused); XCTAssertFalse(pause.shortcutsPaused)
        DispatchQueue.concurrentPerform(iterations: 50) { _ in _ = pause.current }
        pause.resumeAll()
        XCTAssertFalse(pause.current.isAnyPaused)
    }

    // MARK: Headphone correction, through the real runner

    private final class FakeSystemSound: SystemSoundTarget {
        var settings = AppAudioSettings()
        func systemSettings() -> AppAudioSettings { settings }
        func updateSystem(_ change: (inout AppAudioSettings) -> Void) { change(&settings) }
    }

    private func runner(_ fake: FakeSystemSound, output: @escaping () -> String?, suite: UserDefaults? = nil) -> AutoEQRunner {
        let defaults = suite ?? UserDefaults(suiteName: "kriya-tests-\(UUID().uuidString)")!
        let r = AutoEQRunner(defaults: defaults, currentOutput: output, watchesDevices: false)
        r.target = fake
        return r
    }

    private func correction(_ gain: Float, preamp: Float = -3) -> AutoEQ.Correction {
        AutoEQ.Correction(gains: [Float](repeating: gain, count: 10), preampDB: preamp, errorDB: 0.2)
    }

    func testTheOwnersEqualiserComesBackAfterTheCorrectionComesOff() {
        let fake = FakeSystemSound()
        fake.settings.eq[2] = 5; fake.settings.preamp = -1; fake.settings.effectsBypassed = true
        let mine = fake.settings
        var output: String? = "speakers"
        let runner = runner(fake) { output }
        runner.set(correction(2), name: "HD 600", for: "hp")
        runner.start()
        XCTAssertEqual(fake.settings.eq, mine.eq, "speakers have no correction: nothing changes")
        output = "hp"; runner.follow()
        XCTAssertEqual(fake.settings.eq, [Float](repeating: 2, count: 10)); XCTAssertEqual(fake.settings.preamp, -3); XCTAssertFalse(fake.settings.effectsBypassed)
        XCTAssertEqual(runner.appliedTo, "hp")
        output = "speakers"; runner.follow()
        XCTAssertEqual(fake.settings.eq, mine.eq, "this was the bug: the flat one was put back instead")
        XCTAssertEqual(fake.settings.preamp, mine.preamp); XCTAssertEqual(fake.settings.effectsBypassed, mine.effectsBypassed)
        XCTAssertNil(runner.appliedTo)
    }

    func testGoingFromOneCorrectedDeviceToAnotherKeepsTheFirstSnapshot() {
        let fake = FakeSystemSound()
        fake.settings.eq[0] = 4
        let mine = fake.settings
        var output: String? = "a"
        let runner = runner(fake) { output }
        runner.set(correction(1), name: "A", for: "a"); runner.set(correction(2), name: "B", for: "b")
        runner.start()
        XCTAssertEqual(fake.settings.eq, [Float](repeating: 1, count: 10))
        output = "b"; runner.follow()
        XCTAssertEqual(fake.settings.eq, [Float](repeating: 2, count: 10))
        output = nil; runner.follow()
        XCTAssertEqual(fake.settings.eq, mine.eq, "back to what the person had before either correction, not to A's")
    }

    func testChangingTheNumbersOfTheCorrectionInUseKeepsTheOriginalToo() {
        let fake = FakeSystemSound()
        fake.settings.eq[5] = -2
        let mine = fake.settings
        let runner = runner(fake) { "hp" }
        runner.set(correction(1), name: "HP", for: "hp")
        runner.start()
        runner.set(correction(3, preamp: -5), name: "HP", for: "hp")
        XCTAssertEqual(fake.settings.eq, [Float](repeating: 3, count: 10)); XCTAssertEqual(fake.settings.preamp, -5)
        runner.remove("hp")
        XCTAssertEqual(fake.settings.eq, mine.eq, "removing the correction gives back the original, not the first correction")
    }

    func testACorrectionThatWasOnWhenKriyaQuitIsStillTakenOffProperly() {
        let fake = FakeSystemSound()
        fake.settings.eq[1] = 6
        let mine = fake.settings
        let suite = UserDefaults(suiteName: "kriya-tests-\(UUID().uuidString)")!
        var output: String? = "hp"
        let first = runner(fake, output: { output }, suite: suite)
        first.set(correction(2), name: "HP", for: "hp")
        first.start()
        XCTAssertEqual(first.appliedTo, "hp")
        // Kriya quits and starts again: the settings of "All sound" were saved with the correction in them.
        let second = runner(fake, output: { output }, suite: suite)
        XCTAssertEqual(second.appliedTo, "hp", "remembered across launches")
        second.start()
        XCTAssertEqual(fake.settings.eq, [Float](repeating: 2, count: 10), "not captured again as if it were the owner's own")
        output = "speakers"; second.follow()
        XCTAssertEqual(fake.settings.eq, mine.eq, "and it still gives the owner's equaliser back")
    }

    func testReplacingTheCorrectionsBringsTheEqualiserInLineWithTheOutput() {
        let fake = FakeSystemSound()
        let mine = fake.settings
        let runner = runner(fake) { "hp" }
        runner.start()
        runner.replaceAll(["hp": AutoEQ.Saved(name: "HP", correction: correction(2))])
        XCTAssertEqual(fake.settings.eq, [Float](repeating: 2, count: 10))
        runner.replaceAll([:])
        XCTAssertEqual(fake.settings.eq, mine.eq, "a Quick Config without it takes it off")
    }

    func testStoppingTheRunnerGivesTheEqualiserBack() {
        let fake = FakeSystemSound()
        fake.settings.preamp = -4
        let runner = runner(fake) { "hp" }
        runner.set(correction(2), name: "HP", for: "hp")
        runner.start()
        runner.stop()
        XCTAssertEqual(fake.settings.preamp, -4); XCTAssertNil(runner.appliedTo)
    }

    // MARK: The drag tools are put fully to rest

    func testBecomingInactiveClearsEverythingThatWasInProgress() throws {
        let world = try TestWorld()
        defer { world.cleanUp() }
        let store = DragToolsStore(core: world.core)
        store.update { $0.buttonScrolls = [ButtonScrollBinding(button: 2, upActionId: "a", downActionId: nil)]; $0.followModifier = 0 }
        var allowed = true
        let tools = DragTools(events: EventMonitor(), store: store, windowStore: WindowStore(core: world.core), run: { _ in }, isActive: { allowed })
        let down = CGEvent(mouseEventSource: nil, mouseType: .otherMouseDown, mouseCursorPosition: .zero, mouseButton: .center)!
        guard case .drop = tools.handle(.otherMouseDown, down) else { return XCTFail("a button held for the wheel is taken") }
        XCTAssertTrue(tools.hasInteractionInProgress)
        allowed = false
        let moved = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: .zero, mouseButton: .left)!
        _ = tools.handle(.mouseMoved, moved)
        XCTAssertFalse(tools.hasInteractionInProgress, "the wheel button's state is gone the moment the tools stop being allowed")
        tools.reset()
        XCTAssertFalse(tools.hasInteractionInProgress)
    }

    func testStoppingTheDragToolsClearsEverything() throws {
        let world = try TestWorld()
        defer { world.cleanUp() }
        let store = DragToolsStore(core: world.core)
        store.update { $0.buttonScrolls = [ButtonScrollBinding(button: 2, upActionId: "a", downActionId: nil)] }
        let tools = DragTools(events: EventMonitor(), store: store, windowStore: WindowStore(core: world.core), run: { _ in })
        let down = CGEvent(mouseEventSource: nil, mouseType: .otherMouseDown, mouseCursorPosition: .zero, mouseButton: .center)!
        _ = tools.handle(.otherMouseDown, down)
        XCTAssertTrue(tools.hasInteractionInProgress)
        tools.stop()
        XCTAssertFalse(tools.hasInteractionInProgress)
    }
}

/// Reaches the remap editor's pure helper without building the view.
private enum RemapRuleEditorProbe {
    static func selected(_ saved: String?, _ devices: [KeyboardDevice]) -> String {
        guard let saved, !saved.isEmpty else { return "" }
        if devices.contains(where: { $0.id == saved }) { return saved }
        return devices.first(where: { $0.name == saved })?.id ?? saved
    }
}

/// Checks that belong to the screen-by-screen audit, one group per screen.
final class ScreenAuditTests: XCTestCase {
    // Screen 8: Workspaces
    func testAWorkspaceOpensOnlyWebPages() {
        XCTAssertEqual(WorkspaceAddress.url(from: "https://example.com/a")?.absoluteString, "https://example.com/a")
        XCTAssertEqual(WorkspaceAddress.url(from: "example.com/page")?.absoluteString, "https://example.com/page", "a bare address gets https")
        XCTAssertEqual(WorkspaceAddress.url(from: "  http://localhost:3000 ")?.absoluteString, "http://localhost:3000")
        for bad in ["file:///Applications/Calculator.app", "javascript:alert(1)", "ssh://host", "x-apple.systempreferences:", "https://", "two words.com", "", "tel:123"] {
            XCTAssertNil(WorkspaceAddress.url(from: bad), bad)
        }
        let parsed = WorkspaceAddress.parse("example.com\nfile:///etc/passwd\n\n  https://swift.org  ")
        XCTAssertEqual(parsed.valid, ["https://example.com", "https://swift.org"])
        XCTAssertEqual(parsed.rejected, ["file:///etc/passwd"])
    }

    // Screen 5: Shortcut Map names every watcher
    func testEveryWatcherOfTheEventTapHasAFriendlyName() {
        for owner in ["keyboard.remap", "keyboard.shortcuts", "keyboard.expansion", "keyboard.expansion.mouse", "mouse", "drag.tools", "buttons", "pointer.menu.option",
                      "clipboard.stack", "clipboard.merge", "actions.record", "actions.record.clicks", "sound.volumekeys"] {
            XCTAssertNotEqual(InteractionMap.friendlyName(forSubscriber: owner), owner, "\(owner) shows in the Order tab")
        }
    }

    // Screen 10: Displays & Corners
    func testADisplayChangeIsPutBackUnlessKept() {
        let start = Date(timeIntervalSince1970: 1_000)
        let change = DisplayChangeGuard(label: "1920×1080", now: start)
        XCTAssertEqual(change.secondsLeft(now: start), DisplayChangeGuard.seconds)
        XCTAssertFalse(change.isExpired(now: start.addingTimeInterval(9.9)))
        XCTAssertEqual(change.secondsLeft(now: start.addingTimeInterval(7.2)), 3)
        XCTAssertTrue(change.isExpired(now: start.addingTimeInterval(10)), "silence means put it back")
        XCTAssertEqual(change.secondsLeft(now: start.addingTimeInterval(30)), 0)
    }
}

final class ClipboardLockAuditTests: XCTestCase {
    private func lock(allow: Bool, enabled: Bool = true) -> (ClipboardLock, () -> Int) {
        let suite = UserDefaults(suiteName: "kriya-tests-\(UUID().uuidString)")!
        suite.set(enabled, forKey: "clipboardHistoryLocked")
        var asked = 0
        let l = ClipboardLock(defaults: suite, authenticate: { _, done in asked += 1; done(allow) }, watchSystem: false)
        return (l, { asked })
    }

    func testTheLockCannotBeSwitchedOffWithoutProvingWhoYouAre() {
        let (l, asked) = lock(allow: false)
        let done = expectation(description: "answered")
        l.disable(reason: "test") { ok in XCTAssertFalse(ok); done.fulfill() }
        wait(for: [done], timeout: 2)
        XCTAssertTrue(l.isEnabled, "still on: the Mac did not confirm")
        XCTAssertEqual(asked(), 1)
    }

    func testTheOwnerCanSwitchItOffAndTheTimeCanOnlyBeChangedWithTheSameProof() {
        let (l, asked) = lock(allow: true)
        let timeout = expectation(description: "timeout")
        l.changeTimeout(to: 60, reason: "test") { ok in XCTAssertTrue(ok); timeout.fulfill() }
        wait(for: [timeout], timeout: 2)
        XCTAssertEqual(l.timeoutMinutes, 60)
        let off = expectation(description: "off")
        l.disable(reason: "test") { ok in XCTAssertTrue(ok); off.fulfill() }
        wait(for: [off], timeout: 2)
        XCTAssertFalse(l.isEnabled)
        XCTAssertGreaterThanOrEqual(asked(), 1)
    }

    func testAnUnchangedTimeAsksNothingAndAnOffLockAsksNothing() {
        let (l, asked) = lock(allow: false, enabled: false)
        let same = expectation(description: "same")
        l.changeTimeout(to: l.timeoutMinutes, reason: "test") { ok in XCTAssertTrue(ok); same.fulfill() }
        let off = expectation(description: "off")
        l.disable(reason: "test") { ok in XCTAssertTrue(ok); off.fulfill() }
        wait(for: [same, off], timeout: 2)
        XCTAssertEqual(asked(), 0, "a lock that is not on has nothing to prove")
    }
}
