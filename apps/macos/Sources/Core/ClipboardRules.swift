import Foundation

/// Removes the parts of web addresses that only follow you around: `utm_` tags, `fbclid`, `gclid` and the like.
enum LinkCleaner {
    private static let tracking: Set<String> = [
        "fbclid", "gclid", "gclsrc", "dclid", "msclkid", "mc_eid", "mc_cid", "igshid", "igsh", "yclid", "twclid", "ttclid",
        "_hsenc", "_hsmi", "hsctatracking", "mkt_tok", "vero_id", "oly_enc_id", "oly_anon_id", "wickedid", "ref_src", "ref_url",
        "s_cid", "spm", "si", "feature", "pf_rd_r", "pf_rd_p", "pd_rd_r", "pd_rd_w", "pd_rd_wg", "ascsubtag"
    ]

    static func isTracking(_ name: String) -> Bool {
        let n = name.lowercased()
        return n.hasPrefix("utm_") || tracking.contains(n)
    }

    /// The text with every web address cleaned. Text that holds no address comes back as it was.
    static func clean(_ text: String) -> String {
        guard text.contains("http"), let regex = try? NSRegularExpression(pattern: #"https?://[^\s<>"']+"#) else { return text }
        var result = text
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed()
        for match in matches {
            guard let range = Range(match.range, in: result) else { continue }
            var link = String(result[range])
            // A full stop, comma or bracket right after a link belongs to the sentence, not the address.
            var tail = ""
            while let last = link.last, ".,;:!?)]}".contains(last) { tail = String(last) + tail; link.removeLast() }
            result.replaceSubrange(range, with: cleanLink(link) + tail)
        }
        return result
    }

    static func cleanLink(_ link: String) -> String {
        guard var parts = URLComponents(string: link), let items = parts.queryItems else { return link }
        let kept = items.filter { !isTracking($0.name) }
        guard kept.count != items.count else { return link }
        parts.queryItems = kept.isEmpty ? nil : kept
        return parts.string ?? link
    }
}

/// One thing a rule does to copied text.
enum ClipboardRuleAction: String, CaseIterable, Identifiable, Codable {
    case stripTracking, trimEnds, plainText
    case upper, lower, oneLine, stripTags, snake, kebab, camel
    var id: String { rawValue }

    var title: String {
        switch self {
        case .stripTracking: return "Remove tracking from links"
        case .trimEnds: return "Trim spaces at the start and end"
        case .plainText: return "Keep only the plain text"
        case .upper: return "UPPER CASE"
        case .lower: return "lower case"
        case .oneLine: return "Join into one line"
        case .stripTags: return "Remove HTML tags"
        case .snake: return "snake_case"
        case .kebab: return "kebab-case"
        case .camel: return "camelCase"
        }
    }

    func apply(to text: String) -> String {
        switch self {
        case .stripTracking: return LinkCleaner.clean(text)
        case .trimEnds: return text.trimmingCharacters(in: .whitespacesAndNewlines)
        case .plainText: return text
        case .upper: return TextFilter.upper.apply(to: text)
        case .lower: return TextFilter.lower.apply(to: text)
        case .oneLine: return TextFilter.oneLine.apply(to: text)
        case .stripTags: return TextFilter.stripTags.apply(to: text)
        case .snake: return TextFilter.snake.apply(to: text)
        case .kebab: return TextFilter.kebab.apply(to: text)
        case .camel: return TextFilter.camel.apply(to: text)
        }
    }
}

struct ClipboardRule: Identifiable, Codable, Equatable {
    var id = UUID().uuidString
    var name: String
    /// Bundle identifiers of the apps the copy must come from. Empty means every app.
    var apps: [String] = []
    var actions: [ClipboardRuleAction]
    var enabled = true

    func matches(sourceApp: String?) -> Bool {
        enabled && (apps.isEmpty || (sourceApp.map(apps.contains) ?? false))
    }
}

enum ClipboardRules {
    struct Outcome: Equatable {
        var text: String
        var changed: Bool
        /// A rule asked for plain text, so the formatting should go even if the words did not change.
        var wantsPlain: Bool
    }

    /// What copied text becomes under the rules that fit where it came from, applied in order.
    static func apply(_ rules: [ClipboardRule], to text: String, sourceApp: String?) -> Outcome {
        var out = text
        var plain = false
        for rule in rules where rule.matches(sourceApp: sourceApp) {
            for action in rule.actions {
                out = action.apply(to: out)
                if action == .plainText { plain = true }
            }
        }
        return Outcome(text: out, changed: out != text, wantsPlain: plain)
    }
}

/// The rules, kept in the app's preferences.
final class ClipboardRuleStore: ObservableObject {
    @Published var rules: [ClipboardRule] { didSet { save() } }
    private let defaults: UserDefaults
    private let key = "clipboardRules.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        rules = (defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([ClipboardRule].self, from: $0) }) ?? []
    }

    private func save() {
        if let data = try? JSONEncoder().encode(rules) { defaults.set(data, forKey: key) }
    }

    var active: [ClipboardRule] { rules.filter(\.enabled) }
}
