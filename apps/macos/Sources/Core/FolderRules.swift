import Foundation

/// A file as the rules see it: just what a rule can ask about, so rules can be tried without touching a disk.
struct FolderFile: Equatable {
    var name: String
    var isDirectory = false
    var isHidden = false
    var size: Int64 = 0
    var modified: Date
    /// The Finder tags already on the file.
    var tags: [String] = []
    /// Another file in the same folder has exactly the same contents and is older. Only filled in for rules that ask.
    var isDuplicate = false

    var fileExtension: String { (name as NSString).pathExtension.lowercased() }
    var baseName: String { (name as NSString).deletingPathExtension }
}

enum FolderCondition: Codable, Equatable {
    case extensionIs([String])
    case nameContains(String)
    case nameStartsWith(String)
    /// The whole file name matches a pattern (a regular expression), ignoring capitals.
    case nameMatches(String)
    /// One of "Images", "Documents", "Archives", "Audio", "Video", "Installers".
    case kind(String)
    case olderThanDays(Int)
    case largerThanMB(Int)
    case smallerThanMB(Int)
    /// A later copy of a file that is also in the folder: the oldest of identical files is the original and is left alone.
    case isDuplicate

    var summary: String {
        switch self {
        case .extensionIs(let list): return "is " + list.map { ".\($0)" }.joined(separator: " or ")
        case .nameContains(let text): return "name contains “\(text)”"
        case .nameStartsWith(let text): return "name starts with “\(text)”"
        case .nameMatches(let pattern): return "name matches the pattern “\(pattern)”"
        case .kind(let kind): return "is \(kind.lowercased())"
        case .olderThanDays(let days): return "is older than \(days) day\(days == 1 ? "" : "s")"
        case .largerThanMB(let mb): return "is larger than \(mb) MB"
        case .smallerThanMB(let mb): return "is smaller than \(mb) MB"
        case .isDuplicate: return "is a copy of an older file in the folder"
        }
    }
}

enum FolderAction: Codable, Equatable {
    case moveTo(String)
    case copyTo(String)
    /// A new name from a pattern: {name}, {ext}, {date}, {time} and {n} (a running number).
    case rename(String)
    /// Moves to the Trash, where Undo can bring it back.
    case trash
    /// Moves into folders by kind (Images, Documents, …) inside the watched folder.
    case sortByKind
    /// Adds a Finder tag. Files that already have it are left alone.
    case tag(String)
    /// Moves into "Archive/2026-10" inside the watched folder, by the month the file was last changed.
    case archiveByMonth

    var summary: String {
        switch self {
        case .moveTo(let path): return "move to \((path as NSString).abbreviatingWithTildeInPath)"
        case .copyTo(let path): return "copy to \((path as NSString).abbreviatingWithTildeInPath)"
        case .rename(let pattern): return "rename as “\(pattern)”"
        case .trash: return "move to the Trash"
        case .sortByKind: return "sort into folders by kind"
        case .tag(let name): return "tag as “\(name)”"
        case .archiveByMonth: return "archive into month folders"
        }
    }
}

struct FolderRule: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var name: String
    /// Starts off: a new rule does nothing until the person has looked at its preview and turned it on.
    var enabled = false
    var folder: String
    var conditions: [FolderCondition]
    var action: FolderAction

    var summary: String {
        let when = conditions.map(\.summary).joined(separator: " and ")
        return "In \((folder as NSString).abbreviatingWithTildeInPath), when a file \(when): \(action.summary)"
    }
}

/// One thing a rule would do.
struct PlannedChange: Equatable {
    enum Kind: Equatable { case move, copy, trash, tag }
    var kind: Kind
    var from: String
    /// Where it goes. Nil for the Trash, which picks its own place.
    var to: String?
}

enum FolderRuleEngine {
    /// A file touched in the last minute may still be downloading or being written, so it is left for the next look.
    static let settleSeconds: TimeInterval = 60
    static let partialExtensions: Set<String> = ["crdownload", "download", "part", "partial", "tmp", "opdownload", "aria2", "filepart"]
    static let maxChangesPerRun = 200

