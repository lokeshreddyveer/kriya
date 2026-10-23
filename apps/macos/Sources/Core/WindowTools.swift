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
