import Foundation

/// The kinds of thing the launcher can find. Each can be turned off in Settings › Launcher.
enum LauncherCategory: String, CaseIterable, Identifiable, Codable {
    case calculator, utility, command, layout, snippet, action, workflow, feature, setting
    case app, window, clipboard, file, system, emoji, intelligence, web

    var id: String { rawValue }

    var title: String {
        switch self {
        case .calculator: return "Calculator"
        case .utility: return "Timers"
        case .command: return "Commands"
        case .layout: return "Window layouts"
        case .snippet: return "Snippets"
        case .action: return "Saved actions"
        case .workflow: return "Workflows"
        case .feature: return "Kriya features"
        case .setting: return "Kriya settings"
        case .app: return "Apps"
        case .window: return "Open windows"
        case .clipboard: return "Clipboard history"
        case .file: return "Files and folders"
        case .system: return "System"
        case .emoji: return "Emoji"
        case .intelligence: return "Apple Intelligence"
        case .web: return "Web search"
        }
    }

    /// The short word shown beside a result.
    var label: String {
        switch self {
        case .calculator: return "Calculator"
        case .utility: return "Timer"
        case .command: return "Command"
        case .layout: return "Layout"
        case .snippet: return "Snippet"
        case .action: return "Action"
        case .workflow: return "Workflow"
        case .feature: return "Feature"
        case .setting: return "Settings"
        case .app: return "App"
        case .window: return "Window"
        case .clipboard: return "Clipboard"
        case .file: return "File"
        case .system: return "System"
        case .emoji: return "Emoji"
        case .intelligence: return "AI"
        case .web: return "Web"
        }
    }

    var symbol: String {
        switch self {
        case .calculator: return "equal.square"
        case .utility: return "timer"
        case .command: return "command"
        case .layout: return "rectangle.split.2x2"
        case .snippet: return "text.insert"
        case .action: return "bolt"
        case .workflow: return "gearshape.2"
        case .feature: return "switch.2"
        case .setting: return "gearshape"
        case .app: return "app"
        case .window: return "macwindow"
        case .clipboard: return "doc.on.clipboard"
        case .file: return "doc"
        case .system: return "desktopcomputer"
        case .emoji: return "face.smiling"
        case .intelligence: return "sparkles"
        case .web: return "globe"
        }
    }

    /// What pressing Return does with this kind of result, for the hint on the chosen row.
    var verb: String {
        switch self {
        case .app, .file, .setting, .feature, .system: return "Open"
        case .window: return "Switch to"
        case .web: return "Search"
        case .calculator, .emoji, .clipboard: return "Copy"
        case .utility: return "Start"
        case .intelligence: return "Ask"
        case .command, .layout, .snippet, .action, .workflow: return "Run"
        }
    }

    /// Searching these reads things outside Kriya, so they are worth saying out loud in Settings.
    var detail: String {
        switch self {
        case .file: return "Looks in your home folder with Spotlight, only for what you type."
        case .clipboard: return "Searches your clipboard history. Hidden while it is locked."
        case .window: return "Needs Accessibility, to list and raise windows."
        case .app: return "Installed and running apps."
        case .intelligence: return "Type “ask” and a question, or use the clipboard shortcuts. Handled on this Mac; needs Apple Intelligence."
        case .web: return "Offers to search the web, or open an address you type. Only the words you choose are sent, to the site you pick."
        default: return ""
        }
    }

    /// How much this kind of result is pushed up or down when several match equally well.
    var bias: Int {
        switch self {
        case .calculator: return 300
        case .utility: return 120
        case .app: return 60
        case .command, .layout, .snippet, .action, .workflow, .feature: return 20
        case .window: return 30
        case .setting, .system: return 0
        case .emoji: return -10
        case .intelligence: return 10
        case .web: return -80
        case .clipboard: return -20
        case .file: return -60
        }
    }
}

struct LauncherUsage: Codable, Equatable {
    var count: Int
    var last: Date
}

