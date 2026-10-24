import AppKit

struct DiskEntry: Identifiable, Equatable {
    var id: String { url.path }
    let url: URL
    let name: String
    let size: Int64
    let isFolder: Bool
    var modified: Date? = nil
    /// A link to somewhere else: shown, but never opened into or measured for what it points at.
    var isLink = false
}

/// Why a folder shows nothing, so the pane can say the real reason instead of one vague line.
enum DiskMapIssue: Equatable {
    case empty
    case permissionDenied
    case disappeared
    case timedOut(Int)
    case cloudOnly
}

/// Measures what is directly inside a folder, so the disk map can draw it and you can open any folder in it to look deeper. It
/// reads sizes only. Only a Trash action ever removes anything, and that goes to the Trash where it can be put back.
final class DiskMapScanner: ObservableObject {
    @Published private(set) var entries: [DiskEntry] = []
    @Published private(set) var scanning = false
    @Published private(set) var path: [URL]
    @Published private(set) var skipped = 0
    @Published private(set) var issue: DiskMapIssue?
    @Published private(set) var scannedAt: Date?
    /// What the last Trash action moved, so it can be put back.
    @Published private(set) var lastTrashed: [(original: URL, trash: URL)] = []
    @Published var includeCloud = false
    @Published var asAdministrator = false

    private let queue = DispatchQueue(label: "app.kriya.diskmap", qos: .utility, attributes: .concurrent)
    private var generation = 0

    init(start: URL = FileManager.default.homeDirectoryForCurrentUser) { path = [start] }

    var current: URL { path.last ?? FileManager.default.homeDirectoryForCurrentUser }
    var total: Int64 { entries.reduce(0) { $0 + $1.size } }

    func open(_ url: URL) {
        // A link that leads out of the folder is not followed.
        if DiskPaths.escapes(url, root: current) { Toast().show("“\(url.lastPathComponent)” is a link to somewhere else, so Kriya does not follow it.", isError: true); return }
        path.append(url); scan()
    }
    func up() { if path.count > 1 { path.removeLast(); scan() } }
    func go(toIndex i: Int) { guard path.indices.contains(i), i != path.count - 1 else { return }; path = Array(path.prefix(i + 1)); scan() }
    func reset(to url: URL) { path = [url]; scan() }

    /// How many of the folder's items have been measured, so the pane can say how far along it is.
    @Published private(set) var measured = 0
    @Published private(set) var itemCount = 0
    /// What is being measured now, for the status line.
    @Published private(set) var measuring = ""
    /// Items not measured because they are cloud or network places.
    @Published private(set) var notMeasured = 0

    /// Stops measuring; what has been measured so far stays on the map.
    func stop() {
        generation += 1
        scanning = false
        measuring = ""
    }

