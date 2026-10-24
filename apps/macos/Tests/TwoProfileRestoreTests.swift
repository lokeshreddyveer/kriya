import XCTest
@testable import Kriya

/// A backup made on one profile, restored into a second one that starts empty: the nearest a test gets to moving to a new Mac.
final class TwoProfileRestoreTests: XCTestCase {
    private struct Profile {
        let world: TestWorld
        let defaults: UserDefaults
        let passphrases: MemoryPassphraseStore
        let backup: BackupManager

        init() throws {
            world = try TestWorld()
            defaults = UserDefaults(suiteName: "kriya-tests-\(UUID().uuidString)")!
            passphrases = MemoryPassphraseStore()
            let folder = world.folder.appendingPathComponent("Backups", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            backup = BackupManager(core: world.core, folder: folder, passphrases: passphrases, defaults: defaults)
        }
    }

    private var profiles: [Profile] = []
    private func profile() throws -> Profile { let p = try Profile(); profiles.append(p); return p }

    override func tearDown() {
        SettingsReloader.unregisterAll()
        for p in profiles { p.world.cleanUp() }
        profiles = []
    }

    /// Settings on the first profile: core data, settings in preferences, and things that must never travel.
    private func fill(_ a: Profile) throws {
        try a.world.core.saveAction(action: NamedAction(id: "mail", name: "Open Mail", action: .openApplication(target: "com.apple.mail")))
        a.defaults.set(Data([1, 2, 3]), forKey: "windowLocks.v1")
        a.defaults.set(2, forKey: "ui.textSize")
        a.defaults.set("dark", forKey: "popover.theme")
        a.defaults.set(["Safari", "Xcode"], forKey: "keepAwakeApps")
        a.defaults.set(Data("[\"Tokyo\"]".utf8), forKey: "worldClock.places.v1")
        a.defaults.set(true, forKey: "selection.startInKeyboard")
        // Not settings: they must stay behind.
        a.defaults.set(Data([9]), forKey: "deviceTimeline.v1")
        a.defaults.set(Data([9]), forKey: "auditLog.v1")
        a.defaults.set(false, forKey: "launcherAskBeforeRunning")
        a.defaults.set(true, forKey: "localOnlyMode")
        a.defaults.set(Data([7]), forKey: "folderRules.v1")
        a.defaults.set("secret", forKey: "notes.encryptionKey")
    }

    func testASecondEmptyProfileGetsTheSettingsAndNothingElse() throws {
        let a = try profile(), b = try profile()
        try fill(a)
        let file = a.world.folder.appendingPathComponent("moved.kriyabackup")
        try a.backup.export(to: file)

        var locks = 0, popover = 0
        SettingsReloader.register(.windowLocks) { locks += 1 }
        SettingsReloader.register(.popover) { popover += 1 }
        XCTAssertNoThrow(try b.backup.restore(from: file))

        XCTAssertEqual(try b.world.core.actions().map(\.id), ["mail"], "the saved action came across")
        XCTAssertEqual(b.defaults.data(forKey: "windowLocks.v1"), Data([1, 2, 3]))
        XCTAssertEqual(b.defaults.integer(forKey: "ui.textSize"), 2)
        XCTAssertEqual(b.defaults.string(forKey: "popover.theme"), "dark")
        XCTAssertEqual(b.defaults.stringArray(forKey: "keepAwakeApps"), ["Safari", "Xcode"])
        XCTAssertEqual(b.defaults.data(forKey: "worldClock.places.v1"), Data("[\"Tokyo\"]".utf8))
        XCTAssertTrue(b.defaults.bool(forKey: "selection.startInKeyboard"))

        for key in ["deviceTimeline.v1", "auditLog.v1", "launcherAskBeforeRunning", "localOnlyMode", "folderRules.v1", "notes.encryptionKey"] {
            XCTAssertNil(b.defaults.object(forKey: key), "\(key) must not travel")
        }

        let outcome = try XCTUnwrap(b.backup.lastRestore)
        XCTAssertEqual(locks, 1, "window locks were reloaded")
        XCTAssertEqual(popover, 1, "the menu-bar window was reloaded")
        XCTAssertTrue(outcome.applied.contains("windowLocks.v1") && outcome.applied.contains("popover.theme") && outcome.applied.contains("ui.textSize"))
        XCTAssertTrue(outcome.needsRestart.contains("keepAwakeApps"), "read only at launch, so the person is told")
        XCTAssertTrue(BackupPane.restoreMessage(outcome).contains("take effect after a restart"))
    }

    func testAProtectedBackupMovesWithTheSamePassphrase() throws {
        let a = try profile(), b = try profile()
        try fill(a)
        try a.backup.protect(with: "a long shared passphrase")
        let file = a.world.folder.appendingPathComponent("sealed.kriyabackup")
        try a.backup.export(to: file)
        XCTAssertTrue(BackupCrypto.isEncrypted(try Data(contentsOf: file)))

        XCTAssertThrowsError(try b.backup.restore(from: file), "the second profile does not have the passphrase")
        XCTAssertNil(b.defaults.object(forKey: "ui.textSize"), "nothing was applied by the failed attempt")
        XCTAssertNoThrow(try b.backup.restore(from: file, passphrase: "a long shared passphrase"))
        XCTAssertEqual(b.defaults.integer(forKey: "ui.textSize"), 2)
        XCTAssertEqual(try b.world.core.actions().count, 1)
    }

    func testAnOldBackupWithNoPreferencesLeavesTheSecondProfilesOwnAlone() throws {
        let a = try profile(), b = try profile()
        try fill(a)
        let file = a.world.folder.appendingPathComponent("old.kriyabackup")
        try a.backup.export(to: file)
        // Take the preferences slot out, as in a backup made before it existed.
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var extras = try XCTUnwrap(root["extras"] as? [String: Any])
        extras["app_prefs"] = nil
        root["extras"] = extras
        try JSONSerialization.data(withJSONObject: root).write(to: file)

        b.defaults.set(5, forKey: "ui.textSize")
        // Even a value this Mac saved into the core earlier must not be replayed.
        try b.world.core.saveAppPrefsJson(json: #"{"ui.textSize":"stale"}"#)
        XCTAssertNoThrow(try b.backup.restore(from: file))
        XCTAssertEqual(b.defaults.integer(forKey: "ui.textSize"), 5)
        XCTAssertEqual(try b.world.core.actions().count, 1, "the rest of the backup still restored")
        XCTAssertEqual(b.backup.lastRestore?.isEmpty, true)
    }

    func testARestoreOverAnExistingProfileReplacesItsSettingsAndKeepsAnUndoCopy() throws {
        let a = try profile(), b = try profile()
        try fill(a)
        b.defaults.set(5, forKey: "ui.textSize")
        b.defaults.set("light", forKey: "popover.theme")
        let file = a.world.folder.appendingPathComponent("over.kriyabackup")
        try a.backup.export(to: file)
        try b.backup.restore(from: file)
        XCTAssertEqual(b.defaults.integer(forKey: "ui.textSize"), 2)
        XCTAssertEqual(b.defaults.string(forKey: "popover.theme"), "dark")
        XCTAssertEqual(b.backup.automaticBackups.count, 1, "the settings from before the restore were saved first")
        // And the undo copy brings the old values back.
        let undo = try XCTUnwrap(b.backup.automaticBackups.first)
        try b.backup.restore(from: undo.url)
        XCTAssertEqual(b.defaults.integer(forKey: "ui.textSize"), 5)
        XCTAssertEqual(b.defaults.string(forKey: "popover.theme"), "light")
    }
}
