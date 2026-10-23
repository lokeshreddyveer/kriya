import Foundation

/// A saved web address with a place for what was typed: "https://github.com/search?q={query}" with the word "gh".
struct Quicklink: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var name: String
    /// A short word typed first: "gh swift" opens the search for "swift". Empty means it is only found by its name.
    var keyword: String
    /// An http or https address. `{query}` stands for what was typed after the keyword.
    var template: String

    static let placeholder = "{query}"
    var takesQuery: Bool { template.contains(Self.placeholder) }
    /// `{clipboard}` and `{selection}` fill in from the clipboard and the selected text, so the keyword alone is enough.
    var usesVariables: Bool { template.contains("{clipboard}") || template.contains("{selection}") }

    /// The address for `query`, or nil when it is not a web address. The words are encoded so they cannot change the address.
    func url(for query: String, clipboard: String = "", selection: String = "") -> URL? {
        func encode(_ raw: String) -> String? {
            let words = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard words.count <= 500 else { return nil }
            var allowed = CharacterSet.urlQueryAllowed
            allowed.remove(charactersIn: "&+=#?/;:@$,")
            return words.addingPercentEncoding(withAllowedCharacters: allowed)
        }
        guard let encoded = encode(query), let clip = encode(clipboard), let sel = encode(selection) else { return nil }
        let text = template.replacingOccurrences(of: Self.placeholder, with: encoded)
            .replacingOccurrences(of: "{clipboard}", with: clip).replacingOccurrences(of: "{selection}", with: sel)
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http", url.host?.isEmpty == false else { return nil }
        return url
    }

    /// How to use it, in the words the person would type, for showing beside the link.
    var example: String {
        let word = keyword.trimmingCharacters(in: .whitespaces)
        if takesQuery { return word.isEmpty ? "Type its name, then a space and your words" : "Type “\(word) swift” to search for swift" }
        if usesVariables {
            let source = template.contains("{selection}") ? "the selected text" : "the clipboard"
            return word.isEmpty ? "Type its name; it uses \(source)" : "Type “\(word)” to open it with \(source)"
        }
        return word.isEmpty ? "Type its name to open it" : "Type “\(word)” to open it"
    }

    /// The address a test opens: sample words stand in for what would be typed, clipboard or selected.
    var testURL: URL? { url(for: "kriya test", clipboard: "kriya test", selection: "kriya test") }

    /// Why this quicklink cannot be saved, or nil when it can.
    var problem: String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "Give it a name." }
        let word = keyword.trimmingCharacters(in: .whitespaces)
        if word.contains(" ") { return "The keyword is one word." }
        if word.count > 12 { return "The keyword is at most 12 letters." }
        if WebSearch.engines.contains(where: { $0.keyword == word.lowercased() }) { return "“\(word)” already searches \(WebSearch.engines.first { $0.keyword == word.lowercased() }?.name ?? "a site"). Pick another word." }
        if url(for: "x") == nil { return "The address must start with https:// or http://." }
        return nil
    }
}

/// A shell script the person wrote, offered as a launcher command. It runs with zsh, never through anything Kriya adds.
struct ScriptCommand: Codable, Identifiable, Equatable {
    enum Output: String, Codable, CaseIterable, Identifiable {
        case message, clipboard, nothing
        var id: String { rawValue }
        var title: String {
            switch self {
            case .message: return "Show what it prints"
            case .clipboard: return "Copy what it prints"
            case .nothing: return "Say nothing"
            }
        }
    }

    var id = UUID().uuidString
    var name: String
    var keyword: String
    /// The script. What was typed after the keyword arrives as `$1`.
    var source: String
    var output: Output = .message

    var problem: String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "Give it a name." }
        if source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "The script is empty." }
        if source.count > 20_000 { return "The script is too long." }
        let word = keyword.trimmingCharacters(in: .whitespaces)
        if word.contains(" ") { return "The keyword is one word." }
        if word.count > 12 { return "The keyword is at most 12 letters." }
        return nil
    }
}

/// What a typed line means for the quicklinks and scripts: which one it names, and the words after it.
enum LauncherExtraMatch {
    static func split(_ text: String) -> (keyword: String, rest: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let space = trimmed.firstIndex(of: " ") else { return nil }
        let rest = trimmed[trimmed.index(after: space)...].trimmingCharacters(in: .whitespaces)
        return (trimmed[..<space].lowercased(), rest)
    }

