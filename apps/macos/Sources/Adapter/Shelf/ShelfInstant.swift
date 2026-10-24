import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Things the shelf can do with what is on it, in one click: make pictures smaller, change their format, join them into a PDF, read
/// the words in them, copy paths, send text to Notes, upload. New files are made beside the originals; the originals are never changed.
enum ShelfInstant {
    struct Outcome {
        var message: String
        var outputs: [URL] = []
        var isError = false
    }

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "tiff", "tif", "gif", "bmp", "webp"]

    static func images(_ urls: [URL]) -> [URL] { urls.filter { imageExtensions.contains($0.pathExtension.lowercased()) } }

    private static func existing(in folder: URL) -> [String] { (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] }

    /// Pictures made no larger than `maxEdge` pixels on the longer side.
    static func resize(_ urls: [URL], maxEdge: CGFloat) -> Outcome {
        let pictures = images(urls)
        guard !pictures.isEmpty else { return Outcome(message: "There are no pictures on the shelf.", isError: true) }
        var made: [URL] = [], skipped = 0
        for url in pictures {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let w = props[kCGImagePropertyPixelWidth] as? CGFloat, let h = props[kCGImagePropertyPixelHeight] as? CGFloat else { skipped += 1; continue }
            if ImageResize.fit(CGSize(width: w, height: h), maxEdge: maxEdge) == CGSize(width: w, height: h) { skipped += 1; continue }
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: maxEdge]
            guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { skipped += 1; continue }
            let type = CGImageSourceGetType(source) ?? (UTType.png.identifier as CFString)
            let ext = url.pathExtension.isEmpty ? "png" : url.pathExtension
            let folder = url.deletingLastPathComponent()
            let name = ShelfOutputNaming.name(for: url.lastPathComponent, suffix: "\(Int(maxEdge))px", ext: ext, existing: existing(in: folder))
            let target = folder.appendingPathComponent(name)
            guard let destination = CGImageDestinationCreateWithURL(target as CFURL, type, 1, nil) else { skipped += 1; continue }
            CGImageDestinationAddImage(destination, thumb, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
            if CGImageDestinationFinalize(destination) { made.append(target) } else { skipped += 1 }
        }
        let note = skipped > 0 ? " \(skipped) already small enough or not readable." : ""
        return made.isEmpty ? Outcome(message: "Nothing to resize.\(note)", isError: skipped == pictures.count && skipped > 0 ? false : true) : Outcome(message: "Made \(made.count) smaller picture\(made.count == 1 ? "" : "s").\(note)", outputs: made)
    }

    /// Pictures saved again in another format.
    static func convert(_ urls: [URL], to format: CaptureFormat) -> Outcome {
        let pictures = images(urls)
        guard !pictures.isEmpty else { return Outcome(message: "There are no pictures on the shelf.", isError: true) }
        var made: [URL] = [], failed = 0
        for url in pictures {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
                  let data = image.data(as: format) else { failed += 1; continue }
            let folder = url.deletingLastPathComponent()
            let name = ShelfOutputNaming.name(for: url.lastPathComponent, suffix: "", ext: format.fileExtension, existing: existing(in: folder) + [url.lastPathComponent])
            let target = folder.appendingPathComponent(name)
            if (try? data.write(to: target, options: .atomic)) != nil { made.append(target) } else { failed += 1 }
        }
        let note = failed > 0 ? " \(failed) could not be converted." : ""
        return made.isEmpty ? Outcome(message: "Nothing was converted.\(note)", isError: true) : Outcome(message: "Made \(made.count) \(format.title) file\(made.count == 1 ? "" : "s").\(note)", outputs: made)
    }

    /// One PDF with a page for each picture, in shelf order, saved on the Desktop.
    static func pdf(_ urls: [URL]) -> Outcome {
        let pictures = images(urls)
        guard !pictures.isEmpty else { return Outcome(message: "There are no pictures on the shelf.", isError: true) }
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data), let context = CGContext(consumer: consumer, mediaBox: nil, nil) else { return Outcome(message: "The PDF could not be made.", isError: true) }
        var pages = 0
        for url in pictures {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
            var box = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            context.beginPDFPage([kCGPDFContextMediaBox as String: NSData(bytes: &box, length: MemoryLayout<CGRect>.size)] as CFDictionary)
            context.draw(image, in: box)
            context.endPDFPage()
            pages += 1
        }
        context.closePDF()
        guard pages > 0 else { return Outcome(message: "None of the pictures could be read.", isError: true) }
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first ?? FileManager.default.homeDirectoryForCurrentUser
        let target = desktop.appendingPathComponent(ShelfOutputNaming.name(for: "Shelf pictures", suffix: "", ext: "pdf", existing: existing(in: desktop)))
        guard (try? (data as Data).write(to: target, options: .atomic)) != nil else { return Outcome(message: "The PDF could not be saved on the Desktop.", isError: true) }
        return Outcome(message: "Made a PDF of \(pages) page\(pages == 1 ? "" : "s").", outputs: [target])
    }

    /// The words in the pictures, each picture's text under its name when there are several. Read on this Mac.
    static func text(in urls: [URL]) -> String {
        let pictures = images(urls)
        let recognizer = TextRecognizer()
        var parts: [String] = []
        for url in pictures {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  let text = try? recognizer.text(in: image), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            parts.append(pictures.count > 1 ? "\(url.lastPathComponent)\n\(text)" : text)
        }
        return parts.joined(separator: "\n\n")
    }

    static func paths(_ urls: [URL]) -> String { urls.map(\.path).joined(separator: "\n") }

    /// Makes a note in Notes. Notes asks the person once for permission to be controlled.
    static func sendToNotes(_ text: String) -> Bool {
        let script = "on run argv\ntell application \"Notes\" to make new note at default account with properties {body:(item 1 of argv)}\nend run"
        return (try? ToolRunner.run("/usr/bin/osascript", ["-e", script, textToHtml(text: text)], timeout: 30)) != nil
    }

    /// Uploads each file to the person's own bucket and calls back with the links (one per line).
    static func upload(_ urls: [URL], completion: @escaping (Result<String, Error>) -> Void) {
        guard !urls.isEmpty else { return completion(.failure(CaptureUploader.UploadError.notSetUp)) }
        var links: [String] = []
        let group = DispatchGroup()
        var firstError: Error?
        let lock = NSLock()
        for url in urls.prefix(20) {
            guard let data = try? Data(contentsOf: url), data.count <= 200 * 1024 * 1024 else { continue }
            let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            group.enter()
            CaptureUploader.upload(data, fileName: url.lastPathComponent, contentType: type) { result in
                lock.lock(); defer { lock.unlock(); group.leave() }
                switch result { case .success(let done): links.append(done.link); case .failure(let e): firstError = firstError ?? e }
            }
        }
        group.notify(queue: .main) { links.isEmpty ? completion(.failure(firstError ?? CaptureUploader.UploadError.notSetUp)) : completion(.success(links.joined(separator: "\n"))) }
    }
}

/// The menu-bar icon as a place to drop things: dropping files, text or a picture on it makes a new shelf holding them.
final class StatusDropView: NSView {
    var onDrop: (NSPasteboard) -> Bool = { _ in false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL, .URL, .string, .png, .tiff])
        autoresizingMask = [.width, .height]
    }

    required init?(coder: NSCoder) { fatalError() }

    // Clicks go through to the icon underneath; only a drag in progress lands here.
    override func hitTest(_ point: NSPoint) -> NSView? {
        switch NSApp.currentEvent?.type {
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged: return self
        default: return nil
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { onDrop(sender.draggingPasteboard) }
}
