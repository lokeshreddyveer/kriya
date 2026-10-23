import Foundation

/// Which languages the text reader should expect. Empty means "work it out from the picture".
enum OCRLanguages {
    static let defaultsKey = "capture.ocrLanguages"

    /// The chosen codes, kept only if the reader supports them, in the order chosen, without repeats, at most five.
    static func resolve(chosen: [String], supported: [String]) -> [String] {
        var seen = Set<String>()
        return chosen.filter { supported.contains($0) && seen.insert($0).inserted }.prefix(5).map { $0 }
    }

    /// A readable name for a code such as "te-IN" or "zh-Hans", in the person's language.
    static func name(of code: String, in locale: Locale = .current) -> String {
        locale.localizedString(forIdentifier: code) ?? code
    }

    static func parse(_ stored: String) -> [String] { stored.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
    static func join(_ codes: [String]) -> String { codes.joined(separator: ",") }

    /// A sentence about what will happen.
    static func summary(chosen: [String], locale: Locale = .current) -> String {
        chosen.isEmpty ? "Automatic: the reader works out the language from the picture." : "Looks for " + chosen.map { name(of: $0, in: locale) }.joined(separator: ", ") + "."
    }
}
