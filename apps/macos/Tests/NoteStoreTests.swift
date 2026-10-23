import XCTest
@testable import Kriya

final class NoteStoreTests: XCTestCase {
    private var folder: URL!

    override func setUp() {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("kriya-notes-\(UUID().uuidString)")
    }
    override func tearDown() { try? FileManager.default.removeItem(at: folder) }

    func testTitleSkipsHeadingMarks() {
        XCTAssertEqual(NoteStore.title(of: "\n# Shopping list\n- milk"), "Shopping list")
        XCTAssertEqual(NoteStore.title(of: "   \n"), "Untitled")
    }

    func testFileNameHasNoUnsafeCharacters() {
        let name = NoteStore.fileName(for: "a/b: c?", date: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(name.hasSuffix(".md"))
        XCTAssertFalse(name.contains("/") || name.contains(":") || name.contains("?"))
    }

    func testCreateListSearchAppendAndTrash() throws {
        let store = NoteStore(folder: folder)
        let a = try XCTUnwrap(store.create("# Milk run\neggs and bread"))
        let again = try XCTUnwrap(store.create("# Milk run\neggs and bread"))
        XCTAssertNotEqual(a, again, "two notes at the same minute with one title must not overwrite each other")
        _ = store.create("Gym plan")
        XCTAssertEqual(store.list().count, 3)
        XCTAssertEqual(store.search("bread milk").count, 2)
        XCTAssertEqual(store.search("gym").first?.title, "Gym plan")
        XCTAssertTrue(store.append("more", to: a))
        XCTAssertTrue(store.read(a).hasSuffix("\n\nmore"))
        store.trash(a)
        XCTAssertEqual(store.list().count, 2)
    }
}
