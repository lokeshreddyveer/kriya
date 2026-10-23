import Foundation

/// Where indexed content comes from. Each source is off until the person turns it on, except the few that hold only things the
/// person wrote for Kriya. Nothing from a password manager, the Keychain, a private browser window, an API key or a raw screenshot
/// has a source here, so none can be indexed.
enum IndexSource: String, Codable, CaseIterable, Identifiable {
    case notes, workflows, actions, clipboard, savedPages, bookmarks, activity

    var id: String { rawValue }
    var title: String {
        switch self {
        case .notes: return "Notes"
        case .workflows: return "Saved workflows"
        case .actions: return "Kriya commands"
        case .clipboard: return "Snippets and pinned clipboard text"
        case .savedPages: return "Web pages you saved"
        case .bookmarks: return "Browser bookmarks (titles and addresses)"
        case .activity: return "Kriya's activity log"
        }
    }
    var detail: String {
        switch self {
        case .notes: return "Your notes, in full."
        case .workflows: return "Names, notes and what each step does."
        case .actions: return "The names of commands, so “turn on the meeting sound” can find the right one."
        case .clipboard: return "Titles and the first lines of snippets and pinned items. Never items that look like secrets."
        case .savedPages: return "Only pages you chose to save with the browser extension."
        case .bookmarks: return "Titles and addresses only, not the pages."
        case .activity: return "Short generic lines about settings and backups, with every name, path, address and number removed."
        }
    }
    var defaultOn: Bool { self == .notes || self == .workflows || self == .actions }
}

struct IndexDocument: Equatable {
    var id: String
    var source: IndexSource
    var title: String
    var text: String
    /// What opens it: a file path, a web address or a workflow id.
    var target: String
    var sensitivity: AISensitivity = .normal
    var updated: Date
    var favorite = false
    /// From an app the person excluded.
    var fromExcludedApp = false
}

enum IndexPolicy {
    /// Places whose files are never indexed, whatever their source says.
    static let blockedPathParts = [".ssh", ".gnupg", ".aws", ".kube", ".docker", "Keychains", ".env", "id_rsa", "id_ed25519", ".netrc", ".npmrc", ".pypirc", "credentials"]
    static let maxDocumentCharacters = 60_000
    static let maxChunksPerDocument = 40
    static let maxChunksTotal = 50_000

    /// Whether a document may be indexed at all, and in what form: the text has secrets replaced, and is cut.
    static func prepare(_ doc: IndexDocument, enabled: Set<IndexSource>) -> IndexDocument? {
        guard enabled.contains(doc.source), !doc.fromExcludedApp, doc.sensitivity != .secret else { return nil }
        if blockedPathParts.contains(where: { doc.target.contains($0) }) { return nil }
        var out = doc
        out.text = String(SecretRedactor.redact(doc.text).text.prefix(maxDocumentCharacters))
        out.title = String(SecretRedactor.redact(doc.title).text.prefix(200))
        guard !(out.title + out.text).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return out
    }
}

enum TextChunker {
    /// Pieces of about `maxCharacters`, cut at paragraph or sentence ends where possible, with a little overlap so a thought split
    /// across two pieces is found by either.
    static func chunks(_ text: String, maxCharacters: Int = 800, overlap: Int = 80, maxChunks: Int = IndexPolicy.maxChunksPerDocument) -> [String] {
        let clean = text.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return [] }
        if clean.count <= maxCharacters { return [clean] }
        var pieces: [String] = []
        var current = ""
        func flush() {
            let t = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { pieces.append(t) }
            current = ""
        }
        for paragraph in clean.components(separatedBy: "\n\n") {
            if paragraph.count > maxCharacters {
                flush()
                var sentence = ""
                for part in paragraph.split(omittingEmptySubsequences: false, whereSeparator: { ".!?\n".contains($0) }) {
                    if sentence.count + part.count + 1 > maxCharacters, !sentence.isEmpty { pieces.append(sentence.trimmingCharacters(in: .whitespaces)); sentence = "" }
                    var piece = String(part)
                    while piece.count > maxCharacters { pieces.append(String(piece.prefix(maxCharacters))); piece = String(piece.dropFirst(maxCharacters)) }
                    sentence += piece + ". "
                }
                if !sentence.trimmingCharacters(in: .whitespaces).isEmpty { pieces.append(sentence.trimmingCharacters(in: .whitespaces)) }
            } else if current.count + paragraph.count + 2 > maxCharacters {
                flush()
                current = paragraph
            } else {
                current += (current.isEmpty ? "" : "\n\n") + paragraph
            }
        }
        flush()
        guard overlap > 0, pieces.count > 1 else { return Array(pieces.prefix(maxChunks)) }
        var overlapped = [pieces[0]]
        for i in 1..<pieces.count { overlapped.append(String(pieces[i - 1].suffix(overlap)) + " " + pieces[i]) }
        return Array(overlapped.prefix(maxChunks))
    }
}

