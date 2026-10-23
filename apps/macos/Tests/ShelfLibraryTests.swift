import XCTest
@testable import Kriya

final class ShelfLibraryTests: XCTestCase {
    private let day: TimeInterval = 86_400
    private func file(_ path: String, at date: Date = Date()) -> ShelfRecord { ShelfRecord(kind: .file, value: path, added: date) }

    func testTheSameFileOrTextIsHeldOnce() {
        var library = ShelfLibrary()
        XCTAssertTrue(library.add(file("/a/b.pdf")))
        XCTAssertFalse(library.add(file("/a/b.pdf")))
        XCTAssertTrue(library.add(ShelfRecord(kind: .text, value: "hello", added: Date())))
        XCTAssertFalse(library.add(ShelfRecord(kind: .text, value: "hello", added: Date())))
        XCTAssertTrue(library.add(ShelfRecord(kind: .image, value: "1.png", added: Date())))
        XCTAssertTrue(library.add(ShelfRecord(kind: .image, value: "2.png", added: Date())))
        XCTAssertEqual(library.current.items.count, 4)
    }

    func testShelvesAreNamedUniquelyAndTheLastCannotGo() {
        var library = ShelfLibrary()
        let work = library.addShelf(named: "Work")
        XCTAssertEqual(library.currentID, work?.id)
        XCTAssertEqual(library.addShelf(named: "work")?.name, "work 2")
        XCTAssertNil(library.addShelf(named: "  "))
        library.deleteShelf(library.shelves[2].id)
        library.deleteShelf(library.shelves[1].id)
        XCTAssertEqual(library.shelves.count, 1)
        library.deleteShelf(library.shelves[0].id)
        XCTAssertEqual(library.shelves.count, 1, "the last shelf stays")
        XCTAssertEqual(library.currentID, library.shelves[0].id)
    }

    func testRemovedItemsGoToTheHistoryAndCanComeBack() {
        var library = ShelfLibrary()
        let record = file("/x/report.pdf")
        library.add(record)
        library.remove(record.id)
        XCTAssertTrue(library.current.items.isEmpty)
        XCTAssertEqual(library.history.map(\.id), [record.id])
        XCTAssertTrue(library.restore(record.id))
        XCTAssertEqual(library.current.items.count, 1)
        XCTAssertTrue(library.history.isEmpty)
    }

    func testDeletingAShelfKeepsItsItemsInTheHistory() {
        var library = ShelfLibrary()
        let first = library.shelves[0].id
        library.addShelf(named: "Temp")
        library.add(file("/t/one"))
        library.deleteShelf(library.currentID)
        XCTAssertEqual(library.currentID, first)
        XCTAssertEqual(library.history.count, 1)
    }

    func testItemsExpireIntoTheHistoryAndOldHistoryGoes() {
        let now = Date()
        var library = ShelfLibrary()
        library.expiryDays = 7
        library.add(file("/old", at: now.addingTimeInterval(-10 * day)))
        library.add(file("/new", at: now.addingTimeInterval(-1 * day)))
        library.add(ShelfRecord(kind: .image, value: "old.png", added: now.addingTimeInterval(-9 * day)))
        library.expire(now: now)
        XCTAssertEqual(library.current.items.map(\.value), ["/new"])
        XCTAssertEqual(Set(library.history.map(\.value)), ["/old", "old.png"])
        // Long after, the history lets go too, and says which picture files are free to delete.
        let freed = library.expire(now: now.addingTimeInterval(60 * day))
        XCTAssertEqual(library.history.map(\.value), ["/new"], "the old ones are forgotten; /new has only just expired itself")
        XCTAssertEqual(freed, ["old.png"])
    }

    func testNothingExpiresWhenNoExpiryIsSet() {
        var library = ShelfLibrary()
        library.add(file("/ancient", at: Date().addingTimeInterval(-400 * day)))
        library.expire()
        XCTAssertEqual(library.current.items.count, 1)
    }

    func testSearchFindsItemsOnEveryShelfAndInTheHistory() {
        var library = ShelfLibrary()
        library.add(file("/docs/Tax Return 2025.pdf"))
        library.addShelf(named: "Ideas")
        library.add(ShelfRecord(kind: .text, value: "tax idea: file early", added: Date()))
        let gone = file("/old/tax-2019.pdf")
        library.add(gone)
        library.remove(gone.id)
        let hits = library.search("tax")
        XCTAssertEqual(hits.count, 3)
        XCTAssertEqual(hits.map(\.shelf), ["Shelf", "Ideas", nil])
        XCTAssertEqual(library.search("tax early").count, 1)
        XCTAssertTrue(library.search("  ").isEmpty)
    }

    func testTheLibrarySurvivesBeingSavedAndRead() throws {
        var library = ShelfLibrary()
        library.expiryDays = 3
        library.add(file("/a"))
        library.addShelf(named: "Two")
        let decoded = try JSONDecoder().decode(ShelfLibrary.self, from: JSONEncoder().encode(library))
        XCTAssertEqual(decoded, library)
    }

    func testTheStorePersistsAndFreesPictures() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kriya-shelf-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ShelfLibraryStore(folder: folder)
        let image = NSImage(size: NSSize(width: 4, height: 4), flipped: false) { rect in NSColor.red.setFill(); rect.fill(); return true }
        let name = try XCTUnwrap(store.storeImage(image))
        store.change { $0.add(ShelfRecord(kind: .image, value: name, added: Date())) }
        XCTAssertNotNil(ShelfLibraryStore(folder: folder).image(named: name), "it is still there after a restart")
        let id = try XCTUnwrap(store.library.current.items.first?.id)
        store.change { $0.remove(id) }
        XCTAssertNotNil(store.image(named: name), "the history still holds it")
        store.change { $0.clearHistory() }
        XCTAssertNil(store.image(named: name), "the file is deleted once nothing holds it")
    }
}
