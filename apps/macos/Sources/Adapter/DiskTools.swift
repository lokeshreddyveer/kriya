import AppKit
import CryptoKit
import QuickLookUI

/// The pieces of the disk map that talk to macOS: volumes, snapshots, permissions, a deep look at files, history and previews.
enum DiskTools {
    // MARK: Volumes and snapshots

    static func volumeReport(for url: URL = URL(fileURLWithPath: "/")) -> VolumeReport? {
        let keys: Set<URLResourceKey> = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let v = try? url.resourceValues(forKeys: keys), let total = v.volumeTotalCapacity else { return nil }
        let available = Int64(v.volumeAvailableCapacity ?? 0)
        return VolumeReport(name: v.volumeName ?? url.lastPathComponent, total: Int64(total), available: available,
                            availableForImportant: v.volumeAvailableCapacityForImportantUsage ?? available)
    }

    /// Volumes a person might want to look at: the startup disk and anything mounted that is a real disk, not a network share.
    static func mountedVolumes() -> [URL] {
        let keys: [URLResourceKey] = [.volumeIsLocalKey, .volumeIsInternalKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.filter { (try? $0.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal) ?? false }
    }

    /// Time Machine's local snapshots on the startup disk. They hold room macOS gives back when it needs it.
    static func localSnapshots() -> [String] {
        guard let out = run("/usr/bin/tmutil", ["listlocalsnapshots", "/"]) else { return [] }
        return SnapshotList.parse(out)
    }

    static func run(_ tool: String, _ arguments: [String], timeout: TimeInterval = 20) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: tool)
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return nil }
        let stop = DispatchWorkItem { if task.isRunning { task.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: stop)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        stop.cancel()
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Permissions

    /// Whether Kriya has Full Disk Access, found by trying to read a file macOS only lets such apps read.
    static var hasFullDiskAccess: Bool {
        for path in ["/Library/Application Support/com.apple.TCC/TCC.db", NSHomeDirectory() + "/Library/Safari/History.db"] where FileManager.default.fileExists(atPath: path) {
            let fd = open(path, O_RDONLY)
            if fd >= 0 { close(fd); return true }
            if errno == EPERM || errno == EACCES { return false }
        }
        return false
    }

    static func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") { NSWorkspace.shared.open(url) }
    }

    /// Sizes of folders measured with administrator rights, after one password prompt, so system folders Kriya cannot read as
    /// itself are counted. Returns nothing if the prompt is cancelled.
    static func sizesAsAdministrator(of urls: [URL], timeout: TimeInterval = 900) -> [String: Int64] {
        guard !urls.isEmpty else { return [:] }
        func literal(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        let args = urls.map { "quoted form of " + literal($0.path) }.joined(separator: " & \" \" & ")
        let script = "do shell script \"/usr/bin/du -skx \" & " + args + " & \" 2>/dev/null; true\" with administrator privileges"
        guard let out = run("/usr/bin/osascript", ["-e", script], timeout: timeout) else { return [:] }
        var sizes: [String: Int64] = [:]
        for line in out.replacingOccurrences(of: "\r", with: "\n").split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1)
            if parts.count == 2, let kb = Int64(parts[0]) { sizes[String(parts[1])] = kb * 1024 }
        }
        return sizes
    }

    // MARK: Content fingerprint

    /// SHA-256 of a file's contents, read in pieces so a big file never sits in memory. Nil if it cannot be read.
    static func sha256(of path: String, cancelled: () -> Bool = { false }) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            if cancelled() { return nil }
            // read(upToCount:) gives nil at the end of the file, and throws when the file cannot be read.
            do {
                guard let chunk = try handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty else { break }
                hasher.update(data: chunk)
            } catch { return nil }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: History

    private static var historyFile: URL { AppPaths.live.support.appendingPathComponent("diskmap-history.json") }

    static func history() -> [ScanRecord] {
        guard let data = try? Data(contentsOf: historyFile) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([ScanRecord].self, from: data)) ?? []
    }

    /// Keeps the last 20 readings of each folder.
    static func record(_ record: ScanRecord) {
        var all = history()
        all.append(record)
        var kept: [ScanRecord] = []
        var count: [String: Int] = [:]
        for r in all.sorted(by: { $0.date > $1.date }) where count[r.path, default: 0] < 20 { count[r.path, default: 0] += 1; kept.append(r) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: AppPaths.live.support, withIntermediateDirectories: true)
        if let data = try? encoder.encode(kept.sorted { $0.date < $1.date }) { try? data.write(to: historyFile, options: .atomic) }
    }

    static func forgetHistory(for path: String) {
        let kept = history().filter { $0.path != path }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(kept) { try? data.write(to: historyFile, options: .atomic) }
    }

    // MARK: Preview

    static func quickLook(_ urls: [URL]) { QuickLookCoordinator.shared.show(urls) }
}

