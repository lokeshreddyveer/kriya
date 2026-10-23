import Foundation

/// Changes to a piece of clipboard text, offered when pasting from the history: paste it already tidied.
enum TextFilter: String, CaseIterable, Identifiable {
    case upper, lower, title, trim, oneLine, sortLines, uniqueLines, reverseLines, quote, numbered, bullets, stripTags
    case jsonPretty, jsonCompact, base64Encode, base64Decode, urlEncode, urlDecode, snake, kebab, camel
    var id: String { rawValue }

    var title: String {
        switch self {
        case .upper: return "UPPER CASE"
        case .lower: return "lower case"
        case .title: return "Title Case"
        case .trim: return "Trim spaces and blank lines"
        case .oneLine: return "Join into one line"
        case .sortLines: return "Sort the lines"
        case .uniqueLines: return "Remove repeated lines"
        case .reverseLines: return "Reverse the lines"
        case .quote: return "Quote each line (> )"
        case .numbered: return "Number the lines"
        case .bullets: return "Make a bullet list"
        case .stripTags: return "Remove HTML tags"
        case .jsonPretty: return "Format JSON"
        case .jsonCompact: return "Shrink JSON to one line"
        case .base64Encode: return "Encode as Base64"
        case .base64Decode: return "Decode from Base64"
        case .urlEncode: return "Encode for a web address"
        case .urlDecode: return "Decode from a web address"
        case .snake: return "snake_case"
        case .kebab: return "kebab-case"
        case .camel: return "camelCase"
        }
    }

    var symbol: String {
        switch self {
        case .upper, .lower, .title: return "textformat"
        case .trim, .oneLine: return "arrow.left.and.right.text.vertical"
        case .sortLines, .reverseLines: return "arrow.up.arrow.down"
        case .uniqueLines: return "line.3.horizontal.decrease"
        case .quote: return "text.quote"
        case .numbered: return "list.number"
        case .bullets: return "list.bullet"
        case .stripTags: return "chevron.left.forwardslash.chevron.right"
        case .jsonPretty, .jsonCompact: return "curlybraces"
        case .base64Encode, .base64Decode, .urlEncode, .urlDecode: return "lock.rotation"
        case .snake, .kebab, .camel: return "textformat.abc"
        }
    }

    /// The text after the change. The text is never longer than 200,000 characters (a longer one is left as it is).
    func apply(to text: String) -> String {
        guard text.count <= 200_000 else { return text }
        let lines = text.components(separatedBy: .newlines)
        switch self {
        case .upper: return text.uppercased()
        case .lower: return text.lowercased()
        case .title: return text.capitalized
        case .trim:
            return lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: "\n")
        case .oneLine:
            return lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
        case .sortLines:
            return lines.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.joined(separator: "\n")
        case .uniqueLines:
            var seen = Set<String>()
            return lines.filter { seen.insert($0).inserted }.joined(separator: "\n")
        case .reverseLines:
            return lines.reversed().joined(separator: "\n")
        case .quote:
            return lines.map { "> " + $0 }.joined(separator: "\n")
        case .numbered:
            return lines.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        case .bullets:
            return lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map { "- " + $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
        case .jsonPretty, .jsonCompact:
            guard let data = text.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
                  let out = try? JSONSerialization.data(withJSONObject: object, options: self == .jsonPretty ? [.prettyPrinted, .sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes] : [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes]),
                  let result = String(data: out, encoding: .utf8) else { return text }
            return result
        case .base64Encode: return Data(text.utf8).base64EncodedString()
        case .base64Decode:
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let padded = clean + String(repeating: "=", count: (4 - clean.count % 4) % 4)
            guard let data = Data(base64Encoded: padded), let decoded = String(data: data, encoding: .utf8) else { return text }
            return decoded
        case .urlEncode: return text.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? text
        case .urlDecode: return text.removingPercentEncoding ?? text
        case .snake: return Self.words(in: text).map { $0.lowercased() }.joined(separator: "_")
        case .kebab: return Self.words(in: text).map { $0.lowercased() }.joined(separator: "-")
        case .camel:
            let words = Self.words(in: text).map { $0.lowercased() }
            return (words.first ?? "") + words.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
        case .stripTags:
            let stripped = text.replacingOccurrences(of: #"<[^>]{0,500}>"#, with: "", options: .regularExpression)
            return stripped.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&nbsp;", with: " ")
        }
    }

    /// The words in a phrase or identifier: "helloWorld_foo-bar baz" gives hello, World, foo, bar, baz.
    static func words(in text: String) -> [String] {
        var spaced = ""
        var previous: Character?
        for c in text {
            if let p = previous, p.isLowercase || p.isNumber, c.isUppercase { spaced.append(" ") }
            spaced.append(c.isLetter || c.isNumber ? c : " ")
            previous = c
        }
        return spaced.split(separator: " ").map(String.init)
    }
}

/// Appending one copy to the one before: ⌘C twice quickly.
enum ClipboardMerge {
    /// The two texts as one, one under the other. Nothing is merged with an empty text, with itself, or past 200,000 characters.
    static func merge(previous: String?, new: String) -> String? {
        guard let previous, !previous.isEmpty, !new.isEmpty, previous != new else { return nil }
        let joined = previous.hasSuffix("\n") ? previous + new : previous + "\n" + new
        return joined.count <= 200_000 ? joined : nil
    }

    /// Whether the second copy came soon enough after the first to count as a double tap.
    static func isDoubleTap(first: Date?, second: Date, window: TimeInterval = 0.45) -> Bool {
        guard let first else { return false }
        let gap = second.timeIntervalSince(first)
        return gap > 0.02 && gap <= window
    }
}
