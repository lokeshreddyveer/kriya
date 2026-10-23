import XCTest
@testable import Kriya

final class SemanticSearchTests: XCTestCase {
    func testTextIsCutIntoOverlappingPiecesOfAboutTheRightSize() {
        XCTAssertEqual(TextChunker.chunks("   "), [])
        XCTAssertEqual(TextChunker.chunks("short note"), ["short note"])
        let paragraph = String(repeating: "word ", count: 120)
        let text = (0..<8).map { _ in paragraph }.joined(separator: "\n\n")
        let pieces = TextChunker.chunks(text, maxCharacters: 800, overlap: 40)
        XCTAssertGreaterThan(pieces.count, 4)
        XCTAssertTrue(pieces.allSatisfy { $0.count <= 800 + 41 })
        XCTAssertLessThanOrEqual(TextChunker.chunks(String(repeating: "a ", count: 100_000), maxChunks: 7).count, 7)
        let oneHugeWord = TextChunker.chunks(String(repeating: "x", count: 5000), maxCharacters: 800, overlap: 0)
        XCTAssertTrue(oneHugeWord.allSatisfy { $0.count <= 800 }, "text with no breaks is still cut")
    }

    func testSimilarityAndVectorStorage() {
        XCTAssertEqual(VectorMath.cosine([1, 0], [1, 0]), 1, accuracy: 0.0001)
        XCTAssertEqual(VectorMath.cosine([1, 0], [0, 1]), 0, accuracy: 0.0001)
        XCTAssertEqual(VectorMath.cosine([1, 0], [1, 0, 0]), 0, "different sizes are never alike")
        XCTAssertEqual(VectorMath.cosine([0, 0], [1, 1]), 0)
        let v: [Float] = [0.25, -1.5, 3]
        XCTAssertEqual(VectorMath.decode(VectorMath.encode(v)), v)
        XCTAssertEqual(VectorMath.decode(Data([1, 2, 3])), [], "a damaged vector is ignored")
    }

    func testBothSearchesAreMergedAndFindingsFromBothRankFirst() {
        let hits = HybridRanker.rank(keyword: ["a", "b", "c"], vector: [(id: "c", similarity: 0.9), (id: "d", similarity: 0.8), (id: "e", similarity: 0.1)], limit: 10)
        XCTAssertEqual(hits.first?.id, "c", "found both ways")
        XCTAssertTrue(hits.map(\.id).contains("d"), "found by meaning only")
        XCTAssertFalse(hits.map(\.id).contains("e"), "too weak a match")
        XCTAssertEqual(HybridRanker.rank(keyword: [], vector: [], limit: 5), [])
        XCTAssertEqual(HybridRanker.rank(keyword: ["a", "b", "c", "d"], vector: [], limit: 2).count, 2)
    }

    func testFavouritesAndFreshnessBreakTies() {
        let now = Date()
        let fav = HybridRanker.rank(keyword: ["a", "b"], vector: [], favorites: ["b"], now: now)
        XCTAssertEqual(fav.map(\.id), ["b", "a"], "a favourite edges ahead of its neighbour")
        let far = HybridRanker.rank(keyword: (0..<30).map { "k\($0)" } + ["fav"], vector: [], favorites: ["fav"], now: now, limit: 40)
        XCTAssertNotEqual(far.first?.id, "fav", "but not past the strongest matches")
        let tie = HybridRanker.rank(keyword: [], vector: [(id: "old", similarity: 0.5), (id: "new", similarity: 0.5)], updated: ["old": now.addingTimeInterval(-400 * 86_400), "new": now], now: now)
        XCTAssertEqual(Set(tie.map(\.id)), ["old", "new"])
    }

    func testFullTextQueriesAreMadeSafe() {
        XCTAssertEqual(HybridRanker.ftsQuery("Hello, World!"), "\"hello\"* \"world\"*")
        XCTAssertNil(HybridRanker.ftsQuery("  ?!  "))
        XCTAssertEqual(HybridRanker.ftsQuery("a\" OR \"b"), "\"a\"* \"or\"* \"b\"*", "OR is just a quoted word, and quotes in the text cannot break out")
    }