/// Feeds Quick Look the files to show. The system panel is shared, so this keeps what it should show until it is closed.
final class QuickLookCoordinator: NSObject, QLPreviewPanelDataSource {
    static let shared = QuickLookCoordinator()
    private var items: [URL] = []

    func show(_ urls: [URL]) {
        guard !urls.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        items = urls
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { items.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { items[index] as NSURL }
}

/// A deep look at everything under a folder: the biggest files, and every file big enough to matter for duplicates and old files.
final class DiskDeepScanner: ObservableObject {
    @Published private(set) var largest: [DiskFile] = []
    @Published private(set) var candidates: [DiskFile] = []
    @Published private(set) var scanning = false
    @Published private(set) var visited = 0
    @Published private(set) var unreadable = 0
    @Published private(set) var scannedAt: Date?
    @Published private(set) var root: URL?

    private var generation = 0
    private let queue = DispatchQueue(label: "app.kriya.diskdeep", qos: .utility)
    static let keepLargest = 300
    static let candidateFloor: Int64 = 1_000_000
    static let candidateCap = 60_000

    func stop() { generation += 1; scanning = false }

    /// Drops files that were moved to the Trash so the lists stop showing them.
    func forget(_ paths: Set<String>) {
        func gone(_ file: DiskFile) -> Bool { paths.contains { DiskRisk.isInside(file.path, $0) } }
        largest.removeAll(where: gone)
        candidates.removeAll(where: gone)
    }

    func scan(_ folder: URL, includeCloud: Bool = false) {
        generation += 1
        let mine = generation
        scanning = true; largest = []; candidates = []; visited = 0; unreadable = 0; root = folder
        queue.async { [weak self] in
            let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileSizeKey, .contentModificationDateKey, .volumeIdentifierKey]
            var failed = 0
            guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in failed += 1; return true }) else {
                DispatchQueue.main.async { self?.scanning = false }
                return
            }
            let rootVolume = try? folder.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject
            var top: [DiskFile] = []
            var big: [DiskFile] = []
            var count = 0
            var last = Date.distantPast
            func publish(final: Bool) {
                top.sort { $0.allocated > $1.allocated }
                if top.count > Self.keepLargest * 2 { top = Array(top.prefix(Self.keepLargest)) }
                let shown = Array(top.prefix(Self.keepLargest)), pool = big, seen = count, bad = failed
                DispatchQueue.main.async {
                    guard let self, self.generation == mine else { return }
                    self.largest = shown; self.visited = seen; self.unreadable = bad
                    if final { self.candidates = pool; self.scannedAt = Date(); self.scanning = false }
                }
            }
            while let item = walker.nextObject() as? URL {
                if self?.generation != mine { return }
                guard let v = try? item.resourceValues(forKeys: Set(keys)) else { failed += 1; continue }
                if v.isSymbolicLink == true { walker.skipDescendants(); continue }
                if v.isDirectory == true {
                    if (!includeCloud && StorageScanner.isRemoteOrCloud(item)) || (rootVolume != nil && (v.volumeIdentifier as? NSObject) != rootVolume) { walker.skipDescendants() }
                    continue
                }
                guard v.isRegularFile == true else { continue }
                count += 1
                let allocated = Int64(v.totalFileAllocatedSize ?? v.fileSize ?? 0)
                let file = DiskFile(path: item.path, allocated: allocated, logical: Int64(v.fileSize ?? 0), modified: v.contentModificationDate)
                if allocated >= Self.candidateFloor / 4 { top.append(file) }
                if allocated >= Self.candidateFloor, big.count < Self.candidateCap { big.append(file) }
                if Date().timeIntervalSince(last) > 0.5 { last = Date(); publish(final: false) }
            }
            publish(final: true)
        }
    }
}
