import Foundation
import SQLite3

/// The local index: documents split into pieces, a full-text index of the pieces, and (when an embedding provider is chosen) a
/// vector for each piece. One file on this Mac, readable only by this user and left out of backups.
final class AIIndex {
    struct Match {
        var documentID: String
        var title: String
        var source: IndexSource
        var target: String
        var snippet: String
        var updated: Date
        var favorite: Bool
        var score: Double
    }

    enum IndexError: Error { case open(String), sql(String) }

    private var db: OpaquePointer?
    private let lock = NSLock()
    static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    static var defaultURL: URL { AppPaths.live.support.appendingPathComponent("ai-index.sqlite") }

    init(url: URL = AIIndex.defaultURL) throws {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw IndexError.open(String(cString: sqlite3_errmsg(db)))
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        var excluded = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? excluded.setResourceValues(values)
        try run("PRAGMA foreign_keys = ON")
        try run("PRAGMA journal_mode = WAL")
        try run("""
        CREATE TABLE IF NOT EXISTS documents(id TEXT PRIMARY KEY, source TEXT NOT NULL, path TEXT, title TEXT, sensitivity INTEGER, scope TEXT, hash TEXT, updated REAL, favorite INTEGER);
        CREATE TABLE IF NOT EXISTS chunks(id INTEGER PRIMARY KEY AUTOINCREMENT, document_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE, idx INTEGER, text TEXT, created REAL, updated REAL);
        CREATE TABLE IF NOT EXISTS embeddings(chunk_id INTEGER PRIMARY KEY REFERENCES chunks(id) ON DELETE CASCADE, model TEXT, dim INTEGER, vector BLOB);
        CREATE TABLE IF NOT EXISTS sources(source TEXT PRIMARY KEY, enabled INTEGER, last_indexed REAL);
        CREATE TABLE IF NOT EXISTS permissions(source TEXT, scope TEXT, granted INTEGER, PRIMARY KEY(source, scope));
        CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);
        CREATE VIRTUAL TABLE IF NOT EXISTS chunk_fts USING fts5(text, content='chunks', content_rowid='id', tokenize='unicode61 remove_diacritics 2');
        CREATE TRIGGER IF NOT EXISTS chunks_ai AFTER INSERT ON chunks BEGIN INSERT INTO chunk_fts(rowid, text) VALUES (new.id, new.text); END;
        CREATE TRIGGER IF NOT EXISTS chunks_ad AFTER DELETE ON chunks BEGIN INSERT INTO chunk_fts(chunk_fts, rowid, text) VALUES ('delete', old.id, old.text); END;
        """)
    }

    deinit { sqlite3_close(db) }

    enum Bind { case int(Int), double(Double), text(String), blob(Data), null }

