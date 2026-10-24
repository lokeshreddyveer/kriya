import CoreGraphics
import Foundation

/// A shelf written out to a file and read back: for a backup, or to move a shelf to another Mac. Files are listed by path (their
/// contents are not copied); text is kept as it is; pictures travel inside the file.
struct ShelfExport: Codable, Equatable {
    struct Item: Codable, Equatable {
        var kind: String
        var value: String
        var group: String?
        var added: Date
        /// A picture's PNG data, for `image` items.
        var png: Data?
    }

    static let formatName = "kriya-shelf"
    static let currentVersion = 1

    var format = Self.formatName
    var version = Self.currentVersion
    var name: String
    var items: [Item]
}

enum ShelfExchange {
    static let maxBytes = 60 * 1024 * 1024

    /// The shelf as JSON. `imageData` supplies the PNG for a picture kept in the shelf folder by name.
    static func exported(_ shelf: ShelfSet, imageData: (String) -> Data?) -> Data? {
        let items = shelf.items.map { r in
            ShelfExport.Item(kind: r.kind.rawValue, value: r.kind == .image ? "" : r.value, group: r.group, added: r.added, png: r.kind == .image ? imageData(r.value) : nil)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(ShelfExport(name: shelf.name, items: items))
    }

    /// An item read from a file, checked and ready to be put on a shelf.
    struct Imported: Equatable {
        var kind: ShelfRecord.Kind
        var value: String
        var group: String?
        var added: Date
        var png: Data?
    }

    /// Reads a shelf file. Anything that is not one, is from a newer version, or is too big is refused; each item is checked, and
    /// what is not valid (a relative file path, a picture with no data, too much text) is left out.
    static func imported(_ data: Data) -> (name: String, items: [Imported], skipped: Int)? {
        guard data.count <= maxBytes else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let file = try? decoder.decode(ShelfExport.self, from: data), file.format == ShelfExport.formatName, file.version <= ShelfExport.currentVersion else { return nil }
        var out: [Imported] = []
        var skipped = 0
        for item in file.items.prefix(ShelfLibrary.maxItemsPerShelf) {
            guard let kind = ShelfRecord.Kind(rawValue: item.kind) else { skipped += 1; continue }
            switch kind {
            case .file:
                guard item.value.hasPrefix("/"), !item.value.contains("\0"), item.value.count < 4096 else { skipped += 1; continue }
            case .text:
                guard !item.value.isEmpty, item.value.utf8.count <= ShelfLibrary.maxTextBytes else { skipped += 1; continue }
            case .image:
                guard let png = item.png, png.count > 8, png.count <= 30 * 1024 * 1024 else { skipped += 1; continue }
            }
            let group = item.group.map { String($0.prefix(40)) }.flatMap { $0.isEmpty ? nil : $0 }
            out.append(Imported(kind: kind, value: item.value, group: group, added: item.added, png: item.png))
        }
        skipped += max(0, file.items.count - ShelfLibrary.maxItemsPerShelf)
        let name = String(file.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        return (name.isEmpty ? "Imported" : name, out, skipped)
    }
}

/// How big a picture becomes when it is made smaller.
enum ImageResize {
    /// The size that fits `maxEdge` on its longer side, keeping the shape. A picture already small enough is left as it is.
    static func fit(_ size: CGSize, maxEdge: CGFloat) -> CGSize {
        let longest = max(size.width, size.height)
        guard longest > maxEdge, maxEdge > 0, size.width > 0, size.height > 0 else { return size }
        let scale = maxEdge / longest
        return CGSize(width: max(1, (size.width * scale).rounded()), height: max(1, (size.height * scale).rounded()))
    }
}

enum ShelfOutputNaming {
    /// "photo.jpg" made smaller becomes "photo 1280px.jpg"; a name that is taken gets " 2", " 3"…
    static func name(for source: String, suffix: String, ext: String, existing: [String]) -> String {
        let stem = ((source as NSString).deletingPathExtension)
        let base = suffix.isEmpty ? stem : "\(stem) \(suffix)"
        var candidate = "\(base).\(ext)"
        var n = 2
        let taken = Set(existing.map { $0.lowercased() })
        while taken.contains(candidate.lowercased()) { candidate = "\(base) \(n).\(ext)"; n += 1 }
        return candidate
    }
}
