import Foundation

/// What a saved preference is, which decides whether a backup carries it.
enum SettingKind: Equatable {
    /// A choice the person made. Travels in a backup and is cleared by a reset.
    case setting
    /// A log or timeline. Never travels in a backup; a reset clears it.
    case history
    /// A grant of trust or consent (approvals, sending text off this Mac, running things by themselves). Never restored from a
    /// file, because a backup must not switch on something the person has not agreed to on this Mac.
    case approval
    /// Belongs to this Mac or this moment (ids, tokens, paths, paused flags). Never travels.
    case machine
}

/// How a changed value reaches the part of Kriya that uses it.
enum SettingEffect: Equatable {
    /// Read each time it is used, or watched by the screen that shows it: the new value is in force at once.
    case live
    /// Held in memory by a store that has a reload step registered in `SettingsReloader`.
    case reload(ReloadGroup)
    /// Read once when Kriya starts. The new value is in force after a restart, and the person is told so.
    case restart
}

enum ReloadGroup: String, CaseIterable {
    case windowLocks, popover
}

struct SettingEntry: Equatable {
    let key: String
    /// The reset area (`ResettableArea.id`) that clears it.
    let area: String?
    let kind: SettingKind
    let effect: SettingEffect
}

/// Every preference Kriya keeps outside the core's database, listed once. Backup, reset, per-area export, the reload after a
/// restore and diagnostics all read this list, so a new preference is added here and nowhere else. A test fails if a
/// preference used by the app is missing.
enum SettingsRegistry {
    private static func s(_ key: String, _ area: String?, _ effect: SettingEffect = .restart) -> SettingEntry { SettingEntry(key: key, area: area, kind: .setting, effect: effect) }
    private static func h(_ key: String, _ area: String?) -> SettingEntry { SettingEntry(key: key, area: area, kind: .history, effect: .restart) }
    private static func a(_ key: String, _ area: String?) -> SettingEntry { SettingEntry(key: key, area: area, kind: .approval, effect: .restart) }
    private static func m(_ key: String, _ area: String? = nil) -> SettingEntry { SettingEntry(key: key, area: area, kind: .machine, effect: .restart) }