/// What the person chose in the launcher: which kinds to search, short names, pinned results, and what they have used.
struct LauncherPrefsData: Codable, Equatable {
    var disabledCategories: Set<String> = []
    /// A short word that picks one result first, such as "ff" for Firefox. Stored lower-case, without spaces.
    var aliases: [String: String] = [:]
    /// Result ids, shown first when nothing has been typed.
    var pinned: [String] = []
    var usage: [String: LauncherUsage] = [:]
    /// The names of pinned results and results with a short name, so Settings can list them. Never any clipboard text.
    var titles: [String: String] = [:]
    /// The search site for plain web searches. Nil is the default, Google.
    var webEngine: String?

    func isEnabled(_ category: LauncherCategory) -> Bool { !disabledCategories.contains(category.rawValue) }
}

/// What ranking needs to know about a result.
struct LauncherCandidate: Equatable {
    let id: String
    let title: String
    let subtitle: String
    let keywords: [String]
    let category: LauncherCategory
    /// Results from what was typed (a sum, a file the search found) already match; they carry their own score.
    let queryScore: Int?
    /// Whether choosing it should be remembered. Clipboard items and sums are not.
    let rememberable: Bool
}

enum LauncherEngine {
    static let recentCount = 8
    static let maxRemembered = 300

    /// The ids in the order they should be shown.
    static func rank(_ items: [LauncherCandidate], query: String, prefs: LauncherPrefsData, now: Date = Date(), limit: Int = 60, suggestions: [String] = []) -> [String] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let visible = items.filter { prefs.isEnabled($0.category) }
        if text.isEmpty { return startList(visible, prefs: prefs, now: now, suggestions: suggestions) }

        let alias = text.lowercased().filter { !$0.isWhitespace }
        var scored: [(candidate: LauncherCandidate, score: Int)] = []
        for item in visible {
            var score: Int
            if let target = prefs.aliases[alias], target == item.id {
                score = 5000
            } else if let own = item.queryScore {
                score = own
            } else {
                let title = FuzzyMatcher.best(text, in: [item.title] + item.keywords)
                let subtitle = FuzzyMatcher.score(text, in: item.subtitle).map { $0 - 200 }
                guard let best = [title, subtitle].compactMap({ $0 }).max() else { continue }
                score = best
            }
            score += item.category.bias
            score += usageBoost(prefs.usage[item.id], now: now)
            if prefs.pinned.contains(item.id) { score += 40 }
            scored.append((item, score))
        }
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.candidate.title.localizedCaseInsensitiveCompare($1.candidate.title) == .orderedAscending }
        return scored.prefix(limit).map(\.candidate.id)
    }

    /// How many suggestions the opening list shows at most.
    static let startCount = 9

    /// Nothing typed: pinned results in the order they were pinned, then the ones used most and most recently, then
    /// whatever the launcher suggests (the apps that are open) so the list is never bare.
    static func startList(_ items: [LauncherCandidate], prefs: LauncherPrefsData, now: Date, suggestions: [String] = []) -> [String] {
        let known = Set(items.map(\.id))
        var out = prefs.pinned.filter { known.contains($0) }
        let recents = prefs.usage
            .filter { known.contains($0.key) && !out.contains($0.key) }
            .sorted { frecency($0.value, now: now) > frecency($1.value, now: now) }
            .prefix(recentCount)
            .map(\.key)
        out.append(contentsOf: recents)
        for id in suggestions where known.contains(id) && !out.contains(id) { out.append(id) }
        return Array(out.prefix(max(startCount, prefs.pinned.count)))
    }

    /// The heading a row sits under when nothing is typed.
    static func startSection(for id: String, prefs: LauncherPrefsData) -> String {
        if prefs.pinned.contains(id) { return "Pinned" }
        return prefs.usage[id] != nil ? "Recent" : "Suggested"
    }

    /// Up to 60 for something used often, and fading over a few weeks.
    static func usageBoost(_ usage: LauncherUsage?, now: Date) -> Int {
        guard let usage else { return 0 }
        return min(usage.count, 10) * 4 + recency(usage.last, now: now)
    }

    private static func recency(_ date: Date, now: Date) -> Int {
        let days = max(0, now.timeIntervalSince(date) / 86_400)
        return max(0, 20 - Int(days))
    }

    private static func frecency(_ usage: LauncherUsage, now: Date) -> Int {
        min(usage.count, 20) * 5 + recency(usage.last, now: now) * 3
    }

    /// Records a choice, and forgets the least recent when there are too many.
    static func recording(_ id: String, in prefs: LauncherPrefsData, now: Date = Date()) -> LauncherPrefsData {
        var next = prefs
        var usage = next.usage[id] ?? LauncherUsage(count: 0, last: now)
        usage.count += 1
        usage.last = now
        next.usage[id] = usage
        if next.usage.count > maxRemembered {
            let drop = next.usage.sorted { $0.value.last < $1.value.last }.prefix(next.usage.count - maxRemembered).map(\.key)
            for key in drop { next.usage[key] = nil }
        }
        return next
    }
}

