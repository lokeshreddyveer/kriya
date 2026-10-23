import AppKit

/// Keeps the shelves on disk: a small file for the shelves and one picture file for each image. Shared by the shelf panel and
/// Settings. Everything stays on this Mac.
final class ShelfLibraryStore: ObservableObject {
    static let shared = ShelfLibraryStore()

    @Published private(set) var library: ShelfLibrary
    private let folder: URL
    private var timer: Timer?

    init(folder: URL = ShelfLibraryStore.defaultFolder) {
        self.folder = folder
        let file = folder.appendingPathComponent("shelves.json")
        var loaded = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(ShelfLibrary.self, from: $0) } ?? ShelfLibrary()
        if loaded.shelves.isEmpty { loaded = ShelfLibrary() }
        library = loaded
        let released = library.expire()
        removeImages(released)
        // Let go of old items now and then while the app runs.
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in self?.change { _ = $0.expire() } }
    }

    static var defaultFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Kriya/Shelf", isDirectory: true)
    }

    /// Changes the library and saves it. Pictures no longer held are deleted.
    func change(_ edit: (inout ShelfLibrary) -> Void) {
        var next = library
        let before = Set(next.allImageNames)
        edit(&next)
        let gone = before.subtracting(next.allImageNames)
        guard next != library else { return }
        library = next
        save()
        removeImages(Array(gone))
    }

    // MARK: Pictures

    /// Keeps a picture in the shelf folder and returns its name.
    func storeImage(_ image: NSImage) -> String? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let name = UUID().uuidString + ".png"
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try png.write(to: folder.appendingPathComponent(name), options: .atomic)
            return name
        } catch { return nil }
    }

    func image(named name: String) -> NSImage? { NSImage(contentsOf: folder.appendingPathComponent((name as NSString).lastPathComponent)) }

    private func removeImages(_ names: [String]) {
        for name in names { try? FileManager.default.removeItem(at: folder.appendingPathComponent((name as NSString).lastPathComponent)) }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let url = folder.appendingPathComponent("shelves.json")
            try JSONEncoder().encode(library).write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            Log.warning("Shelf", "Could not save the shelves: \(error.localizedDescription)")
        }
    }
}
