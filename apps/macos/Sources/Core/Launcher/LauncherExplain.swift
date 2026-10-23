import Foundation

extension LauncherEngine {
    struct Explanation: Equatable {
        let title: String
        let lines: [String]
        let total: Int?
    }

    /// Why a result sits where it does for a query: what matched and what each part added. Nil total when it did not match.
    static func explain(_ item: LauncherCandidate, query: String, prefs: LauncherPrefsData, now: Date = Date()) -> Explanation {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines: [String] = []
        if text.isEmpty { return Explanation(title: item.title, lines: ["Nothing typed: shown because it is pinned, used often, or suggested."], total: nil) }
        if !prefs.isEnabled(item.category) { return Explanation(title: item.title, lines: ["Its group (\(item.category)) is switched off."], total: nil) }
        if prefs.hidden.contains(item.id) { return Explanation(title: item.title, lines: ["You hid this result."], total: nil) }
        var score: Int
        let alias = text.lowercased().filter { !$0.isWhitespace }
        if let target = prefs.aliases[alias], target == item.id {
            score = 5000
            lines.append("Your short name “\(alias)” is set to this: +5000")
        } else if let own = item.queryScore {
            score = own
            lines.append("It came from what you typed: \(own)")
        } else {
            let title = FuzzyMatcher.best(text, in: [item.title] + item.keywords)
            let subtitle = FuzzyMatcher.score(text, in: item.subtitle).map { $0 - 200 }
            let floor = prefs.matchStrictness.minimumScore
            guard let best = [title, subtitle].compactMap({ $0 }).max() else {
                return Explanation(title: item.title, lines: ["“\(text)” does not match its name, keywords or description."], total: nil)
            }
            if best < floor { return Explanation(title: item.title, lines: ["It matches only loosely (\(best)); the matching setting needs \(floor)."], total: nil) }
            score = best
            lines.append(title.map { $0 == best } == true ? "Name or keyword match: \(best)" : "Description match: \(best)")
        }
        let bias = item.category.bias
        if bias != 0 { lines.append("Kind of result (\(item.category)): \(bias > 0 ? "+" : "")\(bias)") }
        score += bias
        let usage = usageBoost(prefs.usage[item.id], now: now)
        if usage != 0 { lines.append("You choose it often or lately: +\(usage)") }
        score += usage
        if prefs.pinned.contains(item.id) { lines.append("Pinned: +40"); score += 40 }
        lines.append("Total: \(score)")
        return Explanation(title: item.title, lines: lines, total: score)
    }
}

/// The last results the launcher ranked, kept so Settings can say why they were shown.
final class LauncherWhy {
    static let shared = LauncherWhy()
    private let lock = NSLock()
    private var query = ""
    private var items: [LauncherCandidate] = []
    private var prefs: LauncherPrefsData?

    func note(query: String, items: [LauncherCandidate], prefs: LauncherPrefsData) {
        lock.lock(); defer { lock.unlock() }
        self.query = query; self.items = items; self.prefs = prefs
    }

    func explainAll(limit: Int = 8) -> (query: String, rows: [Explanation]) {
        lock.lock(); defer { lock.unlock() }
        guard let prefs else { return ("", []) }
        let all = items.map { LauncherEngine.explain($0, query: query, prefs: prefs) }
        return (query, Array(all.filter { $0.total != nil }.sorted { ($0.total ?? 0) > ($1.total ?? 0) }.prefix(limit)))
    }
}
