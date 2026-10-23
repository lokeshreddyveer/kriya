import Foundation

/// One page a web lookup found: its title, address and the opening text of it.
struct ResearchSource: Equatable {
    let title: String
    let url: String
    let extract: String
}

/// The pure parts of Kriya's optional web research: which Wikipedia to ask, how the question becomes a request, how the answer
/// is read, and how the on-device model is told to use only what was found. Only the question's words are ever sent, and only
/// to Wikipedia.
enum WebResearch {
    static let maxSources = 4
    static let maxExtractCharacters = 1200
    static let maxQuestionCharacters = 200

    /// Wikipedia language codes to ask, in order, for this question: the language of its script, then English.
    static func languages(for question: String) -> [String] {
        var codes: [String] = []
        for scalar in question.unicodeScalars {
            let code: String?
            switch scalar.value {
            case 0x0C00...0x0C7F: code = "te"   // Telugu
            case 0x0B80...0x0BFF: code = "ta"   // Tamil
            case 0x0C80...0x0CFF: code = "kn"   // Kannada
            case 0x0D00...0x0D7F: code = "ml"   // Malayalam
            case 0x0900...0x097F: code = "hi"   // Devanagari
            case 0x0980...0x09FF: code = "bn"   // Bengali
            default: code = nil
            }
            if let code, !codes.contains(code) { codes.append(code) }
        }
        // A question in English that names a language still gets that language's Wikipedia as well.
        let lower = question.lowercased()
        for (word, code) in [("telugu", "te"), ("tamil", "ta"), ("kannada", "kn"), ("malayalam", "ml"), ("hindi", "hi"), ("bengali", "bn")] where lower.contains(word) && !codes.contains(code) {
            codes.append(code)
        }
        if !codes.contains("en") { codes.append("en") }
        return Array(codes.prefix(2))
    }

    /// The request that searches a Wikipedia for the question and returns the opening text of the best pages.
    static func requestURL(question: String, language: String) -> URL? {
        let words = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty, words.count <= maxQuestionCharacters, language.range(of: #"^[a-z]{2,3}$"#, options: .regularExpression) != nil else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "\(language).wikipedia.org"
        components.path = "/w/api.php"
        components.queryItems = [
            URLQueryItem(name: "action", value: "query"), URLQueryItem(name: "format", value: "json"), URLQueryItem(name: "formatversion", value: "2"),
            URLQueryItem(name: "generator", value: "search"), URLQueryItem(name: "gsrsearch", value: words), URLQueryItem(name: "gsrlimit", value: "3"),
            URLQueryItem(name: "prop", value: "extracts|info"), URLQueryItem(name: "exintro", value: "1"), URLQueryItem(name: "explaintext", value: "1"),
            URLQueryItem(name: "exlimit", value: "3"), URLQueryItem(name: "inprop", value: "url"), URLQueryItem(name: "redirects", value: "1"),
        ]
        return components.url
    }

    /// The pages in a Wikipedia answer, best match first. Pages with no text, and addresses that are not Wikipedia's, are dropped.
    static func parse(_ data: Data) -> [ResearchSource] {
        guard data.count < 2_000_000,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let query = root["query"] as? [String: Any], let pages = query["pages"] as? [[String: Any]] else { return [] }
        return pages
            .sorted { ($0["index"] as? Int ?? 99) < ($1["index"] as? Int ?? 99) }
            .compactMap { page -> ResearchSource? in
                guard let title = page["title"] as? String, let url = page["fullurl"] as? String, let host = URL(string: url)?.host, host.hasSuffix(".wikipedia.org"),
                      let extract = (page["extract"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !extract.isEmpty else { return nil }
                return ResearchSource(title: String(title.prefix(120)), url: url, extract: String(extract.prefix(maxExtractCharacters)))
            }
    }

    /// Several lists of sources joined into one, each address once, at most `maxSources`.
    static func merge(_ lists: [[ResearchSource]]) -> [ResearchSource] {
        var seen = Set<String>()
        var out: [ResearchSource] = []
        // Take one from each list in turn so no language crowds the others out.
        let longest = lists.map(\.count).max() ?? 0
        for index in 0..<longest {
            for list in lists where list.indices.contains(index) && seen.insert(list[index].url).inserted { out.append(list[index]) }
        }
        return Array(out.prefix(maxSources))
    }

    static let instructions = """
        You answer a question using only the numbered sources you are given. Cite the source after each fact like [1]. If the sources do not contain the answer, say so plainly and do not guess. Never invent names, dates, cast, release years or links. Keep it short.
        """

    /// What the model is shown: the question and the sources.
    static func prompt(question: String, sources: [ResearchSource]) -> String {
        let list = sources.enumerated().map { "[\($0.offset + 1)] \($0.element.title) (\($0.element.url))\n\($0.element.extract)" }.joined(separator: "\n\n")
        return "Question: \(question)\n\nSources:\n\(list)"
    }

    /// The sources as lines to read under the answer.
    static func sourceLines(_ sources: [ResearchSource]) -> String {
        sources.enumerated().map { "[\($0.offset + 1)] \($0.element.title): \($0.element.url)" }.joined(separator: "\n")
    }
}
