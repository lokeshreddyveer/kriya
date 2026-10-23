import Foundation

/// What a focus session does while it lasts. Everything it changes is put back when it ends.
struct FocusSessionConfig: Codable, Equatable {
    var minutes = 25
    var hideDock = true
    var hideDesktopIcons = true
    /// Bundle identifiers of apps to ask to quit when the session starts (chat, mail and the like).
    var quitAppIDs: [String] = []
    /// Names of Shortcuts to run when it starts and ends, for example one that turns on a Focus. Empty means none.
    var startShortcut = ""
    var endShortcut = ""
    /// Say "take a break" every this many minutes of focus. Nil means never. Optional so older saved settings still load.
    var breakEveryMinutes: Int?

    var clamped: FocusSessionConfig {
        var c = self
        c.minutes = min(max(minutes, 1), 480)
        c.quitAppIDs = Array(Set(quitAppIDs)).sorted()
        c.startShortcut = startShortcut.trimmingCharacters(in: .whitespaces)
        c.endShortcut = endShortcut.trimmingCharacters(in: .whitespaces)
        if let every = breakEveryMinutes { c.breakEveryMinutes = every <= 0 ? nil : min(max(every, 5), 240) }
        return c
    }
}

/// How things were before the session, kept on disk so a crash or quit in the middle never leaves the Dock or desktop changed.
struct FocusSessionState: Codable, Equatable {
    var endsAt: Date
    var dockWasHidden: Bool
    var desktopIconsWereShown: Bool
    var changedDock: Bool
    var changedDesktop: Bool
    var endShortcut: String
    /// Added later, so optional: a session saved by an older version still loads.
    var startedAt: Date?
    var plannedMinutes: Int?
    var pausedAt: Date?
    var pausedTotal: TimeInterval?
    var breaksGiven: Int?

    var isPaused: Bool { pausedAt != nil }
}

enum FocusStep: Equatable {
    case setDockHidden(Bool)
    case setDesktopIcons(Bool)
    case quit(String)
    case shortcut(String)
}

enum FocusPlan {
    /// The steps to start a session, given how the Dock and desktop are now. A setting that is already as wanted is left alone,
    /// so ending the session does not change something the person had set themselves.
    static func start(_ config: FocusSessionConfig, dockHidden: Bool, desktopIconsShown: Bool, now: Date) -> (steps: [FocusStep], state: FocusSessionState) {
        let c = config.clamped
        var steps: [FocusStep] = []
        let changeDock = c.hideDock && !dockHidden
        let changeDesktop = c.hideDesktopIcons && desktopIconsShown
        if changeDock { steps.append(.setDockHidden(true)) }
        if changeDesktop { steps.append(.setDesktopIcons(false)) }
        steps += c.quitAppIDs.map { .quit($0) }
        if !c.startShortcut.isEmpty { steps.append(.shortcut(c.startShortcut)) }
        let state = FocusSessionState(endsAt: now.addingTimeInterval(Double(c.minutes) * 60), dockWasHidden: dockHidden, desktopIconsWereShown: desktopIconsShown,
                                      changedDock: changeDock, changedDesktop: changeDesktop, endShortcut: c.endShortcut,
                                      startedAt: now, plannedMinutes: c.minutes, pausedAt: nil, pausedTotal: 0, breaksGiven: 0)
        return (steps, state)
    }

    static func end(_ state: FocusSessionState) -> [FocusStep] {
        var steps: [FocusStep] = []
        if state.changedDock { steps.append(.setDockHidden(state.dockWasHidden)) }
        if state.changedDesktop { steps.append(.setDesktopIcons(state.desktopIconsWereShown)) }
        if !state.endShortcut.isEmpty { steps.append(.shortcut(state.endShortcut)) }
        return steps
    }

    /// "24:10 left" or "2 h 05 m left".
    static func remaining(until end: Date, now: Date) -> String {
        let s = max(Int(end.timeIntervalSince(now).rounded(.up)), 0)
        if s >= 3600 { return "\(s / 3600) h \(String(format: "%02d", s % 3600 / 60)) m left" }
        return String(format: "%d:%02d left", s / 60, s % 60)
    }

    /// "focus", "focus 45", "focus off" typed in the launcher.
    static func request(_ text: String) -> Request? {
        let words = text.lowercased().trimmingCharacters(in: .whitespaces).split(separator: " ").map(String.init)
        guard words.first == "focus" else { return nil }
        if words.count == 1 { return .start(nil) }
        if ["off", "stop", "end"].contains(words[1]) { return .stop }
        if let n = Int(words[1].replacingOccurrences(of: "m", with: "")), (1...480).contains(n) { return .start(n) }
        return nil
    }

    enum Request: Equatable { case start(Int?), stop }
}


extension FocusPlan {
    /// Stops the clock. The end time moves out by however long the pause lasts, when it is resumed.
    static func paused(_ state: FocusSessionState, at now: Date) -> FocusSessionState {
        guard state.pausedAt == nil else { return state }
        var next = state
        next.pausedAt = now
        return next
    }

    static func resumed(_ state: FocusSessionState, at now: Date) -> FocusSessionState {
        guard let since = state.pausedAt else { return state }
        let gap = max(now.timeIntervalSince(since), 0)
        var next = state
        next.pausedAt = nil
        next.endsAt = state.endsAt.addingTimeInterval(gap)
        next.pausedTotal = (state.pausedTotal ?? 0) + gap
        return next
    }

    /// Minutes of focus so far, not counting pauses.
    static func focusedMinutes(_ state: FocusSessionState, now: Date) -> Int {
        guard let start = state.startedAt else { return 0 }
        let paused = (state.pausedTotal ?? 0) + (state.pausedAt.map { now.timeIntervalSince($0) } ?? 0)
        return max(Int((now.timeIntervalSince(start) - paused) / 60), 0)
    }

    /// Whether a break reminder is due: one for every `every` minutes of focus, given once each.
    static func breakDue(_ state: FocusSessionState, now: Date, every: Int?) -> Bool {
        guard let every, every > 0, !state.isPaused else { return false }
        return focusedMinutes(state, now: now) / every > (state.breaksGiven ?? 0)
    }
}

/// Finished sessions, newest first, kept to the last hundred.
struct FocusHistory: Codable, Equatable {
    struct Entry: Codable, Equatable, Identifiable {
        var id = UUID().uuidString
        var startedAt: Date
        var plannedMinutes: Int
        var focusedMinutes: Int
        /// True when the time ran out; false when the person ended it early.
        var completed: Bool
    }

    var entries: [Entry] = []
    static let limit = 100

    mutating func add(_ entry: Entry) {
        entries.insert(entry, at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
    }

    /// Minutes focused in the seven days up to `now`, and how many sessions.
    func week(now: Date) -> (minutes: Int, sessions: Int) {
        let recent = entries.filter { now.timeIntervalSince($0.startedAt) <= 7 * 86_400 && $0.startedAt <= now }
        return (recent.reduce(0) { $0 + $1.focusedMinutes }, recent.count)
    }

    static func entry(for state: FocusSessionState, endedAt now: Date) -> Entry? {
        guard let start = state.startedAt else { return nil }
        let planned = state.plannedMinutes ?? 0
        let focused = FocusPlan.focusedMinutes(state, now: now)
        return Entry(startedAt: start, plannedMinutes: planned, focusedMinutes: focused, completed: state.endsAt <= now && !state.isPaused)
    }
}
