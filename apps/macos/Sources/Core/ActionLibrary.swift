import Combine
import Foundation

/// The person's saved, named actions. Anything that can trigger an action picks from this list.
final class ActionLibrary: ObservableObject {
    @Published private(set) var actions: [NamedAction] = []

    private let core: KriyaCore

    init(core: KriyaCore) {
        self.core = core
        reload()
    }

    func reload() {
        do {
            actions = try core.actions()
        } catch {
            Log.error("Actions", "Could not load actions: \(error.userMessage)")
        }
    }

    func save(name: String, action: Action, id: String = UUID().uuidString) throws {
        if let problem = actionProblem(action: action) { throw CoreError.Invalid(message: problem) }
        try core.saveAction(action: NamedAction(id: id, name: name, action: action))
        reload()
    }

    /// Adds the ready-made actions (Back, Forward, Mission Control, desktops, tabs and a few window and pointer commands)
    /// that are not saved yet. Returns how many were added.
    @discardableResult
    func addSuggested() -> Int {
        let existing = Set(actions.map(\.id))
        var added = 0
        for item in suggestedActions() where !existing.contains(item.id) {
            do {
                try core.saveAction(action: item)
                added += 1
            } catch {
                Log.error("Actions", "Could not add \(item.name): \(error.userMessage)")
            }
        }
        reload()
        return added
    }

    func delete(_ action: NamedAction) throws {
        try core.deleteAction(id: action.id)
        reload()
    }
}
