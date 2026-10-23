import Foundation

/// The snippet placeholders the core does not know, resolved before the core fills in dates, the clipboard and prompts:
///
/// - `{snippet:abbr}` inserts another snippet's text (up to five levels; one that refers back to itself is left as it is).
/// - `{workday+3}` / `{workday-1:EEEE d MMMM}` is a date counted in working days.
/// - `{random:1-100}` is a whole number in that range.
/// - `{counter:invoice}` is a number that goes up by one each time it is used.
/// - `{clipboard:upper}` is the clipboard changed by one of the text filters (upper, lower, title, trim, snake, kebab, camel, json…).
enum SnippetPreprocessor {
    struct Environment {
        var snippet: (String) -> String? = { _ in nil }
        var counter: (String) -> Int = { _ in 1 }
        var clipboard: String?
        var now = Date()
        var calendar = Calendar.current
        var random: (ClosedRange<Int>) -> Int = { Int.random(in: $0) }
    }

    static let maxDepth = 5

    static func process(_ body: String, _ env: Environment) -> String {
        resolve(body, env, depth: 0, seen: [])
    }

    private static func resolve(_ text: String, _ env: Environment, depth: Int, seen: Set<String>) -> String {
        var out = ""
        var index = text.startIndex
        while index < text.endIndex {
            if text[index...].hasPrefix("{{") { out += "{{"; index = text.index(index, offsetBy: 2); continue }
            if text[index] == "{", let close = text[index...].firstIndex(of: "}"), text.distance(from: index, to: close) <= 80 {
                let inner = String(text[text.index(after: index)..<close])
                if let value = expand(inner, env, depth: depth, seen: seen) {
                    out += value
                    index = text.index(after: close)
                    continue
                }
            }
            out.append(text[index])
            index = text.index(after: index)
        }
        return out
    }

    private static func expand(_ inner: String, _ env: Environment, depth: Int, seen: Set<String>) -> String? {
        if let name = inner.dropPrefix("snippet:") {
            let key = name.trimmingCharacters(in: .whitespaces)
            guard depth < maxDepth, !seen.contains(key), let body = env.snippet(key) else { return nil }
            return resolve(body, env, depth: depth + 1, seen: seen.union([key]))
        }
        if let range = inner.dropPrefix("random:") {
            let parts = range.split(separator: "-", maxSplits: 1).compactMap { Int($0) }
            guard parts.count == 2, parts[0] <= parts[1] else { return nil }
            return String(env.random(parts[0]...parts[1]))
        }
        if let name = inner.dropPrefix("counter:") {
            let key = name.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { return nil }
            return String(env.counter(key))
        }
        if let filterName = inner.dropPrefix("clipboard:"), let clip = env.clipboard {
            let wanted = filterName.lowercased()
            let filter = TextFilter.allCases.first { $0.rawValue.lowercased() == wanted || $0.aliases.contains(wanted) }
            return filter.map { $0.apply(to: clip) }
        }
        if inner.hasPrefix("workday") { return workday(String(inner.dropFirst("workday".count)), env) }
        return nil
    }

    /// "+3" or "-1:EEEE d MMMM": that many working days from now, weekends skipped.
    private static func workday(_ spec: String, _ env: Environment) -> String? {
        let parts = spec.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard let first = parts.first, let n = Int(first.hasPrefix("+") ? String(first.dropFirst()) : String(first)), abs(n) <= 3650 else { return nil }
        let step = n < 0 ? -1 : 1
        var date = env.now
        var left = abs(n)
        while left > 0 {
            date = env.calendar.date(byAdding: .day, value: step, to: date) ?? date
            if !env.calendar.isDateInWeekend(date) { left -= 1 }
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = env.calendar
        f.timeZone = env.calendar.timeZone
        f.dateFormat = parts.count == 2 && !parts[1].isEmpty ? String(parts[1]) : "yyyy-MM-dd"
        return f.string(from: date)
    }
}

private extension String {
    func dropPrefix(_ prefix: String) -> String? { hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil }
}

extension TextFilter {
    /// Short names that can be used in a snippet: `{clipboard:upper}`.
    var aliases: [String] {
        switch self {
        case .upper: return ["uppercase"]
        case .lower: return ["lowercase"]
        case .title: return ["titlecase"]
        case .trim: return ["trimmed"]
        case .oneLine: return ["oneline", "single"]
        case .jsonPretty: return ["json"]
        case .jsonCompact: return ["jsonmin"]
        case .base64Encode: return ["base64"]
        case .urlEncode: return ["urlencode"]
        default: return []
        }
    }
}
