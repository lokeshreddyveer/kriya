import Foundation

struct NoteFile: Identifiable, Equatable {
    var id: URL { url }
    let url: URL
    let title: String
    let modified: Date
}

/// Notes are plain Markdown files in one folder, so any other app can open them and nothing is locked in.
struct NoteStore {
    let folder: URL
    private let fm = FileManager.default

    init(folder: URL) { self.folder = folder }

    static var defaultFolder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Kriya Notes", isDirectory: true)
    }

    /// The first line that has words in it, without Markdown heading marks.
    static func title(of text: String) -> String {
        for line in text.split(whereSeparator: \.isNewline) {
            let clean = line.trimmingCharacters(in: CharacterSet(charactersIn: "# \t>-*"))
            if !clean.isEmpty { return String(clean.prefix(80)) }
        }
        return "Untitled"
    }

    /// "2026-10-23 12.30 Shopping list.md": sorts by date in Finder, and has no character a file name cannot hold.
    static func fileName(for text: String, date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm"
        let bad = CharacterSet(charactersIn: "/:\\?%*|\"<>").union(.controlCharacters)
        let slug = title(of: text).components(separatedBy: bad).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return "\(f.string(from: date)) \(String(slug.prefix(50)).trimmingCharacters(in: .whitespaces)).md"
    }

    private func ensureFolder() { try? fm.createDirectory(at: folder, withIntermediateDirectories: true) }

    func list() -> [NoteFile] {
        let urls = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
        return urls.filter { ["md", "markdown", "txt"].contains($0.pathExtension.lowercased()) }.map { url in
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return NoteFile(url: url, title: Self.title(of: (try? String(contentsOf: url, encoding: .utf8)) ?? ""), modified: modified)
        }.sorted { $0.modified > $1.modified }
    }

    func read(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

    @discardableResult
    func create(_ text: String, date: Date = Date()) -> URL? {
        ensureFolder()
        var url = folder.appendingPathComponent(Self.fileName(for: text, date: date))
        var n = 2
        while fm.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent(Self.fileName(for: text, date: date).replacingOccurrences(of: ".md", with: " \(n).md"))
            n += 1
        }
        do { try text.write(to: url, atomically: true, encoding: .utf8); return url } catch { return nil }
    }

    @discardableResult
    func save(_ text: String, to url: URL, now: Date = Date()) -> Bool {
        ensureFolder()
        keepVersion(of: url, replacedBy: text, now: now)
        return (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil
    }

    // MARK: Versions

    /// A hidden folder inside the notes folder holds earlier versions, so they travel with the notes and no other app lists them.
    static let versionsFolderName = ".versions"
    static let versionLimit = 20
    /// Typing saves every second or so; a version is kept at most this often.
    static let versionEvery: TimeInterval = 300

    struct Version: Identifiable, Equatable {
        var id: URL { url }
        let url: URL
        let date: Date
    }

    private func versionsFolder(for note: URL) -> URL {
        folder.appendingPathComponent(Self.versionsFolderName, isDirectory: true).appendingPathComponent(note.deletingPathExtension().lastPathComponent, isDirectory: true)
    }

    /// Before the note is overwritten, keeps what it held if that differs and the last kept version is old enough.
    private func keepVersion(of url: URL, replacedBy text: String, now: Date) {
        guard fm.fileExists(atPath: url.path), let old = try? String(contentsOf: url, encoding: .utf8), old != text,
              !old.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let existing = versions(of: url)
        if let newest = existing.first, now.timeIntervalSince(newest.date) < Self.versionEvery { return }
        let dir = versionsFolder(for: url)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        try? old.write(to: dir.appendingPathComponent(f.string(from: now) + ".md"), atomically: true, encoding: .utf8)
        for extra in versions(of: url).dropFirst(Self.versionLimit) { try? fm.removeItem(at: extra.url) }
    }

    /// Earlier versions of a note, newest first. The date is read from the file name.
    func versions(of note: URL) -> [Version] {
        let urls = (try? fm.contentsOfDirectory(at: versionsFolder(for: note), includingPropertiesForKeys: nil)) ?? []
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return urls.compactMap { u in f.date(from: u.deletingPathExtension().lastPathComponent).map { Version(url: u, date: $0) } }.sorted { $0.date > $1.date }
    }

    /// Puts an earlier version back. The text being replaced is kept as a version first, so going back can itself be undone.
    @discardableResult
    func restore(_ version: Version, to note: URL, now: Date = Date()) -> Bool {
        guard let text = try? String(contentsOf: version.url, encoding: .utf8) else { return false }
        let dir = versionsFolder(for: note)
        if let current = try? String(contentsOf: note, encoding: .utf8), current != text, !current.isEmpty {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyyMMdd-HHmmss"
            try? current.write(to: dir.appendingPathComponent(f.string(from: now) + ".md"), atomically: true, encoding: .utf8)
        }
        return (try? text.write(to: note, atomically: true, encoding: .utf8)) != nil
    }

    func append(_ text: String, to url: URL) -> Bool {
        let old = read(url)
        return save(old.isEmpty ? text : old.trimmingCharacters(in: .newlines) + "\n\n" + text, to: url)
    }

    func trash(_ url: URL) { try? fm.trashItem(at: url, resultingItemURL: nil) }

    /// Notes whose title or text holds every word, newest first.
    func search(_ query: String) -> [NoteFile] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return list() }
        return list().filter { note in
            let text = (note.title + "\n" + read(note.url)).lowercased()
            return words.allSatisfy { text.contains($0) }
        }
    }
}
