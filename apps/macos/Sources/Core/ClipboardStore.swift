import AppKit
import Combine

extension ClipItem: Identifiable {}
extension ClipCollection: Identifiable {}

extension ClipKind {
    static var all: [ClipKind] { [.text, .richText, .url, .image, .files] }

    var title: String {
        switch self {
        case .text: return "Text"
        case .richText: return "Rich text"
        case .image: return "Image"
        case .files: return "Files"
        case .url: return "Link"
        }
    }

    var symbol: String {
        switch self {
        case .text: return "text.alignleft"
        case .richText: return "textformat"
        case .image: return "photo"
        case .files: return "doc.on.doc"
        case .url: return "link"
        }
    }
}

extension ClipSkipReason {
    var title: String {
        switch self {
        case .paused: return "Paused"
        case .concealed: return "Marked secret by the app"
        case .excludedApp: return "From an excluded app"
        case .looksSensitive: return "Looked like a secret"
        case .tooLarge: return "Too large"
        case .typeTurnedOff: return "That type is turned off"
        case .empty: return "Empty"
        case .vaultLocked: return "History is locked"
        }
    }
}

/// The clipboard history as the interface sees it, plus the settings. The history itself lives in its own local file,
/// handled by the core. Nothing here sends anything anywhere.
final class ClipboardStore: ObservableObject {
    @Published private(set) var items: [ClipItem] = []
    @Published private(set) var collections: [ClipCollection] = []
    @Published private(set) var tags: [String] = []
    @Published private(set) var config = defaultClipConfig()
    @Published private(set) var stats: ClipStats?
    @Published var lastError: String?
    /// What the last copy that was left out was left out for, and how many since launch.
    @Published private(set) var lastSkip: ClipSkipReason?
    @Published private(set) var skippedCount = 0

    private let core: KriyaCore
    private let lock = NSLock()
    private var snapshot = defaultClipConfig()   // guarded by lock
    /// Encryption of the saved history. Created first, so the key is with the core before anything is recorded or read.
    let vault: ClipboardVault

    init(core: KriyaCore, keyStore: VaultKeyStore = KeychainVaultKeyStore()) {
        self.core = core
        vault = ClipboardVault(core: core, keyStore: keyStore)
        reload()
    }

    func reload() {
        do {
            config = try core.clipConfig()
            collections = try core.clipCollections()
            tags = try core.clipAllTags()
            stats = try core.clipStats()
        } catch {
            Log.error("Clipboard", "Could not load clipboard settings: \(error.userMessage)")
        }
        publishSnapshot()
    }

    private func publishSnapshot() {
        lock.lock()
        snapshot = config
        lock.unlock()
    }

    /// The settings, readable from any thread.
    var currentConfig: ClipConfig {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }

    var isEmpty: Bool { (stats?.items ?? 0) == 0 }

    // MARK: Reading

    func search(_ query: String, filter: ClipFilter = ClipFilter(kinds: [], pinnedOnly: false, favoritesOnly: false, collectionId: nil, tag: nil), limit: UInt32 = 300) -> [ClipItem] {
        (try? core.clipSearch(query: query, filter: filter, limit: limit)) ?? []
    }

    func blob(_ id: String) -> ClipBlob? {
        (try? core.clipBlob(id: id)) ?? nil
    }

    func item(_ id: String) -> ClipItem? {
        (try? core.clipItem(id: id)) ?? nil
    }

    func refreshStats() {
        stats = try? core.clipStats()
    }

    // MARK: Settings

    func updateConfig(_ change: (inout ClipConfig) -> Void) {
        var updated = config
        change(&updated)
        do {
            try core.saveClipConfig(config: updated)
            lastError = nil
        } catch {
            lastError = error.userMessage
        }
        reload()
    }

    // MARK: Recording (from the monitor)

    func record(_ clip: NewClip) -> ClipRecordOutcome? {
        do {
            let outcome = try core.clipRecord(new: clip, now: SystemInfo.nowSeconds)
            if outcome.status == .skipped {
                DispatchQueue.main.async { [self] in
                    lastSkip = outcome.skipped
                    skippedCount += 1
                }
            }
            return outcome
        } catch {
            Log.error("Clipboard", "Could not record a copy: \(error.userMessage)")
            return nil
        }
    }