    /// Whether a rule may touch this file at all: a file (not a folder), visible, finished, and not a partial download.
    static func eligible(_ file: FolderFile, now: Date) -> Bool {
        !file.isDirectory && !file.isHidden && !file.name.hasPrefix(".") && !partialExtensions.contains(file.fileExtension)
            && now.timeIntervalSince(file.modified) >= settleSeconds
    }

    static func matches(_ rule: FolderRule, _ file: FolderFile, now: Date) -> Bool {
        guard eligible(file, now: now), !rule.conditions.isEmpty else { return false }
        return rule.conditions.allSatisfy { holds($0, file, now: now) }
    }

    private static func holds(_ condition: FolderCondition, _ file: FolderFile, now: Date) -> Bool {
        switch condition {
        case .extensionIs(let list): return list.contains { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". ")) == file.fileExtension }
        case .nameContains(let text): return !text.isEmpty && file.name.range(of: text, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        case .nameStartsWith(let text): return !text.isEmpty && file.name.lowercased().hasPrefix(text.lowercased())
        case .nameMatches(let pattern): return NamePattern.matches(pattern, file.name)
        case .kind(let kind): return FolderTools.category(for: file.name) == kind
        case .olderThanDays(let days): return now.timeIntervalSince(file.modified) >= Double(days) * 86_400
        case .largerThanMB(let mb): return file.size > Int64(mb) * 1_048_576
        case .smallerThanMB(let mb): return file.size < Int64(mb) * 1_048_576
        case .isDuplicate: return file.isDuplicate
        }
    }

    /// The names of files that are later copies of another file in `files`. Files with the same size are compared by their
    /// fingerprint; of each identical set the oldest (then the first by name) is the original and the rest are copies.
    static func duplicateNames(_ files: [FolderFile], fingerprint: (FolderFile) -> String?) -> Set<String> {
        let candidates = files.filter { !$0.isDirectory && !$0.isHidden && !$0.name.hasPrefix(".") && $0.size > 0 }
        var copies = Set<String>()
        for group in Dictionary(grouping: candidates, by: \.size).values where group.count > 1 {
            var bySum: [String: [FolderFile]] = [:]
            for file in group { if let sum = fingerprint(file) { bySum[sum, default: []].append(file) } }
            for same in bySum.values where same.count > 1 {
                let ordered = same.sorted { ($0.modified, $0.name) < ($1.modified, $1.name) }
                for copy in ordered.dropFirst() { copies.insert(copy.name) }
            }
        }
        return copies
    }

    /// What is wrong with a rule, or nil when it is safe to run.
    static func problem(for rule: FolderRule, folderExists: (String) -> Bool = { var d: ObjCBool = false; return FileManager.default.fileExists(atPath: $0, isDirectory: &d) && d.boolValue }) -> String? {
        if rule.name.trimmingCharacters(in: .whitespaces).isEmpty { return "Give the rule a name." }
        if rule.conditions.isEmpty { return "Add at least one condition, so the rule never acts on every file." }
        for condition in rule.conditions {
            switch condition {
            case .extensionIs(let list) where list.filter({ !$0.trimmingCharacters(in: .whitespaces).isEmpty }).isEmpty: return "Name at least one file type."
            case .nameContains(let t) where t.trimmingCharacters(in: .whitespaces).isEmpty, .nameStartsWith(let t) where t.trimmingCharacters(in: .whitespaces).isEmpty: return "A name condition needs some text."
            case .nameMatches(let pattern):
                if let reason = NamePattern.problem(pattern) { return reason }
            case .olderThanDays(let d) where d < 0, .largerThanMB(let d) where d < 0, .smallerThanMB(let d) where d < 0: return "Numbers cannot be negative."
            default: break
            }
        }
        let watched = (rule.folder as NSString).standardizingPath
        if watched.isEmpty || !watched.hasPrefix("/") { return "Choose the folder to watch." }
        if !folderExists(watched) { return "The folder to watch does not exist." }
        if isOffLimits(watched) { return "That folder cannot be watched: it is the home folder or a system folder. Choose a folder inside it, such as Downloads." }
        switch rule.action {
        case .moveTo(let path), .copyTo(let path):
            let target = (path as NSString).standardizingPath
            if target.isEmpty || !target.hasPrefix("/") { return "Choose where the files go." }
            if isOffLimits(target) { return "Files cannot be sent to that place." }
            if target == watched { return "The destination is the folder being watched." }
            if target.hasPrefix(watched + "/") { return "The destination is inside the folder being watched, so the rule would find the files again." }
        case .rename(let pattern):
            if !pattern.contains("{name}") && !pattern.contains("{n}") && !pattern.contains("{date}") && !pattern.contains("{time}") { return "The new name needs {name}, {date}, {time} or {n} in it, or every file would get the same name." }
            if pattern.contains("/") || pattern.contains(":") || pattern.count > 120 { return "That is not a usable file name." }
        case .tag(let name):
            let t = name.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { return "Give the tag a name." }
            if t.count > 50 || t.contains(",") || t.contains("\n") { return "That is not a usable tag name." }
        case .trash, .sortByKind, .archiveByMonth:
            break
        }
        return nil
    }

    /// The home folder and the system's own folders are never watched or filled.
    static func isOffLimits(_ path: String) -> Bool {
        let clean = (path as NSString).standardizingPath
        return clean == "/" || clean == NSHomeDirectory() || ProtectedPaths.isProtected(clean)
    }

    /// A new name from a pattern.
    static func renamed(_ file: FolderFile, pattern: String, number: Int) -> String {
        let date = DateFormatter()
        date.locale = Locale(identifier: "en_US_POSIX")
        date.dateFormat = "yyyy-MM-dd"
        let time = DateFormatter()
        time.locale = Locale(identifier: "en_US_POSIX")
        time.dateFormat = "HH-mm-ss"
        var out = pattern
            .replacingOccurrences(of: "{name}", with: file.baseName)
            .replacingOccurrences(of: "{date}", with: date.string(from: file.modified))
            .replacingOccurrences(of: "{time}", with: time.string(from: file.modified))
            .replacingOccurrences(of: "{n}", with: String(number))
        let hasExtensionToken = pattern.contains("{ext}")
        out = out.replacingOccurrences(of: "{ext}", with: file.fileExtension)
        // A pattern that does not say where the extension goes keeps the file's own.
        if !hasExtensionToken, !file.fileExtension.isEmpty { out += "." + file.fileExtension }
        return out
    }

    /// What the rule would do now. Names that are taken (on the disk or by an earlier change in this plan) get "name 2",
    /// and nothing is ever overwritten.
    static func plan(
        _ rule: FolderRule, files: [FolderFile], now: Date,
        existingNames: (String) -> Set<String> = { Set((try? FileManager.default.contentsOfDirectory(atPath: $0)) ?? []) }
    ) -> [PlannedChange] {
        guard problem(for: rule, folderExists: { _ in true }) == nil else { return [] }
        let watched = (rule.folder as NSString).standardizingPath
        var taken: [String: Set<String>] = [:]
        func unique(_ name: String, in folder: String) -> String {
            var used = taken[folder] ?? existingNames(folder)
            let chosen = finderUniqueName(candidate: name, existing: Array(used))
            used.insert(chosen)
            taken[folder] = used
            return chosen
        }
        var changes: [PlannedChange] = []
        var number = 1
        for file in files.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) where matches(rule, file, now: now) {
            if changes.count >= maxChangesPerRun { break }
            let from = (watched as NSString).appendingPathComponent(file.name)
            switch rule.action {
            case .moveTo(let path), .copyTo(let path):
                let folder = (path as NSString).standardizingPath
                let to = (folder as NSString).appendingPathComponent(unique(file.name, in: folder))
                if case .copyTo = rule.action { changes.append(PlannedChange(kind: .copy, from: from, to: to)) } else { changes.append(PlannedChange(kind: .move, from: from, to: to)) }
            case .rename(let pattern):
                let newName = renamed(file, pattern: pattern, number: number)
                number += 1
                guard finderNameProblem(name: newName) == nil, newName != file.name else { continue }
                // Renaming happens in the same folder, so the file's own old name is about to be free.
                var names = taken[watched] ?? existingNames(watched)
                names.remove(file.name)
                taken[watched] = names
                changes.append(PlannedChange(kind: .move, from: from, to: (watched as NSString).appendingPathComponent(unique(newName, in: watched))))
            case .trash:
                changes.append(PlannedChange(kind: .trash, from: from, to: nil))
            case .tag(let name):
                let tag = name.trimmingCharacters(in: .whitespaces)
                guard !file.tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) else { continue }
                changes.append(PlannedChange(kind: .tag, from: from, to: tag))
            case .archiveByMonth:
                let f = DateFormatter()
                f.locale = Locale(identifier: "en_US_POSIX")
                f.dateFormat = "yyyy-MM"
                let folder = ((watched as NSString).appendingPathComponent("Archive") as NSString).appendingPathComponent(f.string(from: file.modified))
                changes.append(PlannedChange(kind: .move, from: from, to: (folder as NSString).appendingPathComponent(unique(file.name, in: folder))))
            case .sortByKind:
                guard let kind = FolderTools.category(for: file.name) else { continue }
                let folder = (watched as NSString).appendingPathComponent(kind)
                changes.append(PlannedChange(kind: .move, from: from, to: (folder as NSString).appendingPathComponent(unique(file.name, in: folder))))
            }
        }
        return changes
    }
}


