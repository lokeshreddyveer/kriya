import Foundation

struct NoteFile: Identifiable, Equatable {
    var id: URL { url }
    let url: URL
    let title: String
    let modified: Date
    var locked: Bool { url.pathExtension == NoteStore.lockedExtension }
}

/// Notes are plain Markdown files in one folder, so any other app can open them and nothing is locked in.
struct NoteStore {
    let folder: URL
    private let fm = FileManager.default
    /// A locked note is a file with this ending holding encrypted text.
    static let lockedExtension = "kriyanote"
    /// The key for locked notes; looked up in the Keychain unless a test hands one in.
    var keyProvider: (Bool) -> Data? = { NoteCrypto.keyFromKeychain(create: $0) }

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
        return urls.filter { ["md", "markdown", "txt", Self.lockedExtension].contains($0.pathExtension.lowercased()) }.map { url in
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            // A locked note's title is not read: it would give away what is inside.
            let title = url.pathExtension == Self.lockedExtension ? "Locked note" : Self.title(of: (try? String(contentsOf: url, encoding: .utf8)) ?? "")
            return NoteFile(url: url, title: title, modified: modified)
        }.sorted { $0.modified > $1.modified }
    }

    func read(_ url: URL) -> String {
        if url.pathExtension == Self.lockedExtension {
            guard let key = keyProvider(false), let data = try? Data(contentsOf: url), let text = try? NoteCrypto.open(data, key: key) else { return "" }
            return text
        }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    // MARK: Locking

    /// Replaces a note with an encrypted copy. The plain file is removed only after the locked one is written and reads back.
    @discardableResult
    func lock(_ url: URL) -> URL? {
        guard url.pathExtension != Self.lockedExtension, let key = keyProvider(true), let text = try? String(contentsOf: url, encoding: .utf8),
              let sealed = try? NoteCrypto.seal(text, key: key) else { return nil }
        let target = url.deletingPathExtension().appendingPathExtension(Self.lockedExtension)
        guard (try? sealed.write(to: target, options: .atomic)) != nil, (try? NoteCrypto.open(Data(contentsOf: target), key: key)) == text else { return nil }
        // Earlier plain versions would still hold the words, so they go too.
        try? fm.removeItem(at: versionsFolder(for: url))
        try? fm.removeItem(at: url)
        return target
    }

    /// Turns a locked note back into a plain Markdown file.
    @discardableResult
    func unlock(_ url: URL) -> URL? {
        guard url.pathExtension == Self.lockedExtension, let key = keyProvider(false), let data = try? Data(contentsOf: url), let text = try? NoteCrypto.open(data, key: key) else { return nil }
        let target = url.deletingPathExtension().appendingPathExtension("md")
        guard !fm.fileExists(atPath: target.path), (try? text.write(to: target, atomically: true, encoding: .utf8)) != nil else { return nil }
        try? fm.removeItem(at: url)
        return target
    }

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
        if url.pathExtension == Self.lockedExtension {
            guard let key = keyProvider(false), let sealed = try? NoteCrypto.seal(text, key: key) else { return false }
            return (try? sealed.write(to: url, options: .atomic)) != nil
        }
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

    func trash(_ url: URL) {
        try? fm.trashItem(at: url, resultingItemURL: nil)
        // Its attachments and earlier versions go with it, to the Trash so they can come back.
        for extra in [attachmentsFolder(for: url), versionsFolder(for: url)] where fm.fileExists(atPath: extra.path) { try? fm.trashItem(at: extra, resultingItemURL: nil) }
    }

    // MARK: Attachments

    func attachmentsFolder(for note: URL) -> URL {
        folder.appendingPathComponent(NoteAttachments.folderName, isDirectory: true).appendingPathComponent(note.deletingPathExtension().lastPathComponent, isDirectory: true)
    }

    func attachments(of note: URL) -> [URL] {
        ((try? fm.contentsOfDirectory(at: attachmentsFolder(for: note), includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []).sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Copies a file into the note's attachment folder under a safe, unused name. Returns the Markdown link to put in the note.
    func attach(_ source: URL, to note: URL) -> String? {
        let size = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 } ?? 0
        let isFolder = (try? source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        guard Int64(size) <= NoteAttachments.maxBytes, !isFolder else { return nil }
        let dir = attachmentsFolder(for: note)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var name = NoteAttachments.safeName(source.lastPathComponent)
        var n = 2
        while fm.fileExists(atPath: dir.appendingPathComponent(name).path) {
            let base = (NoteAttachments.safeName(source.lastPathComponent) as NSString)
            name = base.pathExtension.isEmpty ? "\(base) \(n)" : "\(base.deletingPathExtension) \(n).\(base.pathExtension)"
            n += 1
        }
        guard (try? fm.copyItem(at: source, to: dir.appendingPathComponent(name))) != nil else { return nil }
        return NoteAttachments.link(noteStem: note.deletingPathExtension().lastPathComponent, fileName: name)
    }

    func removeAttachment(_ file: URL) { try? fm.trashItem(at: file, resultingItemURL: nil) }

    // MARK: Templates

    var templatesFolder: URL { folder.appendingPathComponent(".templates", isDirectory: true) }

    /// The ready-made templates plus any the person saved as Markdown files in the templates folder (theirs win by name).
    func templates() -> [NoteTemplate] {
        let saved = ((try? fm.contentsOfDirectory(at: templatesFolder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
            .filter { $0.pathExtension == "md" }
            .compactMap { url in (try? String(contentsOf: url, encoding: .utf8)).map { NoteTemplate(name: url.deletingPathExtension().lastPathComponent, body: $0) } }
        let names = Set(saved.map(\.name))
        return saved.sorted { $0.name < $1.name } + NoteTemplate.starters.filter { !names.contains($0.name) }
    }

    @discardableResult
    func saveTemplate(named name: String, body: String) -> Bool {
        try? fm.createDirectory(at: templatesFolder, withIntermediateDirectories: true)
        return (try? body.write(to: templatesFolder.appendingPathComponent(NoteTemplate.fileName(for: name)), atomically: true, encoding: .utf8)) != nil
    }

    /// Notes whose title or text holds every word, newest first.
    func search(_ query: String) -> [NoteFile] {
        let parsed = NoteTags.parseQuery(query)
        if !parsed.tags.isEmpty {
            let matching = list().filter { note in
                guard !note.locked else { return false }
                let tags = Set(NoteTags.extract(read(note.url)))
                return parsed.tags.allSatisfy(tags.contains)
            }
            let words = parsed.words.lowercased().split(separator: " ").map(String.init)
            return matching.filter { note in
                words.isEmpty || { let text = (note.title + "\n" + read(note.url)).lowercased(); return words.allSatisfy { text.contains($0) } }()
            }
        }
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return list() }
        // A locked note is found only by being listed; its words are not searched.
        return list().filter { note in
            if note.locked { return false }
            let text = (note.title + "\n" + read(note.url)).lowercased()
            return words.allSatisfy { text.contains($0) }
        }
    }
}
