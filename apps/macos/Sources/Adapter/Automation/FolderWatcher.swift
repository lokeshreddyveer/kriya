import Foundation

/// Tells when new items appear directly inside one folder. It listens for the folder itself changing (a kernel notice, no polling),
/// waits a moment for a copy or download to settle, then compares the folder's items with the ones it last saw. Items still being
/// written (`.crdownload`, `.part`…) and hidden ones do not count until they have their final name.
final class FolderWatcher {
    private let url: URL
    private let onNew: ([String]) -> Void
    private var source: DispatchSourceFileSystemObject?
    private var seen: Set<String> = []
    private var pending: DispatchWorkItem?

    /// How long the folder must be quiet before it is looked at, so a large copy is not reported half-way.
    static let settle: TimeInterval = 1.5

    init(url: URL, onNew: @escaping ([String]) -> Void) {
        self.url = url
        self.onNew = onNew
    }

    /// False if the folder cannot be opened (it is not there, or Kriya may not read it).
    func start() -> Bool {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), isFolder.boolValue else { return false }
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return false }
        seen = currentNames()
        let watcher = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .extend, .rename, .link], queue: .main)
        watcher.setEventHandler { [weak self] in self?.changed() }
        watcher.setCancelHandler { close(descriptor) }
        watcher.resume()
        source = watcher
        return true
    }

    func stop() {
        pending?.cancel(); pending = nil
        source?.cancel(); source = nil
    }

    deinit { stop() }

    private func changed() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.look() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settle, execute: work)
    }

    private func look() {
        let now = currentNames()
        let added = FolderChange.newItems(before: seen, after: now)
        seen = now
        if !added.isEmpty { onNew(added) }
    }

    private func currentNames() -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        return FolderChange.counted(names)
    }
}
