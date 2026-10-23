import XCTest
@testable import Kriya

final class ConflictFixTests: XCTestCase {
    private func entry(_ kind: InteractionEntry.Kind, _ owner: String, _ title: String) -> InteractionEntry {
        InteractionEntry(kind: kind, owner: owner, title: title, trigger: "⌘K", key: "k:40:8", pane: .keyboard)
    }

    func testRemapsAndAutomationCanBeSwitchedOffHereAndTheRestAreChangedInTheirPane() {
        let group = [entry(.hotkey, "Windows", "Left half"), entry(.remap, "Key remapping", "Caps"), entry(.automation, "Automation", "Tidy")]
        let options = ConflictFix.options(for: group)
        XCTAssertEqual(options.filter { $0.action == .turnOff }.map(\.entry.title), ["Caps", "Tidy"])
        XCTAssertEqual(options.filter { $0.action == .change }.count, 3)
        XCTAssertFalse(ConflictFix.canTurnOff(group[0]))
    }

    func testTheSuggestedKeeperIsTheShortcutOrTheButtonRule() {
        let hotkey = entry(.hotkey, "Windows", "Left half"), remap = entry(.remap, "Key remapping", "Caps")
        XCTAssertEqual(ConflictFix.suggestedKeeper(in: [remap, hotkey]), hotkey)
        let button = entry(.mouseButton, "Mouse (Default)", "Back"), gesture = entry(.gesture, "Mouse (Default)", "Swipes")
        XCTAssertEqual(ConflictFix.suggestedKeeper(in: [gesture, button]), button)
        XCTAssertNil(ConflictFix.suggestedKeeper(in: [entry(.midi, "MIDI", "a"), entry(.midi, "MIDI", "b")]))
    }

    func testTurningOffSparesTheKeeperAndWhatCannotBeSwitchedOffHere() {
        let hotkey = entry(.hotkey, "Windows", "Left half"), remap = entry(.remap, "Key remapping", "Caps"), flow = entry(.automation, "Automation", "Tidy")
        XCTAssertEqual(ConflictFix.turnOffAllExcept(flow, in: [hotkey, remap, flow]).map(\.title), ["Caps"])
    }

    func testFreeShortcutsSkipWhatIsInUse() {
        let q = KeyNames.keyCode(forName: "Q")!
        let base = KeyModifiers.control | KeyModifiers.option | KeyModifiers.command
        let free = ConflictFix.freeShortcuts(usedKeys: [InteractionMap.keyboard(q, base)], limit: 3)
        XCTAssertEqual(free.count, 3)
        XCTAssertFalse(free.contains { $0.keyCode == q && $0.modifiers == base })
        XCTAssertTrue(free.allSatisfy { $0.modifiers & base == base })
    }
}
