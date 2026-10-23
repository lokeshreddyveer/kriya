import Foundation

/// When a launcher web request is worth sending again: only for failures that a second try can fix, a few times, with a wait.
enum RetryPolicy {
    static let maxAttempts = 3
    static let retryableURLErrors: Set<Int> = [
        NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost, NSURLErrorNotConnectedToInternet, NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed,
    ]

    enum Failure: Equatable {
        case status(Int, retryAfter: TimeInterval?)
        case urlError(Int)
        case other
    }

    /// Seconds to wait before the next try, or nil to stop. `attempt` is the one that just failed, starting at 1.
    /// A request that changes something on the server (POST) is only sent again when the server said "too many requests",
    /// since a second try after a lost answer could do the thing twice.
    static func delay(after failure: Failure, attempt: Int, method: String) -> TimeInterval? {
        guard attempt < maxAttempts else { return nil }
        let backoff = pow(2, Double(attempt - 1))
        switch failure {
        case .status(429, let retryAfter): return min(max(retryAfter ?? backoff, 1), 30)
        case .status(let code, _) where (500...599).contains(code): return method.uppercased() == "POST" ? nil : backoff
        case .urlError(let code) where retryableURLErrors.contains(code): return method.uppercased() == "POST" ? nil : backoff
        default: return nil
        }
    }
}

/// An answer made safe and short enough to look at before it is copied, saved or opened.
enum ResponsePreview {
    static let limit = 4_000
    private static let secretWords = ["token", "password", "secret", "authorization", "api_key", "apikey", "access_key", "cookie", "session"]

    struct Preview: Equatable {
        let text: String
        let truncated: Bool
        let redactedCount: Int
        let isJSON: Bool
    }

    static func make(_ data: Data) -> Preview {
        var redacted = 0
        func clean(_ value: Any) -> Any {
            if let object = value as? [String: Any] {
                var out: [String: Any] = [:]
                for (key, inner) in object {
                    if secretWords.contains(where: { key.lowercased().contains($0) }) { out[key] = "•••"; redacted += 1 } else { out[key] = clean(inner) }
                }
                return out
            }
            if let list = value as? [Any] { return list.map(clean) }
            return value
        }
        if let root = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]), JSONSerialization.isValidJSONObject(root) {
            let cleaned = clean(root)
            if let pretty = try? JSONSerialization.data(withJSONObject: cleaned, options: [.prettyPrinted, .sortedKeys]), let text = String(data: pretty, encoding: .utf8) {
                return Preview(text: String(text.prefix(limit)), truncated: text.count > limit, redactedCount: redacted, isJSON: true)
            }
        }
        let text = String(decoding: data.prefix(limit * 4), as: UTF8.self).unicodeScalars.filter { $0 == "\n" || $0 == "\t" || !CharacterSet.controlCharacters.contains($0) }
        let plain = String(String.UnicodeScalarView(text))
        return Preview(text: String(plain.prefix(limit)), truncated: plain.count > limit || data.count > limit * 4, redactedCount: 0, isJSON: false)
    }
}

/// What a link check found.
struct LinkHealth: Equatable {
    enum State: Equatable { case ok, redirected(to: String), broken(Int), slow, unreachable(String), skipped(String) }
    let state: State
    let milliseconds: Int

    var summary: String {
        switch state {
        case .ok: return "Works (\(milliseconds) ms)"
        case .redirected(let to): return "Redirects to \(to)"
        case .broken(let code): return "Answered \(code)"
        case .slow: return "Very slow (\(milliseconds) ms)"
        case .unreachable(let why): return "Could not be reached: \(why)"
        case .skipped(let why): return "Not checked: \(why)"
        }
    }

    var isProblem: Bool {
        switch state {
        case .ok, .redirected, .skipped: return false
        default: return true
        }
    }

    /// Only a plain web address can be checked: not one that needs the clipboard or selection, and not anything but http(s).
    static func checkable(template: String) -> (url: URL?, skip: String?) {
        if template.contains("{clipboard}") || template.contains("{selection}") { return (nil, "it uses the clipboard or selection") }
        guard let url = URL(string: template.replacingOccurrences(of: Quicklink.placeholder, with: "test")), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host != nil else {
            return (nil, "it is not a web address")
        }
        return (url, nil)
    }

    static func classify(status: Int?, error: String?, finalURL: URL?, original: URL, milliseconds: Int) -> LinkHealth {
        if let error { return LinkHealth(state: .unreachable(error), milliseconds: milliseconds) }
        guard let status else { return LinkHealth(state: .unreachable("no answer"), milliseconds: milliseconds) }
        if !(200..<400).contains(status) { return LinkHealth(state: .broken(status), milliseconds: milliseconds) }
        if let finalURL, finalURL.host != original.host || finalURL.path != original.path, let host = finalURL.host { return LinkHealth(state: .redirected(to: host + finalURL.path), milliseconds: milliseconds) }
        return LinkHealth(state: milliseconds > 5_000 ? .slow : .ok, milliseconds: milliseconds)
    }
}

/// How long each launcher source took to answer, so a slow one can be named.
struct SourceLatency: Equatable {
    struct Stat: Equatable {
        var last: Int
        var average: Double
        var worst: Int
        var samples: Int
    }

    private(set) var stats: [String: Stat] = [:]

    mutating func record(_ source: String, milliseconds: Int) {
        var s = stats[source] ?? Stat(last: milliseconds, average: Double(milliseconds), worst: milliseconds, samples: 0)
        s.samples += 1
        s.last = milliseconds
        s.worst = max(s.worst, milliseconds)
        // A running average that favours the recent past, so one slow day is forgotten.
        s.average = s.samples == 1 ? Double(milliseconds) : s.average * 0.8 + Double(milliseconds) * 0.2
        stats[source] = s
    }

    /// "Files 120 ms, Windows 40 ms", slowest first.
    func summary(limit: Int = 6) -> String {
        stats.sorted { $0.value.average > $1.value.average }.prefix(limit).map { "\($0.key) \(Int($0.value.average.rounded())) ms" }.joined(separator: ", ")
    }

    func isSlow(_ source: String, thresholdMs: Double = 250) -> Bool { (stats[source]?.average ?? 0) > thresholdMs }
}