    static let entries: [SettingEntry] = [
        // Launcher
        s("launcherPrefs.v1", "launcher"), s("launcherQuicklinks.v1", "launcher"), s("launcherScripts.v1", "launcher"), s("launcherScriptFolders.v1", "launcher"),
        s("launcherAPICommands.v1", "launcher"), a("launcherAskBeforeRunning", "launcher"), s("launcherSearchHistoryOn", "launcher"),
        a("launcherApprovals.v1", "launcher"), h("launcherSearchHistory.v1", "launcher"), h("recentApps.v1", "launcher"), m("launcherRates.v1", "launcher"),
        // Appearance and placement
        s("ui.textSize", "appearance", .live), s("launcherTheme", "appearance", .live), s("launcherAccent", "appearance", .live),
        s("launcherPlacement", "appearance", .live), s("launcherTopCenter", "appearance"), s("switcherStyle", "appearance", .live),
        // Sound
        s("soundRules.v1", "sound"), s("soundModes.v1", "sound"), s("soundDeviceVolumes.v1", "sound"), s("soundRemembersVolumes", "sound"), s("soundNotifiesDevices", "sound"),
        s("placeRules.v1", "sound"), s("placeRules.enabled", "sound"), s("appAudio.profiles.v1", "sound"), s("appAudio.settings.v1", "sound"),
        s("soundMenuBar.enabled", "sound", .live), s("volumeKeys.enabled", "sound"),
        h("soundDeviceHistory.v1", "sound"), m("soundSnapshot.v1", "sound"), m("soundSnapshotTime.v1", "sound"),
        // Speech
        s("speech.pitch", "speech"), s("speech.rate", "speech"), s("speech.voice", "speech"), s("dictation.language", "speech"), a("dictation.allowServer", "speech"),
        // Finder and dialogs. Folder rules and sets act on files by themselves, so they are not restored from a file.
        a("folderRules.v1", "finder"), a("folderSets.v1", "finder"), s("finder.destinations.v1", "finder"), h("finder.fileOperations.v1", "finder"),
        h("finderWindows.history.v1", "finder"), s("finderWindows.enabled", "finder"), s("dialogAppFolders.v1", "finder"), s("dialogAutoJump", "finder"),
        m("folderRules.paused", "finder"), m("finder.lastTidy", "finder"), m("finderRequestToken"),
        // Capture
        s("captureSettings.v1", "capture"), s("captureProfiles.v1", "capture", .live), s("capture.ocrLanguages", "capture", .live), m("capture.previousArea.v1", "capture"),
        // Clipboard
        s("clipboardRules.v1", "clipboard"), s("clipboardMergeCopies", "clipboard", .live),
        // MIDI triggers start workflows, so they are not restored from a file
        a("midiTriggers.v1", "midi"), a("midiTriggers.enabled", "midi"),
        // Focus
        s("focusSession.config.v1", "focus"), m("focusSession.state.v1", "focus"), h("focusSession.history.v1", "focus"),
        // Apple Intelligence and AI providers: they decide what leaves this Mac
        a("intelligenceSettings.v1", "intelligence"),
        a("clipSync.enabled", "clipsync"), h("clipSync.history", "clipsync"), m("clipSync.state.v1", "clipsync"), m("clipSync.macID", "clipsync"),
        a("sharedClipboard.enabled", "clipsync"), a("sharedClipboard.autoReceive", "clipsync"), m("sharedClipboard.device", "clipsync"),
        a("ai.settings.v1", "ai"), h("ai.activity.v1", "ai"), h("ai.ledger.v1", "ai"), a("mcpClients.v1", "ai"), a("mcpServer.enabled", "ai"), a("mcpServer.port", "ai"),
        a("ai.search.enabled", "ai"), a("ai.search.embeddingConsent.v1", "ai"), a("pageAI.allowedHosts", "ai"), a("pageAI.blockedHosts", "ai"),
        m("automation.pausedAll", "midi"), m("safariExtension.enabled"),
        a("extensions.enabled.v1", nil), a("extensions.trusted.v1", nil), a("localOnlyMode", nil),
        // Activity and updates
        h("auditLog.v1", "activity"), h("appUpgradeHistory.v1", "activity"), h("appUpdateHistory.v1", "activity"), h("appUpdateRetry.v1", "activity"),
        h("featureActivity.v1", nil), h("evidenceLedger.v1", nil), s("ignoredAppUpdates", nil), a("installKriyaUpdatesAutomatically", nil),
        a("upgradeHomebrewAppsAutomatically", nil), m("permissionNotices"), s("featureTimings.enabled", nil),
        // Timelines
        h("deviceTimeline.v1", "timelines"), h("displayHistory.v1", "timelines"),
        // Windows, displays and workspaces
        s("windowLocks.v1", "windowextras", .reload(.windowLocks)), s("windows.layoutOnSpaceChange", "windowextras", .live),
        s("windows.retryUnresolved", "windowextras", .live), s("displaySetupBindings.v1", "windowextras", .live), h("workspaceLaunchLog.v1", "windowextras"),
        s("monitorPresets.v1", "displays"), m("displayProfileIndex", "displays"),
        // Usage
        h("usage.selectionActions.v1", "usage"), h("usage.savedActions.v1", "usage"),
        // Notes
        s("notes.pinned.v1", "notes", .live), m("notes.folder", "notes"), m("notes.encryptionKey"),
        // Selection bar
        s("selection.startInKeyboard", "selection", .live),
        // Shelf and power
        s("shelf.reminderLeadHours", "shelfreminders", .live), h("shelf.notifiedIDs", "shelfreminders"), s("powerSaving.mode", "powersaving"),
        s("keepAwakeApps", "keepawake"), s("keepAwakeBattery", "keepawake"), s("keepAwakeDisplay", "keepawake"),
        // Menu bar window and menu-bar items
        s("popover.tiles", "menubar", .reload(.popover)), s("popover.layouts", "menubar", .reload(.popover)), s("popover.sectionOrder", "menubar", .reload(.popover)),
        s("popover.hiddenSections", "menubar", .reload(.popover)), s("popover.extras", "menubar", .reload(.popover)), s("popover.columns", "menubar", .reload(.popover)),
        s("popover.compact", "menubar", .reload(.popover)), s("popover.showLabels", "menubar", .reload(.popover)), s("popover.showSearch", "menubar", .reload(.popover)),
        s("popover.featuresAsGrid", "menubar", .reload(.popover)), s("popover.theme", "menubar", .reload(.popover)), s("popover.tint", "menubar", .reload(.popover)),
        s("popover.maxHeight", "menubar", .reload(.popover)), s("menuBarHider.enabled", "menubar"), s("menuBarHider.autoHideSeconds", "menubar"),
        // System monitor
        s("systemMonitor.metrics", "sysmonitor"), s("systemMonitor.menuBar", "sysmonitor"), s("systemMonitor.lowBatteryAlerts", "sysmonitor"), s("systemMonitor.resourceAlerts.v1", "sysmonitor"),
        // World clock
        s("worldClock.places.v1", "worldclock"), s("worldClock.menuBar", "worldclock"), s("worldClock.24h", "worldclock"),
        s("worldClock.hoursStart", "worldclock", .live), s("worldClock.hoursEnd", "worldclock", .live),
        // Backup itself
        m("iCloudBackupEnabled"), m("iCloudSyncDismissedAt"),
    ]

