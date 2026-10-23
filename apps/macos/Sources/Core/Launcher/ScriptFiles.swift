import Foundation

/// A script file from a script folder, described by comment lines at its top (`# @raycast.title Say Hello`). The same header
/// works with `@kriya.` instead of `@raycast.`, so scripts written for Raycast run here unchanged.
struct ScriptFile: Equatable, Identifiable {
    enum Mode: String { case silent, compact, fullOutput, inline }

    struct Argument: Equatable {
        var placeholder: String
        var optional: Bool
        var secure: Bool
    }

    var path: String
    var title: String
    var mode: Mode = .compact
    var packageName: String?
    var detail: String?
    /// A short word typed in the launcher to run it with an argument.
    var keyword: String?
    var arguments: [Argument] = []
    var icon: String?
    var directory: String?

    var id: String { path }
    var fileName: String { (path as NSString).lastPathComponent }
    var subtitle: String { [packageName, detail].compactMap { $0 }.joined(separator: " · ") }
}

enum ScriptFileParser {
    /// How much of a file is read to find its header.
    static let headerBytes = 8192

    /// The script a file describes, or nil when it has no title (it is not a script command).
    static func parse(_ text: String, path: String) -> ScriptFile? {
        var script = ScriptFile(path: path, title: "")
        var found = false
        for (index, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).prefix(60).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if index == 0, line.hasPrefix("#!") { continue }
            guard let (key, value) = directive(in: line) else { continue }
            switch key {
            case "title": script.title = String(value.prefix(80)); found = !value.isEmpty
            case "mode": script.mode = ScriptFile.Mode(rawValue: value) ?? .compact
            case "packageName": script.packageName = String(value.prefix(60))
            case "description": script.detail = String(value.prefix(120))
            case "keyword": script.keyword = value.lowercased().filter { $0.isLetter || $0.isNumber }.isEmpty ? nil : String(value.lowercased().filter { $0.isLetter || $0.isNumber }.prefix(12))
            case "icon": script.icon = value
            case "currentDirectoryPath": script.directory = value
            default:
                if key.hasPrefix("argument"), let n = Int(key.dropFirst("argument".count)), (1...3).contains(n), let argument = argument(from: value) {
                    while script.arguments.count < n { script.arguments.append(ScriptFile.Argument(placeholder: "", optional: true, secure: false)) }
                    script.arguments[n - 1] = argument
                }
            }
        }
        return found ? script : nil
    }

    /// `# @raycast.title Say Hello` → ("title", "Say Hello"). Comment marks of the usual languages are allowed.
    private static func directive(in line: String) -> (String, String)? {
        var text = line
        for mark in ["//", "#", "--", ";"] where text.hasPrefix(mark) { text = String(text.dropFirst(mark.count)); break }
        text = text.trimmingCharacters(in: .whitespaces)
        for prefix in ["@raycast.", "@kriya."] where text.hasPrefix(prefix) {
            let rest = text.dropFirst(prefix.count)
            let key = rest.prefix { !$0.isWhitespace }
            guard !key.isEmpty else { return nil }
            return (String(key), rest.dropFirst(key.count).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    /// `{"type":"text","placeholder":"Name","optional":true}`
    private static func argument(from json: String) -> ScriptFile.Argument? {
        guard let data = json.data(using: .utf8), let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let type = object["type"] as? String ?? "text"
        return ScriptFile.Argument(placeholder: String((object["placeholder"] as? String ?? "").prefix(60)), optional: object["optional"] as? Bool ?? false, secure: type == "password")
    }

    /// The command that runs a script: the file itself if it can be run, otherwise the interpreter its first line names.
    static func launch(for path: String, isExecutable: Bool, firstLine: String) -> (executable: String, arguments: [String])? {
        if isExecutable { return (path, []) }
        guard firstLine.hasPrefix("#!") else { return nil }
        let parts = firstLine.dropFirst(2).split(separator: " ").map(String.init)
        guard let interpreter = parts.first, interpreter.hasPrefix("/") else { return nil }
        return (interpreter, Array(parts.dropFirst()) + [path])
    }

    /// Splits what was typed after a keyword into the script's arguments: the last one takes whatever is left.
    static func split(_ typed: String, into count: Int) -> [String] {
        let words = typed.trimmingCharacters(in: .whitespaces)
        guard count > 0, !words.isEmpty else { return [] }
        if count == 1 { return [words] }
        var out: [String] = []
        var rest = Substring(words)
        while out.count < count - 1, let space = rest.firstIndex(of: " ") {
            out.append(String(rest[..<space]))
            rest = rest[rest.index(after: space)...].drop { $0 == " " }
        }
        out.append(String(rest))
        return out
    }
}

/// The scripts found in the folders the person added, kept until a folder or a file changes.
final class ScriptFolderIndex {
    private var cache: [String: (modified: Date, script: ScriptFile?)] = [:]
    static let maxFiles = 300

    func scripts(in folders: [String], fileManager: FileManager = .default) -> [ScriptFile] {
        var found: [ScriptFile] = []
        for folder in folders {
            let names = ((try? fileManager.contentsOfDirectory(atPath: folder)) ?? []).sorted().prefix(Self.maxFiles)
            for name in names where !name.hasPrefix(".") {
                let path = (folder as NSString).appendingPathComponent(name)
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
                let modified = (try? fileManager.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .distantPast
                if let hit = cache[path], hit.modified == modified {
                    if let script = hit.script { found.append(script) }
                    continue
                }
                let script = Self.read(path)
                cache[path] = (modified, script)
                if let script { found.append(script) }
            }
        }
        return found
    }

    /// The first few kilobytes of a file, if it looks like text.
    static func read(_ path: String) -> ScriptFile? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: ScriptFileParser.headerBytes), let text = String(data: data, encoding: .utf8) else { return nil }
        return ScriptFileParser.parse(text, path: path)
    }
}
