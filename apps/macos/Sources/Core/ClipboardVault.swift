import Foundation
import Security

/// Where the clipboard key is kept. The real one is the macOS Keychain; a test stands one in, so tests never touch it.
protocol VaultKeyStore {
    func load() -> Data?
    func save(_ key: Data) -> Bool
    func delete()
}

/// The key in the login Keychain: readable only while the Mac is unlocked, never synced to iCloud, never in a backup.
struct KeychainVaultKeyStore: VaultKeyStore {
    private let service = "app.kriya.clipboard-vault"
    private let account = "history-key"

    private var identity: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    func load() -> Data? {
        var query = identity
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var found: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess else { return nil }
        return found as? Data
    }

    func save(_ key: Data) -> Bool {
        var item = identity
        item[kSecValueData as String] = key
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        item[kSecAttrSynchronizable as String] = false
        item[kSecAttrLabel as String] = "Kriya clipboard history key"
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    func delete() {
        SecItemDelete(identity as CFDictionary)
    }
}

enum VaultKey {
    static let byteCount = 32

    /// A new random key from the system's secure generator.
    static func random() -> Data? {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        return Data(bytes)
    }
}

/// Turning clipboard encryption on and off, and keeping the core supplied with the key. The core does the sealing; this
/// holds the key in the Keychain and tells the interface where things stand.
final class ClipboardVault: ObservableObject {
    @Published private(set) var status: VaultStatus?
    @Published private(set) var isWorking = false

    private let core: KriyaCore
    private let keyStore: VaultKeyStore

    /// The key store is only asked for the key when history is already encrypted, so a fresh install or a test that never
    /// turns encryption on never touches it.
    init(core: KriyaCore, keyStore: VaultKeyStore) {
        self.core = core
        self.keyStore = keyStore
        refresh(loadKey: true)
    }

    var isEncrypted: Bool { status?.enabled ?? false }
    /// Encrypted, but the key is not here: nothing can be read or saved.
    var isLocked: Bool { (status?.enabled ?? false) && !(status?.keyReady ?? false) }

    /// Reads where the core stands, and hands it the key when history is encrypted and it does not have it yet.
    func refresh(loadKey: Bool = false) {
        var current = try? core.clipVaultStatus()
        if loadKey, current?.enabled == true, current?.keyReady == false, let key = keyStore.load() {
            current = (try? core.clipVaultSetKey(key: key)) ?? current
        }
        status = current
    }

    /// Makes (or finds) the key, encrypts everything already saved and turns encryption on. `completion` gets nil on
    /// success, or what went wrong.
    func turnOn(completion: @escaping (String?) -> Void) {
        guard !isWorking, !isEncrypted else { completion(nil); return }
        isWorking = true
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            var failure: String?
            let existing = keyStore.load()
            let key = existing ?? VaultKey.random()
            if let key, existing != nil || keyStore.save(key), keyStore.load() == key {
                do {
                    _ = try core.clipVaultSetKey(key: key)
                    _ = try core.clipVaultEnable()
                } catch {
                    failure = error.userMessage
                }
            } else {
                failure = "Kriya could not keep the encryption key in your Keychain, so nothing was changed."
            }
            if failure != nil, existing == nil {
                keyStore.delete()
                _ = try? core.clipVaultSetKey(key: nil)
            }
            DispatchQueue.main.async {
                self.isWorking = false
                self.refresh()
                if failure == nil { Log.info("Clipboard", "History encryption turned on") }
                completion(failure)
            }
        }
    }

    /// Opens everything back into plain storage, turns encryption off and removes the key.
    func turnOff(completion: @escaping (String?) -> Void) {
        guard !isWorking, isEncrypted else { completion(nil); return }
        isWorking = true
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            var failure: String?
            do {
                if (try core.clipVaultStatus()).keyReady == false, let key = keyStore.load() { _ = try core.clipVaultSetKey(key: key) }
                _ = try core.clipVaultDisable()
                keyStore.delete()
                _ = try core.clipVaultSetKey(key: nil)
            } catch {
                failure = error.userMessage
            }
            DispatchQueue.main.async {
                self.isWorking = false
                self.refresh()
                if failure == nil { Log.info("Clipboard", "History encryption turned off") }
                completion(failure)
            }
        }
    }

    /// For a lost key: deletes the history that can no longer be opened and starts again without encryption.
    func startAgain(completion: @escaping (String?) -> Void) {
        guard !isWorking else { completion(nil); return }
        isWorking = true
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            var failure: String?
            do {
                _ = try core.clipVaultReset()
                keyStore.delete()
            } catch {
                failure = error.userMessage
            }
            DispatchQueue.main.async {
                self.isWorking = false
                self.refresh()
                completion(failure)
            }
        }
    }
}
