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
                       keys: SettingsRegistry.keys(inArea: "launcher")),
        ResettableArea(id: "sound", title: "Sound", detail: "Sound rules, modes, remembered volumes, device history, places and per-app sound settings.",
                       keys: SettingsRegistry.keys(inArea: "sound")),
        ResettableArea(id: "finder", title: "Finder and dialogs", detail: "Folder rules, folder sets, favorites and recent folders, window history, dialog folders and the operation history.",
                       keys: SettingsRegistry.keys(inArea: "finder")),
        ResettableArea(id: "capture", title: "Capture and recording", detail: "Where captures go, naming, recording options and shortcuts.", keys: SettingsRegistry.keys(inArea: "capture")),
        ResettableArea(id: "clipboard", title: "Clipboard rules", detail: "The rules that change what is copied.", keys: SettingsRegistry.keys(inArea: "clipboard")),
        ResettableArea(id: "midi", title: "MIDI triggers", detail: "The controls you taught Kriya.", keys: SettingsRegistry.keys(inArea: "midi")),
        ResettableArea(id: "focus", title: "Focus sessions", detail: "Focus session settings and state.", keys: SettingsRegistry.keys(inArea: "focus")),
        ResettableArea(id: "intelligence", title: "Apple Intelligence", detail: "Its settings, including web research.", keys: SettingsRegistry.keys(inArea: "intelligence")),
        ResettableArea(id: "clipsync", title: "Clipboard sync", detail: "Whether sync is on, what it shared and its removal marks. Files already in iCloud Drive are left alone.", keys: SettingsRegistry.keys(inArea: "clipsync")),
        ResettableArea(id: "ai", title: "AI providers", detail: "Provider settings, which part uses which, tool approvals, usage counts and AI history. Keys stay in the Keychain: remove them in Apple Intelligence settings.",
                       keys: SettingsRegistry.keys(inArea: "ai")),
        ResettableArea(id: "activity", title: "Activity and upgrade history", detail: "The activity log and app upgrade history.", keys: SettingsRegistry.keys(inArea: "activity")),
        ResettableArea(id: "timelines", title: "Device and display history", detail: "The connect and disconnect timelines for devices and displays.", keys: SettingsRegistry.keys(inArea: "timelines")),
        ResettableArea(id: "windowextras", title: "Window locks and workspaces log", detail: "Windows that stay put, the Space-change layout choice, the display-setup layouts and the workspace launch log.",
                       keys: SettingsRegistry.keys(inArea: "windowextras")),
        ResettableArea(id: "pointer", title: "Pointer positions", detail: "Which display each saved pointer position was made for. The positions themselves are kept with the pointer effects settings.",
                       keys: SettingsRegistry.keys(inArea: "pointer")),
        ResettableArea(id: "usage", title: "Action usage", detail: "Which selection-bar and saved actions were used, by name only.", keys: SettingsRegistry.keys(inArea: "usage")),
        ResettableArea(id: "notes", title: "Notes settings", detail: "Which notes are pinned. The notes themselves are files and are left alone.", keys: SettingsRegistry.keys(inArea: "notes")),
        ResettableArea(id: "shelfreminders", title: "File Shelf reminders", detail: "How early shelf items warn you before expiring, and which warnings were already shown.", keys: SettingsRegistry.keys(inArea: "shelfreminders")),
        ResettableArea(id: "powersaving", title: "Power saving", detail: "Kriya's own power-saving mode.", keys: SettingsRegistry.keys(inArea: "powersaving")),
        ResettableArea(id: "appearance", title: "Appearance and placement", detail: "Text size, launcher theme, accent and placement, and the window switcher style.", keys: SettingsRegistry.keys(inArea: "appearance")),
        ResettableArea(id: "speech", title: "Speech and dictation", detail: "Read-aloud voice, rate and pitch, and the dictation language.", keys: SettingsRegistry.keys(inArea: "speech")),
        ResettableArea(id: "keepawake", title: "Keep Awake", detail: "Which apps keep the Mac awake and the battery and display options.", keys: SettingsRegistry.keys(inArea: "keepawake")),
        ResettableArea(id: "menubar", title: "Menu bar window and items", detail: "Tiles, sections, theme and layout of the menu-bar window, and the menu-bar hider.", keys: SettingsRegistry.keys(inArea: "menubar")),
        ResettableArea(id: "sysmonitor", title: "System monitor", detail: "Which numbers show and the alert thresholds.", keys: SettingsRegistry.keys(inArea: "sysmonitor")),
        ResettableArea(id: "worldclock", title: "World clock", detail: "Places, hours and the menu-bar display.", keys: SettingsRegistry.keys(inArea: "worldclock")),
        ResettableArea(id: "displays", title: "Monitor controls", detail: "Saved monitor presets.", keys: SettingsRegistry.keys(inArea: "displays")),
        ResettableArea(id: "selection", title: "Selection bar keyboard mode", detail: "Whether the selection bar opens straight in keyboard mode.", keys: SettingsRegistry.keys(inArea: "selection")),
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

    /// What the area has saved now, so a reset can be taken back.
    static func capture(_ area: ResettableArea, in defaults: UserDefaults = .standard) -> [String: Any] {
        var values: [String: Any] = [:]
        for key in area.keys { if let value = defaults.object(forKey: key) { values[key] = value } }
        return values
    }

    /// Puts captured values back. Only keys that belong to the area are written, whatever the file says.
    @discardableResult
    static func restore(_ values: [String: Any], to area: ResettableArea, in defaults: UserDefaults = .standard) -> Int {
        var count = 0
        for (key, value) in values where area.keys.contains(key) { defaults.set(value, forKey: key); count += 1 }
        return count
    }
}

/// The last reset, kept in a file so it can be undone after a restart, and so a restart that never happened is noticed.
struct FeatureResetUndo {
    let file: URL
    static let keepFor: TimeInterval = 24 * 3600

    func save(area: ResettableArea, values: [String: Any], at date: Date = Date()) throws {
        let plist: [String: Any] = ["area": area.id, "at": date, "values": values]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
    }

    /// The area and values of the last reset, unless it is older than a day or the file is not one of ours.
    func load(now: Date = Date()) -> (area: ResettableArea, values: [String: Any], at: Date)? {
        guard let data = try? Data(contentsOf: file),
              let plist = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any],
              let id = plist["area"] as? String, let area = FeatureReset.areas.first(where: { $0.id == id }),
              let at = plist["at"] as? Date, now.timeIntervalSince(at) <= Self.keepFor,
              let values = plist["values"] as? [String: Any] else { return nil }
        return (area, values, at)
    }

    func clear() { try? FileManager.default.removeItem(at: file) }
}
