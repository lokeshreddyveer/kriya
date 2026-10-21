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
    /// Called after a restore so every store re-reads what changed.
    var onRestored: () -> Void = {}

    init(core: KriyaCore, folder: URL) {
        self.core = core
        self.folder = folder
        self.iCloudEnabled = UserDefaults.standard.bool(forKey: Self.iCloudKey)
        refreshList()
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
        try json.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        Log.info("Backup", "Settings backed up to \(url.lastPathComponent)")
    }

    func inspect(_ url: URL) throws -> BackupSummary {
        try core.inspectBackup(json: try read(url))
    }

    @discardableResult
    func restore(from url: URL) throws -> BackupSummary {
        let json = try read(url)
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

    private func read(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw CoreError.Backup(message: "the file is not a Kriya backup")
        }
        return text
    }
}