enum VectorMath {
    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<a.count { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        let denominator = (na * nb).squareRoot()
        return denominator > 0 ? dot / denominator : 0
    }

    static func encode(_ v: [Float]) -> Data { v.withUnsafeBufferPointer { Data(buffer: $0) } }

    static func decode(_ data: Data) -> [Float] {
        guard data.count % MemoryLayout<Float>.size == 0 else { return [] }
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}

/// Combines a keyword search and a meaning search into one list, by reciprocal rank fusion, with a small push for favourites and
/// recent things. A result found by only one of the two still appears; it just ranks lower than one both found.
enum HybridRanker {
    struct Hit: Equatable {
        var id: String
        var score: Double
    }

    static let k = 60.0
    static let minimumSimilarity: Float = 0.25

    /// Both lists are best first. `vector` pairs an id with its similarity.
    static func rank(keyword: [String], vector: [(id: String, similarity: Float)], updated: [String: Date] = [:], favorites: Set<String> = [], now: Date = Date(), limit: Int = 20) -> [Hit] {
        var scores: [String: Double] = [:]
        for (rank, id) in keyword.enumerated() { scores[id, default: 0] += 1 / (k + Double(rank + 1)) }
        for (rank, hit) in vector.filter({ $0.similarity >= minimumSimilarity }).enumerated() { scores[hit.id, default: 0] += 1 / (k + Double(rank + 1)) }
        for id in scores.keys {
            if favorites.contains(id) { scores[id, default: 0] += 0.004 }
            if let date = updated[id] { scores[id, default: 0] += 0.004 * exp(-max(0, now.timeIntervalSince(date)) / (30 * 86_400)) }
        }
        return scores.map { Hit(id: $0.key, score: $0.value) }.sorted { $0.score != $1.score ? $0.score > $1.score : $0.id < $1.id }.prefix(limit).map { $0 }
    }

    /// Words for a full-text query: letters and digits only, each a prefix match, all required.
    static func ftsQuery(_ text: String) -> String? {
        let words = text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { !$0.isEmpty }.prefix(8)
        return words.isEmpty ? nil : words.map { "\"\($0)\"*" }.joined(separator: " ")
    }
}

/// The activity log is the one source whose text was written for a person to read, not for an index, so it is cut down before it is
/// indexed: only kinds that hold nothing about files or sites are used, and every name, path, address and number is removed.
enum ActivitySummarySanitizer {
    /// Kinds of audit entry that may be indexed. Network (sites), files (names), installs and scripts (names) are left out.
    static let indexedKinds: Set<AuditLog.Kind> = [.setting, .backup]

    static func clean(_ summary: String) -> String {
        var text = summary
        let patterns = [
            #"“[^”]*”"#, #""[^"]*""#, #"‘[^’]*’"#, #"'[^']*'"#,                 // anything in quotes is a name
            #"[A-Za-z][A-Za-z0-9+.\-]*://\S+"#,                                    // addresses
            #"~?/[^\s,;:]+"#,                                                         // paths
            #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#,                    // email addresses
            #"\b[A-Za-z0-9_\-]{24,}\b"#,                                              // long tokens
            #"\b\d[\d.,:\-]*\b"#,                                                   // numbers, times, versions
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        }
        text = SecretRedactor.redact(SupportScrubber.scrub(text), includePersonal: true).text
        return text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    static func documents(from entries: [AuditLog.Entry], limit: Int = 300) -> [IndexDocument] {
        entries.filter { indexedKinds.contains($0.kind) }.prefix(limit).compactMap { entry in
            let text = clean(entry.summary)
            guard text.count >= 4 else { return nil }
            return IndexDocument(id: "audit:" + entry.id, source: .activity, title: entry.kind.title, text: text, target: "", updated: entry.at)
        }
    }
}
