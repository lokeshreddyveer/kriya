import Foundation

/// Plain facts about saved actions: how much harm one could do, which ones are the same, and a search.
enum ActionInsight {
    enum Risk: Int, Comparable {
        case none = 0, low, medium, high
        static func < (a: Risk, b: Risk) -> Bool { a.rawValue < b.rawValue }

        var title: String {
            switch self {
            case .none: return "Harmless"
            case .low: return "Low risk"
            case .medium: return "Check it"
            case .high: return "Can change files"
            }
        }
    }

    static func risk(of action: Action) -> Risk {
        switch action {
        case .noop: return .none
        case .keyPress, .openApplication, .openUrl: return .low
        case .builtin(let command): return command.hasPrefix("window.") || command.hasPrefix("display.") ? .low : .medium
        case .runShortcut, .click: return .medium
        case .runShell, .runScript: return .high
        case .sequence(let steps, _): return steps.map(risk).max() ?? .none
        }
    }

    /// One sentence for why, shown beside the label.
    static func reason(for action: Action) -> String {
        switch risk(of: action) {
        case .none: return "It does nothing."
        case .low: return "It opens something or presses keys."
        case .medium: return "It clicks, runs a Shortcut, or does something that is not a window action."
        case .high: return "It runs a script, which can change or delete anything you can."
        }
    }

    /// Groups of actions that do exactly the same thing, however they are named.
    static func duplicates(_ actions: [NamedAction]) -> [[NamedAction]] {
        Dictionary(grouping: actions) { String(describing: $0.action) }.values.filter { $0.count > 1 }
            .map { $0.sorted { $0.name < $1.name } }
            .sorted { ($0.first?.name ?? "") < ($1.first?.name ?? "") }
    }

    /// Actions whose name or description contains every word typed.
    static func search(_ actions: [NamedAction], text: String, describe: (Action) -> String) -> [NamedAction] {
        let words = text.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return actions }
        return actions.filter { saved in
            let hay = (saved.name + " " + describe(saved.action)).lowercased()
            return words.allSatisfy { hay.contains($0) }
        }
    }
}
