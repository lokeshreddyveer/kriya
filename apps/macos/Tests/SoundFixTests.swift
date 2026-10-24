import XCTest
@testable import Kriya

/// The fixes from the Sound review: one tap per sound, headphone correction that gives back what was there, a device that comes back
/// under another name, a Quick Config that carries the whole mixer setup, and sound shortcuts that clash like any other.
final class SoundFixTests: XCTestCase {
    // MARK: One tap per sound

    func testAnAppWithItsOwnTapIsLeftOutOfTheAllSoundTap() {
        XCTAssertEqual(SoundMaster.excludedFromAllSound(own: [7], handledByApps: [[30, 31], [20], [30]]), [7, 20, 30, 31], "each once, in a fixed order")
        XCTAssertEqual(SoundMaster.excludedFromAllSound(own: [], handledByApps: []), [])
        XCTAssertEqual(SoundMaster.excludedFromAllSound(own: [7], handledByApps: [[]]), [7])
        XCTAssertEqual(SoundMaster.excludedFromAllSound(own: [7, 7], handledByApps: [[7]]), [7])
    }

    func testAllSoundVolumeAndMuteReachAnAppThatHasItsOwnTap() {
        XCTAssertEqual(SoundMaster.gain(app: 0.5, master: 0.5, maxVolume: 4), 0.25, accuracy: 1e-9)
        XCTAssertEqual(SoundMaster.gain(app: 3, master: 3, maxVolume: 4), 4, "never past what Kriya allows")
        XCTAssertEqual(SoundMaster.gain(app: 1, master: 1, maxVolume: 4), 1, "untouched when nothing is changed")
        XCTAssertEqual(SoundMaster.gain(app: -1, master: 2, maxVolume: 4), 0)
        XCTAssertTrue(SoundMaster.isMuted(app: false, master: true))
        XCTAssertTrue(SoundMaster.isMuted(app: true, master: false))
        XCTAssertFalse(SoundMaster.isMuted(app: false, master: false))
        XCTAssertEqual(SoundMaster.temporary(app: 0.5, master: 0.5), 0.25, accuracy: 1e-6, "a timed mute on all sound and one on the app add up")
        XCTAssertEqual(SoundMaster.temporary(app: 1, master: 0), 0)
    }

    // MARK: Headphone correction gives back what was there

    func testWhatWasThereBeforeIsKeptWithTheDeviceTheCorrectionIsFor() throws {
        var settings = AppAudioSettings()
        settings.eq = EQPreset.matching([Float](repeating: 0, count: 10)) == nil ? settings.eq : settings.eq
        settings.eq[0] = 4; settings.preamp = -2; settings.effectsBypassed = true
        let before = AutoEQRunner.snapshot(settings)
        XCTAssertEqual(before.eq[0], 4); XCTAssertEqual(before.preamp, -2); XCTAssertTrue(before.effectsBypassed)
        let applied = AutoEQ.Applied(uid: "hp", previous: before)
        let again = try JSONDecoder().decode(AutoEQ.Applied.self, from: JSONEncoder().encode(applied))
        XCTAssertEqual(again, applied, "it survives Kriya quitting while the correction is on")
    }

    func testSwitchingBetweenTwoCorrectedDevicesKeepsTheFirstSnapshot() {
        let a = AutoEQ.Correction(gains: [Float](repeating: 1, count: 10), preampDB: -1, errorDB: 0.1)
        let b = AutoEQ.Correction(gains: [Float](repeating: 2, count: 10), preampDB: -2, errorDB: 0.1)
        let both = ["a": a, "b": b]
        XCTAssertEqual(AutoEQ.plan(applied: "a", current: "b", corrections: both), .apply("b", b))
        XCTAssertEqual(AutoEQ.plan(applied: "b", current: "plain", corrections: both), .clear)
    }

    // MARK: A device that comes back under another name

    func testARankedDeviceThatReturnsWithANewUniqueNameKeepsItsPlace() {
        let saved = ["old-uid": "AirPods Pro", "desk": "Desk DAC"]
        XCTAssertEqual(DevicePolicy.migrate(["old-uid", "desk"], savedNames: saved, connectedNames: ["new-uid": "AirPods Pro", "desk": "Desk DAC"]), ["new-uid", "desk"])
        XCTAssertEqual(DevicePolicy.migrate(["old-uid"], savedNames: saved, connectedNames: ["x": "AirPods Pro", "y": "AirPods Pro"]), ["old-uid"], "two look alike: no guess")
        XCTAssertEqual(DevicePolicy.migrate(["old-uid"], savedNames: saved, connectedNames: [:]), ["old-uid"], "still away")
        XCTAssertEqual(DevicePolicy.migrate(["desk"], savedNames: saved, connectedNames: ["desk": "Desk DAC"]), ["desk"], "connected: nothing to do")
        XCTAssertEqual(DevicePolicy.migrate(["a", "b"], savedNames: ["a": "Same", "b": "Same"], connectedNames: ["c": "Same"]), ["c", "b"], "only one place is given to one device")
        XCTAssertEqual(DevicePolicy.migrate(["old-uid"], savedNames: [:], connectedNames: ["n": "AirPods Pro"]), ["old-uid"], "no saved name, no match")
    }

