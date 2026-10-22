import XCTest
@testable import Kriya

final class InteractionMapTests: XCTestCase {
    private func preset(_ id: String, rules: [ButtonRule], gestureButton: UInt32? = nil) -> MousePreset {
        var settings = defaultMouseSettings()
        settings.buttons = rules
        settings.gestures.enabled = gestureButton != nil
        if let gestureButton { settings.gestures.activationButton = gestureButton }
        return MousePreset(id: id, name: id.capitalized, isBuiltin: false, settings: settings)
    }

    private func remap(_ name: String, key: UInt16, mods: UInt64, apps: [String] = [], enabled: Bool = true) -> RemapRule {
        RemapRule(id: name, name: name, enabled: enabled, keyCode: key, modifiers: mods, appIds: apps, tap: nil, hold: nil, doubleTap: nil, chordWith: [], keyboard: nil)
    }

    private func hotkey(_ owner: String, _ title: String, key: UInt16, mods: UInt64, apps: [String] = []) -> ShortcutEntry {
        ShortcutEntry(owner: owner, command: title, title: title, keyCode: key, modifiers: mods, apps: apps)
    }

    func testAGestureOnAButtonThatHasARuleIsFlagged() {
        var input = InteractionMap.Inputs()
        input.presets = [preset("default", rules: [ButtonRule(button: 2, modifiers: 0, actionId: "a1", trigger: .click)], gestureButton: 2)]
        input.name = { $0 == "a1" ? "Mission Control" : $0 }
        let entries = InteractionMap.entries(input)
        XCTAssertEqual(entries.map(\.kind).sorted { $0.rawValue < $1.rawValue }, [.gesture, .mouseButton])
        XCTAssertEqual(entries.first { $0.kind == .mouseButton }?.title, "Mission Control")
        let clashes = InteractionMap.clashes(entries)
        XCTAssertEqual(clashes.count, 1)
        XCTAssertTrue(InteractionMap.explanation(for: clashes[0]).contains("gesture"))
    }

    func testAPresetForOneAppReplacesTheDefaultAndIsNotAClash() {
        var input = InteractionMap.Inputs()
        let rule = ButtonRule(button: 3, modifiers: 0, actionId: "a", trigger: .click)
        input.presets = [preset("default", rules: [rule]), preset("games", rules: [rule])]
        input.assignments = [MouseAssignment(id: "x", deviceId: nil, appId: "com.game", presetId: "games")]
        let entries = InteractionMap.entries(input)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.first { $0.owner.contains("Games") }?.apps, ["com.game"])
        XCTAssertTrue(InteractionMap.clashes(entries).isEmpty)
    }

    func testARemappedKeyAndAShortcutOnTheSameKeysClash() {
        var input = InteractionMap.Inputs()
        input.hotkeys = [hotkey("Windows", "Left half", key: 123, mods: KeyModifiers.control | KeyModifiers.option)]
        input.remapEnabled = true
        input.remaps = [remap("Arrow trick", key: 123, mods: KeyModifiers.control | KeyModifiers.option)]
        let clashes = InteractionMap.clashes(InteractionMap.entries(input))
        XCTAssertEqual(clashes.count, 1)
        XCTAssertEqual(Set(clashes[0].map(\.kind)), [.hotkey, .remap])
        XCTAssertTrue(InteractionMap.explanation(for: clashes[0]).contains("remapping"))
    }

    func testRemapsThatAreOffOrInAnotherAppDoNotClash() {
        var input = InteractionMap.Inputs()
        input.hotkeys = [hotkey("Windows", "Left half", key: 123, mods: 6, apps: ["com.a"])]
        input.remaps = [remap("Elsewhere", key: 123, mods: 6, apps: ["com.b"])]
        input.remapEnabled = true
        XCTAssertTrue(InteractionMap.clashes(InteractionMap.entries(input)).isEmpty, "different apps")
        input.remaps = [remap("Everywhere", key: 123, mods: 6)]
        input.remapEnabled = false
        XCTAssertEqual(InteractionMap.entries(input).count, 1, "remapping is off, so its rules do nothing")
        input.remapEnabled = true
        input.remaps = [remap("Off", key: 123, mods: 6, enabled: false)]
        XCTAssertEqual(InteractionMap.entries(input).count, 1, "a rule that is off does nothing")
    }

    func testShortcutsAgainstEachOtherAreLeftToTheShortcutList() {
        var input = InteractionMap.Inputs()
        input.hotkeys = [hotkey("Windows", "A", key: 1, mods: 6), hotkey("Clipboard", "B", key: 1, mods: 6)]
        XCTAssertTrue(InteractionMap.clashes(InteractionMap.entries(input)).isEmpty)
    }

    func testTwoRulesOfTheSameKindFromTheSamePartAreNotSetAgainstEachOther() {
        var input = InteractionMap.Inputs()
        input.remapEnabled = true
        input.remaps = [remap("One", key: 5, mods: 0), remap("Two", key: 5, mods: 0)]
        XCTAssertTrue(InteractionMap.clashes(InteractionMap.entries(input)).isEmpty)
    }

    func testWindowButtonBindingsAreListedWithTheirModifiers() {
        var traffic = defaultTrafficConfig()
        traffic.bindings = [TrafficBinding(button: .close, modifiers: KeyModifiers.option, action: .quitApp)]
        var input = InteractionMap.Inputs()
        input.traffic = traffic
        let entry = InteractionMap.entries(input).first
        XCTAssertEqual(entry?.kind, .trafficLight)
        XCTAssertTrue(entry?.trigger.contains("close") == true)
        XCTAssertEqual(entry?.pane, .buttons)
        XCTAssertTrue(entry?.trigger.hasPrefix(KeyModifiers.glyphs(for: KeyModifiers.option)) == true)
    }

    func testWords() {
        XCTAssertEqual(InteractionMap.words("topLeft"), "top left")
        XCTAssertEqual(InteractionMap.words("bottomRight"), "bottom right")
        XCTAssertEqual(InteractionMap.words("pinchIn"), "pinch in")
        XCTAssertEqual(InteractionMap.words("top"), "top")
    }

    func testEverySubscriberHasAReadableName() {
        for owner in ["keyboard.remap", "keyboard.shortcuts", "mouse", "drag.tools", "buttons", "pointer.menu.option", "clipboard.stack"] {
            XCTAssertNotEqual(InteractionMap.friendlyName(forSubscriber: owner), owner)
        }
        XCTAssertEqual(InteractionMap.friendlyName(forSubscriber: "something.new"), "something.new", "an unknown one is shown as it is")
    }
}
