import AppKit

/// What dragging an item out of the clipboard history hands to the app it is dropped on. Sensitive items (passwords and the
/// like) and anything that cannot be read are never offered.
enum ClipDrag {
    static func provider(for item: ClipItem, blob: ClipBlob?) -> NSItemProvider? {
        guard !item.sensitive else { return nil }
        switch item.kind {
        case .image:
            guard let data = blob?.image, let image = NSImage(data: data) else { return nil }
            return NSItemProvider(object: image)
        case .files:
            // One file can be dragged at a time; the rest are still in the item.
            guard let first = item.files.first(where: { FileManager.default.fileExists(atPath: $0) }) else { return nil }
            return NSItemProvider(contentsOf: URL(fileURLWithPath: first))
        case .url:
            guard let text = blob?.plain, let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme != nil else { return textProvider(blob) }
            return NSItemProvider(object: url as NSURL)
        case .text, .richText:
            return textProvider(blob)
        }
    }

    private static func textProvider(_ blob: ClipBlob?) -> NSItemProvider? {
        guard let text = blob?.plain, !text.isEmpty else { return nil }
        return NSItemProvider(object: text as NSString)
    }
}
