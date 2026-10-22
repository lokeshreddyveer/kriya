import Combine
import Foundation

struct BackupFileInfo: Identifiable, Equatable {
    let url: URL
    let date: Date
    var id: URL { url }
    var name: String { url.lastPathComponent }
}

/// Backing up and restoring settings. The core writes and validates the backup; this class handles the files.
/// A restore always saves the current settings first, so it can be undone from the list of automatic backups.
final class BackupManager: ObservableObject {
    static let fileExtension = "kriyabackup"
    private static let keptAutomaticBackups = 10

    @Published private(set) var automaticBackups: [BackupFileInfo] = []
    @Published private(set) var iCloudBackups: [BackupFileInfo] = []
    @Published private(set) var lastICloudBackup: Date?
    /// Backups are sealed with a passphrase kept in the Keychain.
    @Published private(set) var isProtected = false
    @Published var iCloudEnabled: Bool {
        didSet {
            UserDefaults.standard.set(iCloudEnabled, forKey: Self.iCloudKey)
            if iCloudEnabled { backUpToICloudQuietly() } else { timer?.invalidate(); timer = nil }
            startICloud()
        }
    }

    private static let iCloudKey = "iCloudBackupEnabled"
    private static let iCloudInterval: TimeInterval = 3600
    private var timer: Timer?

    /// iCloud Drive's folder for Kriya, or nil when iCloud Drive is not turned on for this Mac.
    static var iCloudFolder: URL? {
        let drive = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        guard FileManager.default.fileExists(atPath: drive.path) else { return nil }
        return drive.appendingPathComponent("Kriya Backups", isDirectory: true)
    }

    var iCloudAvailable: Bool { Self.iCloudFolder != nil }

    private let core: KriyaCore
    private let folder: URL
    private let passphrases: BackupPassphraseStore
    /// Called after a restore so every store re-reads what changed.
    var onRestored: () -> Void = {}

    /// `passphrases` is where the protection passphrase lives. A test passes its own, so the real Keychain is never used.
    init(core: KriyaCore, folder: URL, passphrases: BackupPassphraseStore = KeychainBackupPassphraseStore()) {
        self.core = core
        self.folder = folder
        self.passphrases = passphrases
        self.iCloudEnabled = UserDefaults.standard.bool(forKey: Self.iCloudKey)
        isProtected = passphrases.load() != nil
        refreshList()
    }

    // MARK: Protection

    /// Seals every backup from now on, and seals the ones already saved here and in iCloud Drive.
    func protect(with passphrase: String) throws {
        guard passphrase.count >= BackupCrypto.minimumLength else { throw BackupCryptoError.tooShort }
        guard passphrases.save(passphrase) else {
            throw CoreError.Backup(message: "Kriya could not keep the passphrase in your Keychain, so backups were not protected")
        }
        isProtected = true
        sealExistingBackups(passphrase: passphrase)
        Log.info("Backup", "Backups are now protected with a passphrase")
    }

    /// Goes back to plain backups from now on. Backups already sealed still need the passphrase to open.
    func stopProtecting() {
        passphrases.delete()
        isProtected = false
        Log.info("Backup", "Backup protection turned off")
    }

    private func sealExistingBackups(passphrase: String) {
        refreshList()
        refreshICloudList()
        for file in automaticBackups + iCloudBackups {
            guard let data = try? Data(contentsOf: file.url), !BackupCrypto.isEncrypted(data), let text = String(data: data, encoding: .utf8),
                  let sealed = try? BackupCrypto.seal(text, passphrase: passphrase) else { continue }
            try? sealed.write(to: file.url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.url.path)
        }
    }

    // MARK: iCloud Drive

