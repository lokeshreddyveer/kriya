import Foundation

/// What the file shelf holds, kept between runs: several named shelves, a history of what was taken off them, and when things
/// are let go. Plain data with its rules, so they can be checked without a screen.
struct ShelfRecord: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case file, text, image }

    var id = UUID().uuidString
    var kind: Kind
    /// A file's path, a piece of text, or the name of a picture kept in the shelf folder.
    var value: String
    var added: Date
    /// When it was taken off a shelf, for items in the history.
    var removed: Date?

    /// A short name for lists and for searching.
    var title: String {
        switch kind {
        case .file: return (value as NSString).lastPathComponent
        case .text: return String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        case .image: return "Image"
        }
    }
}

struct ShelfSet: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var name: String
    var items: [ShelfRecord] = []
}

struct ShelfLibrary: Codable, Equatable {
    static let maxShelves = 12
    static let maxItemsPerShelf = 200
    static let maxHistory = 100
    static let maxTextBytes = 200_000
    /// How long a taken-off item stays in the history.
    static let historyDays = 30

    var shelves: [ShelfSet] = [ShelfSet(id: "main", name: "Shelf")]
    var currentID = "main"
    /// Items are let go this many days after they were put on a shelf. Nil keeps them until taken off.
    var expiryDays: Int?
    var history: [ShelfRecord] = []

    var current: ShelfSet { shelves.first { $0.id == currentID } ?? shelves[0] }

    private func index(_ id: String) -> Int? { shelves.firstIndex { $0.id == id } }

    // MARK: Shelves

    /// A new shelf, which becomes the current one. Nil if there are too many already.
    @discardableResult
    mutating func addShelf(named name: String) -> ShelfSet? {
        let clean = Self.cleanName(name)
        guard shelves.count < Self.maxShelves, !clean.isEmpty else { return nil }
        let unique = Self.uniqueName(clean, among: shelves.map(\.name))
        let shelf = ShelfSet(name: unique)
        shelves.append(shelf)
        currentID = shelf.id
        return shelf
    }

    mutating func rename(_ id: String, to name: String) {
        guard let i = index(id) else { return }
        let clean = Self.cleanName(name)
        guard !clean.isEmpty else { return }
        shelves[i].name = Self.uniqueName(clean, among: shelves.enumerated().filter { $0.offset != i }.map(\.element.name))
    }

    /// Deletes a shelf; what it held goes to the history. The last shelf cannot be deleted.
    mutating func deleteShelf(_ id: String, now: Date = Date()) {
        guard shelves.count > 1, let i = index(id) else { return }
        for item in shelves[i].items { remember(item, at: now) }
        shelves.remove(at: i)
        if currentID == id { currentID = shelves[0].id }
    }

    mutating func select(_ id: String) { if index(id) != nil { currentID = id } }

    // MARK: Items

    /// Puts something on a shelf (the current one by default). The same file twice, or the same text twice, is held once.
    /// Returns false if it was a repeat or the shelf is full.
    @discardableResult
    mutating func add(_ record: ShelfRecord, to shelfID: String? = nil) -> Bool {
        guard let i = index(shelfID ?? currentID) else { return false }
        var record = record
        if record.kind == .text { record.value = String(record.value.prefix(Self.maxTextBytes)) }
        if shelves[i].items.contains(where: { $0.kind == record.kind && $0.value == record.value && record.kind != .image }) { return false }
        guard shelves[i].items.count < Self.maxItemsPerShelf else { return false }
        shelves[i].items.append(record)
        return true
    }

    /// Takes an item off its shelf and into the history.
    mutating func remove(_ itemID: String, now: Date = Date()) {
        for i in shelves.indices {
            if let j = shelves[i].items.firstIndex(where: { $0.id == itemID }) {
                remember(shelves[i].items.remove(at: j), at: now)
                return
            }
        }
    }

    /// Takes everything off a shelf (the current one by default); it all goes to the history.
    mutating func clear(_ shelfID: String? = nil, now: Date = Date()) {
        guard let i = index(shelfID ?? currentID) else { return }
        for item in shelves[i].items { remember(item, at: now) }
        shelves[i].items = []
    }

    /// Puts a history item back on a shelf.
    @discardableResult
    mutating func restore(_ itemID: String, to shelfID: String? = nil, now: Date = Date()) -> Bool {
        guard let h = history.firstIndex(where: { $0.id == itemID }) else { return false }
        var record = history[h]
        record.added = now
        record.removed = nil
        guard add(record, to: shelfID) else { return false }
        history.remove(at: h)
        return true
    }

    mutating func clearHistory() { history = [] }

    private mutating func remember(_ record: ShelfRecord, at date: Date) {
        var record = record
        record.removed = date
        history.removeAll { $0.id == record.id }
        history.insert(record, at: 0)
        if history.count > Self.maxHistory { history.removeLast(history.count - Self.maxHistory) }
    }

    // MARK: Time

    /// Lets go of items older than the expiry (into the history) and forgets history older than 30 days. Returns the pictures
    /// that are no longer held anywhere, so their files can be deleted.
    @discardableResult
    mutating func expire(now: Date = Date()) -> [String] {
        let before = Set(allImageNames)
        if let days = expiryDays, days > 0 {
            let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
            for i in shelves.indices {
                let old = shelves[i].items.filter { $0.added < cutoff }
                shelves[i].items.removeAll { $0.added < cutoff }
                for item in old { remember(item, at: now) }
            }
        }
        history.removeAll { now.timeIntervalSince($0.removed ?? $0.added) > Double(Self.historyDays) * 86_400 }
        return before.subtracting(allImageNames).sorted()
    }

    /// Names of the pictures still held on a shelf or in the history.
    var allImageNames: [String] {
        (shelves.flatMap(\.items) + history).filter { $0.kind == .image }.map(\.value)
    }

    // MARK: Searching

    struct Hit: Equatable {
        let record: ShelfRecord
        /// The shelf's name, or nil for the history.
        let shelf: String?
    }

    /// Items on any shelf, then in the history, whose name or text contains every word typed.
    func search(_ query: String) -> [Hit] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        func matches(_ record: ShelfRecord) -> Bool {
            let haystack = (record.kind == .file ? record.value : record.kind == .text ? record.value : "image").lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
        var hits: [Hit] = []
        for shelf in shelves { hits += shelf.items.filter(matches).map { Hit(record: $0, shelf: shelf.name) } }
        hits += history.filter(matches).map { Hit(record: $0, shelf: nil) }
        return hits
    }

    // MARK: Names

    static func cleanName(_ name: String) -> String { String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(30)) }

    static func uniqueName(_ name: String, among taken: [String]) -> String {
        var candidate = name
        var n = 2
        while taken.contains(where: { $0.caseInsensitiveCompare(candidate) == .orderedSame }) {
            candidate = "\(name) \(n)"
            n += 1
        }
        return candidate
    }
}
