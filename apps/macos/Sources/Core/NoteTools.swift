import CryptoKit
import Foundation

/// #tags written inside a note's text.
enum NoteTags {
    /// The tags in a text, lower-case, without the #, in the order first seen. A tag starts with a letter, may hold letters, digits,
    /// "-" and "_", and is not part of a word, a web address or a Markdown heading.
    static func extract(_ text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"(?<![\p{L}\p{N}_&/#])#([\p{L}][\p{L}\p{N}_-]{0,29})"#) else { return [] }
        var seen = Set<String>()
        var out: [String] = []
        // Code fences hold things like "#include"; they are skipped.
        var inFence = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inFence.toggle(); continue }
            if inFence { continue }
            let s = String(line)
            for m in regex.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
                guard let r = Range(m.range(at: 1), in: s) else { continue }
                let tag = s[r].lowercased()
                if seen.insert(tag).inserted { out.append(tag) }
            }
        }
        return out
    }

    /// "tag:work budget" becomes the tag "work" and the words "budget".
    static func parseQuery(_ query: String) -> (tags: [String], words: String) {
        var tags: [String] = []
        var rest: [String] = []
        for part in query.split(separator: " ") {
            if part.lowercased().hasPrefix("tag:"), part.count > 4 { tags.append(String(part.dropFirst(4)).trimmingCharacters(in: CharacterSet(charactersIn: "#")).lowercased()) }
            else if part.hasPrefix("#"), part.count > 1 { tags.append(String(part.dropFirst()).lowercased()) }
            else { rest.append(String(part)) }
        }
        return (tags, rest.joined(separator: " "))
    }

    /// Every tag across notes with how many notes carry it, most used first.
    static func counts(_ texts: [String]) -> [(tag: String, notes: Int)] {
        var counts: [String: Int] = [:]
        for text in texts { for tag in extract(text) { counts[tag, default: 0] += 1 } }
        return counts.map { (tag: $0.key, notes: $0.value) }.sorted { ($1.notes, $0.tag) < ($0.notes, $1.tag) }
    }
}

/// Reusable starting text with a few variables.
struct NoteTemplate: Equatable, Identifiable {
    var id: String { name }
    let name: String
    let body: String

    static let starters: [NoteTemplate] = [
        NoteTemplate(name: "Meeting", body: "# {title}\n\n{date} {time}\n\n**With:** \n\n## Notes\n\n{cursor}\n\n## Actions\n\n- [ ] "),
        NoteTemplate(name: "Daily log", body: "# {weekday} {date}\n\n## Done\n\n{cursor}\n\n## Next\n\n- [ ] "),
        NoteTemplate(name: "Checklist", body: "# {title}\n\n- [ ] {cursor}\n- [ ] \n- [ ] "),
    ]

    /// The text with {title}, {date}, {time}, {weekday} and {clipboard} filled in, and where the caret should go (at {cursor}).
    func render(title: String, date: Date, clipboard: String = "") -> (text: String, cursor: Int) {
        func format(_ pattern: String) -> String {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = pattern
            return f.string(from: date)
        }
        var text = body
            .replacingOccurrences(of: "{title}", with: title.isEmpty ? "Untitled" : title)
            .replacingOccurrences(of: "{date}", with: format("yyyy-MM-dd"))
            .replacingOccurrences(of: "{time}", with: format("HH:mm"))
            .replacingOccurrences(of: "{weekday}", with: format("EEEE"))
            .replacingOccurrences(of: "{clipboard}", with: String(clipboard.prefix(2000)))
        var cursor = text.count
        if let r = text.range(of: "{cursor}") {
            cursor = text.distance(from: text.startIndex, to: r.lowerBound)
            text.replaceSubrange(r, with: "")
        }
        return (text.replacingOccurrences(of: "{cursor}", with: ""), cursor)
    }

