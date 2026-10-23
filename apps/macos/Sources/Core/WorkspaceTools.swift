import Foundation

/// What opening a workspace would do, worked out before anything opens.
struct WorkspaceLaunchPlan: Equatable {
    var toOpen: [String] = []
    var alreadyRunning: [String] = []
    var notInstalled: [String] = []

    static func make(appIDs: [String], running: Set<String>, installed: (String) -> Bool) -> WorkspaceLaunchPlan {
        var plan = WorkspaceLaunchPlan()
        var seen = Set<String>()
        for id in appIDs where seen.insert(id).inserted {
            if running.contains(id) { plan.alreadyRunning.append(id) } else if installed(id) { plan.toOpen.append(id) } else { plan.notInstalled.append(id) }
        }
        return plan
    }

    func sentence(name: (String) -> String) -> String {
        var parts: [String] = []
        if !toOpen.isEmpty { parts.append("will open " + toOpen.map(name).joined(separator: ", ")) }
        if !alreadyRunning.isEmpty { parts.append("leaves " + alreadyRunning.map(name).joined(separator: ", ") + " as it is") }
        if !notInstalled.isEmpty { parts.append("cannot find " + notInstalled.joined(separator: ", ")) }
        return parts.isEmpty ? "has no apps" : parts.joined(separator: "; ")
    }
}

/// What each launch of a workspace did, newest first, so it can be read back and undone.
struct WorkspaceLaunchLog: Codable, Equatable {
    struct Entry: Codable, Equatable, Identifiable {
        var id = UUID().uuidString
        var at: Date
        var workspaceID: String
        var workspaceName: String
        var opened: [String]
        var alreadyRunning: [String]
        var notInstalled: [String]
        var hidden: [String]
        var urlsOpened: Int
        var undone = false
        /// Whether a Sound mode was turned on by this launch. Optional so older logs load.
        var soundModeApplied: Bool?
    }

    var entries: [Entry] = []
    static let limit = 50

    mutating func add(_ entry: Entry) {
        entries.insert(entry, at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
    }

    mutating func markUndone(_ id: String) {
        if let i = entries.firstIndex(where: { $0.id == id }) { entries[i].undone = true }
    }

    var lastUndoable: Entry? { entries.first { !$0.undone && (!$0.opened.isEmpty || !$0.hidden.isEmpty || $0.soundModeApplied == true) } }
}

enum WorkspaceRollback {
    struct Plan: Equatable {
        /// Apps this launch started that are still running: asked to quit.
        var quit: [String]
        /// Apps this launch hid that are still running: shown again.
        var unhide: [String]
    }

    /// Only what the launch itself did is undone. An app that was already open is never quit.
    static func plan(for entry: WorkspaceLaunchLog.Entry, running: Set<String>) -> Plan {
        Plan(quit: entry.opened.filter(running.contains), unhide: entry.hidden.filter(running.contains))
    }
}
