import CryptoKit
import Foundation

/// What is shared between a person's Macs through iCloud Drive: snippets, pinned text, and (only if asked) a few recent text
/// copies. Never anything that looked like a password or key, never images or files, and never anything from an excluded app. Each
/// Mac writes its own encrypted file; each Mac reads the others' and merges, so there is no shared file to fight over.
struct ClipSyncItem: Codable, Equatable {
    enum Kind: String, Codable { case snippet, pinned, history }
    var key: String
    var kind: Kind
    var title: String
    var text: String
    var updatedAt: Double
    /// The Mac it came from, for naming a conflicting copy.
    var origin: String?
}

struct ClipSyncTombstone: Codable, Equatable {
    var key: String
    var at: Double
}

struct ClipSyncFile: Codable, Equatable {
    static let currentVersion = 1
    var version = ClipSyncFile.currentVersion
    var mac: String
    var macID: String
    var written: Double
    var items: [ClipSyncItem]
    var tombstones: [ClipSyncTombstone]
}

enum ClipSync {
    static let maxItems = 500
    static let maxTextLength = 20_000
    static let historyLimit = 100
    static let tombstoneKeepDays = 90.0

    /// The identity of an item on every Mac: a hash of what it is. A snippet is its title and text; other text is just its text.
    static func key(kind: ClipSyncItem.Kind, title: String, text: String) -> String {
        let basis = kind == .snippet ? "s\u{0}\(title)\u{0}\(text)" : "t\u{0}\(text)"
        return SHA256.hash(data: Data(basis.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Whether an item may leave this Mac at all.
    static func isShareable(isText: Bool, sensitive: Bool, text: String?) -> Bool {
        guard isText, !sensitive, let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= maxTextLength else { return false }
        return true
    }

    /// Keys that were here at the last sync and are not now: the person removed them, so the other Macs should too.
    static func newTombstones(previous: Set<String>, current: Set<String>, now: Double) -> [ClipSyncTombstone] {
        previous.subtracting(current).sorted().map { ClipSyncTombstone(key: $0, at: now) }
    }

    /// The tombstones to keep: the newest for each key, and none older than 90 days.
    static func pruned(_ tombstones: [ClipSyncTombstone], now: Double) -> [ClipSyncTombstone] {
        var latest: [String: Double] = [:]
        for t in tombstones where now - t.at <= tombstoneKeepDays * 86_400 { latest[t.key] = max(latest[t.key] ?? 0, t.at) }
        return latest.map { ClipSyncTombstone(key: $0.key, at: $0.value) }.sorted { $0.key < $1.key }
    }

    struct Plan: Equatable {
        var add: [ClipSyncItem] = []
        /// Local keys the other Macs removed.
        var remove: Set<String> = []
    }

    /// What this Mac should do after reading the others' files. `local` is what this Mac holds now.
    static func merge(local: [ClipSyncItem], localTombstones: [ClipSyncTombstone], remote: [ClipSyncFile], includeHistory: Bool) -> Plan {
        var dead: [String: Double] = [:]
        for t in localTombstones + remote.flatMap(\.tombstones) { dead[t.key] = max(dead[t.key] ?? 0, t.at) }
        let localByKey = Dictionary(local.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        var plan = Plan()

        // Removals the others made, for the things worth removing everywhere. History ages out by itself.
        for (key, item) in localByKey where item.kind != .history {
            if let at = dead[key], at >= item.updatedAt, remote.flatMap(\.tombstones).contains(where: { $0.key == key }) { plan.remove.insert(key) }
        }

        // Things the others have that this Mac lacks, newest copy of each, titles that clash kept apart.
        var best: [String: ClipSyncItem] = [:]
        for item in remote.flatMap(\.items) {
            guard item.kind != .history || includeHistory, item.text.count <= maxTextLength else { continue }
            if let existing = best[item.key], existing.updatedAt >= item.updatedAt { continue }
            best[item.key] = item
        }
        var titles = Set(local.filter { $0.kind == .snippet }.map { $0.title.lowercased() })
        for item in best.values.sorted(by: { ($0.updatedAt, $0.key) < ($1.updatedAt, $1.key) }) {
            if localByKey[item.key] != nil { continue }
            if let at = dead[item.key], at >= item.updatedAt { continue }
            var added = item
            if item.kind == .snippet, !item.title.isEmpty, titles.contains(item.title.lowercased()) {
                added.title = "\(item.title) (from \(item.origin ?? "another Mac"))"
            }
            if item.kind == .snippet { titles.insert(added.title.lowercased()) }
            plan.add.append(added)
        }
        return plan
    }

    // MARK: Files

    static let fileExtension = "kriyasync"

    static func fileName(macID: String) -> String { "clipboard-\(macID).\(fileExtension)" }

    static func isSyncFileName(_ name: String) -> Bool {
        name.range(of: #"^clipboard-[0-9a-fA-F-]{36}\.kriyasync$"#, options: .regularExpression) != nil
    }

    static func encode(_ file: ClipSyncFile, passphrase: String) throws -> Data {
        var capped = file
        capped.items = Array(file.items.sorted { $0.updatedAt > $1.updatedAt }.prefix(maxItems))
        let json = try JSONEncoder().encode(capped)
        return try BackupCrypto.seal(String(decoding: json, as: UTF8.self), passphrase: passphrase)
    }

    static func decode(_ data: Data, passphrase: String) throws -> ClipSyncFile {
        guard data.count < 20_000_000 else { throw BackupCryptoError.damaged }
        let text = try BackupCrypto.open(data, passphrase: passphrase)
        guard let file = try? JSONDecoder().decode(ClipSyncFile.self, from: Data(text.utf8)), file.version <= ClipSyncFile.currentVersion else { throw BackupCryptoError.damaged }
        return file
    }
}
