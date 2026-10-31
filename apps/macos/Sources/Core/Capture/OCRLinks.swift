import Foundation

/// A web address or e-mail address found in text read from a picture.
struct DetectedLink: Equatable, Identifiable {
    let url: URL
    /// Where it sits in the text (UTF-16 units, as `NSRange` counts them).
    let range: NSRange
    /// The words as the picture had them, which may be shorter than the address ("example.com/a").
    let shown: String

    var id: String { "\(range.location):\(range.length)" }
    /// A web page. Only these can be opened or sent through Link Routing; an e-mail address can only be copied.
    var isWeb: Bool { ["http", "https"].contains(url.scheme?.lowercased() ?? "") }
    /// What "ignore this link" remembers.
    var key: String { IgnoredLinks.key(for: url) }
}

/// What a picture's text says, and which links are in it.
struct OCRTextResult: Equatable {
    var text: String
    var links: [DetectedLink]
}

/// What can be done with a link found in a picture. None of them happens by itself: each is chosen by the person.
enum OCRLinkAction: String, CaseIterable, Identifiable {
    case open, copy, route, ignore
    var id: String { rawValue }

    var title: String {
        switch self {
        case .open: return "Open link"
        case .copy: return "Copy link"
        case .route: return "Route through Link Routing"
        case .ignore: return "Ignore this link"
        }
    }

    func isAvailable(for link: DetectedLink) -> Bool {
        switch self {
        case .open, .route: return link.isWeb
        case .copy, .ignore: return true
        }
    }
}

/// What the actions do. Given by the app; a check gives its own, so it can see that nothing opens by itself.
struct OCRLinkHandlers {
    var open: (URL) -> Void
    var copy: (String) -> Void
    var route: (URL) -> Void
    var ignore: (URL) -> Void
}

enum OCRLinks {
    /// More links than this in one picture is a list, not a few to choose from.
    static let maxOffered = 8

    /// Web and e-mail addresses in the text, in the order they appear. Found with the system's own link detector.
    static func detect(in text: String) -> [DetectedLink] {
        guard !text.isEmpty, let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        let whole = NSRange(text.startIndex..., in: text)
        var found: [DetectedLink] = []
        detector.enumerateMatches(in: text, options: [], range: whole) { match, _, _ in
            guard let match, let url = match.url, let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme),
                  let range = Range(match.range, in: text) else { return }
            found.append(DetectedLink(url: url, range: match.range, shown: String(text[range])))
        }
        return found
    }

    /// The text with its links, leaving out ones the person said to ignore and ones that repeat. The text itself is not changed.
    static func result(for text: String, ignored: IgnoredLinks = IgnoredLinks()) -> OCRTextResult {
        var seen = Set<String>()
        let links = detect(in: text).filter { link in
            !ignored.contains(link.url) && seen.insert(link.key).inserted
        }
        return OCRTextResult(text: text, links: Array(links.prefix(maxOffered)))
    }

    /// The links to offer after text was read from a picture: none when link detection is off. Nothing is opened here or anywhere
    /// along the way; the links are only listed, and the person chooses what happens to each.
    static func offers(in text: String, policy: TextPolicy, ignored: IgnoredLinks) -> [DetectedLink] {
        policy.detectLinks ? result(for: text, ignored: ignored).links : []
    }

    /// Does what the person chose. The only place a link is ever opened or routed.
    static func perform(_ action: OCRLinkAction, on link: DetectedLink, using handlers: OCRLinkHandlers) {
        guard action.isAvailable(for: link) else { return }
        switch action {
        case .open: handlers.open(link.url)
        case .copy: handlers.copy(link.url.absoluteString)
        case .route: handlers.route(link.url)
        case .ignore: handlers.ignore(link.url)
        }
    }
}

/// Links the person said not to offer again. Kept by address, so the same link in another picture is not offered either.
struct IgnoredLinks: Codable, Equatable {
    static let limit = 200

    private(set) var keys: [String] = []

    init(keys: [String] = []) { self.keys = Array(keys.suffix(Self.limit)) }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        keys = Array(c.value(.keys, [String]()).suffix(Self.limit))
    }

    /// The same address written two ways (capital letters in the host, a slash at the end, a #fragment) is one link.
    static func key(for url: URL) -> String {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString.lowercased() }
        parts.scheme = parts.scheme?.lowercased()
        parts.host = parts.host?.lowercased()
        parts.fragment = nil
        if parts.path.count > 1, parts.path.hasSuffix("/") { parts.path.removeLast() }
        if parts.path == "/" { parts.path = "" }
        return parts.string ?? url.absoluteString.lowercased()
    }

    func contains(_ url: URL) -> Bool { keys.contains(Self.key(for: url)) }

    func adding(_ url: URL) -> IgnoredLinks {
        let key = Self.key(for: url)
        var next = keys.filter { $0 != key }
        next.append(key)
        return IgnoredLinks(keys: next)
    }

    func removing(_ url: URL) -> IgnoredLinks { IgnoredLinks(keys: keys.filter { $0 != Self.key(for: url) }) }
}

/// Reads and writes the ignored links. Takes the preferences to use, so a check never touches the real ones.
struct IgnoredLinkStore {
    static let key = "capture.ignoredLinks.v1"
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var links: IgnoredLinks {
        get { defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(IgnoredLinks.self, from: $0) } ?? IgnoredLinks() }
        nonmutating set { if let data = try? JSONEncoder().encode(newValue) { defaults.set(data, forKey: Self.key) } }
    }
}
