import Foundation

/// A website the launcher can send what was typed to.
struct SearchEngine: Identifiable, Equatable {
    let id: String
    let name: String
    /// A short word typed first to pick this engine: "yt cats" searches YouTube.
    let keyword: String
    /// The address, with `%s` where the words go.
    let template: String
    let symbol: String
}

enum WebSearch {
    static let engines: [SearchEngine] = [
        SearchEngine(id: "google", name: "Google", keyword: "g", template: "https://www.google.com/search?q=%s", symbol: "magnifyingglass"),
        SearchEngine(id: "duckduckgo", name: "DuckDuckGo", keyword: "ddg", template: "https://duckduckgo.com/?q=%s", symbol: "shield"),
        SearchEngine(id: "bing", name: "Bing", keyword: "bing", template: "https://www.bing.com/search?q=%s", symbol: "magnifyingglass"),
        SearchEngine(id: "brave", name: "Brave Search", keyword: "brave", template: "https://search.brave.com/search?q=%s", symbol: "shield.lefthalf.filled"),
        SearchEngine(id: "ecosia", name: "Ecosia", keyword: "eco", template: "https://www.ecosia.org/search?q=%s", symbol: "leaf"),
        SearchEngine(id: "youtube", name: "YouTube", keyword: "yt", template: "https://www.youtube.com/results?search_query=%s", symbol: "play.rectangle"),
        SearchEngine(id: "maps", name: "Apple Maps", keyword: "maps", template: "https://maps.apple.com/?q=%s", symbol: "map"),
        SearchEngine(id: "github", name: "GitHub", keyword: "gh", template: "https://github.com/search?q=%s", symbol: "chevron.left.forwardslash.chevron.right"),
        SearchEngine(id: "wikipedia", name: "Wikipedia", keyword: "wiki", template: "https://en.wikipedia.org/w/index.php?search=%s", symbol: "book"),
        SearchEngine(id: "stackoverflow", name: "Stack Overflow", keyword: "so", template: "https://stackoverflow.com/search?q=%s", symbol: "questionmark.bubble"),
    ]

    /// The engines a person picks as the default for plain searches (not the ones that only suit one kind of search).
    static var general: [SearchEngine] { engines.filter { ["google", "duckduckgo", "bing", "brave", "ecosia"].contains($0.id) } }

    static let defaultEngineID = "google"

    static func engine(id: String?) -> SearchEngine {
        engines.first { $0.id == id } ?? engines[0]
    }

    /// The address that searches `engine` for `query`, or nil for nothing to search for.
    static func url(for engine: SearchEngine, query: String) -> URL? {
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty, words.count <= 500 else { return nil }
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=#?/;:@$,")
        guard let encoded = words.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: engine.template.replacingOccurrences(of: "%s", with: encoded))
    }

    /// "yt cats" is a YouTube search for "cats". Nil when the first word is not an engine's keyword, or nothing follows it.
    static func trigger(in text: String) -> (engine: SearchEngine, query: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let space = trimmed.firstIndex(of: " ") else { return nil }
        let word = trimmed[..<space].lowercased()
        let rest = trimmed[trimmed.index(after: space)...].trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty, let engine = engines.first(where: { $0.keyword == word }) else { return nil }
        return (engine, rest)
    }

    private static let topLevelDomains: Set<String> = [
        "com", "org", "net", "io", "dev", "app", "co", "ai", "edu", "gov", "info", "me", "tv", "xyz", "uk", "de", "fr", "in", "jp", "ca", "au", "nl", "ru", "us", "eu", "ch", "se", "no", "es", "it", "br", "cn", "kr", "sh", "so", "cc", "ly", "gg", "to", "fm", "tech", "online", "site", "store", "blog", "cloud",
    ]

    /// A web address typed as one word: "example.com", "https://example.com/page", "localhost:3000". Nothing else counts, so a
    /// sentence or a sum is never mistaken for one.
    static func address(in text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 300, !trimmed.contains(" "), !trimmed.contains("\n") else { return nil }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            guard let url = URL(string: trimmed), let host = url.host, host.contains(".") || host == "localhost" else { return nil }
            return url
        }
        if lower.hasPrefix("localhost") {
            let rest = lower.dropFirst("localhost".count)
            guard rest.isEmpty || rest.first == ":" || rest.first == "/" else { return nil }
            return URL(string: "http://" + trimmed)
        }
        // "example.com" or "example.com/path": a name, a dot and a real ending, with no other odd characters before the path.
        let hostPart = String(lower.prefix { $0 != "/" && $0 != "?" && $0 != "#" })
        let labels = hostPart.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }), let ending = labels.last, topLevelDomains.contains(String(ending).split(separator: ":")[0].description) else { return nil }
        guard hostPart.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == ":" }) else { return nil }
        return URL(string: "https://" + trimmed)
    }
}
