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

final class PasteIntoFolderTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_760_000_000)

    func testTextBecomesTxtOrMarkdownAndPicturesPng() {
        XCTAssertTrue(PasteIntoFolder.name(for: .text("hello"), at: date, exists: { _ in false })!.hasSuffix(".txt"))
        XCTAssertTrue(PasteIntoFolder.name(for: .text("# Title\nbody"), at: date, exists: { _ in false })!.hasSuffix(".md"))
        XCTAssertTrue(PasteIntoFolder.name(for: .imagePNG(Data([1])), at: date, exists: { _ in false })!.hasSuffix(".png"))
        XCTAssertNil(PasteIntoFolder.name(for: .nothing, at: date, exists: { _ in false }))
        XCTAssertNil(PasteIntoFolder.name(for: .files([]), at: date, exists: { _ in false }))
    }

    func testNothingIsOverwritten() {
        let first = PasteIntoFolder.name(for: .text("a"), at: date, exists: { _ in false })!
        let second = PasteIntoFolder.name(for: .text("a"), at: date, exists: { $0 == first })!
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(second.hasSuffix(" 2.txt"))
        XCTAssertEqual(PasteIntoFolder.uniqueName("a.pdf", exists: { $0 == "a.pdf" || $0 == "a 2.pdf" }), "a 3.pdf")
        XCTAssertEqual(PasteIntoFolder.uniqueName("notes", exists: { $0 == "notes" }), "notes 2")
        XCTAssertEqual(PasteIntoFolder.uniqueName("fresh.txt", exists: { _ in false }), "fresh.txt")
    }

    func testOnlyOrdinaryFoldersInHomeAreWrittenTo() {
        XCTAssertTrue(PasteIntoFolder.isAllowedFolder("/Users/me/Documents", home: "/Users/me"))
        XCTAssertTrue(PasteIntoFolder.isAllowedFolder("/Users/me", home: "/Users/me"))
        XCTAssertFalse(PasteIntoFolder.isAllowedFolder("/System/Library", home: "/Users/me"))
        XCTAssertFalse(PasteIntoFolder.isAllowedFolder("/Users/me/.ssh", home: "/Users/me"))
        XCTAssertFalse(PasteIntoFolder.isAllowedFolder("/Users/me/Library/Preferences", home: "/Users/me"))
        XCTAssertFalse(PasteIntoFolder.isAllowedFolder("/Users/mefoo", home: "/Users/me"))
        XCTAssertFalse(PasteIntoFolder.isAllowedFolder("/Users/me/../other", home: "/Users/me"))
    }
}
