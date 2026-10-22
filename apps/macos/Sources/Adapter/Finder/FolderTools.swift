import AppKit
import CryptoKit

/// Folder actions for the Finder menu: several folders at once, the biggest files in a folder, and a tidy-up that sorts
/// loose files into subfolders by kind. A tidy-up never deletes or overwrites anything, and the last one can be undone.
enum FolderTools {
    // MARK: Several folders at once

    /// Asks for folder names, one per line. Returns nil when cancelled or nothing was typed.
    static func askFolderNames() -> [String]? {
        let alert = NSAlert()
        alert.messageText = "New Folders"
        alert.informativeText = "Type one folder name per line."
        let field = NSTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 140))
        field.font = .systemFont(ofSize: 13)
        field.isRichText = false
        field.isAutomaticQuoteSubstitutionEnabled = false
        let scroll = NSScrollView(frame: field.frame)
        scroll.documentView = field
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        alert.accessoryView = scroll
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let names = field.string.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-") }
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
        return names.isEmpty ? nil : Array(names.prefix(100))
    }

    static func createFolders(_ names: [String], in folder: URL) throws -> FileActionRunner.Outcome {
        let fm = FileManager.default
        var existing = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
        var made: [URL] = []
        for name in names {
            let unique = finderUniqueName(candidate: name, existing: existing)
            let url = folder.appendingPathComponent(unique, isDirectory: true)
            try fm.createDirectory(at: url, withIntermediateDirectories: false)
            existing.append(unique)
            made.append(url)
        }
        return FileActionRunner.Outcome(message: made.count == 1 ? "Created 1 folder" : "Created \(made.count) folders", reveal: made)
    }

    // MARK: Large files

    struct Found {
        let url: URL
        let bytes: Int64
    }

    /// The biggest files inside a folder, biggest first. Skips hidden files and the insides of packages; looks at no more
    /// than 300,000 entries so a huge disk cannot hold it up.
    static func largeFiles(in root: URL, minimumBytes: Int64, limit: Int) -> [Found] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var found: [Found] = []
        var seen = 0
        for case let url as URL in walker {
            seen += 1
            if seen > 300_000 { break }
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                  let size = values.fileSize, Int64(size) >= minimumBytes else { continue }
            found.append(Found(url: url, bytes: Int64(size)))
        }
        return Array(found.sorted { $0.bytes > $1.bytes }.prefix(limit))
    }

    static func present(_ found: [Found], in root: URL, minimumMB: UInt32) {
        let alert = NSAlert()
        guard !found.isEmpty else {
            alert.messageText = "No large files"
            alert.informativeText = "Nothing in “\(root.lastPathComponent)” is \(minimumMB) MB or more."
            alert.addButton(withTitle: "OK")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            return
        }
        let total = ByteCountFormatter.string(fromByteCount: found.reduce(0) { $0 + $1.bytes }, countStyle: .file)
        alert.messageText = "\(found.count) large file\(found.count == 1 ? "" : "s") in “\(root.lastPathComponent)”"
        alert.informativeText = "\(total) in total, biggest first. Nothing has been changed."
        let rootPath = root.standardizedFileURL.path
        let lines = found.map { item -> String in
            let size = ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file)
            let path = item.url.standardizedFileURL.path
            let relative = path.hasPrefix(rootPath + "/") ? String(path.dropFirst(rootPath.count + 1)) : path
            return "\(size.padding(toLength: 10, withPad: " ", startingAt: 0))\(relative)"
        }
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 220))
        text.isEditable = false
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.string = lines.joined(separator: "\n")
        let scroll = NSScrollView(frame: text.frame)
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        alert.accessoryView = scroll
        alert.addButton(withTitle: "Show in Finder")
        alert.addButton(withTitle: "Copy List")
        alert.addButton(withTitle: "Close")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            NSWorkspace.shared.activateFileViewerSelecting(Array(found.prefix(20)).map(\.url))
        case .alertSecondButtonReturn:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        default:
            break
        }
    }

    // MARK: Tidy up

    private static let categories: [(folder: String, extensions: Set<String>)] = [
        ("Images", ["jpg", "jpeg", "png", "gif", "heic", "webp", "tiff", "bmp", "svg", "raw"]),
        ("Documents", ["pdf", "doc", "docx", "txt", "rtf", "pages", "md", "odt", "xls", "xlsx", "csv", "numbers", "ppt", "pptx", "key"]),
        ("Archives", ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz"]),
        ("Audio", ["mp3", "m4a", "wav", "aac", "flac", "aiff", "ogg"]),
        ("Video", ["mp4", "mov", "m4v", "avi", "mkv", "webm"]),
        ("Installers", ["dmg", "pkg", "iso"]),
    ]

    private static let undoKey = "finder.lastTidy"

    static func category(for fileName: String) -> String? {
        let ext = (fileName as NSString).pathExtension.lowercased()
        return categories.first { $0.extensions.contains(ext) }?.folder
    }

    /// Moves the loose files of a folder into subfolders by kind. Files of a kind it does not know stay where they are.
    static func tidy(_ folder: URL) throws -> FileActionRunner.Outcome {
        let fm = FileManager.default
        let path = folder.standardizedFileURL.path
        if ProtectedPaths.isProtected(path) || path == NSHomeDirectory() || path == "/" {
            throw FileActionError("“\(folder.lastPathComponent)” is not a folder that can be tidied.")
        }
        let entries = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        var moves: [[String]] = []
        for url in entries {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  let kind = category(for: url.lastPathComponent) else { continue }
            let destinationFolder = folder.appendingPathComponent(kind, isDirectory: true)
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: destinationFolder.path, isDirectory: &isDirectory) {
                guard isDirectory.boolValue else { continue }
            } else {
                try fm.createDirectory(at: destinationFolder, withIntermediateDirectories: false)
            }
            let name = finderUniqueName(candidate: url.lastPathComponent, existing: (try? fm.contentsOfDirectory(atPath: destinationFolder.path)) ?? [])
            let target = destinationFolder.appendingPathComponent(name)
            try fm.moveItem(at: url, to: target)
            moves.append([url.path, target.path])
        }
        guard !moves.isEmpty else { return FileActionRunner.Outcome(message: "Nothing to tidy: no loose files of a known kind", reveal: []) }
        UserDefaults.standard.set(moves, forKey: undoKey)
        return FileActionRunner.Outcome(message: "Moved \(moves.count) file\(moves.count == 1 ? "" : "s") into folders. “Undo Last Tidy-Up” puts them back.", reveal: [])
    }

    /// Puts back what the last tidy-up moved, skipping any file that has since moved or whose old place is taken.
    static func undoLastTidy() throws -> FileActionRunner.Outcome {
        let fm = FileManager.default
        guard let moves = UserDefaults.standard.array(forKey: undoKey) as? [[String]], !moves.isEmpty else {
            throw FileActionError("There is no tidy-up to undo.")
        }
        var restored = 0
        for pair in moves where pair.count == 2 {
            guard fm.fileExists(atPath: pair[1]), !fm.fileExists(atPath: pair[0]) else { continue }
            try? fm.moveItem(atPath: pair[1], toPath: pair[0])
            restored += 1
        }
        UserDefaults.standard.removeObject(forKey: undoKey)
        return FileActionRunner.Outcome(message: restored == 0 ? "Nothing could be put back" : "Put back \(restored) file\(restored == 1 ? "" : "s")", reveal: [])
    }

    // MARK: Checksums, download warnings and aliases

    /// The SHA-256 checksum of a file, read in pieces so a large file does not have to fit in memory.
    static func checksum(of url: URL) throws -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw FileActionError("Could not read “\(url.lastPathComponent)”.") }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Copies the SHA-256 checksum of each selected file. A folder has none, so it is skipped.
    static func copyChecksums(_ urls: [URL]) throws -> FileActionRunner.Outcome {
        let files = urls.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true }
        guard !files.isEmpty else { throw FileActionError("Select a file: a folder has no checksum.") }
        var lines: [String] = []
        for url in files {
            let hex = try checksum(of: url)
            lines.append(files.count == 1 ? hex : "\(hex)  \(url.lastPathComponent)")
        }
        let text = lines.joined(separator: "\n")
        DispatchQueue.main.async {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        return FileActionRunner.Outcome(message: files.count == 1 ? "Copied the SHA-256 checksum" : "Copied \(files.count) checksums", reveal: [])
    }

    /// Takes the "downloaded from the internet" mark off the items and everything inside them.
    static func removeQuarantine(_ urls: [URL]) throws -> FileActionRunner.Outcome {
        var cleared = 0
        for url in urls {
            if ProtectedPaths.isProtected(url.path) { throw FileActionError("“\(url.lastPathComponent)” is a system folder and is left alone.") }
            var targets = [url]
            if let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: []) {
                var seen = 0
                for case let item as URL in walker {
                    seen += 1
                    if seen > 50_000 { break }
                    targets.append(item)
                }
            }
            for target in targets where removexattr(target.path, "com.apple.quarantine", XATTR_NOFOLLOW) == 0 { cleared += 1 }
        }
        return FileActionRunner.Outcome(message: cleared == 0 ? "There was no download warning to remove" : "Removed the download warning", reveal: [])
    }

    /// Makes a Finder alias beside each item, named like the item with " alias" after it.
    static func makeAliases(_ urls: [URL]) throws -> FileActionRunner.Outcome {
        let fm = FileManager.default
        var made: [URL] = []
        for url in urls {
            let folder = url.deletingLastPathComponent()
            // "photo.jpg alias", then "photo.jpg alias 2": the number goes at the very end, as Finder does it.
            let existing = Set((try? fm.contentsOfDirectory(atPath: folder.path)) ?? [])
            var name = url.lastPathComponent + " alias"
            var number = 2
            while existing.contains(name) {
                name = url.lastPathComponent + " alias \(number)"
                number += 1
            }
            let alias = folder.appendingPathComponent(name)
            let data = try url.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
            try URL.writeBookmarkData(data, to: alias)
            made.append(alias)
        }
        return FileActionRunner.Outcome(message: made.count == 1 ? "Made an alias" : "Made \(made.count) aliases", reveal: made)
    }
}