    /// A template file name safe to use, from the name the person gave.
    static func fileName(for name: String) -> String {
        let bad = CharacterSet(charactersIn: "/:\\?%*|\"<>.").union(.controlCharacters)
        // Each removed character leaves a space; runs of spaces become one.
        let clean = name.components(separatedBy: bad).joined(separator: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return (clean.isEmpty ? "Template" : String(clean.prefix(50)).trimmingCharacters(in: .whitespaces)) + ".md"
    }
}

/// Locking a note's text with a key kept in the Keychain. Nothing is stored in the note's file name or beside it.
enum NoteCrypto {
    enum Failure: Error, Equatable { case badKey, damaged, notEncrypted }

    static let magic = Data("KRIYANOTE1".utf8)

    static func newKey() -> Data { SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) } }

    static func seal(_ text: String, key: Data) throws -> Data {
        guard key.count == 32 else { throw Failure.badKey }
        let box = try AES.GCM.seal(Data(text.utf8), using: SymmetricKey(data: key), authenticating: magic)
        guard let combined = box.combined else { throw Failure.damaged }
        return magic + combined
    }

    static func open(_ data: Data, key: Data) throws -> String {
        guard key.count == 32 else { throw Failure.badKey }
        guard data.starts(with: magic) else { throw Failure.notEncrypted }
        do {
            let box = try AES.GCM.SealedBox(combined: data.dropFirst(magic.count))
            let plain = try AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: magic)
            return String(decoding: plain, as: UTF8.self)
        } catch { throw Failure.damaged }
    }

    static let keychainAccount = "notes.encryptionKey"

    /// The key, made and kept in the Keychain the first time it is needed. Nil if the Keychain refuses.
    static func keyFromKeychain(create: Bool) -> Data? {
        if let text = KeychainSecrets.get(keychainAccount), let data = Data(base64Encoded: text), data.count == 32 { return data }
        guard create else { return nil }
        let key = newKey()
        return KeychainSecrets.set(key.base64EncodedString(), for: keychainAccount) ? key : nil
    }
}

/// Files attached to a note, kept in a folder of their own.
enum NoteAttachments {
    static let folderName = ".attachments"
    static let maxBytes: Int64 = 100_000_000

    /// A name that cannot leave its folder or hide: no slashes, no leading dot, no control characters, not too long.
    static func safeName(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "/:\\").union(.controlCharacters)
        var clean = name.components(separatedBy: bad).joined(separator: "-").trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespaces))
        if clean.isEmpty { clean = "file" }
        if clean.count > 100 {
            let ext = (clean as NSString).pathExtension
            let stem = String((clean as NSString).deletingPathExtension.prefix(90))
            clean = ext.isEmpty ? stem : stem + "." + String(ext.prefix(8))
        }
        return clean
    }

    /// The Markdown that points at an attachment from the note, relative to the notes folder.
    static func link(noteStem: String, fileName: String) -> String {
        let escaped = fileName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? fileName
        let folder = noteStem.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? noteStem
        let isImage = ["png", "jpg", "jpeg", "gif", "heic", "webp"].contains((fileName as NSString).pathExtension.lowercased())
        return "\(isImage ? "!" : "")[\(fileName)](\(folderName)/\(folder)/\(escaped))"
    }
}

/// Notes kept at the top of the list. A note is known by its file name without the ending, so locking or unlocking it keeps its pin.
enum NotePins {
    static func key(_ url: URL) -> String { url.deletingPathExtension().lastPathComponent }

    /// Pinned notes first, each group in its own order.
    static func apply(_ notes: [NoteFile], pinned: Set<String>) -> [NoteFile] {
        notes.filter { pinned.contains(key($0.url)) } + notes.filter { !pinned.contains(key($0.url)) }
    }

    static func toggled(_ pinned: Set<String>, _ url: URL) -> Set<String> {
        var next = pinned
        let k = key(url)
        if next.contains(k) { next.remove(k) } else { next.insert(k) }
        return next
    }

    static let defaultsKey = "notes.pinned.v1"
    static var stored: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: defaultsKey) }
    }
}
