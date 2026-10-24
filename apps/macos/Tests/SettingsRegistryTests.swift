import XCTest
@testable import Kriya

final class SettingsRegistryTests: XCTestCase {
    /// What each reset area cleared before the registry existed. A reset must never clear less than it used to.
    private let before: [String: [String]] = [
        "launcher": ["launcherPrefs.v1", "launcherQuicklinks.v1", "launcherScripts.v1", "launcherScriptFolders.v1", "launcherAPICommands.v1", "launcherApprovals.v1", "launcherSearchHistory.v1", "launcherRates.v1", "recentApps.v1", "launcherAskBeforeRunning"],
        "sound": ["soundRules.v1", "soundModes.v1", "soundDeviceVolumes.v1", "soundDeviceHistory.v1", "soundSnapshot.v1", "soundSnapshotTime.v1", "soundRemembersVolumes", "soundNotifiesDevices", "placeRules.v1", "placeRules.enabled", "appAudio.profiles.v1", "appAudio.settings.v1"],
        "finder": ["folderRules.v1", "folderSets.v1", "finder.destinations.v1", "finder.fileOperations.v1", "finderWindows.history.v1", "finderWindows.enabled", "dialogAppFolders.v1"],
        "capture": ["captureSettings.v1", "captureProfiles.v1", "capture.ocrLanguages"],
        "clipboard": ["clipboardRules.v1"],
        "midi": ["midiTriggers.v1", "midiTriggers.enabled"],
        "focus": ["focusSession.config.v1", "focusSession.state.v1"],
        "intelligence": ["intelligenceSettings.v1"],
        "clipsync": ["clipSync.enabled", "clipSync.history", "clipSync.state.v1"],
        "ai": ["ai.settings.v1", "ai.activity.v1", "ai.ledger.v1", "mcpClients.v1", "mcpServer.enabled", "mcpServer.port", "ai.search.enabled", "ai.search.embeddingConsent.v1"],
        "activity": ["auditLog.v1", "appUpgradeHistory.v1", "appUpdateHistory.v1", "appUpdateRetry.v1"],
    ]

    func testEveryKeyAnOlderResetClearedIsStillCleared() {
        for (id, keys) in before {
            let area = FeatureReset.areas.first { $0.id == id }
            XCTAssertNotNil(area, id)
            for key in keys { XCTAssertTrue(area?.keys.contains(key) ?? false, "\(id) no longer clears \(key)") }
        }
    }

    func testNoKeyIsListedTwiceAndEveryAreaExistsAndHasKeys() {
        let keys = SettingsRegistry.entries.map(\.key)
        XCTAssertEqual(keys.count, Set(keys).count, "a key is listed twice")
        let ids = Set(FeatureReset.areas.map(\.id))
        XCTAssertEqual(ids.count, FeatureReset.areas.count, "an area is listed twice")
        for id in SettingsRegistry.areaIDs { XCTAssertTrue(ids.contains(id), "no reset area for \(id)") }
        for area in FeatureReset.areas { XCTAssertFalse(area.keys.isEmpty, "\(area.id) clears nothing") }
    }

    func testABackupCarriesSettingsAndNeverApprovalsHistoryOrMachineState() {
        let backup = Set(SettingsRegistry.backupKeys)
        for entry in SettingsRegistry.entries { XCTAssertEqual(backup.contains(entry.key), entry.kind == .setting, entry.key) }
        for key in ["launcherApprovals.v1", "launcherAskBeforeRunning", "localOnlyMode", "folderRules.v1", "ai.settings.v1", "mcpServer.enabled",
                    "extensions.trusted.v1", "clipSync.enabled", "midiTriggers.v1", "deviceTimeline.v1", "auditLog.v1", "notes.encryptionKey", "clipSync.macID"] {
            XCTAssertFalse(backup.contains(key), "\(key) must not travel in a backup")
        }
        for key in ["ui.textSize", "launcherTheme", "windowLocks.v1", "worldClock.places.v1", "keepAwakeApps", "popover.tint", "soundRules.v1", "captureProfiles.v1"] {
            XCTAssertTrue(backup.contains(key), "\(key) should travel in a backup")
        }
    }

    func testAreaExportAndBackupShareTheSameKeys() {
        // The portable pack and the per-area export both read the registry, so a key cannot be in one and missing from the other.
        let inAreas = Set(FeatureReset.areas.flatMap(\.keys))
        for key in SettingsRegistry.backupKeys where SettingsRegistry.entry(key)?.area != nil { XCTAssertTrue(inAreas.contains(key), key) }
    }