/// The pattern behind "name matches": kept small and checked, so a mistyped pattern cannot hang the rules or match everything.
enum NamePattern {
    static let maxLength = 120

    /// What is wrong with a pattern, or nil when it can be used.
    static func problem(_ pattern: String) -> String? {
        let trimmed = pattern.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "A pattern condition needs a pattern." }
        if trimmed.count > maxLength { return "That pattern is too long." }
        if hasNestedRepeat(trimmed) { return "That pattern repeats a repeat (like (a+)+), which can make it very slow. Simplify it." }
        if (try? NSRegularExpression(pattern: trimmed, options: [.caseInsensitive])) == nil { return "That is not a valid pattern." }
        if matches(trimmed, "") { return "That pattern matches an empty name, so it would match everything." }
        return nil
    }

    /// True when the whole name fits the pattern.
    static func matches(_ pattern: String, _ name: String) -> Bool {
        let trimmed = pattern.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= maxLength, !hasNestedRepeat(trimmed),
              let regex = try? NSRegularExpression(pattern: "^(?:\(trimmed))$", options: [.caseInsensitive]) else { return false }
        let range = NSRange(name.startIndex..., in: name)
        return regex.firstMatch(in: name, options: [], range: range) != nil
    }

    /// A group that ends in a repeat and is itself repeated: the shape behind runaway matching.
    static func hasNestedRepeat(_ pattern: String) -> Bool {
        pattern.range(of: "[+*}]\\)[+*{]", options: .regularExpression) != nil
    }

    /// Which of the sample names the pattern picks, for trying a pattern before saving a rule.
    static func test(_ pattern: String, samples: [String]) -> [(name: String, matches: Bool)] {
        samples.map { ($0, matches(pattern, $0)) }
    }
}

