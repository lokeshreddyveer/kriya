import Foundation

/// Where Kriya keeps its files. Tests pass their own folders so they never touch the real data.
struct AppPaths {
    let support: URL
    let logs: URL

    var backups: URL { support.appendingPathComponent("Backups", isDirectory: true) }
    var logFile: URL { logs.appendingPathComponent("kriya.log") }
    var crashSignalLog: URL { logs.appendingPathComponent("crash-signal.log") }

    static let live: AppPaths = {
        let fm = FileManager.default
        #if DEBUG
        // Screenshot and test runs of a debug build use a throwaway folder, never the real saved data.
        if let override = ProcessInfo.processInfo.environment["KRIYA_DATA_DIR"] {
            let root = URL(fileURLWithPath: override, isDirectory: true)
            return AppPaths(support: root.appendingPathComponent("Support", isDirectory: true), logs: root.appendingPathComponent("Logs", isDirectory: true))
        }
        #endif
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kriya", isDirectory: true)
        let logs = fm.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Kriya", isDirectory: true)
        return AppPaths(support: support, logs: logs)
    }()

    /// Private to the person: nothing in these folders is meant for other accounts on the Mac.
    func createDirectories() {
        let attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        for url in [support, logs, backups] {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: attributes)
        }
    }
}
