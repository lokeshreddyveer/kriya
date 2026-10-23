import XCTest
@testable import Kriya

final class DuplicateFinderTests: XCTestCase {
    private func f(_ p: String, _ size: Int64) -> FoundFile { FoundFile(path: p, size: size, modified: nil) }

    func testOnlySameSizedFilesCanBeCopies() {
        let files = [f("/a/x", 5_000_000), f("/b/x", 5_000_000), f("/c/y", 6_000_000), f("/d/tiny", 100), f("/e/tiny", 100)]
        let groups = DuplicateFinder.sizeGroups(files)
        XCTAssertEqual(groups.count, 1, "the tiny ones are too small to matter and y has no partner")
        XCTAssertEqual(groups[0].map(\.path), ["/a/x", "/b/x"])
    }

    func testIdenticalContentSplitsOutOfASizeGroup() {
        let group = [f("/1", 9), f("/2", 9), f("/3", 9)]
        let sets = DuplicateFinder.duplicates(in: group) { $0.path == "/3" ? "other" : "same" }
        XCTAssertEqual(sets.count, 1)
        XCTAssertEqual(sets[0].map(\.path), ["/1", "/2"])
        XCTAssertEqual(DuplicateFinder.reclaimable(sets), 9)
    }

    func testLargestRespectsTheMinimumAndTheCount() {
        let mb: Int64 = 1_048_576
        let files = [f("/a", 10 * mb), f("/b", 300 * mb), f("/c", 200 * mb), f("/d", 60 * mb)]
        XCTAssertEqual(DuplicateFinder.largest(files, count: 2).map(\.path), ["/b", "/c"])
        XCTAssertEqual(DuplicateFinder.largest(files, count: 9).count, 3)
    }

    func testFingerprintMatchesForEqualFilesOnly() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kriya-dup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a"), b = dir.appendingPathComponent("b"), c = dir.appendingPathComponent("c")
        try Data(repeating: 7, count: 5000).write(to: a); try Data(repeating: 7, count: 5000).write(to: b); try Data(repeating: 8, count: 5000).write(to: c)
        XCTAssertEqual(FileCleanupScanner.fingerprint(of: a.path), FileCleanupScanner.fingerprint(of: b.path))
        XCTAssertNotEqual(FileCleanupScanner.fingerprint(of: a.path), FileCleanupScanner.fingerprint(of: c.path))
        XCTAssertNil(FileCleanupScanner.fingerprint(of: dir.appendingPathComponent("missing").path))
    }
}
