import XCTest
@testable import Kriya

final class DiskAnalysisTests: XCTestCase {
    private let home = "/Users/me"
    private func level(_ path: String) -> DiskRisk.Level { DiskRisk.classify(path, home: home).level }
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func file(_ path: String, _ allocated: Int64, logical: Int64? = nil, days: Double = 0) -> DiskFile {
        DiskFile(path: path, allocated: allocated, logical: logical ?? allocated, modified: now.addingTimeInterval(-days * 86_400))
    }

    // MARK: Risk wording and matching

    func testNothingIsCalledSafe() {
        XCTAssertEqual(DiskRisk.Level.safe.title, "Likely rebuildable")
        XCTAssertFalse(DiskRisk.Level.allCases_titles.contains { $0.localizedCaseInsensitiveContains("safe") })
    }

    func testMarkersMatchWholePathPiecesOnly() {
        XCTAssertEqual(level("/Users/me/Library/Caches/x"), .safe)
        XCTAssertNotEqual(level("/Users/me/Library/CachesBackup/x"), .safe, "a longer name is not the cache folder")
        XCTAssertNotEqual(level("/Users/me/Documents/my.cache-notes"), .safe)
        XCTAssertNotEqual(level("/Users/me/code/node_modules_old"), .safe)
        XCTAssertEqual(level("/Users/me/code/app/node_modules"), .safe)
        XCTAssertEqual(level("/Users/me/Documents2/taxes.pdf"), .review, "Documents2 is not Documents")
        XCTAssertEqual(level("/Users/me/Documents/taxes.pdf"), .keep)
        XCTAssertEqual(level("/Users/me2/Documents/x"), .review, "someone else's folder is not this person's")
        XCTAssertEqual(level("/Systemx/thing"), .review)
        XCTAssertEqual(level("/System/Library"), .keep)
    }

    func testPersonalFoldersAreNeverCalledRebuildableByACacheName() {
        XCTAssertEqual(level("/Users/me/Documents/photos/.cache"), .keep, "user data is never auto-classified as rebuildable")
        XCTAssertEqual(level("/Users/me/Desktop/Library/Caches"), .keep)
        XCTAssertEqual(level("/Users/me/Documents/app/node_modules"), .safe, "a project's own dependencies still are")
    }

    func testIsInsideUsesWholePieces() {
        XCTAssertTrue(DiskRisk.isInside("/a/b/c", "/a/b"))
        XCTAssertTrue(DiskRisk.isInside("/a/b", "/a/b"))
        XCTAssertFalse(DiskRisk.isInside("/a/bc", "/a/b"))
        XCTAssertFalse(DiskRisk.isInside("/a", "/a/b"))
    }

