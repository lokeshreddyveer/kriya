import AppKit
import CryptoKit

/// Looks through a folder for the biggest files and for files that are exact copies of each other. It reads and reports; the
/// only thing it ever removes is a file you press Move to Trash on, and that goes to the Trash, not away.
final class FileCleanupScanner: ObservableObject {
    @Published private(set) var large: [FoundFile] = []
    @Published private(set) var duplicateSets: [[FoundFile]] = []
    @Published private(set) var stale: [FoundFile] = []
    /// How long a file must have gone untouched to be listed as old.
    @Published var staleDays = 365
    @Published private(set) var scanning = false
    @Published private(set) var status = ""
    @Published var folder: URL = FileManager.default.homeDirectoryForCurrentUser

    private let queue = DispatchQueue(label: "app.kriya.cleanup", qos: .utility)
    private var cancelled = false

    var reclaimable: Int64 { DuplicateFinder.reclaimable(duplicateSets) }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.directoryURL = folder
        panel.prompt = "Look Here"
        if panel.runModal() == .OK, let url = panel.url { folder = url; large = []; duplicateSets = []; stale = [] }
    }

    func cancel() { cancelled = true }

    func scan(duplicates: Bool, stale findStale: Bool = false) {
        guard !scanning else { return }
        let staleDays = self.staleDays
        scanning = true; cancelled = false
        status = "Looking through \(folder.lastPathComponent)…"
        let root = folder
        queue.async { [weak self] in
            var files: [FoundFile] = []
            let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .contentAccessDateKey, .isRegularFileKey, .isPackageKey]
            let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]) { _, _ in true }
            while let url = enumerator?.nextObject() as? URL {
                if self?.cancelled == true { break }
                // Libraries and app bundles hold what apps need; copies there are not clutter.
                if url.lastPathComponent == "Library" && url.deletingLastPathComponent() == FileManager.default.homeDirectoryForCurrentUser { enumerator?.skipDescendants(); continue }
                guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true, let size = v.fileSize else { continue }
                files.append(FoundFile(path: url.path, size: Int64(size), modified: v.contentModificationDate, accessed: v.contentAccessDate))
            }
            let large = DuplicateFinder.largest(files, count: 40)
            let old = findStale ? DuplicateFinder.stale(files, olderThanDays: staleDays) : []
            var sets: [[FoundFile]] = []
            if duplicates, self?.cancelled != true {
                let groups = DuplicateFinder.sizeGroups(files)
                for (i, group) in groups.enumerated() {
                    if self?.cancelled == true { break }
                    DispatchQueue.main.async { self?.status = "Comparing \(i + 1) of \(groups.count) groups of same-sized files…" }
                    sets += DuplicateFinder.duplicates(in: group) { Self.fingerprint(of: $0.path) }
                }
                sets.sort { ($0.first?.size ?? 0) * Int64($0.count) > ($1.first?.size ?? 0) * Int64($1.count) }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.large = large
                if findStale { self.stale = old }
                if duplicates { self.duplicateSets = sets }
                self.scanning = false
                self.status = self.cancelled ? "Stopped." : findStale ? "Found \(old.count) old file\(old.count == 1 ? "" : "s")." : duplicates ? "Found \(sets.count) set\(sets.count == 1 ? "" : "s") of copies." : "Done."
            }
        }
    }

    /// A fingerprint of the whole file, read in pieces so a big file is never held in memory.
    static func fingerprint(of path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            guard let chunk = try? handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func trash(_ file: FoundFile) {
        do { try FileManager.default.trashItem(at: URL(fileURLWithPath: file.path), resultingItemURL: nil) } catch { Toast().show("“\(file.name)” could not be moved to the Trash.", isError: true); return }
        large.removeAll { $0.path == file.path }
        duplicateSets = duplicateSets.map { $0.filter { $0.path != file.path } }.filter { $0.count > 1 }
        stale.removeAll { $0.path == file.path }
    }
}
