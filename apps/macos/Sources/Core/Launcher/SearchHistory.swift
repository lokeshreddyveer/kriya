import Foundation

/// The words typed into the launcher before a result was chosen, kept on this Mac so they can be browsed and reused. Off until
/// the person turns it on, since it holds what they typed. Never holds clipboard text.
struct SearchHistory: Codable, Equatable {
    struct Entry: Codable, Equatable, Identifiable {
        var text: String
        var last: Date
        var count: Int
        var id: String { text.lowercased() }
    }

    static let maxEntries = 200
    static let maxLength = 120

    private(set) var entries: [Entry] = []

    /// Notes a search. The same words again move to the front and are counted. Very short, very long and secret-looking text
    /// (a long run of letters and digits with no spaces, such as a key) is not kept.
    mutating func record(_ text: String, at date: Date = Date()) {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard words.count >= 2, words.count <= Self.maxLength, !Self.looksSecret(words) else { return }
        if let index = entries.firstIndex(where: { $0.id == words.lowercased() }) {
            var entry = entries.remove(at: index)
            entry.last = date
            entry.count += 1
            entry.text = words
            entries.insert(entry, at: 0)
        } else {
            entries.insert(Entry(text: words, last: date, count: 1), at: 0)
        }
        if entries.count > Self.maxEntries { entries.removeLast(entries.count - Self.maxEntries) }
    }

    mutating func remove(_ id: String) { entries.removeAll { $0.id == id } }
    mutating func clear() { entries = [] }

    /// The most recent first.
    func recent(_ limit: Int = 20) -> [Entry] { Array(entries.prefix(limit)) }

    /// Entries that contain these words, the most used and recent first.
    func matching(_ query: String, limit: Int = 20) -> [Entry] {
        let words = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !words.isEmpty else { return recent(limit) }
        return Array(entries.filter { $0.text.lowercased().contains(words) }.prefix(limit))
    }

    /// Stepping back through the recent ones with the up arrow: where to go from `index` (nil is what the person typed).
    static func older(_ index: Int?, count: Int) -> Int? {
        count > 0 ? min((index ?? -1) + 1, count - 1) : nil
    }

    /// The down arrow: toward what the person typed, which is nil.
    static func newer(_ index: Int?) -> Int? {
        guard let index, index > 0 else { return nil }
        return index - 1
    }

    /// One long token of mixed letters and digits is probably a password or key.
    static func looksSecret(_ text: String) -> Bool {
        guard !text.contains(" "), text.count >= 20 else { return false }
        return text.contains(where: \.isNumber) && text.contains(where: \.isLetter)
    }
}

/// Saves the history in the app's preferences.
final class SearchHistoryStore: ObservableObject {
    /// The one the launcher and Settings share.
    static let shared = SearchHistoryStore()

    @Published private(set) var history: SearchHistory
    private let defaults: UserDefaults
    private let key = "launcherSearchHistory.v1"
    private let enabledKey = "launcherSearchHistoryOn"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        history = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(SearchHistory.self, from: $0) } ?? SearchHistory()
    }

    var isEnabled: Bool {
        get { defaults.bool(forKey: enabledKey) }
        set {
            defaults.set(newValue, forKey: enabledKey)
            // Turning it off forgets what was kept.
            if !newValue { clear() }
            objectWillChange.send()
        }
    }

    func record(_ text: String) {
        guard isEnabled else { return }
        history.record(text)
        save()
    }

    func remove(_ id: String) { history.remove(id); save() }
    func clear() { history.clear(); save() }

    private func save() {
        if let data = try? JSONEncoder().encode(history) { defaults.set(data, forKey: key) }
    }
}
