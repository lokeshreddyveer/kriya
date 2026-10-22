import CommonCrypto
import CryptoKit
import Foundation
import Security

enum BackupCryptoError: Error, Equatable, LocalizedError {
    case needsPassphrase
    case wrongPassphrase
    case damaged
    case tooShort

    var errorDescription: String? {
        switch self {
        case .needsPassphrase: return "This backup is protected with a passphrase."
        case .wrongPassphrase: return "That passphrase does not open this backup."
        case .damaged: return "The backup file is damaged."
        case .tooShort: return "Use at least 8 characters."
        }
    }
}

/// Protecting a backup with a passphrase: the passphrase is stretched into a key (PBKDF2-SHA256), and the backup is sealed
/// with AES-256-GCM. The settings that make the key travel with the file, and are covered by the seal, so changing them
/// makes the file refuse to open.
enum BackupCrypto {
    static let format = "kriya-encrypted-backup"
    static let defaultIterations = 600_000
    static let minimumLength = 8
    private static let allowedIterations = 10_000...5_000_000

    struct Envelope: Codable, Equatable {
        var format: String
        var version: Int
        var kdf: String
        var iterations: Int
        var salt: String
        var sealed: String
    }

    static func isEncrypted(_ data: Data) -> Bool {
        (try? JSONDecoder().decode(Envelope.self, from: data))?.format == format
    }

    static func seal(_ text: String, passphrase: String, iterations: Int = defaultIterations) throws -> Data {
        guard passphrase.count >= minimumLength else { throw BackupCryptoError.tooShort }
        var salt = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, salt.count, &salt) == errSecSuccess else { throw BackupCryptoError.damaged }
        let key = try derive(passphrase, salt: salt, iterations: iterations)
        let box = try AES.GCM.seal(Data(text.utf8), using: key, authenticating: authenticated(iterations: iterations, salt: salt))
        guard let combined = box.combined else { throw BackupCryptoError.damaged }
        let envelope = Envelope(
            format: format, version: 1, kdf: "pbkdf2-sha256", iterations: iterations,
            salt: Data(salt).base64EncodedString(), sealed: combined.base64EncodedString()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(envelope)
    }

    static func open(_ data: Data, passphrase: String) throws -> String {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data), envelope.format == format,
              envelope.version == 1, envelope.kdf == "pbkdf2-sha256", allowedIterations.contains(envelope.iterations),
              let salt = Data(base64Encoded: envelope.salt), let combined = Data(base64Encoded: envelope.sealed) else {
            throw BackupCryptoError.damaged
        }
        let key = try derive(passphrase, salt: [UInt8](salt), iterations: envelope.iterations)
        do {
            let box = try AES.GCM.SealedBox(combined: combined)
            let plain = try AES.GCM.open(box, using: key, authenticating: authenticated(iterations: envelope.iterations, salt: [UInt8](salt)))
            guard let text = String(data: plain, encoding: .utf8) else { throw BackupCryptoError.damaged }
            return text
        } catch let error as BackupCryptoError {
            throw error
        } catch {
            // A wrong passphrase and a changed file both fail the seal; the person can only act on the first.
            throw BackupCryptoError.wrongPassphrase
        }
    }

    private static func authenticated(iterations: Int, salt: [UInt8]) -> Data {
        Data("\(format)|1|pbkdf2-sha256|\(iterations)|".utf8) + Data(salt)
    }

    private static func derive(_ passphrase: String, salt: [UInt8], iterations: Int) throws -> SymmetricKey {
        var key = [UInt8](repeating: 0, count: 32)
        let phrase = Array(passphrase.utf8)
        let status = phrase.withUnsafeBufferPointer { phraseBytes in
            phraseBytes.withMemoryRebound(to: Int8.self) { chars in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2), chars.baseAddress, phrase.count, salt, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations), &key, key.count
                )
            }
        }
        guard status == Int32(kCCSuccess) else { throw BackupCryptoError.damaged }
        return SymmetricKey(data: key)
    }
}

/// Where the backup passphrase is kept, so automatic and iCloud backups can be protected without asking each time. The
/// real one is the login Keychain; a test stands one in, so tests never touch it.
protocol BackupPassphraseStore {
    func load() -> String?
    func save(_ passphrase: String) -> Bool
    func delete()
}

struct KeychainBackupPassphraseStore: BackupPassphraseStore {
    private let service = "app.kriya.backup-passphrase"
    private let account = "backups"

    private var identity: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    func load() -> String? {
        var query = identity
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var found: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess, let data = found as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func save(_ passphrase: String) -> Bool {
        delete()
        var item = identity
        item[kSecValueData as String] = Data(passphrase.utf8)
        // Readable after the first unlock since start-up, so a backup in the background still works with the screen locked.
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        item[kSecAttrSynchronizable as String] = false
        item[kSecAttrLabel as String] = "Kriya backup passphrase"
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    func delete() {
        SecItemDelete(identity as CFDictionary)
    }
}
