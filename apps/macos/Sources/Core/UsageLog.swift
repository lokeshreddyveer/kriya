import Foundation

/// A short record of what was used and when: names only, never the text or files involved.
struct UsageLog: Codable, Equatable {
    struct Entry: Codable, Equatable, Identifiable {
        var id = UUID().uuidString
        let title: String
        let detail: String
        let at: Date
    }

    var entries: [Entry] = []
    static let limit = 100

    mutating func record(_ title: String, detail: String = "", at: Date) {
        let clean = String(title.prefix(80))
        guard !clean.isEmpty else { return }
        entries.insert(Entry(title: clean, detail: String(detail.prefix(80)), at: at), at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
    }

    /// The most used titles with how many times, most used first.
    func top(_ count: Int) -> [(title: String, uses: Int)] {
        Dictionary(grouping: entries, by: \.title).map { (title: $0.key, uses: $0.value.count) }
            .sorted { ($1.uses, $0.title) < ($0.uses, $1.title) }
            .prefix(count).map { $0 }
    }

    func lastUsed(_ title: String) -> Date? { entries.first { $0.title == title }?.at }
}

/// A usage log kept in preferences under its own key.
final class UsageLogStore: ObservableObject {
    static let selection = UsageLogStore(key: "usage.selectionActions.v1")
    static let actions = UsageLogStore(key: "usage.savedActions.v1")

    private let key: String
    @Published private(set) var log: UsageLog

    init(key: String) {
        self.key = key
        log = UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(UsageLog.self, from: $0) } ?? UsageLog()
    }

    func record(_ title: String, detail: String = "") {
        DispatchQueue.main.async { [self] in
            log.record(title, detail: detail, at: Date())
            if let data = try? JSONEncoder().encode(log) { UserDefaults.standard.set(data, forKey: key) }
        }
    }

    func clear() {
        log = UsageLog()
        UserDefaults.standard.removeObject(forKey: key)
    }
}