    func scan() {
        generation += 1
        let mine = generation
        let folder = current
        let cloud = includeCloud, admin = asAdministrator
        scanning = true; entries = []; skipped = 0; notMeasured = 0; measured = 0; itemCount = 0; measuring = ""; issue = nil
        // Reading the folder and measuring each item happen off the main thread; each result is shown as it arrives, so one slow
        // folder never holds the rest back.
        queue.async { [weak self] in
            let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .totalFileAllocatedSizeKey, .isPackageKey, .isSymbolicLinkKey, .contentModificationDateKey]
            let children: [URL]
            do { children = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: []) } catch {
                let code = (error as NSError).code
                let found: DiskMapIssue = code == NSFileNoSuchFileError || code == NSFileReadNoSuchFileError ? .disappeared : .permissionDenied
                DispatchQueue.main.async { guard let self, self.generation == mine else { return }; self.issue = found; self.scanning = false }
                return
            }
            DispatchQueue.main.async { guard let self, self.generation == mine else { return }; self.itemCount = children.count }
            if children.isEmpty { DispatchQueue.main.async { guard let self, self.generation == mine else { return }; self.issue = .empty; self.scanning = false }; return }
            let lock = NSLock()
            var found: [DiskEntry] = []
            var failed = 0, remote = 0, done = 0
            var lastPublish = Date.distantPast
            let group = DispatchGroup()
            let limit = DispatchSemaphore(value: 6)
            func publish(force: Bool = false) {
                lock.lock()
                let now = Date()
                guard force || now.timeIntervalSince(lastPublish) > 0.25 else { lock.unlock(); return }
                lastPublish = now
                let snapshot = found.filter { $0.size > 0 }.sorted { $0.size > $1.size }
                let counts = (failed, remote, done)
                lock.unlock()
                DispatchQueue.main.async {
                    guard let self, self.generation == mine else { return }
                    self.entries = snapshot
                    self.skipped = counts.0; self.notMeasured = counts.1; self.measured = counts.2
                }
            }
            // One password prompt measures every folder with administrator rights, for system places Kriya cannot read itself.
            var adminSizes: [String: Int64] = [:]
            if admin {
                let folders = children.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]))?.isDirectory == true && !StorageScanner.isRemoteOrCloud($0) }
                DispatchQueue.main.async { guard let self, self.generation == mine else { return }; self.measuring = "waiting for your password" }
                adminSizes = DiskTools.sizesAsAdministrator(of: folders)
            }
            for child in children {
                if self?.generation != mine { return }
                let v = try? child.resourceValues(forKeys: Set(keys))
                let modified = v?.contentModificationDate
                if v?.isSymbolicLink == true {
                    lock.lock(); found.append(DiskEntry(url: child, name: child.lastPathComponent, size: Int64(v?.totalFileAllocatedSize ?? v?.fileSize ?? 0), isFolder: false, modified: modified, isLink: true)); done += 1; lock.unlock()
                    continue
                }
                if v?.isDirectory != true {
                    lock.lock(); found.append(DiskEntry(url: child, name: child.lastPathComponent, size: Int64(v?.totalFileAllocatedSize ?? v?.fileSize ?? 0), isFolder: false, modified: modified)); done += 1; lock.unlock()
                    continue
                }
                if !cloud, StorageScanner.isRemoteOrCloud(child) {
                    lock.lock(); remote += 1; done += 1; lock.unlock()
                    continue
                }
                if let bytes = adminSizes[child.path] {
                    lock.lock(); found.append(DiskEntry(url: child, name: child.lastPathComponent, size: bytes, isFolder: v?.isPackage != true, modified: modified)); done += 1; lock.unlock()
                    continue
                }
                group.enter()
                self?.queue.async {
                    defer { group.leave() }
                    limit.wait()
                    defer { limit.signal() }
                    if self?.generation != mine { return }
                    DispatchQueue.main.async { if self?.generation == mine { self?.measuring = child.lastPathComponent } }
                    let bytes = StorageScanner.size(of: child)
                    lock.lock()
                    if let bytes { found.append(DiskEntry(url: child, name: child.lastPathComponent, size: bytes, isFolder: v?.isPackage != true, modified: modified)) } else { failed += 1 }
                    done += 1
                    lock.unlock()
                    publish()
                }
            }
            publish(force: true)
            group.notify(queue: .main) {
                guard let self, self.generation == mine else { return }
                publish(force: true)
                DispatchQueue.main.async {
                    guard self.generation == mine else { return }
                    self.scanning = false
                    self.measuring = ""
                    self.scannedAt = Date()
                    if self.entries.isEmpty { self.issue = self.notMeasured > 0 ? .cloudOnly : (self.skipped > 0 ? .timedOut(self.skipped) : .empty) }
                    else { DiskTools.record(ScanRecord(date: Date(), path: folder.path, total: self.total, items: self.entries.prefix(60).map { .init(name: $0.name, size: $0.size) })) }
                }
            }
        }
    }

    /// Moves items to the Trash, keeping where they went so `undo` can put them back. Returns how many moved.
    @discardableResult
    func trash(_ list: [DiskEntry]) -> Int {
        var moved: [(original: URL, trash: URL)] = []
        for entry in list {
            var result: NSURL?
            do { try FileManager.default.trashItem(at: entry.url, resultingItemURL: &result) } catch { Toast().show("“\(entry.name)” could not be moved to the Trash.", isError: true); continue }
            moved.append((entry.url, (result as URL?) ?? entry.url))
        }
        let ids = Set(moved.map { $0.original.path })
        entries.removeAll { ids.contains($0.id) }
        if !moved.isEmpty { lastTrashed = moved }
        return moved.count
    }

    func trash(_ entry: DiskEntry) { trash([entry]) }

    /// Puts back what the last Trash action moved.
    func undo() {
        var failed = 0
        for item in lastTrashed {
            do { try FileManager.default.moveItem(at: item.trash, to: item.original) } catch { failed += 1 }
        }
        lastTrashed = []
        if failed > 0 { Toast().show("\(failed) item\(failed == 1 ? "" : "s") could not be put back. Look in the Trash.", isError: true) }
        scan()
    }

    func dismissUndo() { lastTrashed = [] }
}