    private static let index: [String: SettingEntry] = Dictionary(entries.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })

    static func entry(_ key: String) -> SettingEntry? { index[key] }

    /// The keys a reset area clears, in the order listed here.
    static func keys(inArea area: String) -> [String] { entries.filter { $0.area == area }.map(\.key) }

    /// The areas that have at least one key, in the order they first appear.
    static var areaIDs: [String] {
        var seen: [String] = []
        for entry in entries { if let area = entry.area, !seen.contains(area) { seen.append(area) } }
        return seen
    }

    /// The keys a backup carries: settings only.
    static var backupKeys: [String] { entries.filter { $0.kind == .setting }.map(\.key) }

    /// A one-paragraph account of what is saved and how, for diagnostics.
    static func coverageSummary() -> String {
        func count(_ kind: SettingKind) -> Int { entries.filter { $0.kind == kind }.count }
        let restart = entries.filter { $0.kind == .setting && $0.effect == .restart }.count
        return "Saved preferences: \(count(.setting)) settings (backed up; \(restart) need a restart after a restore), \(count(.history)) logs, \(count(.approval)) approvals and consents (never restored from a file), \(count(.machine)) tied to this Mac."
    }
}

/// What a restore or a reset did to the running app.
struct SettingsApplyOutcome: Equatable {
    /// The titles of what is in force now.
    var applied: [String] = []
    /// Keys whose new value is read only at launch.
    var needsRestart: [String] = []

    var isEmpty: Bool { applied.isEmpty && needsRestart.isEmpty }
}

/// Makes changed preferences take effect in the running app. A store registers a reload step for its group; a key with no
/// registered step is reported as needing a restart, so nothing is silently stale.
enum SettingsReloader {
    private static let lock = NSLock()
    private static var handlers: [ReloadGroup: () -> Void] = [:]

    static func register(_ group: ReloadGroup, _ handler: @escaping () -> Void) {
        lock.lock(); handlers[group] = handler; lock.unlock()
    }

    static func unregisterAll() { lock.lock(); handlers = [:]; lock.unlock() }

    /// Runs the reload step for every group touched by `keys` (once each) and reports the rest. Call on the main thread.
    @discardableResult
    static func apply(keys: [String]) -> SettingsApplyOutcome {
        var outcome = SettingsApplyOutcome()
        var groups: [ReloadGroup] = []
        for key in keys {
            guard let entry = SettingsRegistry.entry(key) else { outcome.needsRestart.append(key); continue }
            switch entry.effect {
            case .live: outcome.applied.append(key)
            case .restart: outcome.needsRestart.append(key)
            case .reload(let group):
                lock.lock(); let handler = handlers[group]; lock.unlock()
                if let handler {
                    if !groups.contains(group) { groups.append(group); handler() }
                    outcome.applied.append(key)
                } else {
                    outcome.needsRestart.append(key)
                }
            }
        }
        return outcome
    }
}
