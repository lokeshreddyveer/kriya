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

    var clamped: FocusSessionConfig {
        var c = self
        c.minutes = min(max(minutes, 1), 480)
        c.quitAppIDs = Array(Set(quitAppIDs)).sorted()
        c.startShortcut = startShortcut.trimmingCharacters(in: .whitespaces)
        c.endShortcut = endShortcut.trimmingCharacters(in: .whitespaces)
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
                                      changedDock: changeDock, changedDesktop: changeDesktop, endShortcut: c.endShortcut)
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