    // MARK: Bluetooth by the device's own name

    func testAPinnedDeviceIsFoundByItsOwnNameNotItsNickname() throws {
        let pin = PinnedDevice(uid: "u", name: "Desk headphones", input: false, hardwareName: "AirPods Pro")
        XCTAssertEqual(pin.lookupName, "AirPods Pro")
        XCTAssertEqual(PinnedDevice(uid: "u", name: "AirPods Pro", input: false).lookupName, "AirPods Pro", "a pin saved before the field existed")
        let old = try JSONDecoder().decode(PinnedDevice.self, from: Data(#"{"uid":"u","name":"Old","input":false}"#.utf8))
        XCTAssertNil(old.hardwareName); XCTAssertEqual(old.lookupName, "Old")
        let peers = [BluetoothPeer(address: "aa", name: "AirPods Pro", isConnected: false)]
        XCTAssertEqual(BluetoothAudio.peer(named: pin.lookupName, in: peers)?.address, "aa")
        XCTAssertNil(BluetoothAudio.peer(named: pin.name, in: peers), "the nickname finds nothing, which was the bug")
    }

    // MARK: A Quick Config carries the whole mixer setup

    func testAQuickConfigKeepsEverythingItSaysItKeeps() throws {
        var config = QuickConfig(name: "Desk")
        config.menuBarApps = ["com.apple.Music"]; config.boostApps = ["com.spotify.client"]; config.excludedApps = ["com.game"]
        config.effectsUID = "fx"; config.outputPriority = ["a", "b"]; config.inputPriority = ["m"]
        config.autoEQ = ["hp": AutoEQ.Saved(name: "HD 600", correction: AutoEQ.Correction(gains: [Float](repeating: 1, count: 10), preampDB: -3, errorDB: 0.4))]
        var label = DeviceLabel(); label.nickname = "Desk"; label.hidden = true
        config.deviceLabels = ["u": label]
        config.mixerDensity = "compact"; config.mixerAppearance = "light"
        let data = try XCTUnwrap(QuickConfig.exported([config]))
        let back = try XCTUnwrap(QuickConfig.imported(data, existingNames: [])).first
        XCTAssertEqual(back?.menuBarApps, ["com.apple.Music"]); XCTAssertEqual(back?.boostApps, ["com.spotify.client"]); XCTAssertEqual(back?.excludedApps, ["com.game"])
        XCTAssertEqual(back?.effectsUID, "fx"); XCTAssertEqual(back?.outputPriority, ["a", "b"]); XCTAssertEqual(back?.inputPriority, ["m"])
        XCTAssertEqual(back?.autoEQ?["hp"]?.name, "HD 600"); XCTAssertEqual(back?.deviceLabels?["u"]?.hidden, true)
        XCTAssertEqual(back?.mixerDensity, "compact"); XCTAssertEqual(back?.mixerAppearance, "light")
    }

    func testAQuickConfigSavedBeforeTheseExistedStillLoadsAndLeavesThemAlone() throws {
        let old = #"{"format":"kriya-quick-configs","version":1,"configs":[{"id":"x","name":"Old","deviceVolumes":{},"apps":{},"favorites":["a"]}]}"#
        let configs = try XCTUnwrap(QuickConfig.imported(Data(old.utf8), existingNames: []))
        XCTAssertEqual(configs.first?.favorites, ["a"])
        XCTAssertNil(configs.first?.menuBarApps, "not in the file, so applying it does not touch the menu-bar icons")
        XCTAssertNil(configs.first?.outputPriority); XCTAssertNil(configs.first?.autoEQ)
    }

    // MARK: Sound shortcuts clash like any other shortcut

    func testSoundShortcutsAreCheckedAgainstEachOtherAndOtherFeatures() throws {
        let world = try TestWorld()
        defer { world.cleanUp() }
        let store = KeyboardStore(core: world.core)
        let mute = KeyShortcut(id: "s1", name: "Mute front app", keyCode: 46, modifiers: KeyModifiers.option, scope: .global, target: .command(command: "sound.front.mute"), enabled: true)
        store.saveShortcut(mute)
        XCTAssertNil(store.lastError)
        let boost = KeyShortcut(id: "s2", name: "Boost front app", keyCode: 46, modifiers: KeyModifiers.option, scope: .global, target: .command(command: "sound.front.boost"), enabled: true)
        XCTAssertTrue(store.checkShortcut(boost).contains { $0.kind == .duplicate }, "two sound commands cannot share a key")
        store.reservedProvider = { [ReservedKey(keyCode: 45, modifiers: KeyModifiers.option, owner: "Windows: Left half")] }
        let clash = KeyShortcut(id: "s3", name: "Next output", keyCode: 45, modifiers: KeyModifiers.option, scope: .global, target: .command(command: "audio.next_output"), enabled: true)
        store.saveShortcut(clash)
        XCTAssertTrue(store.lastError?.contains("Windows") ?? false, "a sound command cannot take a key another feature owns")
        XCTAssertEqual(store.shortcut(keyCode: 46, modifiers: KeyModifiers.option, app: nil)?.target, mute.target, "and the one that was saved finds its command")
    }
}