/// Files that more than one switched-on rule in the same folder would act on, so the person can see who wins before it happens.
enum RuleOverlap {
    struct Overlap: Equatable {
        let fileName: String
        let rules: [String]
    }

    /// Rules run in the order of the list; the first to move, trash or rename a file takes it and later ones find it gone.
    static func find(_ rules: [FolderRule], files: [FolderFile], now: Date) -> [Overlap] {
        var result: [Overlap] = []
        for (folder, group) in Dictionary(grouping: rules.filter(\.enabled), by: { ($0.folder as NSString).standardizingPath }) {
            _ = folder
            guard group.count > 1 else { continue }
            for file in files.sorted(by: { $0.name < $1.name }) {
                let hits = group.filter { FolderRuleEngine.matches($0, file, now: now) && !isHarmless($0.action) }
                if hits.count > 1 { result.append(Overlap(fileName: file.name, rules: hits.map(\.name))) }
            }
        }
        return result.sorted { ($0.fileName, $0.rules.first ?? "") < ($1.fileName, $1.rules.first ?? "") }
    }

    /// Tagging and copying leave the file where it is, so a second rule can still act on it.
    private static func isHarmless(_ action: FolderAction) -> Bool {
        switch action {
        case .tag, .copyTo: return true
        default: return false
        }
    }

    static func sentence(_ overlap: Overlap) -> String {
        "“\(overlap.fileName)” fits \(overlap.rules.map { "“\($0)”" }.joined(separator: " and ")). The first in the list acts on it."
    }
}
