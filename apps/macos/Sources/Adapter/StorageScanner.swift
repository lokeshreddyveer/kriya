import AppKit

struct StorageItem: Identifiable, Equatable {
    var id: String { url.path }
    let name: String
    let url: URL
    let bytes: Int64
    let note: String?
}

/// Measures the folders that usually take the room, so the biggest can be seen and opened. It reads sizes only; it never
/// deletes anything except the Trash, and only when the person presses the button for it.
final class StorageScanner: ObservableObject {
    @Published private(set) var items: [StorageItem] = []
    @Published private(set) var scanning = false
    @Published private(set) var lastScan: Date?

    private let home = FileManager.default.homeDirectoryForCurrentUser
    private let queue = DispatchQueue(label: "kriya.storage", qos: .utility, attributes: .concurrent)

    private var places: [(name: String, path: String, note: String?)] {
        [("Downloads", "Downloads", nil), ("Documents", "Documents", nil), ("Desktop", "Desktop", nil), ("Movies", "Movies", nil),
         ("Music", "Music", nil), ("Pictures", "Pictures", nil), ("Trash", ".Trash", "Empty it to get this room back"),
         ("App caches", "Library/Caches", "Apps rebuild these when they need them"),
         ("Developer files", "Library/Developer", "Xcode builds, simulators and device support"),
         ("App data", "Library/Application Support", nil), ("Mail and messages", "Library/Mail", nil),
         ("Containers", "Library/Containers", nil)]
    }

    func scan() {
        guard !scanning else { return }
        scanning = true
        let group = DispatchGroup()
        let lock = NSLock()
        var found: [StorageItem] = []
        for place in places {
            let url = home.appendingPathComponent(place.path, isDirectory: true)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            group.enter()
            queue.async {
                let bytes = Self.size(of: url)
                if bytes != nil {
                    lock.lock(); found.append(StorageItem(name: place.name, url: url, bytes: bytes ?? 0, note: place.note)); lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            self?.items = found.sorted { $0.bytes > $1.bytes }
            self?.lastScan = Date()
            self?.scanning = false
        }
    }

    /// Bytes used by a folder, from `du` (not crossing into other volumes, so a network share inside it is not walked). Nil if it
    /// cannot be read (macOS asks before some folders; then it is skipped) or if it takes longer than `timeout` seconds.
    static func size(of url: URL, timeout: TimeInterval = 90) -> Int64? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        task.arguments = ["-skx", url.path]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return nil }
        // A folder that never finishes (a stuck cloud folder, a huge tree) is given up on instead of holding everything else.
        let stop = DispatchWorkItem { if task.isRunning { task.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: stop)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        stop.cancel()
        guard task.terminationReason == .exit,
              let kilobytes = String(decoding: data, as: UTF8.self).split(whereSeparator: { $0 == "\t" || $0 == " " }).first.flatMap({ Int64($0) }) else { return nil }
        return kilobytes * 1024
    }

    /// Places whose contents live somewhere else (iCloud Drive, other cloud services, mounted volumes): measuring them can take
    /// minutes and reads files that are not on this Mac, so the map does not.
    static func isRemoteOrCloud(_ url: URL) -> Bool {
        let path = url.path.lowercased()
        return path.contains("/library/cloudstorage") || path.contains("/library/mobile documents") || path.hasPrefix("/volumes")
            || path.hasSuffix("/library/group containers/group.com.apple.cloudstorage") || path.contains("/library/application support/fileprovider")
    }

    func emptyTrash() {
        NSAppleScript(source: "tell application \"Finder\" to empty the trash")?.executeAndReturnError(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.scan() }
    }
}