    @discardableResult
    func run(_ sql: String, _ binds: [Bind] = []) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        if binds.isEmpty {
            var error: UnsafeMutablePointer<CChar>?
            guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else { let m = error.map { String(cString: $0) } ?? "error"; sqlite3_free(error); throw IndexError.sql(m) }
            return Int(sqlite3_changes(db))
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw IndexError.sql(String(cString: sqlite3_errmsg(db))) }
        defer { sqlite3_finalize(statement) }
        bind(statement, binds)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw IndexError.sql(String(cString: sqlite3_errmsg(db))) }
        return Int(sqlite3_changes(db))
    }

    func rows<T>(_ sql: String, _ binds: [Bind] = [], _ map: (OpaquePointer) -> T) throws -> [T] {
        lock.lock(); defer { lock.unlock() }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw IndexError.sql(String(cString: sqlite3_errmsg(db))) }
        defer { sqlite3_finalize(statement) }
        bind(statement, binds)
        var out: [T] = []
        while sqlite3_step(statement) == SQLITE_ROW { out.append(map(statement)) }
        return out
    }

    private func bind(_ statement: OpaquePointer?, _ binds: [Bind]) {
        for (i, value) in binds.enumerated() {
            let index = Int32(i + 1)
            switch value {
            case .int(let v): sqlite3_bind_int64(statement, index, Int64(v))
            case .double(let v): sqlite3_bind_double(statement, index, v)
            case .text(let v): sqlite3_bind_text(statement, index, v, -1, Self.transient)
            case .blob(let v): v.withUnsafeBytes { _ = sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(v.count), Self.transient) }
            case .null: sqlite3_bind_null(statement, index)
            }
        }
    }

    static func text(_ s: OpaquePointer, _ column: Int32) -> String { sqlite3_column_text(s, column).map { String(cString: $0) } ?? "" }

    // MARK: Writing

    func isSourceEnabled(_ source: IndexSource) -> Bool {
        let value = try? rows("SELECT enabled FROM sources WHERE source = ?", [.text(source.rawValue)]) { Int(sqlite3_column_int($0, 0)) }.first
        return value.map { $0 == 1 } ?? source.defaultOn
    }

    func setSource(_ source: IndexSource, enabled: Bool) throws {
        try run("INSERT INTO sources(source, enabled, last_indexed) VALUES(?, ?, NULL) ON CONFLICT(source) DO UPDATE SET enabled = excluded.enabled", [.text(source.rawValue), .int(enabled ? 1 : 0)])
        if !enabled { try removeSource(source) }
    }

    var enabledSources: Set<IndexSource> { Set(IndexSource.allCases.filter(isSourceEnabled)) }

    /// Adds or replaces a document. Nothing is done when its content has not changed.
    func upsert(_ doc: IndexDocument) throws {
        let hash = AIIndex.hash(doc)
        let existing = try rows("SELECT hash FROM documents WHERE id = ?", [.text(doc.id)]) { Self.text($0, 0) }.first
        if existing == hash { return }
        let total = try rows("SELECT COUNT(*) FROM chunks", []) { Int(sqlite3_column_int64($0, 0)) }.first ?? 0
        guard total < IndexPolicy.maxChunksTotal else { return }
        try run("BEGIN")
        do {
            try run("DELETE FROM documents WHERE id = ?", [.text(doc.id)])
            try run("INSERT INTO documents(id, source, path, title, sensitivity, scope, hash, updated, favorite) VALUES(?,?,?,?,?,?,?,?,?)",
                    [.text(doc.id), .text(doc.source.rawValue), .text(doc.target), .text(doc.title), .int(doc.sensitivity.rawValue), .text(doc.source == .savedPages ? AIPermission.userSelected.rawValue : AIPermission.indexed.rawValue),
                     .text(hash), .double(doc.updated.timeIntervalSince1970), .int(doc.favorite ? 1 : 0)])
            let now = Date().timeIntervalSince1970
            for (i, chunk) in TextChunker.chunks(doc.title + "\n\n" + doc.text).enumerated() {
                try run("INSERT INTO chunks(document_id, idx, text, created, updated) VALUES(?,?,?,?,?)", [.text(doc.id), .int(i), .text(chunk), .double(now), .double(now)])
            }
            try run("COMMIT")
        } catch {
            _ = try? run("ROLLBACK")
            throw error
        }
    }

    static func hash(_ doc: IndexDocument) -> String { LauncherApprovals.fingerprint(kind: doc.source.rawValue, content: doc.title + "\u{0}" + doc.text + "\u{0}" + doc.target + "\(doc.favorite)") }

    func remove(_ id: String) throws { try run("DELETE FROM documents WHERE id = ?", [.text(id)]) }

    func removeSource(_ source: IndexSource) throws { try run("DELETE FROM documents WHERE source = ?", [.text(source.rawValue)]) }

    /// Removes documents of a source that are no longer there.
    func prune(_ source: IndexSource, keeping ids: Set<String>) throws {
        for id in try rows("SELECT id FROM documents WHERE source = ?", [.text(source.rawValue)]) { Self.text($0, 0) } where !ids.contains(id) { try remove(id) }
    }

    func deleteAll() throws {
        try run("DELETE FROM documents")
        try run("DELETE FROM meta")
        _ = try? run("INSERT INTO chunk_fts(chunk_fts) VALUES('rebuild')")
        _ = try? run("VACUUM")
    }

    func markIndexed(_ source: IndexSource) {
        _ = try? run("INSERT INTO sources(source, enabled, last_indexed) VALUES(?, ?, ?) ON CONFLICT(source) DO UPDATE SET last_indexed = excluded.last_indexed", [.text(source.rawValue), .int(isSourceEnabled(source) ? 1 : 0), .double(Date().timeIntervalSince1970)])
    }

    func lastIndexed(_ source: IndexSource) -> Date? {
        (try? rows("SELECT last_indexed FROM sources WHERE source = ?", [.text(source.rawValue)]) { sqlite3_column_type($0, 0) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double($0, 0)) }.first) ?? nil
    }

    func counts() -> (documents: Int, chunks: Int, embedded: Int) {
        func n(_ sql: String) -> Int { (try? rows(sql, []) { Int(sqlite3_column_int64($0, 0)) }.first) ?? 0 }
        return (n("SELECT COUNT(*) FROM documents"), n("SELECT COUNT(*) FROM chunks"), n("SELECT COUNT(*) FROM embeddings"))
    }

    // MARK: Embeddings

    /// Pieces that have no vector for this model yet (or an old one), so they can be sent to be embedded.
    func piecesNeedingVectors(model: String, limit: Int) -> [(id: Int, text: String)] {
        (try? rows("""
        SELECT c.id, c.text FROM chunks c JOIN documents d ON d.id = c.document_id
        WHERE NOT EXISTS (SELECT 1 FROM embeddings e WHERE e.chunk_id = c.id AND e.model = ?) AND d.sensitivity < 2 ORDER BY c.id LIMIT ?
        """, [.text(model), .int(limit)]) { (Int(sqlite3_column_int64($0, 0)), Self.text($0, 1)) }) ?? []
    }

    func store(vectors: [(chunk: Int, vector: [Float])], model: String) throws {
        try run("BEGIN")
        do {
            for item in vectors {
                try run("INSERT OR REPLACE INTO embeddings(chunk_id, model, dim, vector) VALUES(?,?,?,?)", [.int(item.chunk), .text(model), .int(item.vector.count), .blob(VectorMath.encode(item.vector))])
            }
            try run("COMMIT")
        } catch { _ = try? run("ROLLBACK"); throw error }
    }

    func dropVectors(notFrom model: String) { _ = try? run("DELETE FROM embeddings WHERE model != ?", [.text(model)]) }

    // MARK: Searching

    private func match(_ s: OpaquePointer) -> Match {
        Match(documentID: Self.text(s, 0), title: Self.text(s, 1), source: IndexSource(rawValue: Self.text(s, 2)) ?? .notes, target: Self.text(s, 3), snippet: Self.text(s, 4),
              updated: Date(timeIntervalSince1970: sqlite3_column_double(s, 5)), favorite: sqlite3_column_int(s, 6) == 1, score: 0)
    }

    /// Documents whose pieces hold every word, best first, from enabled sources only.
    func keywordSearch(_ query: String, limit: Int = 40) -> [Match] {
        guard let fts = HybridRanker.ftsQuery(query) else { return [] }
        let enabled = enabledSources.map(\.rawValue)
        guard !enabled.isEmpty else { return [] }
        let marks = enabled.map { _ in "?" }.joined(separator: ",")
        let sql = """
        SELECT d.id, d.title, d.source, d.path, snippet(chunk_fts, 0, '', '', '…', 14), d.updated, d.favorite
        FROM chunk_fts JOIN chunks c ON c.id = chunk_fts.rowid JOIN documents d ON d.id = c.document_id
        WHERE chunk_fts MATCH ? AND d.source IN (\(marks)) ORDER BY bm25(chunk_fts) LIMIT ?
        """
        let found = (try? rows(sql, [.text(fts)] + enabled.map { .text($0) } + [.int(limit * 3)]) { self.match($0) }) ?? []
        var seen = Set<String>()
        return found.filter { seen.insert($0.documentID).inserted }.prefix(limit).map { $0 }
    }

    /// Documents whose pieces are closest in meaning to the query's vector.
    func vectorSearch(_ query: [Float], model: String, limit: Int = 40) -> [(match: Match, similarity: Float)] {
        let enabled = enabledSources.map(\.rawValue)
        guard !enabled.isEmpty, !query.isEmpty else { return [] }
        let marks = enabled.map { _ in "?" }.joined(separator: ",")
        let sql = """
        SELECT d.id, d.title, d.source, d.path, substr(c.text, 1, 160), d.updated, d.favorite, e.vector
        FROM embeddings e JOIN chunks c ON c.id = e.chunk_id JOIN documents d ON d.id = c.document_id
        WHERE e.model = ? AND e.dim = ? AND d.source IN (\(marks))
        """
        let scored = (try? rows(sql, [.text(model), .int(query.count)] + enabled.map { .text($0) }) { s -> (Match, Float) in
            let blob = sqlite3_column_blob(s, 7).map { Data(bytes: $0, count: Int(sqlite3_column_bytes(s, 7))) } ?? Data()
            return (self.match(s), VectorMath.cosine(query, VectorMath.decode(blob)))
        }) ?? []
        var best: [String: (Match, Float)] = [:]
        for (m, sim) in scored where sim > (best[m.documentID]?.1 ?? -1) { best[m.documentID] = (m, sim) }
        return best.values.sorted { $0.1 > $1.1 }.prefix(limit).map { (match: $0.0, similarity: $0.1) }
    }
}
