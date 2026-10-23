import Foundation

/// The saved settings of one part of Kriya, so that part can be put back to how it was on first launch without touching the rest.
struct ResettableArea: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
    /// The preference keys it keeps its settings under.
    let keys: [String]
}

enum FeatureReset {
    static let areas: [ResettableArea] = [
        ResettableArea(id: "launcher", title: "Launcher", detail: "Search sources, quicklinks, scripts, API commands, approvals, history and rates.",
                       keys: ["launcherPrefs.v1", "launcherQuicklinks.v1", "launcherScripts.v1", "launcherScriptFolders.v1", "launcherAPICommands.v1", "launcherApprovals.v1",
                              "launcherSearchHistory.v1", "launcherRates.v1", "recentApps.v1"]),
        ResettableArea(id: "sound", title: "Sound", detail: "Sound rules, modes, remembered volumes, device history, places and per-app sound settings.",
                       keys: ["soundRules.v1", "soundModes.v1", "soundDeviceVolumes.v1", "soundDeviceHistory.v1", "soundSnapshot.v1", "soundSnapshotTime.v1",
                              "soundRemembersVolumes", "soundNotifiesDevices", "placeRules.v1", "placeRules.enabled", "appAudio.profiles.v1", "appAudio.settings.v1"]),
        ResettableArea(id: "finder", title: "Finder and dialogs", detail: "Folder rules, folder sets, favorites and recent folders, window history, dialog folders and the operation history.",
                       keys: ["folderRules.v1", "folderSets.v1", "finder.destinations.v1", "finder.fileOperations.v1", "finderWindows.history.v1", "finderWindows.enabled", "dialogAppFolders.v1"]),
        ResettableArea(id: "capture", title: "Capture and recording", detail: "Where captures go, naming, recording options and shortcuts.", keys: ["captureSettings.v1"]),
        ResettableArea(id: "clipboard", title: "Clipboard rules", detail: "The rules that change what is copied.", keys: ["clipboardRules.v1"]),
        ResettableArea(id: "midi", title: "MIDI triggers", detail: "The controls you taught Kriya.", keys: ["midiTriggers.v1", "midiTriggers.enabled"]),
        ResettableArea(id: "focus", title: "Focus sessions", detail: "Focus session settings and state.", keys: ["focusSession.config.v1", "focusSession.state.v1"]),
        ResettableArea(id: "intelligence", title: "Apple Intelligence", detail: "Its settings, including web research.", keys: ["intelligenceSettings.v1"]),
        ResettableArea(id: "activity", title: "Activity and upgrade history", detail: "The activity log and app upgrade history.", keys: ["auditLog.v1", "appUpgradeHistory.v1"]),
    ]

    /// The keys of one area that are actually saved, so a reset reports what it removed.
    static func savedKeys(of area: ResettableArea, in defaults: UserDefaults = .standard) -> [String] {
        area.keys.filter { defaults.object(forKey: $0) != nil }
    }

    /// Removes only that area's saved settings. Returns how many keys were removed.
    @discardableResult
    static func reset(_ area: ResettableArea, in defaults: UserDefaults = .standard) -> Int {
        let saved = savedKeys(of: area, in: defaults)
        for key in saved { defaults.removeObject(forKey: key) }
        return saved.count
    }
}