    private func doc(_ text: String, source: IndexSource = .notes, target: String = "/Users/me/n.md", sensitivity: AISensitivity = .normal, excluded: Bool = false) -> IndexDocument {
        IndexDocument(id: "d", source: source, title: "T", text: text, target: target, sensitivity: sensitivity, updated: Date(), favorite: false, fromExcludedApp: excluded)
    }

    func testThePolicyKeepsSecretsAndOffSourcesOut() {
        let on: Set<IndexSource> = [.notes]
        XCTAssertNil(IndexPolicy.prepare(doc("x", source: .bookmarks), enabled: on), "a source that is off")
        XCTAssertNil(IndexPolicy.prepare(doc("x", sensitivity: .secret), enabled: on))
        XCTAssertNil(IndexPolicy.prepare(doc("x", excluded: true), enabled: on))
        XCTAssertNil(IndexPolicy.prepare(doc("x", target: "/Users/me/.ssh/notes.md"), enabled: on))
        XCTAssertNil(IndexPolicy.prepare(doc("x", target: "/Users/me/Library/Keychains/x"), enabled: on))
        XCTAssertNil(IndexPolicy.prepare(doc("   "), enabled: on), "nothing to index")
        let kept = IndexPolicy.prepare(doc("my key is sk-abcdefghijklmnopqrstuvwxyz and password = swordfish99"), enabled: on)
        XCTAssertFalse(kept?.text.contains("sk-abcdefgh") ?? true)
        XCTAssertFalse(kept?.text.contains("swordfish99") ?? true)
        XCTAssertEqual(IndexSource.allCases.filter(\.defaultOn).count, 3)
        XCTAssertFalse(IndexSource.clipboard.defaultOn)
    }

    // MARK: The index file

    private func makeIndex() throws -> AIIndex {
        try AIIndex(url: FileManager.default.temporaryDirectory.appendingPathComponent("kriya-index-\(UUID().uuidString).sqlite"))
    }

    func testDocumentsAreFoundByWordsAndRemovedCleanly() throws {
        let index = try makeIndex()
        try index.upsert(doc("The quarterly budget review is on Tuesday, bring the forecast spreadsheet."))
        var second = doc("Grocery list: milk, eggs, bread."); second.id = "d2"
        try index.upsert(second)
        XCTAssertEqual(index.keywordSearch("budget forecast").map(\.documentID), ["d"])
        XCTAssertEqual(index.keywordSearch("bud").map(\.documentID), ["d"], "prefix match")
        XCTAssertEqual(index.keywordSearch("grocery").map(\.documentID), ["d2"])
        XCTAssertTrue(index.keywordSearch("nonexistent").isEmpty)
        XCTAssertTrue(index.keywordSearch("\" OR *").isEmpty, "odd input is harmless")
        XCTAssertEqual(index.counts().documents, 2)
        try index.remove("d")
        XCTAssertTrue(index.keywordSearch("budget").isEmpty, "the words go with the document")
        XCTAssertEqual(index.counts().documents, 1)
    }

    func testChangedDocumentsAreReplacedAndUnchangedOnesLeftAlone() throws {
        let index = try makeIndex()
        try index.upsert(doc("first version about apples"))
        let before = index.counts().chunks
        try index.upsert(doc("first version about apples"))
        XCTAssertEqual(index.counts().chunks, before)
        try index.upsert(doc("second version about oranges"))
        XCTAssertTrue(index.keywordSearch("apples").isEmpty)
        XCTAssertEqual(index.keywordSearch("oranges").count, 1)
    }

