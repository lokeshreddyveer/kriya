import Foundation

/// Windows Kriya must never move, whatever a layout, a rule or a shortcut says.
struct WindowLock: Codable, Equatable, Identifiable {
    var id = UUID().uuidString
    var appID: String
    /// Empty locks every window of the app; otherwise only windows whose title contains this.
    var titleContains: String

    func covers(appID: String, title: String) -> Bool {
        guard self.appID == appID else { return false }
        return titleContains.isEmpty || title.range(of: titleContains, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}

enum WindowLocks {
    static func isLocked(_ locks: [WindowLock], appID: String, title: String) -> Bool {
        locks.contains { $0.covers(appID: appID, title: title) }
    }
}

/// The locks, kept in preferences and safe to read from any thread.
final class WindowLockStore: ObservableObject {
    static let shared = WindowLockStore()
    private let key = "windowLocks.v1"
    private let lock = NSLock()
    private var cache: [WindowLock]
    @Published private(set) var locks: [WindowLock]

    private init() {
        let saved = UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode([WindowLock].self, from: $0) } ?? []
        cache = saved
        locks = saved
    }

    func isLocked(appID: String, title: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return WindowLocks.isLocked(cache, appID: appID, title: title)
    }

    func add(appID: String, title: String) {
        update { list in
            let new = WindowLock(appID: appID, titleContains: title)
            if !list.contains(where: { $0.appID == new.appID && $0.titleContains == new.titleContains }) { list.append(new) }
        }
    }

    func remove(_ id: String) { update { $0.removeAll { $0.id == id } } }

    private func update(_ change: (inout [WindowLock]) -> Void) {
        lock.lock()
        var next = cache
        change(&next)
        cache = next
        lock.unlock()
        DispatchQueue.main.async { [self] in
            locks = next
            if let data = try? JSONEncoder().encode(next) { UserDefaults.standard.set(data, forKey: key) }
        }
    }
}

/// What restoring a layout would do, before doing it.
struct LayoutPreviewRow: Equatable, Identifiable {
    enum Result: Equatable {
        case moves(windowTitle: String)
        /// The app is not running; it will be opened if the layout says to.
        case appMissing(willOpen: Bool)
        case lockedWindow
        case noMatchingWindow
        case displayAbsent
    }
    let id: Int
    let appID: String
    let entryTitle: String
    let result: Result

    var willMove: Bool { if case .moves = result { return true }; return false }
}

enum LayoutPreview {
    /// One row per layout entry. `matches[i]` is the entry index chosen for open window `i`, as the matcher returns it.
    static func rows(
        entries: [(appID: String, title: String, displayID: String)], launchMissing: Bool,
        open: [(appID: String, title: String)], matches: [Int?], runningApps: Set<String>, displayIDs: Set<String>,
        isLocked: (String, String) -> Bool
    ) -> [LayoutPreviewRow] {
        var windowFor: [Int: Int] = [:]
        for (windowIndex, entryIndex) in matches.enumerated() { if let entryIndex { windowFor[entryIndex] = windowIndex } }
        return entries.enumerated().map { index, entry in
            let result: LayoutPreviewRow.Result
            if let w = windowFor[index] {
                result = isLocked(open[w].appID, open[w].title) ? .lockedWindow : .moves(windowTitle: open[w].title)
            } else if !runningApps.contains(entry.appID) {
                result = .appMissing(willOpen: launchMissing)
            } else {
                result = .noMatchingWindow
            }
            // A window that would move to a display that is not connected is shown, because it lands on the main one.
            if case .moves = result, !displayIDs.contains(entry.displayID) {
                return LayoutPreviewRow(id: index, appID: entry.appID, entryTitle: entry.title, result: .displayAbsent)
            }
            return LayoutPreviewRow(id: index, appID: entry.appID, entryTitle: entry.title, result: result)
        }
    }

    static func describe(_ row: LayoutPreviewRow, appName: String) -> String {
        switch row.result {
        case .moves(let title): return "\(appName) “\(title.isEmpty ? "window" : title)” will move"
        case .appMissing(let open): return open ? "\(appName) is not open; it will be opened" : "\(appName) is not open; it will be skipped"
        case .lockedWindow: return "\(appName) is locked and will stay where it is"
        case .noMatchingWindow: return "\(appName) is open but has no window to place"
        case .displayAbsent: return "\(appName) will move to the main display, because the one it was saved on is not connected"
        }
    }
}

/// Layout entries that found no window when a layout was restored, kept so they can be placed when the window turns up.
struct RestoreRetryQueue: Equatable {
    struct Item: Equatable, Identifiable {
        var id: String { "\(layoutID)#\(entryIndex)" }
        let layoutID: String
        let layoutName: String
        let entryIndex: Int
        let appID: String
        let title: String
        var attempts = 0
        let addedAt: Date
    }

    struct OpenWindow: Equatable {
        let appID: String
        let title: String
        let role: String?
        let key: String
    }

    private(set) var items: [Item] = []
    static let maxAge: TimeInterval = 600
    static let maxAttempts = 40
    static let maxItems = 50

    /// Adds entries (by index) of a layout; one already waiting is not added twice.
    mutating func add(layoutID: String, layoutName: String, entries: [(index: Int, appID: String, title: String)], now: Date) {
        for e in entries where !items.contains(where: { $0.layoutID == layoutID && $0.entryIndex == e.index }) && items.count < Self.maxItems {
            items.append(Item(layoutID: layoutID, layoutName: layoutName, entryIndex: e.index, appID: e.appID, title: e.title, addedAt: now))
        }
    }

    /// The best window for an item: same app, an ordinary window, the same title first, then any window of the app not already
    /// taken by another item.
    static func match(_ item: Item, among windows: [OpenWindow], taken: Set<String>) -> OpenWindow? {
        let candidates = windows.filter { $0.appID == item.appID && !taken.contains($0.key) && ($0.role == nil || $0.role == "AXStandardWindow") }
        if !item.title.isEmpty, let exact = candidates.first(where: { $0.title == item.title }) { return exact }
        if !item.title.isEmpty, let near = candidates.first(where: { $0.title.localizedCaseInsensitiveContains(item.title) }) { return near }
        return item.title.isEmpty ? candidates.first : nil
    }

    /// One pass: pairs each waiting item with a window if there is one, drops the old and the worn out, and counts an attempt
    /// for the rest. Returns the pairs to place; those items leave the queue.
    mutating func pass(windows: [OpenWindow], now: Date) -> [(item: Item, window: OpenWindow)] {
        var taken = Set<String>()
        var placed: [(Item, OpenWindow)] = []
        var remaining: [Item] = []
        for var item in items {
            if now.timeIntervalSince(item.addedAt) > Self.maxAge || item.attempts >= Self.maxAttempts { continue }
            if let window = Self.match(item, among: windows, taken: taken) {
                taken.insert(window.key)
                placed.append((item, window))
            } else {
                item.attempts += 1
                remaining.append(item)
            }
        }
        items = remaining
        return placed
    }

    mutating func cancel(_ id: String) { items.removeAll { $0.id == id } }
    mutating func clear() { items = [] }
}