/// The launcher's saved choices, kept in the app's preferences. Nothing in here ever holds clipboard text or file contents.
final class LauncherPrefs: ObservableObject {
    @Published private(set) var data: LauncherPrefsData

    private let defaults: UserDefaults
    private let key = "launcherPrefs.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let stored = defaults.data(forKey: key), let decoded = try? JSONDecoder().decode(LauncherPrefsData.self, from: stored) {
            data = decoded
        } else {
            data = LauncherPrefsData()
        }
    }

    private func change(_ edit: (inout LauncherPrefsData) -> Void) {
        var next = data
        edit(&next)
        guard next != data else { return }
        data = next
        if let encoded = try? JSONEncoder().encode(next) { defaults.set(encoded, forKey: key) }
    }

    func record(_ id: String) { data = LauncherEngine.recording(id, in: data); persist() }
    private func persist() { if let encoded = try? JSONEncoder().encode(data) { defaults.set(encoded, forKey: key) } }

    func setEnabled(_ category: LauncherCategory, _ on: Bool) {
        change { if on { $0.disabledCategories.remove(category.rawValue) } else { $0.disabledCategories.insert(category.rawValue) } }
    }

    func isPinned(_ id: String) -> Bool { data.pinned.contains(id) }

    func togglePin(_ id: String, title: String? = nil) {
        change {
            if let index = $0.pinned.firstIndex(of: id) {
                $0.pinned.remove(at: index)
            } else {
                $0.pinned.append(id)
                if let title { $0.titles[id] = title }
            }
        }
    }

    func setWebEngine(_ id: String) {
        change { $0.webEngine = id == WebSearch.defaultEngineID ? nil : id }
    }

    func unpin(_ id: String) { change { $0.pinned.removeAll { $0 == id } } }

    func movePinned(_ id: String, by delta: Int) {
        change {
            guard let index = $0.pinned.firstIndex(of: id) else { return }
            let target = min(max(index + delta, 0), $0.pinned.count - 1)
            $0.pinned.remove(at: index)
            $0.pinned.insert(id, at: target)
        }
    }

    /// Sets a short word for a result. The word is kept lower-case without spaces; an empty word removes it.
    @discardableResult
    func setAlias(_ word: String, for id: String, title: String? = nil) -> Bool {
        let cleaned = word.lowercased().filter { !$0.isWhitespace }
        guard cleaned.count <= 20 else { return false }
        change {
            for (existing, target) in $0.aliases where target == id { $0.aliases[existing] = nil }
            if !cleaned.isEmpty {
                $0.aliases[cleaned] = id
                if let title { $0.titles[id] = title }
            }
        }
        return true
    }

    func alias(for id: String) -> String? { data.aliases.first { $0.value == id }?.key }

    func clearHistory() { change { $0.usage = [:] } }

    func reset() { change { $0 = LauncherPrefsData() } }
}
