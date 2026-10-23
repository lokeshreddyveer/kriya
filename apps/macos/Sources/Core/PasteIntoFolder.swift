import Foundation

/// Pasting the clipboard into empty space: the text, picture or files on it become real files in a folder. The naming and the
/// choice of what to make are here so they can be checked; the pasteboard and the disk are the adapter's.
enum PasteIntoFolder {
    enum Content: Equatable {
        case text(String)
        case imagePNG(Data)
        case files([URL])
        case nothing
    }

    /// A file name for text or a picture: "Clipboard 2026-10-22 14.05.09.txt", numbered if that exists.
    static func name(for content: Content, at date: Date, exists: (String) -> Bool) -> String? {
        let ext: String
        switch content {
        case .text(let text): ext = looksLikeMarkdown(text) ? "md" : "txt"
        case .imagePNG: ext = "png"
        case .files, .nothing: return nil
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let base = "Clipboard \(formatter.string(from: date))"
        var candidate = "\(base).\(ext)"
        var counter = 2
        while exists(candidate) {
            candidate = "\(base) \(counter).\(ext)"
            counter += 1
        }
        return candidate
    }

    static func looksLikeMarkdown(_ text: String) -> Bool {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard let first = lines.first else { return false }
        if first.hasPrefix("# ") || first.hasPrefix("## ") { return true }
        return lines.contains { $0.hasPrefix("```") } || lines.filter { $0.hasPrefix("- ") || $0.hasPrefix("* ") }.count >= 3
    }

    /// Where a file of that name goes when copying files in: a copy gets "name 2.ext" rather than replacing what is there.
    static func uniqueName(_ name: String, exists: (String) -> Bool) -> String {
        guard exists(name) else { return name }
        let ns = name as NSString
        let ext = ns.pathExtension, stem = ns.deletingPathExtension
        var counter = 2
        while true {
            let candidate = ext.isEmpty ? "\(stem) \(counter)" : "\(stem) \(counter).\(ext)"
            if !exists(candidate) { return candidate }
            counter += 1
        }
    }

    /// The most that is written in one go.
    static let maxTextBytes = 20_000_000
    static let maxFiles = 200

    /// Folders it will not write into: the system's own, and anything outside the person's home.
    static func isAllowedFolder(_ path: String, home: String = NSHomeDirectory()) -> Bool {
        let p = (path as NSString).standardizingPath
        guard p == home || p.hasPrefix(home + "/") else { return false }
        let lower = p.lowercased()
        return !["/library", "/.ssh", "/.gnupg", "/.aws"].contains { lower.hasPrefix((home + $0).lowercased()) }
    }
}