    static func quicklink(in text: String, among links: [Quicklink]) -> (link: Quicklink, query: String)? {
        guard let (word, rest) = split(text), !rest.isEmpty,
              let link = links.first(where: { $0.takesQuery && !$0.keyword.isEmpty && $0.keyword.lowercased() == word }) else { return nil }
        return (link, rest)
    }

    /// A quicklink whose address uses the clipboard or the selected text, found by typing just its keyword.
    static func variableLink(in text: String, among links: [Quicklink]) -> Quicklink? {
        let word = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !word.isEmpty, !word.contains(" ") else { return nil }
        return links.first { !$0.keyword.isEmpty && $0.keyword.lowercased() == word && $0.usesVariables && !$0.takesQuery }
    }

    /// An API command named by its keyword. One that takes words needs some after the keyword; one that does not runs on the
    /// keyword alone.
    static func apiCommand(in text: String, among commands: [APICommand]) -> (command: APICommand, query: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let (word, rest) = split(trimmed), !rest.isEmpty,
           let command = commands.first(where: { $0.takesQuery && $0.keyword.lowercased() == word }) { return (command, rest) }
        if let command = commands.first(where: { !$0.takesQuery && $0.keyword.lowercased() == trimmed.lowercased() }) { return (command, "") }
        return nil
    }

    static func script(in text: String, among scripts: [ScriptCommand]) -> (script: ScriptCommand, argument: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let (word, rest) = split(trimmed), let script = scripts.first(where: { !$0.keyword.isEmpty && $0.keyword.lowercased() == word }) {
            return (script, rest)
        }
        if let script = scripts.first(where: { !$0.keyword.isEmpty && $0.keyword.lowercased() == trimmed.lowercased() }) { return (script, "") }
        return nil
    }
}

/// The person's quicklinks and scripts, kept in the app's preferences.
final class LauncherExtras: ObservableObject {
    static let maxItems = 60

    @Published private(set) var quicklinks: [Quicklink]
    @Published private(set) var scripts: [ScriptCommand]
    @Published private(set) var apiCommands: [APICommand]
    /// Folders of script files (Raycast's format works as it is).
    @Published private(set) var scriptFolders: [String]

