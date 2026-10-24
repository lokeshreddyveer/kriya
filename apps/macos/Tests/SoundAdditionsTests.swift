import XCTest
@testable import Kriya

final class SoundAdditionsTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    func testATimedMuteFadesOutHoldsAndFadesBackIn() {
        let change = TimedChange(level: 0, duration: 10, fadeOut: 2, fadeIn: 4, start: t0)
        XCTAssertEqual(change.factor(at: t0.addingTimeInterval(-1)), 1)
        XCTAssertEqual(change.factor(at: t0.addingTimeInterval(1)), 0.5, accuracy: 0.001, "halfway down the fade out")
        XCTAssertEqual(change.factor(at: t0.addingTimeInterval(5)), 0)
        XCTAssertEqual(change.factor(at: t0.addingTimeInterval(12)), 0.5, accuracy: 0.001, "halfway back up")
        XCTAssertEqual(change.factor(at: t0.addingTimeInterval(14)), 1)
        XCTAssertFalse(change.isFinished(at: t0.addingTimeInterval(13)))
        XCTAssertTrue(change.isFinished(at: t0.addingTimeInterval(14)))
        XCTAssertEqual(change.remaining(at: t0.addingTimeInterval(4)), 6, accuracy: 0.001)
    }

    func testATurnDownGoesToItsLevelAndNoFadeMeansNoRamp() {
        let change = TimedChange(level: 0.3, duration: 5, start: t0)
        XCTAssertEqual(change.factor(at: t0.addingTimeInterval(0.01)), 0.3, accuracy: 0.001)
        XCTAssertEqual(change.factor(at: t0.addingTimeInterval(5)), 1)
    }

    func testFavoritesComeFirstThenPlayingThenSettingsThenRecent() {
        let now = t0
        let entries = SoundAppList.entries(
            playing: ["b", "c"], favorites: ["z", "b"], withSettings: ["d"], lastPlayed: ["e": now.addingTimeInterval(-60), "old": now.addingTimeInterval(-3_600)],
            excluded: [], now: now, recentWindow: 600, name: { $0 })
        XCTAssertEqual(entries.map(\.id), ["z", "b", "c", "d", "e"], "favorites in their own order, an hour-old app expired")
        XCTAssertEqual(entries.first { $0.id == "z" }?.isPlaying, false, "a favorite stays listed while quiet")
        XCTAssertTrue(entries.first { $0.id == "e" }?.isRecent ?? false)
    }

    func testExcludedAppsNeverAppearAndFavoritesCanBeReordered() {
        let entries = SoundAppList.entries(playing: ["a", "b"], favorites: ["a"], withSettings: [], lastPlayed: [:], excluded: ["a"], now: t0, recentWindow: 600, name: { $0 })
        XCTAssertEqual(entries.map(\.id), ["b"])
        XCTAssertEqual(SoundAppList.move("b", by: -1, in: ["a", "b", "c"]), ["b", "a", "c"])
        XCTAssertEqual(SoundAppList.move("a", by: -1, in: ["a", "b"]), ["a", "b"], "nothing before the first")
        XCTAssertEqual(SoundAppList.move("x", by: 1, in: ["a", "b"]), ["a", "b"])
    }

    func testQuickConfigsRoundTripThroughAFileAndNeverReplaceExistingOnes() throws {
        var apps: [String: AppAudioSettings] = [:]
        var loud = AppAudioSettings(); loud.volume = 9; loud.preamp = 40; loud.balance = -3
        apps["com.spotify.client"] = loud
        let config = QuickConfig(name: "Desk", outputUID: "out", inputUID: "in", deviceVolumes: ["out": 7, "in": -1], apps: apps, favorites: ["com.spotify.client"])
        let data = try XCTUnwrap(QuickConfig.exported([config]))
        let back = try XCTUnwrap(QuickConfig.imported(data, existingNames: ["Desk"]))
        XCTAssertEqual(back.count, 1)
        XCTAssertNotEqual(back[0].id, config.id, "a new id, so nothing is replaced")
        XCTAssertEqual(back[0].name, "Desk 2")
        XCTAssertEqual(back[0].apps["com.spotify.client"]?.volume, AppAudioSettings.maxVolume, "brought into range")
        XCTAssertEqual(back[0].apps["com.spotify.client"]?.preamp, SoundPreamp.limit)
        XCTAssertEqual(back[0].apps["com.spotify.client"]?.balance, -1)
        XCTAssertEqual(back[0].deviceVolumes["out"], 1)
        XCTAssertEqual(back[0].deviceVolumes["in"], 0)
        XCTAssertNil(QuickConfig.imported(Data("{\"format\":\"other\",\"version\":1,\"configs\":[]}".utf8), existingNames: []))
        XCTAssertNil(QuickConfig.imported(Data("nope".utf8), existingNames: []))
    }

    func testDuplicatingAndNamingKeepNamesUnique() {
        let a = QuickConfig(name: "Desk")
        XCTAssertEqual(a.duplicated(among: ["Desk"]).name, "Desk copy")
        XCTAssertEqual(a.duplicated(among: ["Desk", "Desk copy"]).name, "Desk copy 2")
        XCTAssertEqual(QuickConfig.uniqueName("  ", among: []), "Quick Config")
    }

    func testDeviceNicknamesAndIconsFallBackToTheDevicesOwn() {
        var labels: [String: DeviceLabel] = [:]
        XCTAssertEqual(DeviceNaming.name("Display Audio", uid: "u", labels: labels), "Display Audio")
        labels = DeviceNaming.setting(DeviceLabel(nickname: "  Desk speakers ", symbol: "hifispeaker"), for: "u", in: labels)
        XCTAssertEqual(DeviceNaming.name("Display Audio", uid: "u", labels: labels), "Desk speakers")
        XCTAssertEqual(DeviceNaming.symbol(uid: "u", fallback: "speaker.wave.2", labels: labels), "hifispeaker")
        labels = DeviceNaming.setting(DeviceLabel(nickname: "", symbol: nil), for: "u", in: labels)
        XCTAssertNil(labels["u"], "an empty label is removed")
        XCTAssertEqual(DeviceNaming.name("x", uid: "u", labels: [:]), "x")
        let long = DeviceNaming.setting(DeviceLabel(nickname: String(repeating: "a", count: 90)), for: "u", in: [:])
        XCTAssertEqual(long["u"]?.nickname?.count, 40)
    }

    func testBalanceLeavesTheLouderSideAloneAndPreampIsDecibels() {
        XCTAssertEqual(SoundBalance.gains(0).left, 1); XCTAssertEqual(SoundBalance.gains(0).right, 1)
        XCTAssertEqual(SoundBalance.gains(0.5).left, 0.5); XCTAssertEqual(SoundBalance.gains(0.5).right, 1)
        XCTAssertEqual(SoundBalance.gains(-1).right, 0); XCTAssertEqual(SoundBalance.gains(-1).left, 1)
        XCTAssertEqual(SoundBalance.gains(5).left, 0, "clamped")
        XCTAssertEqual(SoundBalance.preampGain(db: 6), 1.995, accuracy: 0.01)
        XCTAssertEqual(SoundBalance.preampGain(db: 99), SoundBalance.preampGain(db: 12), "clamped")
    }

    func testTheProcessorAppliesPreampBalanceAndTemporaryGain() {
        let p = AudioProcessor()
        p.preampGain = 0.5
        p.balance = 1                      // all right: left silent
        var input = [Float](repeating: 0.4, count: 8)        // 4 stereo frames
        var output = [Float](repeating: 0, count: 8)
        // The first buffer ramps the gain from 1; run one to settle, then check the second.
        p.process(input: &input, output: &output, frames: 4, channels: 2)
        p.process(input: &input, output: &output, frames: 4, channels: 2)
        XCTAssertEqual(output[0], 0, accuracy: 0.0001, "left is silent at full right balance")
        XCTAssertEqual(output[1], 0.2, accuracy: 0.01, "right gets the preamp's half")
        p.balance = 0; p.preampGain = 1; p.tempGain = 0
        p.process(input: &input, output: &output, frames: 4, channels: 2)
        p.process(input: &input, output: &output, frames: 4, channels: 2)
        XCTAssertEqual(output[2], 0, accuracy: 0.0001, "a timed mute silences it")
    }

    func testSettingsSavedBeforeThePreampExistedStillLoad() throws {
        let old = Data(#"{"volume":2,"muted":false,"outputs":[],"eq":[1,0,0,0,0,0,0,0,0,0]}"#.utf8)
        let s = try JSONDecoder().decode(AppAudioSettings.self, from: old)
        XCTAssertEqual(s.volume, 2)
        XCTAssertEqual(s.preamp, 0)
        XCTAssertEqual(s.balance, 0)
        XCTAssertFalse(s.effectsBypassed)
        var fx = AppAudioSettings(); fx.balance = 0.5
        XCTAssertFalse(fx.isDefault, "a balance is a change")
        fx.balance = 0; fx.effectsBypassed = true
        XCTAssertTrue(fx.isDefault, "bypassing nothing leaves the app alone")
    }

    func testAlertsKeepTheNewestFirstAndDropRepeats() {
        var list: [SoundAlert] = []
        list = SoundAlert.adding(SoundAlert(at: t0, app: "A", message: "x"), to: list)
        list = SoundAlert.adding(SoundAlert(at: t0, app: "A", message: "x"), to: list)
        XCTAssertEqual(list.count, 1)
        list = SoundAlert.adding(SoundAlert(at: t0, app: "B", message: "y"), to: list)
        XCTAssertEqual(list.map(\.app), ["B", "A"])
        for i in 0..<80 { list = SoundAlert.adding(SoundAlert(at: t0, app: "C", message: "\(i)"), to: list) }
        XCTAssertEqual(list.count, SoundAlert.keep)
    }
}
