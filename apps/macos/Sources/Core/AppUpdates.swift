import Foundation

/// What was updated and when, newest first, kept to the last two hundred.
struct UpdateHistory: Codable, Equatable {
    struct Entry: Codable, Equatable, Identifiable {
        var id = UUID().uuidString
        let app: String
        let from: String
        let to: String
        /// "Homebrew", "Sparkle" or "App Store".
        let source: String
        let at: Date
        let ok: Bool
        let note: String
    }

    var entries: [Entry] = []
    static let limit = 200

    mutating func add(_ entry: Entry) {
        entries.insert(entry, at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
    }

    func entries(for app: String) -> [Entry] { entries.filter { $0.app == app } }
}

/// Failed Homebrew upgrades waiting to be tried again, each after a longer wait, up to five tries.
struct UpdateRetryQueue: Equatable {
    struct Item: Equatable, Identifiable {
        var id: String { token }
        let token: String
        var attempts: Int
        var nextAttempt: Date
        var lastError: String
    }

    private(set) var items: [Item] = []
    static let maxAttempts = 5

    /// 1, 2, 4, 8 minutes... up to an hour.
    static func backoff(attempts: Int) -> TimeInterval { min(60 * pow(2, Double(max(attempts - 1, 0))), 3600) }

    mutating func fail(_ token: String, error: String, now: Date) {
        if let i = items.firstIndex(where: { $0.token == token }) {
            items[i].attempts += 1
            items[i].lastError = error
            items[i].nextAttempt = now.addingTimeInterval(Self.backoff(attempts: items[i].attempts))
        } else {
            items.append(Item(token: token, attempts: 1, nextAttempt: now.addingTimeInterval(Self.backoff(attempts: 1)), lastError: error))
        }
    }

    mutating func succeed(_ token: String) { items.removeAll { $0.token == token } }

    /// Items whose time has come and that have not used up their tries.
    func due(now: Date) -> [Item] { items.filter { $0.attempts < Self.maxAttempts && $0.nextAttempt <= now } }

    func gaveUp() -> [Item] { items.filter { $0.attempts >= Self.maxAttempts } }

    /// Makes an item due now (the Retry button), even one that gave up.
    mutating func retryNow(_ token: String, now: Date) {
        if let i = items.firstIndex(where: { $0.token == token }) {
            items[i].nextAttempt = now
            if items[i].attempts >= Self.maxAttempts { items[i].attempts = Self.maxAttempts - 1 }
        }
    }

    mutating func retryAll(now: Date) { for item in items { retryNow(item.token, now: now) } }
}

enum UpdateProgress {
    /// A fraction only when there is a list of several; one Homebrew install does not report a percentage, so it gets none.
    static func fraction(done: Int, total: Int) -> Double? {
        total > 1 ? min(max(Double(done) / Double(total), 0), 1) : nil
    }

    /// "2 of 5: firefox" or just the name.
    static func label(done: Int, total: Int, current: String?) -> String {
        guard let current else { return total > 1 ? "\(done) of \(total) done" : "" }
        return total > 1 ? "\(min(done + 1, total)) of \(total): \(current)" : current
    }
}

/// Keeping a zip of an app's support files before they go to the Trash.
enum RemovalArchive {
    static let maxBytes: Int64 = 1_000_000_000

    static func fileName(appName: String, at date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm"
        let bad = CharacterSet(charactersIn: "/:\\?%*|\"<>").union(.controlCharacters)
        let clean = appName.components(separatedBy: bad).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return "\(clean.isEmpty ? "App" : String(clean.prefix(50))) \(f.string(from: date)).zip"
    }

    /// Whether there is anything to keep, and whether it is small enough to zip without surprising the disk.
    static func verdict(sizes: [Int64]) -> (archive: Bool, reason: String?) {
        guard !sizes.isEmpty else { return (false, "There are no support files to keep.") }
        let total = sizes.reduce(0, +)
        return total > maxBytes ? (false, "The support files are over 1 GB, too large to zip here. They still go to the Trash and can be put back from there.") : (true, nil)
    }
}
