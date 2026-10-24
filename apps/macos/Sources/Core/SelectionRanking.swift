import Foundation

/// What a selection looks like, worked out from its text, so the actions that fit it come first.
struct SelectionContext: Equatable {
    var isLink = false
    var hasLink = false
    var hasEmail = false
    var isPath = false
    var isJSON = false
    var isCode = false
    var isSingleWord = false
    var isNumberLike = false
    var looksEncoded = false
    var looksPercentEncoded = false
    var multiline = false
    var long = false

    static func detect(_ text: String) -> SelectionContext {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var c = SelectionContext()
        guard !t.isEmpty else { return c }
        c.multiline = t.contains("\n")
        c.long = t.count > 200
        let oneToken = !t.contains(where: \.isWhitespace)
        c.isLink = oneToken && (t.hasPrefix("http://") || t.hasPrefix("https://")) && URL(string: t)?.host != nil
        c.hasLink = t.contains("http://") || t.contains("https://")
        c.hasEmail = t.range(of: #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#, options: .regularExpression) != nil
        c.isPath = !c.multiline && (t.hasPrefix("/") || t.hasPrefix("~/") || t.hasPrefix("file://")) && !t.hasPrefix("//")
        c.isJSON = (t.hasPrefix("{") && t.hasSuffix("}")) || (t.hasPrefix("[") && t.hasSuffix("]"))
        c.isCode = c.isJSON || t.contains("{") && t.contains("}") || t.contains(");") || t.contains("=>") || t.contains("</")
        c.isSingleWord = oneToken && t.count <= 40 && t.allSatisfy { $0.isLetter || $0 == "-" || $0 == "'" }
        c.isNumberLike = oneToken && t.allSatisfy(\.isNumber) && (9...13).contains(t.count)
        c.looksPercentEncoded = t.range(of: #"%[0-9A-Fa-f]{2}"#, options: .regularExpression) != nil
        c.looksEncoded = oneToken && t.count >= 12 && t.count % 4 == 0 && t.allSatisfy { $0.isLetter || $0.isNumber || $0 == "+" || $0 == "/" || $0 == "=" } && t.contains { $0.isNumber } && t.contains { $0.isUppercase }
        return c
    }
}

/// The order of the actions in the bar: first what fits what is selected, then what the person uses and has pinned, with slow ones
/// (they run a model, a script or a web search) after quick ones. The person's own order is the tie-breaker, so nothing jumps around
/// without a reason.
enum SelectionRanking {
    struct Signals {
        var context: SelectionContext
        var editable: Bool
        /// How many times each action title was used lately.
        var usage: [String: Int] = [:]
        var pinned: Set<String> = []
    }

    enum Latency { case instant, quick, slow }

    static func latency(_ action: SelectionAction) -> Latency {
        switch action.kind {
        case .intelligence, .script, .shortcut, .workflow: return .slow
        case .translate, .urlTemplate, .dictionary: return .quick
        default: return .instant
        }
    }

    /// How well an action fits the selection, from 0 (no reason to prefer it) up.
    static func relevance(_ action: SelectionAction, _ c: SelectionContext, editable: Bool) -> Double {
        var score = 0.0
        switch action.kind {
        case .copy: score += 20
        case .paste, .pastePlain: score += editable ? 6 : 0
        case .openUrls: score += c.hasLink ? (c.isLink ? 40 : 28) : 0
        case .revealPath, .openInTerminal: score += c.isPath ? 38 : 0
        case .dictionary: score += c.isSingleWord ? 26 : 0
        case .spelling: score += editable && !c.isCode && !c.isSingleWord ? 14 : 0
        case .count: score += c.long || c.multiline ? 12 : 0
        case .translate: score += c.long ? 8 : 0
        case .intelligence: score += c.long ? 18 : (c.multiline ? 8 : 0)
        case .copyMarkdown, .copyHtml: score += c.long || c.multiline ? 6 : 0
        case .sendToShelf: score += 2
        case .transform(let ops, _):
            for op in ops {
                switch op {
                case .jsonFormat, .jsonMinify: score += c.isJSON ? 40 : 0
                case .urlDecode: score += c.looksPercentEncoded ? 32 : 0
                case .urlEncode: score += !c.looksPercentEncoded && c.hasLink ? 8 : 0
                case .base64Decode: score += c.looksEncoded ? 30 : 0
                case .base64Encode: score += c.isCode ? 4 : 0
                case .unixTimeToDate: score += c.isNumberLike ? 36 : 0
                case .extractEmails: score += c.hasEmail && c.multiline ? 20 : 0
                case .extractUrls, .stripUrlTracking: score += c.hasLink ? 18 : 0
                case .removeDuplicateLines, .sortLines, .removeBlankLines, .reverseLines, .numberLines, .linesToComma: score += c.multiline ? 16 : 0
                case .joinLines: score += c.multiline ? 22 : 0
                case .commaToLines: score += !c.multiline && c.long ? 6 : 0
                case .escapeString, .unescapeString: score += c.isCode ? 10 : 0
                default: score += editable ? 3 : 0
                }
            }
        default: break
        }
        return score
    }

    /// The actions in the order to show them.
    static func rank(_ actions: [SelectionAction], signals: Signals) -> [SelectionAction] {
        let scored: [(action: SelectionAction, index: Int, score: Double)] = actions.enumerated().map { i, a in
            var score = relevance(a, signals.context, editable: signals.editable)
            score += Double(min(signals.usage[a.title] ?? 0, 20)) * 1.5
            if signals.pinned.contains(a.id) { score += 1000 }
            switch latency(a) { case .slow: score -= 6; case .quick: score -= 2; case .instant: break }
            // A group moves as one, so its place is its best member's.
            return (a, i, score)
        }
        // Actions that share a group stay together: the group takes the score of its best member, and members keep their order.
        var groupBest: [String: Double] = [:]
        for s in scored { if let g = s.action.group, !g.isEmpty { groupBest[g] = max(groupBest[g] ?? -.infinity, s.score) } }
        func key(_ s: (action: SelectionAction, index: Int, score: Double)) -> Double { s.action.group.flatMap { $0.isEmpty ? nil : groupBest[$0] } ?? s.score }
        return scored.sorted { a, b in
            let ka = key(a), kb = key(b)
            if ka != kb { return ka > kb }
            // Same group: keep the person's order; otherwise the person's order decides.
            return a.index < b.index
        }.map(\.action)
    }

    /// The overflow menu's headings, by what an action does.
    static func category(_ action: SelectionAction) -> String {
        switch action.kind {
        case .intelligence: return "AI"
        case .transform(let ops, _):
            let developer = ops.contains { switch $0 { case .jsonFormat, .jsonMinify, .base64Encode, .base64Decode, .escapeString, .unescapeString, .urlEncode, .urlDecode, .htmlEscape, .htmlUnescape, .camelCase, .pascalCase, .snakeCase, .kebabCase, .constantCase, .unixTimeToDate, .dateToUnixTime, .regexReplace: return true; default: return false } }
            return developer ? "Developer" : "Transform"
        case .urlTemplate, .translate, .dictionary, .spelling, .openUrls: return "Search"
        case .share, .copyMarkdown, .copyHtml, .copyPlain, .sendToShelf: return "Share"
        case .script, .shortcut, .workflow, .openInApp, .revealPath, .openInTerminal: return "Apps"
        default: return "More"
        }
    }

    /// The headings in a fixed order, each with its actions in ranked order. Empty headings are left out.
    static func grouped(_ actions: [SelectionAction]) -> [(title: String, actions: [SelectionAction])] {
        let order = ["Transform", "Search", "Share", "Developer", "AI", "Apps", "More"]
        let byCategory = Dictionary(grouping: actions, by: category)
        return order.compactMap { name in byCategory[name].map { (name, $0) } }
    }
}

/// Actions the person pinned to stay first.
enum SelectionPins {
    static let key = "selection.pinned.v1"
    static let rankKey = "selection.rankByContext"

    static var pinned: [String] {
        get { UserDefaults.standard.stringArray(forKey: key) ?? [] }
        set { UserDefaults.standard.set(Array(NSOrderedSet(array: newValue)) as? [String] ?? newValue, forKey: key) }
    }

    /// Whether the bar puts the actions that fit the selection first. On unless turned off.
    static var rankByContext: Bool {
        get { UserDefaults.standard.object(forKey: rankKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: rankKey) }
    }
}

/// How the bar reports a change it made to the person's text.
struct ReplacementSummary: Equatable {
    var original: String
    var result: String

    var changed: Bool { original != result }

    /// "12 words → 9 words" or "No change".
    var headline: String {
        guard changed else { return "No change" }
        func words(_ s: String) -> Int { s.split(whereSeparator: \.isWhitespace).count }
        return "\(words(original)) → \(words(result)) words"
    }

    /// A short look at text for the preview: one line, cut at `limit` characters.
    static func preview(_ text: String, limit: Int = 70) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ⏎ ").trimmingCharacters(in: .whitespaces)
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
    }
}
