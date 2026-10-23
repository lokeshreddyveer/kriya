import Foundation

struct Bookmark: Equatable {
    let title: String
    let url: String
    let source: String
}

/// Reads the bookmark files browsers keep on disk. Pure: the caller supplies the bytes.
enum BookmarkParser {
    /// Chrome, Brave, Edge, Arc and Vivaldi share one JSON layout.
    static func chromium(_ data: Data, source: String) -> [Bookmark] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let roots = root["roots"] as? [String: Any] else { return [] }
        var found: [Bookmark] = []
        func walk(_ node: [String: Any]) {
            if (node["type"] as? String) == "url", let url = node["url"] as? String, let name = node["name"] as? String { found.append(Bookmark(title: name, url: url, source: source)) }
            for child in node["children"] as? [[String: Any]] ?? [] { walk(child) }
        }
        for case let node as [String: Any] in roots.values { walk(node) }
        return found
    }

    /// Safari's property list: folders hold `Children`, bookmarks have a `URLString` and a `URIDictionary`.
    static func safari(_ data: Data) -> [Bookmark] {
        guard let root = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else { return [] }
        var found: [Bookmark] = []
        func walk(_ node: [String: Any]) {
            if let url = node["URLString"] as? String {
                let title = ((node["URIDictionary"] as? [String: Any])?["title"] as? String) ?? url
                found.append(Bookmark(title: title, url: url, source: "Safari"))
            }
            for child in node["Children"] as? [[String: Any]] ?? [] { walk(child) }
        }
        walk(root)
        return found.filter { !$0.url.hasPrefix("place:") }
    }

    /// Best matches first, by title then address.
    static func search(_ query: String, in all: [Bookmark], limit: Int = 5) -> [Bookmark] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { return [] }
        return all.compactMap { b -> (Bookmark, Int)? in
            let score = max(FuzzyMatcher.score(q, in: b.title) ?? -1, (FuzzyMatcher.score(q, in: b.url).map { $0 - 200 }) ?? -1)
            return score >= 0 ? (b, score) : nil
        }.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }
}
