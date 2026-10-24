import AppKit
import Security

/// Kept apart from the backup passphrase, in the login Keychain.
struct KeychainSharedClipboardPassphraseStore: BackupPassphraseStore {
    private let service = "app.kriya.shared-clipboard"
    private var identity: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "passphrase"] }

    func load() -> String? {
        var q = identity
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var found: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &found) == errSecSuccess, let d = found as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    func save(_ passphrase: String) -> Bool {
        delete()
        var item = identity
        item[kSecValueData as String] = Data(passphrase.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        item[kSecAttrSynchronizable as String] = false
        item[kSecAttrLabel as String] = "Kriya shared clipboard passphrase"
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    func delete() { SecItemDelete(identity as CFDictionary) }
}

/// Sends the clipboard's text to your other Macs on request, and tells you when one arrives. Nothing is sent unless you ask,
/// everything is sealed with a passphrase you set on each Mac, and the shared files are removed after ten minutes.
final class SharedClipboardService: ObservableObject {
    static let enabledKey = "sharedClipboard.enabled"
    static let autoKey = "sharedClipboard.autoReceive"
    private static let deviceKey = "sharedClipboard.device"
    private static let iterations = 100_000

    @Published var enabled: Bool { didSet { UserDefaults.standard.set(enabled, forKey: Self.enabledKey); schedule() } }
    @Published var autoReceive: Bool { didSet { UserDefaults.standard.set(autoReceive, forKey: Self.autoKey) } }
    @Published private(set) var pending: SharedClipboard.Payload?
    @Published private(set) var hasPassphrase: Bool

    private let passphrases: BackupPassphraseStore
    private let toast = Toast()
    private var timer: Timer?
    private var seen = Date()
    private let queue = DispatchQueue(label: "app.kriya.sharedclip", qos: .utility)
    /// Called with text that arrived and was taken automatically. Set by the app so the clipboard monitor does not record it twice.
    var onReceived: (String) -> Void = { _ in }

    let deviceID: String
    var deviceName: String { Host.current().localizedName ?? "this Mac" }
    var folder: URL? {
        let drive = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        guard FileManager.default.fileExists(atPath: drive.path) else { return nil }
        return drive.appendingPathComponent("Kriya Clipboard", isDirectory: true)
    }
    var isAvailable: Bool { folder != nil }

    init(passphrases: BackupPassphraseStore = KeychainSharedClipboardPassphraseStore()) {
        self.passphrases = passphrases
        let d = UserDefaults.standard
        enabled = d.bool(forKey: Self.enabledKey)
        autoReceive = d.bool(forKey: Self.autoKey)
        if let id = d.string(forKey: Self.deviceKey) { deviceID = id } else { deviceID = UUID().uuidString.prefix(8).lowercased(); d.set(deviceID, forKey: Self.deviceKey) }
        hasPassphrase = passphrases.load() != nil
    }

    func start() { schedule() }

    func stop() { timer?.invalidate(); timer = nil }

    func setPassphrase(_ text: String) -> String? {
        guard text.count >= BackupCrypto.minimumLength else { return BackupCryptoError.tooShort.errorDescription }
        guard passphrases.save(text) else { return "The passphrase could not be saved in your Keychain." }
        hasPassphrase = true
        return nil
    }

    func clearPassphrase() { passphrases.delete(); hasPassphrase = false }

    private func schedule() {
        timer?.invalidate(); timer = nil
        guard enabled else { return }
        seen = Date()
        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: Sending

    func send() {
        guard enabled else { toast.show("Turn on Shared Clipboard in Settings › Clipboard first.", isError: true); return }
        guard let phrase = passphrases.load() else { toast.show("Set a passphrase for Shared Clipboard first.", isError: true); return }
        guard let folder else { toast.show("iCloud Drive is off on this Mac.", isError: true); return }
        let text = NSPasteboard.general.string(forType: .string)
        guard SharedClipboard.isSendable(text), let text else { toast.show("The clipboard has no text to send (or it is too long).", isError: true); return }
        let payload = SharedClipboard.Payload(from: deviceName, text: text)
        let device = deviceID
        queue.async { [toast] in
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let json = String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
                let data = try BackupCrypto.seal(json, passphrase: phrase, iterations: Self.iterations)
                try data.write(to: folder.appendingPathComponent(SharedClipboard.fileName(deviceID: device, at: Date())), options: .atomic)
                DispatchQueue.main.async { toast.show("Sent to your other Macs") }
            } catch {
                DispatchQueue.main.async { toast.show("The clipboard could not be sent.", isError: true) }
            }
        }
    }

    // MARK: Receiving

    private func poll() {
        guard enabled, let folder, let phrase = passphrases.load() else { return }
        let me = deviceID, since = seen
        queue.async { [weak self] in
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            for old in SharedClipboard.expired(names, now: Date()) { try? FileManager.default.removeItem(at: folder.appendingPathComponent(old)) }
            guard let name = SharedClipboard.newestForMe(names, myID: me, after: since, now: Date()), let date = SharedClipboard.parse(name)?.date,
                  let data = try? Data(contentsOf: folder.appendingPathComponent(name)),
                  let json = try? BackupCrypto.open(data, passphrase: phrase), let payload = try? JSONDecoder().decode(SharedClipboard.Payload.self, from: Data(json.utf8)) else { return }
            DispatchQueue.main.async { self?.arrived(payload, at: date) }
        }
    }

    private func arrived(_ payload: SharedClipboard.Payload, at date: Date) {
        seen = date
        if autoReceive { take(payload); toast.show("Clipboard from \(payload.from): \(SharedClipboard.preview(payload.text))") }
        else {
            pending = payload
            toast.show("\(payload.from) sent: \(SharedClipboard.preview(payload.text)). Choose “Paste from other Mac” in the launcher.")
        }
    }

    /// Puts the waiting text on this Mac's clipboard.
    func receive() {
        guard let p = pending else { toast.show("Nothing has arrived from another Mac.", isError: true); return }
        take(p)
        pending = nil
        toast.show("Copied from \(p.from)")
    }

    private func take(_ payload: SharedClipboard.Payload) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(payload.text, forType: .string)
        onReceived(payload.text)
    }
}
