import Foundation

/// Tidies what the speech recogniser heard: spoken punctuation and line breaks become the real thing.
enum DictationText {
    private static let replacements: [(spoken: String, written: String)] = [
        ("new paragraph", "\n\n"), ("new line", "\n"), ("full stop", "."), ("period", "."), ("comma", ","), ("question mark", "?"),
        ("exclamation mark", "!"), ("exclamation point", "!"), ("colon", ":"), ("semicolon", ";"), ("open bracket", "("), ("close bracket", ")"),
        ("open quote", "“"), ("close quote", "”"), ("hyphen", "-"), ("dash", " —"),
    ]

    static func process(_ raw: String, spokenPunctuation: Bool = true) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        if spokenPunctuation {
            for (spoken, written) in replacements {
                text = text.replacingOccurrences(of: "\\s*\\b\(NSRegularExpression.escapedPattern(for: spoken))\\b\\s*", with: written == "\n" || written == "\n\n" ? written : written + " ", options: [.regularExpression, .caseInsensitive])
            }
            // No space before closing marks, and none left dangling at the ends of lines.
            text = text.replacingOccurrences(of: " +([.,?!:;)”])", with: "$1", options: .regularExpression)
            text = text.replacingOccurrences(of: "([(“]) +", with: "$1", options: .regularExpression)
            text = text.replacingOccurrences(of: " *\n *", with: "\n", options: .regularExpression)
            text = text.trimmingCharacters(in: .whitespaces)
        }
        // A sentence starts with a capital.
        var out = ""
        var capitalise = true
        for ch in text {
            if capitalise, ch.isLetter { out.append(contentsOf: String(ch).uppercased()); capitalise = false }
            else { out.append(ch) }
            if ".?!\n".contains(ch) { capitalise = true } else if ch.isLetter || ch.isNumber { capitalise = false }
        }
        return out
    }
}