    func testRestoreTouchesOnlyWhatIsRegisteredAndSaysWhatNeedsARestart() {
        SettingsReloader.unregisterAll()
        defer { SettingsReloader.unregisterAll() }
        var locks = 0, popover = 0
        SettingsReloader.register(.windowLocks) { locks += 1 }
        SettingsReloader.register(.popover) { popover += 1 }
        let outcome = SettingsReloader.apply(keys: ["windowLocks.v1", "popover.tint", "popover.theme", "ui.textSize", "soundRules.v1", "not.a.registered.key"])
        XCTAssertEqual(locks, 1)
        XCTAssertEqual(popover, 1, "one reload for several keys of a group")
        XCTAssertEqual(Set(outcome.applied), ["windowLocks.v1", "popover.tint", "popover.theme", "ui.textSize"])
        XCTAssertEqual(Set(outcome.needsRestart), ["soundRules.v1", "not.a.registered.key"])
    }

    func testAGroupWithNoReloadStepIsReportedAsWaitingForARestart() {
        SettingsReloader.unregisterAll()
        let outcome = SettingsReloader.apply(keys: ["windowLocks.v1"])
        XCTAssertEqual(outcome.needsRestart, ["windowLocks.v1"])
        XCTAssertTrue(outcome.applied.isEmpty)
    }

    func testTheRestoreMessageSaysWhatIsInForce() {
        XCTAssertEqual(BackupPane.restoreMessage(nil), "Settings restored.")
        XCTAssertEqual(BackupPane.restoreMessage(SettingsApplyOutcome(applied: ["a"], needsRestart: [])), "Settings restored. They are in force now.")
        XCTAssertTrue(BackupPane.restoreMessage(SettingsApplyOutcome(applied: ["a", "b"], needsRestart: ["c"])).contains("2 are in force now; 1 take effect after a restart"))
    }

    func testEveryCommandKriyaCanRunIsOfferedForShortcutsAndMouseButtons() {
        let keyboard = KeyboardCommands.all.map(\.command)
        let mouse = WindowCommands.all.map(\.command)
        XCTAssertEqual(keyboard.count, Set(keyboard).count, "a command is listed twice in the shortcut picker")
        for command in ["capture.ruler", "capture.record", "capture.region", "notes.open", "audio.mute", "audio.next_output", "power.keep_awake", "shelf.toggle",
                        "dictation.toggle", "color.pick", "display.next_profile", "text.speak", "pointer.spotlight", "clipboard.stack", "automation.pause_toggle"] {
            XCTAssertTrue(keyboard.contains(command), "\(command) cannot be bound to a shortcut")
            XCTAssertTrue(mouse.contains(command), "\(command) cannot be bound to a mouse button")
        }
    }

    func testEveryPermissionIsNeededBySomeListedFeature() {
        for permission in Permission.allCases {
            XCTAssertFalse(FeatureRegistry.features(needing: permission).isEmpty, "\(permission.title) shows as needed by nothing")
        }
        XCTAssertTrue(FeatureRegistry.features(needing: .screenRecording).contains("Screen Capture and Recording"))
    }

    func testTheCoverageSummaryCountsEveryKind() {
        let text = SettingsRegistry.coverageSummary()
        XCTAssertTrue(text.contains("settings") && text.contains("logs") && text.contains("approvals") && text.contains("tied to this Mac"), text)
    }

    /// Every preference the source code uses must be classified, so a new one cannot be forgotten by backup and reset.
    func testEveryPreferenceKeyInTheSourceIsInTheRegistry() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")
        guard let walker = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil) else { return XCTFail("no Sources folder at \(sources.path)") }
        let patterns = [#"forKey:\s*"([A-Za-z0-9_.]+)""#, #"@AppStorage\("([A-Za-z0-9_.]+)""#, #"(?:let|var)\s+\w*[kK]ey\w*\s*=\s*"([A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z0-9_]+)+|[A-Za-z0-9]+\.v[0-9])""#]
        let regexes = try patterns.map { try NSRegularExpression(pattern: $0) }
        // Not preferences: Info.plist and system keys, and Core Image filter parameters.
        let notPreferences: Set<String> = ["AppleSymbolicHotKeys", "HIDMouseAcceleration", "HIDTrackpadAcceleration", "SUPublicEDKey", "KriyaGitCommit", "inputMessage", "inputCorrectionLevel"]
        var missing: Set<String> = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for regex in regexes {
                for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                    guard let r = Range(match.range(at: 1), in: text) else { continue }
                    let key = String(text[r])
                    if notPreferences.contains(key) || SettingsRegistry.entry(key) != nil || key.hasPrefix("CF") || key.hasPrefix("NS") { continue }
                    missing.insert(key)
                }
            }
        }
        XCTAssertEqual(missing.sorted(), [], "preferences used by the app but not in SettingsRegistry")
    }
}
