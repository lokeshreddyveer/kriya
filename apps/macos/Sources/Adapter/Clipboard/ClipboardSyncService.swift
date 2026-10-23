import AppKit

/// Shares snippets, pinned text and (if asked) a few recent text copies between a person's Macs through iCloud Drive. Everything is
/// encrypted with a passphrase only the person's Macs know; secrets, images, files and excluded apps are never included.
final class ClipboardSyncService: ObservableObject {
    static let shared = ClipboardSyncService()
    private static let enabledKey = "clipSync.enabled"
    private static let historyKey = "clipSync.history"
    private static let macIDKey = "clipSync.macID"
    private static let stateKey = "clipSync.state.v1"
    private static let passphraseAccount = "clip-sync-passphrase"
    private static let interval: TimeInterval = 300

    private struct State: Codable {
        var previousKeys: [String] = []
        var tombstones: [ClipSyncTombstone] = []
    }

    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: Self.enabledKey); enabled ? start() : stop() }
    }
    @Published var includeHistory: Bool { didSet { UserDefaults.standard.set(includeHistory, forKey: Self.historyKey) } }
    @Published private(set) var status: String?
    @Published private(set) var lastSync: Date?
    @Published private(set) var busy = false

    private var store: ClipboardStore?
    private var timer: Timer?
    private let queue = DispatchQueue(label: "app.kriya.clipsync", qos: .utility)

    static var folder: URL? {
        let drive = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        guard FileManager.default.fileExists(atPath: drive.path) else { return nil }
        return drive.appendingPathComponent("Kriya Sync", isDirectory: true)
    }

    var hasPassphrase: Bool { KeychainSecrets.get(Self.passphraseAccount) != nil }

    private lazy var macID: String = {
        if let id = UserDefaults.standard.string(forKey: Self.macIDKey) { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: Self.macIDKey)
        return id
    }()

    private init() {
        enabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        includeHistory = UserDefaults.standard.bool(forKey: Self.historyKey)
    }

    func attach(_ store: ClipboardStore) { self.store = store; start() }

    func setPassphrase(_ passphrase: String) -> Bool {
        guard passphrase.count >= BackupCrypto.minimumLength else { status = BackupCryptoError.tooShort.localizedDescription; return false }
        return KeychainSecrets.set(passphrase, for: Self.passphraseAccount)
    }

    func start() {
        guard enabled, store != nil, timer == nil else { return }
        let t = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in self?.syncNow() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        syncNow()
    }

    func stop() { timer?.invalidate(); timer = nil }

    func syncNow() {
        guard !busy, let store else { return }
        guard !LocalOnly.isOn else { status = LocalOnly.blockedMessage; return }
        guard let folder = Self.folder else { status = "iCloud Drive is not turned on for this Mac."; return }
        guard let passphrase = KeychainSecrets.get(Self.passphraseAccount) else { status = "Choose a sync passphrase first. Use the same one on every Mac."; return }
        busy = true
        // Reading the clipboard store is quick; the encryption and the files are not, so they run off the main thread.
        let local = gather(store)
        let wantHistory = includeHistory
        let mac = Host.current().localizedName ?? "Mac"
        queue.async { [self] in
            let outcome = run(local: local, store: store, folder: folder, passphrase: passphrase, includeHistory: wantHistory, mac: mac)
            DispatchQueue.main.async {
                self.busy = false
                self.status = outcome.message
                if outcome.ok { self.lastSync = Date() }
            }
        }
    }

    // MARK: Gathering what this Mac holds

    private struct Local {
        var items: [ClipSyncItem]
        /// The local id for each key, so a removal can be carried out.
        var ids: [String: String]
    }

    private func gather(_ store: ClipboardStore) -> Local {
        var items: [ClipSyncItem] = []
        var ids: [String: String] = [:]
        func take(_ filter: ClipFilter, _ kind: ClipSyncItem.Kind, limit: UInt32, skip: (ClipItem) -> Bool = { _ in false }) {
            for clip in store.search("", filter: filter, limit: limit) where !skip(clip) {
                guard clip.kind == .text || clip.kind == .url, !clip.sensitive, let text = store.blob(clip.id)?.plain,
                      ClipSync.isShareable(isText: true, sensitive: false, text: text) else { continue }
                let title = kind == .snippet ? (clip.title ?? "") : ""
                let key = ClipSync.key(kind: kind, title: title, text: text)
                guard ids[key] == nil else { continue }
                ids[key] = clip.id
                items.append(ClipSyncItem(key: key, kind: kind, title: title, text: text, updatedAt: Double(max(clip.lastUsedAt, clip.createdAt)), origin: nil))
            }
        }
        take(ClipFilter(kinds: [], pinnedOnly: false, favoritesOnly: true, collectionId: nil, tag: nil), .snippet, limit: 400)
        take(ClipFilter(kinds: [], pinnedOnly: true, favoritesOnly: false, collectionId: nil, tag: nil), .pinned, limit: 400, skip: { $0.favorite })
        if includeHistory {
            take(ClipFilter(kinds: [.text], pinnedOnly: false, favoritesOnly: false, collectionId: nil, tag: nil), .history, limit: UInt32(ClipSync.historyLimit), skip: { $0.favorite || $0.pinned })
        }
        return Local(items: items, ids: ids)
    }

    // MARK: One round

    private func run(local: Local, store: ClipboardStore, folder: URL, passphrase: String, includeHistory: Bool, mac: String) -> (ok: Bool, message: String) {
        let fm = FileManager.default
        let now = Date().timeIntervalSince1970
        var state = UserDefaults.standard.data(forKey: Self.stateKey).flatMap { try? JSONDecoder().decode(State.self, from: $0) } ?? State()
        do { try fm.createDirectory(at: folder, withIntermediateDirectories: true) } catch { return (false, "The sync folder could not be made: \(error.localizedDescription)") }

        // The other Macs' files.
        var remote: [ClipSyncFile] = []
        var unreadable = 0
        let mine = ClipSync.fileName(macID: macID)
        for name in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] where ClipSync.isSyncFileName(name) && name != mine {
            let url = folder.appendingPathComponent(name)
            // A file still downloading from iCloud shows up as a placeholder; ask for it and try again next time.
            if !fm.isReadableFile(atPath: url.path) { try? fm.startDownloadingUbiquitousItem(at: url); unreadable += 1; continue }
            guard let data = try? Data(contentsOf: url), let file = try? ClipSync.decode(data, passphrase: passphrase) else { unreadable += 1; continue }
            remote.append(file)
        }
        // Items carry the name of the Mac they came from, for naming a copy that clashes.
        remote = remote.map { file in var f = file; f.items = f.items.map { var i = $0; i.origin = file.mac; return i }; return f }

        // What the person removed here since the last round.
        let durable = Set(local.items.filter { $0.kind != .history }.map(\.key))
        state.tombstones = ClipSync.pruned(state.tombstones + ClipSync.newTombstones(previous: Set(state.previousKeys), current: durable, now: now), now: now)

        let plan = ClipSync.merge(local: local.items, localTombstones: state.tombstones, remote: remote, includeHistory: includeHistory)

        // Carry it out on the main thread, where the store lives, and wait for it.
        var added = 0, removed = 0
        var addedKeys: [String] = []
        DispatchQueue.main.sync {
            for key in plan.remove { if let id = local.ids[key] { store.delete(id); removed += 1 } }
            for item in plan.add {
                switch item.kind {
                case .snippet:
                    if store.addSnippet(title: item.title.isEmpty ? nil : item.title, text: item.text) != nil { added += 1; addedKeys.append(item.key) }
                case .pinned, .history:
                    var clip = NewClip(text: item.text, rich: nil, richFormat: nil, image: nil, imageFormat: nil, imageWidth: nil, imageHeight: nil, files: [], sourceApp: nil, concealed: false)
                    clip.text = item.text
                    if let id = store.record(clip)?.id {
                        if item.kind == .pinned { store.setPinned(id, true) }
                        added += 1
                        if item.kind == .pinned { addedKeys.append(item.key) }
                    }
                }
            }
        }

        // Remember what this Mac holds now, and publish it.
        let nowKeys = durable.subtracting(plan.remove).union(addedKeys)
        state.previousKeys = Array(nowKeys)
        if let data = try? JSONEncoder().encode(state) { UserDefaults.standard.set(data, forKey: Self.stateKey) }
        var publish: [ClipSyncItem] = []
        DispatchQueue.main.sync { publish = self.gather(store).items }
        let file = ClipSyncFile(mac: mac, macID: macID, written: now, items: publish, tombstones: state.tombstones)
        do {
            try ClipSync.encode(file, passphrase: passphrase).write(to: folder.appendingPathComponent(mine), options: .atomic)
        } catch {
            return (false, "Could not write this Mac's file: \(error.localizedDescription)")
        }
        AuditLog.shared.record(.backup, "Clipboard sync: \(added) added, \(removed) removed")
        var message = "Synced: \(added) added, \(removed) removed, \(publish.count) shared."
        if unreadable > 0 { message += " \(unreadable) file\(unreadable == 1 ? "" : "s") could not be read yet (wrong passphrase, or still downloading)." }
        return (true, message)
    }
}