    private let defaults: UserDefaults
    private let foldersKey = "launcherScriptFolders.v1"
    private let linksKey = "launcherQuicklinks.v1"
    private let scriptsKey = "launcherScripts.v1"
    private let apiKey = "launcherAPICommands.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        quicklinks = defaults.data(forKey: linksKey).flatMap { try? JSONDecoder().decode([Quicklink].self, from: $0) } ?? Self.starterLinks
        scripts = defaults.data(forKey: scriptsKey).flatMap { try? JSONDecoder().decode([ScriptCommand].self, from: $0) } ?? []
        scriptFolders = defaults.stringArray(forKey: foldersKey) ?? []
        apiCommands = defaults.data(forKey: apiKey).flatMap { try? JSONDecoder().decode([APICommand].self, from: $0) } ?? []
    }

    /// A few to begin with, so the feature is visible. They are ordinary quicklinks and can be changed or removed.
    static let starterLinks = [
        Quicklink(id: "starter-maps", name: "Google Maps", keyword: "gmaps", template: "https://www.google.com/maps/search/{query}"),
        Quicklink(id: "starter-translate", name: "Google Translate", keyword: "tr", template: "https://translate.google.com/?sl=auto&text={query}"),
        Quicklink(id: "starter-amazon", name: "Amazon", keyword: "amz", template: "https://www.amazon.com/s?k={query}"),
        Quicklink(id: "starter-npm", name: "npm", keyword: "npm", template: "https://www.npmjs.com/search?q={query}"),
    ]

    /// Saves a quicklink (new or changed). Returns what is wrong with it, or nil when it was saved.
    @discardableResult
    func save(_ link: Quicklink) -> String? {
        if let problem = link.problem { return problem }
        let word = link.keyword.trimmingCharacters(in: .whitespaces).lowercased()
        if !word.isEmpty, quicklinks.contains(where: { $0.id != link.id && $0.keyword.lowercased() == word }) || scripts.contains(where: { $0.keyword.lowercased() == word }) || apiCommands.contains(where: { $0.keyword.lowercased() == word }) {
            return "“\(word)” is already used."
        }
        var saved = link
        saved.keyword = word
        saved.name = link.name.trimmingCharacters(in: .whitespaces)
        if let index = quicklinks.firstIndex(where: { $0.id == link.id }) {
            quicklinks[index] = saved
        } else {
            guard quicklinks.count < Self.maxItems else { return "That is as many as can be kept." }
            quicklinks.append(saved)
        }
        persist()
        return nil
    }

    @discardableResult
    func save(_ script: ScriptCommand) -> String? {
        if let problem = script.problem { return problem }
        let word = script.keyword.trimmingCharacters(in: .whitespaces).lowercased()
        if !word.isEmpty, scripts.contains(where: { $0.id != script.id && $0.keyword.lowercased() == word }) || quicklinks.contains(where: { $0.keyword.lowercased() == word }) || apiCommands.contains(where: { $0.keyword.lowercased() == word }) {
            return "“\(word)” is already used."
        }
        var saved = script
        saved.keyword = word
        saved.name = script.name.trimmingCharacters(in: .whitespaces)
        if let index = scripts.firstIndex(where: { $0.id == script.id }) {
            scripts[index] = saved
        } else {
            guard scripts.count < Self.maxItems else { return "That is as many as can be kept." }
            scripts.append(saved)
        }
        persist()
        return nil
    }

    @discardableResult
    func save(_ command: APICommand) -> String? {
        if let problem = command.problem { return problem }
        let word = command.keyword.trimmingCharacters(in: .whitespaces).lowercased()
        if apiCommands.contains(where: { $0.id != command.id && $0.keyword.lowercased() == word })
            || quicklinks.contains(where: { $0.keyword.lowercased() == word }) || scripts.contains(where: { $0.keyword.lowercased() == word }) {
            return "“\(word)” is already used."
        }
        var saved = command
        saved.keyword = word
        saved.name = command.name.trimmingCharacters(in: .whitespaces)
        if let index = apiCommands.firstIndex(where: { $0.id == command.id }) {
            apiCommands[index] = saved
        } else {
            guard apiCommands.count < Self.maxItems else { return "That is as many as can be kept." }
            apiCommands.append(saved)
        }
        persist()
        return nil
    }

    /// Removes a command and the keys kept for it.
    func deleteAPICommand(_ id: String) {
        if let command = apiCommands.first(where: { $0.id == id }) {
            for name in command.headerNames { KeychainSecrets.delete(APICommandRunner.account(command, header: name)) }
        }
        apiCommands.removeAll { $0.id == id }
        persist()
    }

    /// Adds a folder of scripts. Returns why it cannot be used, or nil.
    @discardableResult
    func addScriptFolder(_ path: String, folderExists: (String) -> Bool = { var d: ObjCBool = false; return FileManager.default.fileExists(atPath: $0, isDirectory: &d) && d.boolValue }) -> String? {
        let clean = (path as NSString).standardizingPath
        guard clean.hasPrefix("/"), folderExists(clean) else { return "That folder does not exist." }
        if clean == "/" || clean == NSHomeDirectory() { return "Choose a folder inside it that holds only scripts, not the whole home folder." }
        if scriptFolders.contains(clean) { return "That folder is already added." }
        guard scriptFolders.count < 10 else { return "That is as many folders as can be kept." }
        scriptFolders.append(clean)
        defaults.set(scriptFolders, forKey: foldersKey)
        return nil
    }

    func removeScriptFolder(_ path: String) {
        scriptFolders.removeAll { $0 == path }
        defaults.set(scriptFolders, forKey: foldersKey)
    }

    func deleteQuicklink(_ id: String) { quicklinks.removeAll { $0.id == id }; persist() }
    func deleteScript(_ id: String) { scripts.removeAll { $0.id == id }; persist() }

    private func persist() {
        if let data = try? JSONEncoder().encode(quicklinks) { defaults.set(data, forKey: linksKey) }
        if let data = try? JSONEncoder().encode(scripts) { defaults.set(data, forKey: scriptsKey) }
        if let data = try? JSONEncoder().encode(apiCommands) { defaults.set(data, forKey: apiKey) }
    }
}