    func testSymlinkThatLeavesTheFolderIsAnEscape() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("kriya-escape-\(UUID().uuidString)")
        let outside = fm.temporaryDirectory.appendingPathComponent("kriya-outside-\(UUID().uuidString)")
        try fm.createDirectory(at: root.appendingPathComponent("real"), withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root); try? fm.removeItem(at: outside) }
        try fm.createSymbolicLink(at: root.appendingPathComponent("away"), withDestinationURL: outside)
        try fm.createSymbolicLink(at: root.appendingPathComponent("near"), withDestinationURL: root.appendingPathComponent("real"))
        XCTAssertTrue(DiskPaths.escapes(root.appendingPathComponent("away"), root: root))
        XCTAssertFalse(DiskPaths.escapes(root.appendingPathComponent("near"), root: root))
        XCTAssertFalse(DiskPaths.escapes(root.appendingPathComponent("real"), root: root))
    }

    // MARK: Filter, sort, export

    func testFilterBySearchKindSizeAndAge() {
        let files = [file("/a/report.pdf", 5_000_000, days: 400), file("/a/clip.mov", 900_000_000, days: 2), file("/b/old.pdf", 20_000_000, days: 800)]
        XCTAssertEqual(DiskFilter.apply(files, query: "report", now: now).map(\.name), ["report.pdf"])
        XCTAssertEqual(DiskFilter.apply(files, ext: ".PDF", now: now).count, 2)
        XCTAssertEqual(DiskFilter.apply(files, minBytes: 10_000_000, now: now).count, 2)
        XCTAssertEqual(DiskFilter.apply(files, olderThanDays: 365, now: now).map(\.name).sorted(), ["old.pdf", "report.pdf"])
        XCTAssertEqual(DiskFilter.apply(files, query: "/b/", now: now).map(\.name), ["old.pdf"], "search also matches the folder")
    }

    func testFilesWithoutADateAreNotCalledOld() {
        let undated = DiskFile(path: "/a/x", allocated: 1, logical: 1, modified: nil)
        XCTAssertTrue(DiskFilter.apply([undated], olderThanDays: 30, now: now).isEmpty)
    }

    func testSorting() {
        let files = [file("/a/b.txt", 10, logical: 99), file("/a/a.txt", 50, logical: 5), file("/a/c.mov", 30, logical: 30, days: 9)]
        XCTAssertEqual(DiskFilter.sorted(files, by: .size).map(\.name), ["a.txt", "c.mov", "b.txt"])
        XCTAssertEqual(DiskFilter.sorted(files, by: .logical).map(\.name), ["b.txt", "c.mov", "a.txt"])
        XCTAssertEqual(DiskFilter.sorted(files, by: .name).map(\.name), ["a.txt", "b.txt", "c.mov"])
        XCTAssertEqual(DiskFilter.sorted(files, by: .name, ascending: true).map(\.name), ["c.mov", "b.txt", "a.txt"])
        XCTAssertEqual(DiskFilter.sorted(files, by: .modified).last?.name, "c.mov")
    }

    func testCSVQuotesAndCarriesBothSizesAndRisk() {
        let csv = DiskExport.csv([DiskFile(path: "/Users/me/Library/Caches/a \"b\".bin", allocated: 100, logical: 250, modified: nil)], home: home)
        let lines = csv.split(separator: "\n")
        XCTAssertEqual(lines[0], "name,path,disk_usage_bytes,length_bytes,modified,kind,risk")
        XCTAssertTrue(lines[1].contains("\"a \"\"b\"\".bin\""))
        XCTAssertTrue(lines[1].contains(",100,250,"))
        XCTAssertTrue(lines[1].hasSuffix("\"Likely rebuildable\""))
    }

    func testJSONRoundTrips() throws {
        let data = try XCTUnwrap(DiskExport.json([file("/a/b", 5, logical: 9)]))
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode([DiskFile].self, from: data).first?.logical, 9)
    }

    // MARK: Volume, snapshots, freshness

    func testPurgeableIsTheGapBetweenFreeAndFreeIfGivenBack() {
        let r = VolumeReport(name: "Mac", total: 1000, available: 200, availableForImportant: 350)
        XCTAssertEqual(r.used, 800)
        XCTAssertEqual(r.purgeable, 150)
        XCTAssertEqual(r.unaccounted(measured: 500), 300)
        XCTAssertEqual(VolumeReport(name: "x", total: 10, available: 5, availableForImportant: 4).purgeable, 0, "never negative")
    }

    func testSnapshotListParsingAndDates() {
        let out = "Snapshots for disk /:\ncom.apple.TimeMachine.2026-10-20-101500.local\ncom.apple.TimeMachine.2026-10-21-081500.local\n"
        let names = SnapshotList.parse(out)
        XCTAssertEqual(names.count, 2)
        XCTAssertNotNil(SnapshotList.date(of: names[0]))
        XCTAssertNil(SnapshotList.date(of: "junk"))
        XCTAssertTrue(SnapshotList.parse("").isEmpty)
    }

    func testStaleAfterTenMinutes() {
        XCTAssertFalse(ScanFreshness.isStale(scannedAt: now.addingTimeInterval(-599), now: now))
        XCTAssertTrue(ScanFreshness.isStale(scannedAt: now.addingTimeInterval(-601), now: now))
        XCTAssertFalse(ScanFreshness.isStale(scannedAt: nil, now: now))
    }

    func testAgeBands() {
        XCTAssertEqual(DiskPaths.Age.of(now.addingTimeInterval(-86_400), now: now), .week)
        XCTAssertEqual(DiskPaths.Age.of(now.addingTimeInterval(-20 * 86_400), now: now), .month)
        XCTAssertEqual(DiskPaths.Age.of(now.addingTimeInterval(-200 * 86_400), now: now), .year)
        XCTAssertEqual(DiskPaths.Age.of(now.addingTimeInterval(-900 * 86_400), now: now), .older)
        XCTAssertEqual(DiskPaths.Age.of(nil, now: now), .older)
    }

    // MARK: Duplicates and history

    func testDuplicatesNeedSameSizeThenSameContent() {
        let a = file("/a/one.bin", 4_000_000), b = file("/a/two.bin", 4_000_000), c = file("/a/three.bin", 4_000_000), tiny = file("/a/t1", 10), tiny2 = file("/a/t2", 10)
        let groups = DiskDuplicates.sizeGroups([a, b, c, tiny, tiny2])
        XCTAssertEqual(groups.count, 1, "small files are ignored")
        let confirmed = DiskDuplicates.confirm(groups) { $0.name == "three.bin" ? "other" : "same" }
        XCTAssertEqual(confirmed.count, 1)
        XCTAssertEqual(confirmed[0].map(\.name), ["one.bin", "two.bin"])
        XCTAssertEqual(DiskDuplicates.reclaimable(confirmed), 4_000_000)
        XCTAssertTrue(DiskDuplicates.confirm(groups) { _ in nil }.isEmpty, "unreadable files are never called copies")
    }

    func testSha256MatchesForEqualContentOnly() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kriya-hash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for (name, text) in [("a", "hello"), ("b", "hello"), ("c", "world")] { try Data(text.utf8).write(to: dir.appendingPathComponent(name)) }
        let a = DiskTools.sha256(of: dir.appendingPathComponent("a").path), b = DiskTools.sha256(of: dir.appendingPathComponent("b").path), c = DiskTools.sha256(of: dir.appendingPathComponent("c").path)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
        XCTAssertEqual(a, "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
        XCTAssertNil(DiskTools.sha256(of: dir.appendingPathComponent("missing").path))
    }

    func testChangesSinceAnEarlierReading() {
        let old = ScanRecord(date: now, path: "/p", total: 0, items: [.init(name: "A", size: 500_000_000), .init(name: "B", size: 2_000_000), .init(name: "Gone", size: 300_000_000)])
        let new = ScanRecord(date: now, path: "/p", total: 0, items: [.init(name: "A", size: 900_000_000), .init(name: "B", size: 2_100_000), .init(name: "New", size: 50_000_000)])
        let changes = new.changes(since: old)
        XCTAssertEqual(changes.map(\.name), ["A", "Gone", "New"], "B moved by under 1 MB and is left out; biggest change first")
        XCTAssertEqual(changes[0].delta, 400_000_000)
        XCTAssertEqual(changes[1].delta, -300_000_000)
    }

    func testDeveloperPlacesAreUniqueAndUnderHome() {
        let paths = DeveloperPlaces.list.map(\.path)
        XCTAssertEqual(Set(paths).count, paths.count)
        XCTAssertTrue(paths.allSatisfy { !$0.hasPrefix("/") && !$0.contains("..") })
    }

    // MARK: Sunburst

    func testSunburstArcsFillTheCircleInProportion() {
        let arcs = Sunburst.arcs([("a", 300), ("b", 100), ("zero", 0)])
        XCTAssertEqual(arcs.map(\.id), ["a", "b"])
        XCTAssertEqual(arcs[0].end - arcs[0].start, 1.5 * .pi, accuracy: 1e-9)
        XCTAssertEqual(arcs[1].end, 2 * .pi, accuracy: 1e-9)
        XCTAssertTrue(Sunburst.arcs([("big", 1_000_000), ("sliver", 1)]).map(\.id) == ["big"], "slivers too thin to see are not drawn")
    }

    func testSunburstHitTest() {
        let arcs = Sunburst.arcs([("left", 50), ("right", 50)]) // right is the clockwise half from the top: 0..pi
        let c = CGPoint(x: 100, y: 100)
        XCTAssertEqual(Sunburst.hit(CGPoint(x: 150, y: 100), center: c, inner: 20, outer: 90, in: arcs)?.id, arcs[0].id, "east lies in the first half")
        XCTAssertEqual(Sunburst.hit(CGPoint(x: 50, y: 100), center: c, inner: 20, outer: 90, in: arcs)?.id, arcs[1].id)
        XCTAssertNil(Sunburst.hit(CGPoint(x: 105, y: 100), center: c, inner: 20, outer: 90, in: arcs), "inside the hole")
        XCTAssertNil(Sunburst.hit(CGPoint(x: 100, y: 0), center: c, inner: 20, outer: 90, in: arcs), "outside the ring")
    }
}

private extension DiskRisk.Level {
    static var allCases_titles: [String] { [DiskRisk.Level.safe, .review, .keep].map(\.title) }
}
