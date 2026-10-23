import Foundation

/// A prefix typed in the launcher that limits the results to one kind: "apps: saf", "files: budget", "clip: invoice".
enum LauncherFilter {
    static let prefixes: [(words: [String], category: LauncherCategory)] = [
        (["apps", "app"], .app),
        (["files", "file", "folders", "folder"], .file),
        (["windows", "window", "win"], .window),
        (["clip", "clipboard"], .clipboard),
        (["cmd", "commands", "command"], .command),
        (["emoji"], .emoji),
        (["web"], .web),
        (["settings", "setting"], .setting),
        (["snippets", "snippet"], .snippet),
        (["workflows", "workflow", "wf"], .workflow),
        (["system", "sys"], .system),
        (["tools", "tool"], .tools),
    ]

    /// The kind named at the start of `text` and what follows it. `https://…` and the like are not filters: the word must be
    /// one of the listed ones and the colon must not be followed by `//`.
    static func parse(_ text: String) -> (category: LauncherCategory, rest: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let colon = trimmed.firstIndex(of: ":") else { return nil }
        let word = trimmed[..<colon].lowercased()
        let after = trimmed[trimmed.index(after: colon)...]
        guard !after.hasPrefix("//"), let entry = prefixes.first(where: { $0.words.contains(word) }) else { return nil }
        return (entry.category, after.trimmingCharacters(in: .whitespaces))
    }
}

/// Folders the person keeps out of the launcher's file search.
enum FileSearchFilter {
    /// Whether a file is inside one of the folders (or is one). Matching is by whole folder names, so "/Users/me/Work" does not
    /// cover "/Users/me/Workshop".
    static func isExcluded(_ path: String, folders: [String]) -> Bool {
        for folder in folders {
            let clean = folder.count > 1 && folder.hasSuffix("/") ? String(folder.dropLast()) : folder
            if path == clean || path.hasPrefix(clean + "/") { return true }
        }
        return false
    }
}
