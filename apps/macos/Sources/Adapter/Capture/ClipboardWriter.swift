import AppKit

/// Writing a copy to the clipboard.
enum ClipboardWriter {
    /// Puts everything in the payload on the clipboard as one item, so an app can take whichever form it prefers. An empty payload writes
    /// nothing and leaves the clipboard as it was. Returns whether every form was written.
    @discardableResult
    static func write(_ payload: ClipboardPayload, to pasteboard: NSPasteboard) -> Bool {
        guard !payload.isEmpty else { return false }
        var types: [NSPasteboard.PasteboardType] = []
        if payload.fileURL != nil { types.append(.fileURL) }
        if payload.png != nil { types.append(.png) }
        if payload.tiff != nil { types.append(.tiff) }
        // Declaring the types replaces what was there, now that it is known there is something to replace it with.
        pasteboard.declareTypes(types, owner: nil)
        var ok = true
        if let url = payload.fileURL { ok = pasteboard.setString(url.absoluteString, forType: .fileURL) && ok }
        if let png = payload.png { ok = pasteboard.setData(png, forType: .png) && ok }
        if let tiff = payload.tiff { ok = pasteboard.setData(tiff, forType: .tiff) && ok }
        return ok
    }

    private static var folder: URL { FileManager.default.temporaryDirectory.appendingPathComponent("kriya-clipboard", isDirectory: true) }

    /// A file written only so it can be copied as a file. Files older than ten minutes are removed each time, so none pile up.
    static func temporaryFile(png: Data?, now: Date = Date()) -> URL? {
        guard let png else { return nil }
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch { return nil }
        for old in (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            if let modified = try? old.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, now.timeIntervalSince(modified) > 600 {
                try? manager.removeItem(at: old)
            }
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let url = folder.appendingPathComponent("Kriya Capture \(formatter.string(from: now)) \(UUID().uuidString.prefix(4)).png")
        do { try png.write(to: url, options: .atomic) } catch { return nil }
        return url
    }
}
