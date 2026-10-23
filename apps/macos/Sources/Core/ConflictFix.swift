import Foundation

/// Ways to settle two or more things that want the same trigger, worked out from the conflict group alone. Nothing here
/// changes anything; the wizard shows these and applies the one chosen.
enum ConflictFix {
    enum Action: Equatable {
        /// Switch it off (it can be switched on again from its own pane, or with Undo).
        case turnOff
        /// Go to its pane to give it a different trigger.
        case change
    }

    struct Option: Identifiable, Equatable {
        let entry: InteractionEntry
        let action: Action
        var id: String { "\(action)|\(entry.id)" }
        var label: String {
            switch action {
            case .turnOff: return "Turn off “\(entry.title)”"
            case .change: return "Give “\(entry.title)” a different trigger"
            }
        }
    }

    /// What can be done about each member of a group. Remapped keys and automation triggers can be switched off from here;
    /// the rest are changed in their own pane.
    static func options(for group: [InteractionEntry]) -> [Option] {
        group.flatMap { entry -> [Option] in
            var list = [Option(entry: entry, action: .change)]
            if canTurnOff(entry) { list.insert(Option(entry: entry, action: .turnOff), at: 0) }
            return list
        }
    }

    static func canTurnOff(_ entry: InteractionEntry) -> Bool {
        entry.kind == .remap || entry.owner == "Automation"
    }

    /// The one most worth keeping, to start from: a keyboard shortcut over a remap, a button rule over a gesture. Nil when
    /// nothing is clearly better.
    static func suggestedKeeper(in group: [InteractionEntry]) -> InteractionEntry? {
        let kinds = Set(group.map(\.kind))
        if kinds.contains(.remap), let hotkey = group.first(where: { $0.kind == .hotkey }) { return hotkey }
        if kinds.contains(.gesture), let button = group.first(where: { $0.kind == .mouseButton }) { return button }
        return nil
    }

    /// The members to turn off once `keeper` is chosen. Only those that can be switched off from here.
    static func turnOffAllExcept(_ keeper: InteractionEntry, in group: [InteractionEntry]) -> [InteractionEntry] {
        group.filter { $0.id != keeper.id && canTurnOff($0) }
    }

    /// Keyboard shortcuts nobody uses yet, built on Control-Option-Command (which almost nothing else takes), for a
    /// person to pick from. `usedKeys` are the `key` strings of every entry.
    static func freeShortcuts(usedKeys: Set<String>, limit: Int = 6) -> [(keyCode: UInt16, modifiers: UInt64, text: String)] {
        let base = KeyModifiers.control | KeyModifiers.option | KeyModifiers.command
        var found: [(UInt16, UInt64, String)] = []
        for modifiers in [base, base | KeyModifiers.shift] {
            for name in "QWERTYUIOPASDFGHJKLZXCVBNM1234567890".map(String.init) {
                guard let code = KeyNames.keyCode(forName: name),
                      !usedKeys.contains(InteractionMap.keyboard(code, modifiers)) else { continue }
                found.append((code, modifiers, KeyNames.describe(keyCode: code, modifiers: modifiers)))
                if found.count >= limit { return found }
            }
        }
        return found
    }
}
