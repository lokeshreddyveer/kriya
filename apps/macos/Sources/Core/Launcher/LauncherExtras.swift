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

    /// The address for `query`, or nil when it is not a web address. The words are encoded so they cannot change the address.
    func url(for query: String) -> URL? {
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard words.count <= 500 else { return nil }
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=#?/;:@$,")
        guard let encoded = words.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        let text = template.replacingOccurrences(of: Self.placeholder, with: encoded)
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http", url.host?.isEmpty == false else { return nil }
        return url
    }

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

    private let defaults: UserDefaults
    private let linksKey = "launcherQuicklinks.v1"
    private let scriptsKey = "launcherScripts.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        quicklinks = defaults.data(forKey: linksKey).flatMap { try? JSONDecoder().decode([Quicklink].self, from: $0) } ?? Self.starterLinks
        scripts = defaults.data(forKey: scriptsKey).flatMap { try? JSONDecoder().decode([ScriptCommand].self, from: $0) } ?? []
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
        if !word.isEmpty, quicklinks.contains(where: { $0.id != link.id && $0.keyword.lowercased() == word }) || scripts.contains(where: { $0.keyword.lowercased() == word }) {
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
        if !word.isEmpty, scripts.contains(where: { $0.id != script.id && $0.keyword.lowercased() == word }) || quicklinks.contains(where: { $0.keyword.lowercased() == word }) {
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

    func deleteQuicklink(_ id: String) { quicklinks.removeAll { $0.id == id }; persist() }
    func deleteScript(_ id: String) { scripts.removeAll { $0.id == id }; persist() }

    private func persist() {
        if let data = try? JSONEncoder().encode(quicklinks) { defaults.set(data, forKey: linksKey) }
        if let data = try? JSONEncoder().encode(scripts) { defaults.set(data, forKey: scriptsKey) }
    }
}
