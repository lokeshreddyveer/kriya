import AppKit

struct DiskEntry: Identifiable, Equatable {
    var id: String { url.path }
    let url: URL
    let name: String
    let size: Int64
    let isFolder: Bool
}

/// Measures what is directly inside a folder, so the disk map can draw it and you can open any folder in it to look deeper. It
/// reads sizes only. Only the Trash button on a tile ever removes anything, and that goes to the Trash.
final class DiskMapScanner: ObservableObject {
    @Published private(set) var entries: [DiskEntry] = []
    @Published private(set) var scanning = false
    @Published private(set) var path: [URL]
    @Published private(set) var skipped = 0

    private let queue = DispatchQueue(label: "app.kriya.diskmap", qos: .utility, attributes: .concurrent)
    private var generation = 0

    init(start: URL = FileManager.default.homeDirectoryForCurrentUser) { path = [start] }

    var current: URL { path.last ?? FileManager.default.homeDirectoryForCurrentUser }
    var total: Int64 { entries.reduce(0) { $0 + $1.size } }

    func open(_ url: URL) { path.append(url); scan() }
    func up() { if path.count > 1 { path.removeLast(); scan() } }
    func go(toIndex i: Int) { guard path.indices.contains(i), i != path.count - 1 else { return }; path = Array(path.prefix(i + 1)); scan() }
    func reset(to url: URL) { path = [url]; scan() }

    func scan() {
        generation += 1
        let mine = generation
        let folder = current
        scanning = true; entries = []; skipped = 0
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .isPackageKey]
        let children = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [])) ?? []
        let group = DispatchGroup()
        let lock = NSLock()
        var found: [DiskEntry] = []
        var failed = 0
        let limit = DispatchSemaphore(value: 6)
        for child in children {
            let v = try? child.resourceValues(forKeys: Set(keys))
            let isDir = v?.isDirectory == true
            if !isDir {
                lock.lock(); found.append(DiskEntry(url: child, name: child.lastPathComponent, size: Int64(v?.fileSize ?? 0), isFolder: false)); lock.unlock()
                continue
            }
            group.enter()
            queue.async {
                limit.wait()
                let bytes = StorageScanner.size(of: child)
                limit.signal()
                lock.lock()
                if let bytes { found.append(DiskEntry(url: child, name: child.lastPathComponent, size: bytes, isFolder: v?.isPackage != true)) } else { failed += 1 }
                lock.unlock()
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self, self.generation == mine else { return }
            self.entries = found.filter { $0.size > 0 }.sorted { $0.size > $1.size }
            self.skipped = failed
            self.scanning = false
        }
    }

    func trash(_ entry: DiskEntry) {
        do { try FileManager.default.trashItem(at: entry.url, resultingItemURL: nil) } catch { Toast().show("“\(entry.name)” could not be moved to the Trash.", isError: true); return }
        entries.removeAll { $0.id == entry.id }
    }
}
