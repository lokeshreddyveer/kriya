import Foundation

/// What kind of secret a copied text looks like, so the history can label it without ever showing it. Decided from the text's shape
/// (a known key prefix, a card number that passes the check digit); the text itself is never kept in the label.
enum ClipSecretKind: String, CaseIterable {
    case privateKey, awsKey, githubToken, slackToken, stripeKey, googleKey, jwt, creditCard, apiKey, password

    var title: String {
        switch self {
        case .privateKey: return "Private or SSH key"
        case .awsKey: return "AWS key"
        case .githubToken: return "GitHub token"
        case .slackToken: return "Slack token"
        case .stripeKey: return "Stripe key"
        case .googleKey: return "Google API key"
        case .jwt: return "JWT token"
        case .creditCard: return "Card number"
        case .apiKey: return "Token or API key"
        case .password: return "Password"
        }
    }

    /// The tag the label is kept as, so it survives in the history and can be searched ("secret:aws").
    static let tagPrefix = "secret:"
    var tag: String { Self.tagPrefix + rawValue }
    static func from(tag: String) -> ClipSecretKind? { tag.hasPrefix(tagPrefix) ? ClipSecretKind(rawValue: String(tag.dropFirst(tagPrefix.count))) : nil }
}

enum ClipSecrets {
    static func classify(_ text: String) -> ClipSecretKind? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= 20_000 else { return nil }
        if t.contains("-----BEGIN"), t.contains("PRIVATE KEY") { return .privateKey }
        guard !t.contains(where: \.isWhitespace) || isCardLike(t) else { return nil }
        // Links and file paths are long and mixed-case too, but they are not secrets.
        if t.contains("://") || t.hasPrefix("/") || t.hasPrefix("~") { return nil }
        func matches(_ pattern: String) -> Bool { t.range(of: pattern, options: .regularExpression) != nil }
        if matches(#"^(AKIA|ASIA)[0-9A-Z]{16}$"#) { return .awsKey }
        if matches(#"^(gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,})$"#) { return .githubToken }
        if matches(#"^xox[abprs]-[A-Za-z0-9-]{10,}$"#) { return .slackToken }
        if matches(#"^(sk|rk|pk)_(live|test)_[A-Za-z0-9]{16,}$"#) { return .stripeKey }
        if matches(#"^AIza[0-9A-Za-z_-]{35}$"#) { return .googleKey }
        if matches(#"^eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]*$"#) { return .jwt }
        if isCardLike(t), luhn(t.filter(\.isNumber)) { return .creditCard }
        if matches(#"^sk-[A-Za-z0-9_-]{20,}$"#) || (t.count >= 24 && t.count <= 200 && classes(t) >= 3 && !t.contains("/") && !t.contains(".")) { return .apiKey }
        if t.count >= 8, t.count <= 64, classes(t) >= 4 { return .password }
        return nil
    }

    private static func isCardLike(_ t: String) -> Bool {
        let digits = t.filter(\.isNumber)
        return (13...19).contains(digits.count) && t.allSatisfy { $0.isNumber || $0 == " " || $0 == "-" }
    }

    /// How many of lower case, upper case, digits and symbols the text uses.
    private static func classes(_ t: String) -> Int {
        [t.contains { $0.isLowercase }, t.contains { $0.isUppercase }, t.contains { $0.isNumber }, t.contains { !$0.isLetter && !$0.isNumber }].filter { $0 }.count
    }

    /// The card check digit (Luhn): a random run of digits rarely passes, a real card number always does.
    static func luhn(_ digits: String) -> Bool {
        let values = digits.compactMap { $0.wholeNumberValue }
        guard values.count >= 2 else { return false }
        var sum = 0
        for (i, d) in values.reversed().enumerated() { var v = d; if i % 2 == 1 { v *= 2; if v > 9 { v -= 9 } }; sum += v }
        return sum % 10 == 0
    }
}

enum ClipDateRange: String, CaseIterable, Identifiable {
    case any = "Any time", today = "Today", week = "Past week", month = "Past month"
    var id: String { rawValue }

    func cutoff(now: Date = Date()) -> Date? {
        switch self {
        case .any: return nil
        case .today: return Calendar.current.startOfDay(for: now)
        case .week: return now.addingTimeInterval(-7 * 86_400)
        case .month: return now.addingTimeInterval(-30 * 86_400)
        }
    }
}

/// The choices the quick paste window adds on top of the search: where it came from, when, how often, and whether it is a secret.
struct ClipViewFilter: Equatable {
    var sourceApp: String? = nil
    var range: ClipDateRange = .any
    var frequentOnly = false
    var secretsOnly = false

    var isActive: Bool { sourceApp != nil || range != .any || frequentOnly || secretsOnly }
    static let frequentUses: UInt32 = 3

    func apply(_ items: [ClipItem], now: Date = Date()) -> [ClipItem] {
        let cutoff = range.cutoff(now: now)
        return items.filter { item in
            if let sourceApp, item.sourceApp != sourceApp { return false }
            if let cutoff, Date(timeIntervalSince1970: TimeInterval(item.lastUsedAt)) < cutoff { return false }
            if frequentOnly, item.useCount < Self.frequentUses { return false }
            if secretsOnly, !(item.sensitive || item.tags.contains { ClipSecretKind.from(tag: $0) != nil }) { return false }
            return true
        }
    }

    /// The apps that copied the items, most copies first, for the "From app" menu.
    static func sources(in items: [ClipItem]) -> [String] {
        Dictionary(grouping: items.compactMap(\.sourceApp), by: { $0 }).sorted { ($0.value.count, $1.key) > ($1.value.count, $0.key) }.map(\.key)
    }
}

/// Items set to go away on their own: a secret that should not outlive the afternoon, a one-time paste.
struct ClipExpiry: Codable, Equatable {
    private(set) var at: [String: TimeInterval] = [:]

    mutating func schedule(_ id: String, after seconds: TimeInterval, now: Date = Date()) { at[id] = now.addingTimeInterval(seconds).timeIntervalSince1970 }
    mutating func cancel(_ id: String) { at[id] = nil }
    func due(now: Date = Date()) -> [String] { at.filter { $0.value <= now.timeIntervalSince1970 }.map(\.key).sorted() }
    mutating func forget(_ ids: [String]) { for id in ids { at[id] = nil } }
    func remaining(_ id: String, now: Date = Date()) -> TimeInterval? { at[id].map { max(0, $0 - now.timeIntervalSince1970) } }
}

enum ClipPause {
    /// When a pause of `minutes` ends; nil for "until I turn it back on" (0 minutes).
    static func resumeAt(minutes: Int, now: Date = Date()) -> Date? { minutes > 0 ? now.addingTimeInterval(Double(minutes) * 60) : nil }

    static func isOver(until: Date?, now: Date = Date()) -> Bool { until.map { $0 <= now } ?? false }

    static func label(until: Date?, now: Date = Date()) -> String {
        guard let until else { return "Paused until you resume" }
        let minutes = Int((until.timeIntervalSince(now) / 60).rounded(.up))
        return minutes <= 1 ? "Paused for about a minute" : "Paused for \(minutes) more minutes"
    }
}

/// Ways to paste a link or several items as one piece of text.
enum ClipPasteText {
    enum Separator: String, CaseIterable, Identifiable {
        case newline = "New line", tab = "Tab", comma = "Comma", space = "Space"
        var id: String { rawValue }
        var text: String { switch self { case .newline: return "\n"; case .tab: return "\t"; case .comma: return ", "; case .space: return " " } }
    }

    /// `[example.com](https://example.com/page)`, or nil when the text is not a web link.
    static func markdownLink(_ link: String) -> String? {
        let t = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: t), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), let host = url.host else { return nil }
        let label = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return "[\(label)](\(t.replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29")))"
    }

    static func joined(_ texts: [String], by separator: Separator) -> String { texts.joined(separator: separator.text) }
}
