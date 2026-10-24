import XCTest
@testable import Kriya

/// A restored backup must change the running sound engines, not wait for a restart.
final class RestoreReloadTests: XCTestCase {
    private func suite() -> UserDefaults {
        let name = "kriya.test.restore.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    func testTheAppAudioEngineReadsRestoredValues() {
        let defaults = suite()
        defaults.set(["old.app"], forKey: "appAudio.favorites.v1")
        let engine = AppAudioEngine(defaults: defaults)
        XCTAssertEqual(engine.favorites, ["old.app"])
        defaults.set(["new.app"], forKey: "appAudio.favorites.v1")
        defaults.set(["muted.app"], forKey: "appAudio.excluded.v1")
        engine.reload()
        XCTAssertEqual(engine.favorites, ["new.app"])
        XCTAssertEqual(engine.excluded, ["muted.app"])
        engine.stopAll()
    }

    func testTheRuleRunnerReadsRestoredFlags() {
        let defaults = suite()
        let runner = SoundRuleRunner(defaults: defaults)
        XCTAssertFalse(runner.remembersVolumes)
        defaults.set(true, forKey: "soundRemembersVolumes")
        defaults.set(true, forKey: "soundNotifiesDevices")
        runner.reload()
        XCTAssertTrue(runner.remembersVolumes)
        XCTAssertTrue(runner.notifiesDevices)
    }

    func testSoundKeysAreReportedAsAppliedWhenTheReloadIsRegistered() {
        var ran = 0
        SettingsReloader.register(.sound) { ran += 1 }
        defer { SettingsReloader.unregisterAll() }
        let outcome = SettingsReloader.apply(keys: ["appAudio.settings.v1", "soundRules.v1", "soundDevices.priority.v1"])
        XCTAssertEqual(ran, 1, "one reload for the whole group")
        XCTAssertEqual(outcome.applied.count, 3)
        XCTAssertTrue(outcome.needsRestart.isEmpty)
    }

    func testFinderMenusCanBeFoundInSettingsSearch() {
        XCTAssertTrue(SettingsIndex.entries.contains { $0.pane == "finder" && $0.tab == "Menus" })
    }
}
