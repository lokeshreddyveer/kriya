import Foundation

/// The rules for a name the person types for a capture, and the name the file will really get.
enum FileNameEntry {
    /// The longest name, without its extension. File systems allow 255 bytes in all; this leaves room for an extension, a counter and
    /// "@2x" even in languages whose letters take several bytes.
    static let maxStem = 100
    /// Characters a file name cannot hold on a Mac: "/" separates folders, and ":" is how older Mac software spells that.
    static let forbidden: [Character] = ["/", ":"]

    /// What was typed with the extension the file will have taken off, when they typed it: "Shot.png" for a PNG is "Shot".
    static func stem(from typed: String, ext: String) -> String {
        let trimmed = typed.trimmingCharacters(in: .whitespaces)
        let tail = "." + ext.lowercased()
        return !ext.isEmpty && trimmed.lowercased().hasSuffix(tail) ? String(trimmed.dropLast(tail.count)).trimmingCharacters(in: .whitespaces) : trimmed
    }

    /// What is wrong with a typed name, as a sentence that says what to do, or nil if it can be used.
    static func problem(typed: String, ext: String) -> String? {
        let name = stem(from: typed, ext: ext)
        if name.isEmpty { return "Type a name for the file." }
        if let bad = name.first(where: { forbidden.contains($0) }) { return "A file name cannot contain “\(bad)”. Take it out or use another character." }
        if name.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) { return "A file name cannot contain control characters." }
        if name.hasPrefix(".") { return "A name that starts with a dot would hide the file. Start it with a letter or a number." }
        if name.count > maxStem { return "That name is too long. Use \(maxStem) characters or fewer." }
        return nil
    }

    /// The name the file will really have, with its extension: the typed name, the suffix (such as "@2x") before the extension, and a
    /// counter if a file with that name is already there. Nil if the typed name cannot be used.
    static func finalName(typed: String, ext: String, existing: (String) -> Bool = { _ in false }, suffix: (String) -> String = { _ in "" }) -> String? {
        guard problem(typed: typed, ext: ext) == nil else { return nil }
        let base = stem(from: typed, ext: ext)
        func named(_ stem: String) -> String { stem + suffix(stem) + (ext.isEmpty ? "" : "." + ext) }
        var number = 1
        var name = named(base)
        while existing(name) {
            number += 1
            name = named("\(base) \(number)")
        }
        return name
    }
}

/// What the name sheet shows as the person types: whether the name is usable, what the file will be called, and why that may differ.
struct FileNameEntryModel {
    var typed: String
    let ext: String
    var existing: (String) -> Bool = { _ in false }
    var suffix: (String) -> String = { _ in "" }

    var problem: String? { FileNameEntry.problem(typed: typed, ext: ext) }

    /// The name the file will be saved as, or nil while the typed name cannot be used.
    var finalName: String? { FileNameEntry.finalName(typed: typed, ext: ext, existing: existing, suffix: suffix) }

    var canSave: Bool { finalName != nil }

    /// What the preview line says.
    var preview: String {
        if let problem { return problem }
        return "Saved as: " + (finalName ?? "")
    }

    /// A line to add when the name had to change: a file with that name is already there, or a suffix was added.
    var note: String? {
        guard let finalName else { return nil }
        let plain = FileNameEntry.stem(from: typed, ext: ext) + (ext.isEmpty ? "" : "." + ext)
        guard finalName != plain else { return nil }
        if existing(plain) { return "A file called “\(plain)” is already there, so this one gets a number." }
        return "“\(suffix(FileNameEntry.stem(from: typed, ext: ext)))” is added for a Retina picture at full size."
    }
}
