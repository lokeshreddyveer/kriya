import Foundation

/// The numbers behind `{counter:name}`. A preview shows the next number without using it; inserting the snippet uses it.
enum SnippetCounters {
    private static func key(_ name: String) -> String { "snippetCounter.\(name)" }

    static func peek(_ name: String, defaults: UserDefaults = .standard) -> Int { defaults.integer(forKey: key(name)) + 1 }

    /// Counts up every `{counter:name}` the snippet holds, once each.
    static func advance(in body: String, defaults: UserDefaults = .standard) {
        var names = Set<String>()
        var rest = Substring(body)
        while let start = rest.range(of: "{counter:") {
            rest = rest[start.upperBound...]
            if let end = rest.firstIndex(of: "}") { names.insert(rest[..<end].trimmingCharacters(in: .whitespaces)); rest = rest[end...] }
        }
        for name in names where !name.isEmpty { defaults.set(defaults.integer(forKey: key(name)) + 1, forKey: key(name)) }
    }
}
