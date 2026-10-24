import AppKit

/// A copy of an app kept before it is replaced, so the old version can be put back. Copies live in Kriya's own folder and only the
/// newest two of each app are kept.
enum AppBackup {
    struct Entry: Identifiable, Equatable {
        let id: String
        let folder: URL
        let appName: String
        let version: String
        let originalPath: String
        let date: Date
    }

    private struct Meta: Codable { var originalPath: String; var appName: String; var version: String; var date: Date }

    static var root: URL { AppPaths.live.support.appendingPathComponent("App Backups", isDirectory: true) }
    static let maxBytes: Int64 = 3_000_000_000

    /// Copies the app into the backup folder. Nil when it is too big, cannot be copied, or there is no room to spare.
    @discardableResult
    static func backup(_ app: InstalledApp, bytes: Int64?) -> Entry? {
        let fm = FileManager.default
        if let bytes, bytes > maxBytes { return nil }
        let free = (try? root.deletingLastPathComponent().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage) ?? 0
        if let bytes, free > 0, free < bytes * 2 { return nil }
        let name = AppBackupNaming.folderName(app: app.name, version: app.version, at: Date())
        let folder = root.appendingPathComponent(name, isDirectory: true)
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            // ditto keeps signatures, links and extended attributes intact, which a plain copy can break.
            _ = try ToolRunner.run("/usr/bin/ditto", [app.url.path, folder.appendingPathComponent(app.url.lastPathComponent).path], timeout: 600)
            let meta = Meta(originalPath: app.url.path, appName: app.name, version: app.version, date: Date())
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(meta).write(to: folder.appendingPathComponent("backup.json"))
        } catch {
            try? fm.removeItem(at: folder)
            return nil
        }
        prune()
        return Entry(id: name, folder: folder, appName: app.name, version: app.version, originalPath: app.url.path, date: Date())
    }

    static func list() -> [Entry] {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.compactMap { name -> Entry? in
            let folder = root.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("backup.json")), let m = try? decoder.decode(Meta.self, from: data) else { return nil }
            return Entry(id: name, folder: folder, appName: m.appName, version: m.version, originalPath: m.originalPath, date: m.date)
        }.sorted { $0.date > $1.date }
    }

    static func prune() {
        for id in AppBackupNaming.expired(list().map { ($0.id, $0.appName, $0.date) }) { try? FileManager.default.removeItem(at: root.appendingPathComponent(id)) }
    }

    /// Puts the saved copy back where the app was. What is there now goes to the Trash first, so even a restore can be undone.
    static func restore(_ entry: Entry) -> String? {
        let fm = FileManager.default
        let saved = entry.folder.appendingPathComponent((entry.originalPath as NSString).lastPathComponent)
        guard fm.fileExists(atPath: saved.path) else { return "The saved copy is gone." }
        let target = URL(fileURLWithPath: entry.originalPath)
        for running in NSRunningApplication.runningApplications(withBundleIdentifier: Bundle(url: target)?.bundleIdentifier ?? "") { running.terminate() }
        if fm.fileExists(atPath: target.path) {
            do { try fm.trashItem(at: target, resultingItemURL: nil) } catch { return "The current version could not be moved to the Trash: \(error.localizedDescription)" }
        }
        do { _ = try ToolRunner.run("/usr/bin/ditto", [saved.path, target.path], timeout: 600) } catch { return "Could not copy the saved version back: \((error as? FileActionError)?.message ?? error.localizedDescription)" }
        return nil
    }
}