    /// A copy that was left out, counted so the person can see the rules working.
    func noteSkipped(_ reason: ClipSkipReason) {
        lastSkip = reason
        skippedCount += 1
    }

    func markUsed(_ id: String) { try? core.clipMarkUsed(id: id, now: SystemInfo.nowSeconds) }

    // MARK: Editing items

    func setPinned(_ id: String, _ pinned: Bool) { perform { try core.clipSetPinned(id: id, pinned: pinned) } }
    func setFavorite(_ id: String, _ favorite: Bool, title: String? = nil) { perform { try core.clipSetFavorite(id: id, favorite: favorite, title: title) } }
    func setTitle(_ id: String, _ title: String?) { perform { try core.clipSetTitle(id: id, title: title) } }
    func setTags(_ id: String, _ tags: [String]) { perform { try core.clipSetTags(id: id, tags: tags) } }
    func setCollection(_ id: String, _ collection: String?) { perform { try core.clipSetCollection(id: id, collection: collection) } }
    func delete(_ id: String) { perform { try core.clipDelete(id: id) } }

    @discardableResult
    func addSnippet(title: String?, text: String, collection: String? = nil) -> String? {
        var made: String?
        perform { made = try core.clipAddSnippet(title: title, text: text, collection: collection, now: SystemInfo.nowSeconds) }
        return lastError == nil ? made : nil
    }

    func updateSnippet(_ id: String, title: String?, text: String?) { perform { try core.clipUpdateSnippet(id: id, title: title, text: text) } }

    func clear(keepPinned: Bool, keepSnippets: Bool) -> Int {
        var removed = 0
        perform { removed = Int(try core.clipClear(keepPinned: keepPinned, keepSnippets: keepSnippets)) }
        Log.info("Clipboard", "History cleared (\(removed) items)")
        return removed
    }

    /// Removes items labelled sensitive. Pinned items and snippets stay.
    func purgeSensitive() -> Int {
        var removed = 0
        perform { removed = Int(try core.clipPurgeSensitive()) }
        Log.info("Clipboard", "Sensitive items removed (\(removed))")
        return removed
    }

    func cleanup() {
        let removed = (try? core.clipCleanup(now: SystemInfo.nowSeconds)) ?? 0
        if removed > 0 { Log.info("Clipboard", "Cleanup removed \(removed) item(s)") }
        reload()
    }

    // MARK: Collections

    func saveCollection(id: String = UUID().uuidString, name: String) { perform { try core.clipSaveCollection(id: id, name: name) } }
    func deleteCollection(_ id: String) { perform { try core.clipDeleteCollection(id: id) } }

    // MARK: Sharing snippets

    /// Writes the snippets to a file. With a passphrase the file is sealed (AES-256-GCM, key from the passphrase) and cannot be
    /// read without it; without one it is plain JSON.
    func exportSnippets(_ ids: [String], to url: URL, passphrase: String? = nil) throws {
        let json = try core.clipExportSnippets(ids: ids)
        if let passphrase, !passphrase.isEmpty {
            try BackupCrypto.seal(json, passphrase: passphrase).write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } else {
            try json.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Whether a snippet file is sealed and needs a passphrase to be read.
    static func needsPassphrase(_ url: URL) -> Bool {
        (try? Data(contentsOf: url)).map(BackupCrypto.isEncrypted) ?? false
    }

    func importSnippets(from url: URL, passphrase: String? = nil) throws -> SnippetImportSummary {
        let data = try Data(contentsOf: url)
        let json: String
        if BackupCrypto.isEncrypted(data) {
            guard let passphrase, !passphrase.isEmpty else { throw BackupCryptoError.needsPassphrase }
            json = try BackupCrypto.open(data, passphrase: passphrase)
        } else {
            guard let text = String(data: data, encoding: .utf8) else { throw CoreError.Backup(message: "the file is not a Kriya snippet file") }
            json = text
        }
        let summary = try core.clipImportSnippets(json: json, now: SystemInfo.nowSeconds)
        reload()
        return summary
    }

    private func perform(_ work: () throws -> Void) {
        do {
            try work()
            lastError = nil
        } catch {
            lastError = error.userMessage
        }
        reload()
    }
}