    func testSourcesCanBeSwitchedOffAndTheirDocumentsGoWithThem() throws {
        let index = try makeIndex()
        try index.upsert(doc("notes about pandas"))
        XCTAssertEqual(index.keywordSearch("pandas").count, 1)
        try index.setSource(.notes, enabled: false)
        XCTAssertTrue(index.keywordSearch("pandas").isEmpty)
        XCTAssertEqual(index.counts().documents, 0, "turning a source off removes what it added")
        XCTAssertFalse(index.isSourceEnabled(.notes))
        XCTAssertTrue(index.isSourceEnabled(.workflows), "the defaults apply to sources never touched")
        XCTAssertFalse(index.isSourceEnabled(.bookmarks))
    }

    func testVectorsAreStoredPerModelAndSearchedByMeaning() throws {
        let index = try makeIndex()
        try index.upsert(doc("cats and dogs"))
        var other = doc("tax forms"); other.id = "d2"
        try index.upsert(other)
        let pieces = index.piecesNeedingVectors(model: "m1", limit: 10)
        XCTAssertEqual(pieces.count, 2)
        try index.store(vectors: [(chunk: pieces[0].id, vector: [1, 0]), (chunk: pieces[1].id, vector: [0, 1])], model: "m1")
        XCTAssertTrue(index.piecesNeedingVectors(model: "m1", limit: 10).isEmpty)
        XCTAssertEqual(index.piecesNeedingVectors(model: "m2", limit: 10).count, 2, "another model starts again")
        let nearest = index.vectorSearch([0.9, 0.1], model: "m1")
        XCTAssertEqual(nearest.first?.match.documentID, "d")
        XCTAssertTrue(index.vectorSearch([1, 0, 0], model: "m1").isEmpty, "a vector of another size is never compared")
        index.dropVectors(notFrom: "m2")
        XCTAssertEqual(index.counts().embedded, 0)
    }

    func testSecretDocumentsAreNeverSentOutForEmbedding() throws {
        let index = try makeIndex()
        try index.upsert(doc("a secret page", sensitivity: .secret))
        XCTAssertTrue(index.piecesNeedingVectors(model: "m", limit: 10).isEmpty)
    }

    func testDeleteAllEmptiesEverything() throws {
        let index = try makeIndex()
        try index.upsert(doc("something to forget"))
        try index.deleteAll()
        XCTAssertEqual(index.counts().documents, 0)
        XCTAssertEqual(index.counts().chunks, 0)
        XCTAssertTrue(index.keywordSearch("forget").isEmpty)
    }
}

final class ActivitySanitizerTests: XCTestCase {
    private func entry(_ kind: AuditLog.Kind, _ summary: String) -> AuditLog.Entry { AuditLog.Entry(kind: kind, summary: summary, at: Date()) }

    func testNamesPathsAddressesAndNumbersAreRemoved() {
        let dirty = "Moved “Tax 2024.pdf” from /Users/lokesh/Documents to ~/Desktop via https://example.com/a?token=abc, mail lokesh@example.com, key 7f3a9c1e5b2d4f6a8c0e1d3b5a7c9e2f at 14:30 version 2.10.0"
        let clean = ActivitySummarySanitizer.clean(dirty)
        for leak in ["Tax", "pdf", "lokesh", "/Users", "Desktop", "example.com", "token", "7f3a9c1e", "14:30", "2.10"] { XCTAssertFalse(clean.contains(leak), "\(leak) leaked into: \(clean)") }
        XCTAssertTrue(clean.contains("Moved"))
    }

    func testOnlyKindsThatHoldNoNamesAreIndexed() {
        let docs = ActivitySummarySanitizer.documents(from: [
            entry(.network, "Contacted api.openai.com"), entry(.files, "Moved “a.txt”"), entry(.script, "Script “backup” run"), entry(.install, "brew install --cask firefox"),
            entry(.setting, "Local-only mode turned on"), entry(.backup, "Backed up to iCloud Drive"),
        ])
        XCTAssertEqual(Set(docs.map(\.title)), Set([AuditLog.Kind.setting.title, AuditLog.Kind.backup.title]))
        XCTAssertTrue(docs.allSatisfy { $0.source == .activity })
        XCTAssertTrue(ActivitySummarySanitizer.documents(from: [entry(.setting, "“x”")]).isEmpty, "nothing is left to index once the name is gone")
    }
}
