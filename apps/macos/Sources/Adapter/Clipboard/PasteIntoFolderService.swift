import AppKit

/// Writes what is on the clipboard into the folder of the front Finder window, or the Desktop.
enum PasteIntoFolderService {
    static func currentContent(_ pasteboard: NSPasteboard = .general) -> PasteIntoFolder.Content {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty { return .files(urls) }
        if let png = pasteboard.data(forType: .png) { return .imagePNG(png) }
        if let tiff = pasteboard.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) { return .imagePNG(png) }
        if let text = pasteboard.string(forType: .string), !text.isEmpty { return .text(text) }
        return .nothing
    }

    @discardableResult
    static func run(toast: Toast = Toast()) -> Bool {
        let folderPath = (try? FinderSelectionReader.read().folder) ?? nil
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0].path
        let target = folderPath.flatMap { PasteIntoFolder.isAllowedFolder($0) ? $0 : nil } ?? desktop
        let folder = URL(fileURLWithPath: target, isDirectory: true)
        let fm = FileManager.default
        let exists: (String) -> Bool = { fm.fileExists(atPath: folder.appendingPathComponent($0).path) }
        do {
            switch currentContent() {
            case .nothing:
                toast.show("The clipboard is empty.", isError: true)
                return false
            case .files(let urls):
                guard urls.count <= PasteIntoFolder.maxFiles else { toast.show("Too many files to paste at once.", isError: true); return false }
                for url in urls {
                    let name = PasteIntoFolder.uniqueName(url.lastPathComponent, exists: exists)
                    try fm.copyItem(at: url, to: folder.appendingPathComponent(name))
                }
                toast.show("Pasted \(urls.count) file\(urls.count == 1 ? "" : "s") into \(folder.lastPathComponent)")
            case let content:
                if case .text(let text) = content, text.utf8.count > PasteIntoFolder.maxTextBytes { toast.show("That text is too large to paste as a file.", isError: true); return false }
                guard let name = PasteIntoFolder.name(for: content, at: Date(), exists: exists) else { return false }
                let url = folder.appendingPathComponent(name)
                switch content {
                case .text(let text): try text.write(to: url, atomically: true, encoding: .utf8)
                case .imagePNG(let data): try data.write(to: url, options: .atomic)
                default: break
                }
                toast.show("Pasted as “\(name)” in \(folder.lastPathComponent)")
            }
            AuditLog.shared.record(.setting, "Clipboard pasted into a folder")
            return true
        } catch {
            toast.show("Could not paste: \(error.localizedDescription)", isError: true)
            return false
        }
    }
}