    /// Keeps one backup per Mac in iCloud Drive, refreshed every hour and when Kriya quits. Another Mac can restore it.
    func startICloud() {
        refreshICloudList()
        guard iCloudEnabled, timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.iCloudInterval, repeats: true) { [weak self] _ in
            self?.backUpToICloudQuietly()
        }
        if lastICloudBackup == nil || Date().timeIntervalSince(lastICloudBackup ?? .distantPast) > Self.iCloudInterval {
            backUpToICloudQuietly()
        }
    }

    func flushICloud() {
        if iCloudEnabled { backUpToICloudQuietly() }
    }

    func backUpToICloud() throws {
        guard let folder = Self.iCloudFolder else {
            throw CoreError.Backup(message: "iCloud Drive is not turned on for this Mac")
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let host = (Host.current().localizedName ?? "Mac").replacingOccurrences(of: "/", with: "-")
        try export(to: folder.appendingPathComponent("Kriya – \(host).\(Self.fileExtension)"))
        lastICloudBackup = Date()
        refreshICloudList()
    }

    private func backUpToICloudQuietly() {
        do { try backUpToICloud() } catch { Log.warning("Backup", "iCloud backup failed: \(error.userMessage)") }
    }

    func refreshICloudList() {
        guard let folder = Self.iCloudFolder else { iCloudBackups = []; return }
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        )) ?? []
        iCloudBackups = urls
            .filter { $0.pathExtension == Self.fileExtension }
            .map { url in
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return BackupFileInfo(url: url, date: date)
            }
            .sorted { $0.date > $1.date }
    }

    func export(to url: URL) throws {
        let json = try core.exportBackup(appVersion: SystemInfo.appVersion, now: SystemInfo.nowSeconds)
        let data: Data
        if let phrase = passphrases.load() {
            data = try BackupCrypto.seal(json, passphrase: phrase)
        } else {
            data = Data(json.utf8)
        }
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        Log.info("Backup", "Settings backed up to \(url.lastPathComponent)\(isProtected ? " (protected)" : "")")
    }

    /// `passphrase` is for a backup protected with a passphrase this Mac does not hold. Without it, the stored one is used.
    func inspect(_ url: URL, passphrase: String? = nil) throws -> BackupSummary {
        try core.inspectBackup(json: try read(url, passphrase: passphrase))
    }

    @discardableResult
    func restore(from url: URL, passphrase: String? = nil) throws -> BackupSummary {
        let json = try read(url, passphrase: passphrase)
        _ = try core.inspectBackup(json: json)     // refuse a bad file before touching anything
        try writeAutomaticBackup(reason: "before-restore")
        let summary = try core.importBackup(json: json)
        Log.info("Backup", "Restored \(url.lastPathComponent)")
        onRestored()
        refreshList()
        return summary
    }

    func writeAutomaticBackup(reason: String) throws {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = folder.appendingPathComponent("auto-\(reason)-\(stamp).\(Self.fileExtension)")
        try export(to: url)
        pruneAutomaticBackups()
        refreshList()
    }

    func refreshList() {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        )) ?? []
        automaticBackups = urls
            .filter { $0.pathExtension == Self.fileExtension && $0.lastPathComponent.hasPrefix("auto-") }
            .map { url in
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return BackupFileInfo(url: url, date: date)
            }
            .sorted { $0.date > $1.date }
    }

    private func pruneAutomaticBackups() {
        refreshList()
        for old in automaticBackups.dropFirst(Self.keptAutomaticBackups) {
            try? FileManager.default.removeItem(at: old.url)
        }
    }

    private func read(_ url: URL, passphrase: String?) throws -> String {
        let data = try Data(contentsOf: url)
        if BackupCrypto.isEncrypted(data) {
            guard let phrase = passphrase ?? passphrases.load() else { throw BackupCryptoError.needsPassphrase }
            // The stored passphrase may be an old one; ask for the right one rather than fail.
            do { return try BackupCrypto.open(data, passphrase: phrase) } catch BackupCryptoError.wrongPassphrase where passphrase == nil { throw BackupCryptoError.needsPassphrase }
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw CoreError.Backup(message: "the file is not a Kriya backup")
        }
        return text
    }
}
