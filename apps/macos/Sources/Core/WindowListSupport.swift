import Foundation

/// A window the person wants close at hand: any window of an app, or the ones whose title holds some words.
struct PinnedWindow: Codable, Equatable, Identifiable {
    var id = UUID().uuidString
    var appID: String
    var titleContains: String

    func matches(appID other: String, title: String) -> Bool {
        guard appID == other else { return false }
        let words = titleContains.trimmingCharacters(in: .whitespaces)
        return words.isEmpty || title.localizedCaseInsensitiveContains(words)
    }
}

enum WindowFavorites {
    static let maxCount = 30

    static func isFavorite(appID: String, title: String, in list: [PinnedWindow]) -> Bool {
        list.contains { $0.matches(appID: appID, title: title) }
    }

    /// Adds the window as a favorite, or takes the matching ones off. A new favorite remembers the title as it is now.
    static func toggled(appID: String, title: String, in list: [PinnedWindow]) -> [PinnedWindow] {
        if isFavorite(appID: appID, title: title, in: list) { return list.filter { !$0.matches(appID: appID, title: title) } }
        guard list.count < maxCount else { return list }
        return list + [PinnedWindow(appID: appID, titleContains: title)]
    }
}

/// One line of the window list.
struct WindowRow: Identifiable, Equatable {
    var id: String
    var appID: String
    var appName: String
    var title: String
    var display: String
    var isMinimized: Bool
    var isAppHidden: Bool
    var isFront: Bool
    var lastUsed: Int64
    var isFavorite: Bool
}

struct WindowSection: Identifiable, Equatable {
    var id: String { title }
    var title: String
    var rows: [WindowRow]
}

enum WindowGrouping: String, CaseIterable, Identifiable {
    case recent = "Recent", app = "By App", display = "By Display"
    var id: String { rawValue }
}

enum WindowListOrder {
    /// Rows that fit the words (in the app's name, the title or the display's name), every word having to.
    static func filter(_ rows: [WindowRow], query: String) -> [WindowRow] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return rows }
        return rows.filter { row in
            let haystack = (row.appName + " " + row.title + " " + row.display).lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
    }

    static func sections(_ rows: [WindowRow], query: String, grouping: WindowGrouping) -> [WindowSection] {
        let list = filter(rows, query: query).sorted { $0.lastUsed > $1.lastUsed }
        switch grouping {
        case .recent:
            var out: [WindowSection] = []
            let favorites = list.filter(\.isFavorite)
            if !favorites.isEmpty { out.append(WindowSection(title: "Favorites", rows: favorites)) }
            let open = list.filter { !$0.isFavorite && !$0.isMinimized && !$0.isAppHidden }
            if !open.isEmpty { out.append(WindowSection(title: "Open", rows: open)) }
            let tucked = list.filter { !$0.isFavorite && ($0.isMinimized || $0.isAppHidden) }
            if !tucked.isEmpty { out.append(WindowSection(title: "Minimized and hidden", rows: tucked)) }
            return out
        case .app:
            return Dictionary(grouping: list, by: \.appName).map { WindowSection(title: $0.key, rows: $0.value) }
                .sorted { $0.title.lowercased() < $1.title.lowercased() }
        case .display:
            return Dictionary(grouping: list, by: \.display).map { WindowSection(title: $0.key, rows: $0.value) }
                .sorted { $0.title.lowercased() < $1.title.lowercased() }
        }
    }

    /// Why a window is in the list, in plain words.
    static func why(_ row: WindowRow, query: String, rank: Int, now: Date = Date(), clock: Int64) -> String {
        var reasons: [String] = []
        if row.isFavorite { reasons.append("a favorite") }
        if row.isFront { reasons.append("the window in front") }
        else if rank < 3 { reasons.append("one of the last windows you used") }
        if row.isMinimized { reasons.append("minimized") }
        if row.isAppHidden { reasons.append("its app is hidden") }
        let words = query.trimmingCharacters(in: .whitespaces)
        if !words.isEmpty {
            if row.title.localizedCaseInsensitiveContains(words) { reasons.append("“\(words)” is in its title") }
            else if row.appName.localizedCaseInsensitiveContains(words) { reasons.append("“\(words)” is in its app's name") }
        }
        if reasons.isEmpty { reasons.append("open on \(row.display)") }
        return "Shown because it is " + ListFormatter.localizedString(byJoining: reasons)
    }

    /// The display (by name) whose area holds the middle of the window; the first display if none does.
    static func displayName(for frame: Rect?, displays: [(name: String, full: Rect)]) -> String {
        guard let frame, !displays.isEmpty else { return displays.first?.name ?? "Display" }
        let cx = frame.x + frame.width / 2, cy = frame.y + frame.height / 2
        let hit = displays.first { cx >= $0.full.x && cx < $0.full.x + $0.full.width && cy >= $0.full.y && cy < $0.full.y + $0.full.height }
        return (hit ?? displays[0]).name
    }
}
