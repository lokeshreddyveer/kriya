import XCTest
@testable import Kriya

final class WarningsTests: XCTestCase {
    private func store() throws -> (WarningStore, UserDefaults, String) {
        let suite = "kriya.test.warnings.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        return (WarningStore(defaults: defaults), defaults, suite)
    }

    // MARK: Names that never change

    func testTheNamesOfWarningsAlreadyShippedAreNeverChanged() {
        // A person's choice is kept under the name. Add to this list when a warning ships; never edit or remove a line.
        let shipped = ["capture.editor.discard-marks", "backup.icloud.newer-from-other-mac"]
        for id in shipped { XCTAssertNotNil(WarningCatalog.definition(id), "\(id) was renamed or removed: people who switched it off would see it again") }
    }

    func testEveryWarningHasAStableWellFormedName() {
        let ids = WarningCatalog.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "unique")
        for warning in WarningCatalog.all {
            XCTAssertNotNil(warning.id.range(of: #"^[a-z0-9]+(\.[a-z0-9-]+)+$"#, options: .regularExpression), warning.id)
            XCTAssertTrue(warning.id.hasPrefix(warning.feature + "."), "\(warning.id) starts with its feature")
            XCTAssertFalse(warning.title.isEmpty)
            XCTAssertGreaterThan(warning.detail.count, 20)
            XCTAssertFalse(warning.featureTitle.isEmpty)
        }
    }

    func testAConfirmationThatGuardsFilesCanNeverBeSwitchedOff() throws {
        XCTAssertFalse(WarningCatalog.all.contains { $0.id.contains("trash") || $0.id.contains("cleanup") || $0.id.contains("delete-files") })
        let (store, _, suite) = try store()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        XCTAssertFalse(store.dismiss("capture.cleanup.move-to-trash"), "not in the catalog, so it cannot be dismissed")
        XCTAssertTrue(store.shouldShow("capture.cleanup.move-to-trash"))
    }

    // MARK: Dismissing and resetting

    func testAWarningShowsUntilItIsSwitchedOff() throws {
        let (store, defaults, suite) = try store()
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = "capture.editor.discard-marks"
        XCTAssertTrue(store.shouldShow(id))
        XCTAssertNil(store.dismissedAt(id))
        let when = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(store.dismiss(id, at: when))
        XCTAssertFalse(store.shouldShow(id))
        XCTAssertTrue(store.isDismissed(id))
        XCTAssertEqual(store.dismissedAt(id), when)
        XCTAssertEqual(WarningStore(defaults: defaults).ledger.records, [WarningRecord(id: id, dismissedAt: when)], "kept for next time")
    }

    func testResetThisWarningBringsBackOnlyThatOne() throws {
        let (store, defaults, suite) = try store()
        defer { defaults.removePersistentDomain(forName: suite) }
        store.dismiss("capture.editor.discard-marks")
        store.dismiss("backup.icloud.newer-from-other-mac")
        store.reset("capture.editor.discard-marks")
        XCTAssertTrue(store.shouldShow("capture.editor.discard-marks"))
        XCTAssertFalse(store.shouldShow("backup.icloud.newer-from-other-mac"))
    }

    func testResetWarningsForAFeatureLeavesTheOthers() throws {
        let (store, defaults, suite) = try store()
        defer { defaults.removePersistentDomain(forName: suite) }
        store.dismiss("capture.editor.discard-marks")
        store.dismiss("backup.icloud.newer-from-other-mac")
        store.reset(feature: "capture")
        XCTAssertTrue(store.shouldShow("capture.editor.discard-marks"))
        XCTAssertFalse(store.shouldShow("backup.icloud.newer-from-other-mac"))
    }

    func testResetAllWarningsBringsBackEverything() throws {
        let (store, defaults, suite) = try store()
        defer { defaults.removePersistentDomain(forName: suite) }
        for warning in WarningCatalog.all { store.dismiss(warning.id) }
        XCTAssertEqual(store.dismissedCount, WarningCatalog.all.count)
        store.resetAll()
        XCTAssertEqual(store.dismissedCount, 0)
        for warning in WarningCatalog.all { XCTAssertTrue(store.shouldShow(warning.id), warning.id) }
    }

    func testAnUnknownWarningAlwaysShowsAndCannotBeDismissed() throws {
        let (store, defaults, suite) = try store()
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(store.shouldShow("something.from.a.later.version"))
        XCTAssertFalse(store.dismiss("something.from.a.later.version"))
        XCTAssertTrue(store.ledger.records.isEmpty)
    }

    func testRecordsFromALaterVersionSurviveResetsOfOtherWarningsButNotResetAll() throws {
        let (store, defaults, suite) = try store()
        defer { defaults.removePersistentDomain(forName: suite) }
        let future = WarningRecord(id: "capture.future.thing", dismissedAt: Date(timeIntervalSince1970: 5))
        store.ledger = WarningLedger(records: [future, WarningRecord(id: "capture.editor.discard-marks", dismissedAt: Date(timeIntervalSince1970: 6))])
        store.reset("capture.editor.discard-marks")
        XCTAssertEqual(store.ledger.records, [future])
        store.reset(feature: "capture")
        XCTAssertEqual(store.ledger.records, [future], "a warning this version does not know is not touched")
        store.resetAll()
        XCTAssertTrue(store.ledger.records.isEmpty)
    }

    func testDismissingAgainReplacesTheRecordInsteadOfRepeatingIt() throws {
        let (store, defaults, suite) = try store()
        defer { defaults.removePersistentDomain(forName: suite) }
        store.dismiss("capture.editor.discard-marks", at: Date(timeIntervalSince1970: 1))
        store.dismiss("capture.editor.discard-marks", at: Date(timeIntervalSince1970: 2))
        XCTAssertEqual(store.ledger.records.count, 1)
        XCTAssertEqual(store.dismissedAt("capture.editor.discard-marks"), Date(timeIntervalSince1970: 2))
    }

    // MARK: What older versions remembered

    func testAnOlderVersionsDismissalCountsAndIsClearedByAReset() throws {
        let (store, defaults, suite) = try store()
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = "backup.icloud.newer-from-other-mac"
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        defaults.set(when, forKey: "iCloudSyncDismissedAt")
        XCTAssertFalse(store.shouldShow(id), "dismissed before this list existed")
        XCTAssertEqual(store.dismissedAt(id), when)
        store.reset(id)
        XCTAssertTrue(store.shouldShow(id))
        XCTAssertNil(defaults.object(forKey: "iCloudSyncDismissedAt"), "so the banner can come back")
        defaults.set(when, forKey: "iCloudSyncDismissedAt")
        store.resetAll()
        XCTAssertNil(defaults.object(forKey: "iCloudSyncDismissedAt"))
        defaults.set(when, forKey: "iCloudSyncDismissedAt")
        store.reset(feature: "backup")
        XCTAssertNil(defaults.object(forKey: "iCloudSyncDismissedAt"))
    }

    // MARK: Saved data

    func testDamagedWarningDataLoadsAsNothingDismissed() throws {
        let (store, defaults, suite) = try store()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("not json".utf8), forKey: WarningStore.key)
        XCTAssertTrue(store.ledger.records.isEmpty)
        XCTAssertEqual(try JSONDecoder().decode(WarningLedger.self, from: Data(#"{"records":7}"#.utf8)), WarningLedger())
    }

    func testAWarningRecordKeepsItsNameAndDate() throws {
        let record = WarningRecord(id: "capture.editor.discard-marks", dismissedAt: Date(timeIntervalSince1970: 1_800_000_000))
        let back = try JSONDecoder().decode(WarningRecord.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(back, record)
    }

    func testTheListIsRegisteredForBackupAndReset() throws {
        let entry = try XCTUnwrap(SettingsRegistry.entries.first { $0.key == WarningStore.key })
        XCTAssertEqual(entry.kind, .setting)
    }

    func testTheDiscardQuestionIsSkippedOnceSwitchedOffAndNeverWithNothingToLose() throws {
        let (store, defaults, suite) = try store()
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(CaptureEditorController.confirmDiscard(0, warnings: store), "no marks: nothing to ask about")
        store.dismiss(CaptureEditorController.discardWarning)
        XCTAssertTrue(CaptureEditorController.confirmDiscard(5, warnings: store), "switched off: it goes ahead without asking")
    }
}

/// A stand-in that records what was asked of it and fails for the steps it is told to.
private final class FakeSound: CaptureSoundBackend {
    var failing: Set<String> = []
    var played: [CaptureSoundPlan.Step] = []

    private func key(_ step: CaptureSoundPlan.Step) -> String {
        switch step {
        case .custom: return "custom"
        case .system: return "system"
        case .camera: return "camera"
        case .beep: return "beep"
        }
    }

    func play(_ step: CaptureSoundPlan.Step) -> Bool {
        played.append(step)
        return !failing.contains(key(step))
    }
}

final class CaptureSoundTests: XCTestCase {
    private func policy(_ choice: CaptureSound, custom: String = "") -> SoundPolicy {
        var p = SoundPolicy()
        p.choice = choice
        p.customPath = custom
        return p
    }

    // MARK: Which sound

    func testEachChoiceTriesItsOwnSoundFirst() {
        XCTAssertEqual(CaptureSoundPlan.steps(for: policy(.system)).first, .system)
        XCTAssertEqual(CaptureSoundPlan.steps(for: policy(.camera)).first, .camera)
        XCTAssertEqual(CaptureSoundPlan.steps(for: policy(.custom, custom: "/tmp/click.wav")).first, .custom(URL(fileURLWithPath: "/tmp/click.wav")))
        XCTAssertTrue(CaptureSoundPlan.steps(for: policy(.none)).isEmpty)
    }

    func testEveryChoiceEndsWithTheBeepSoASoundIsNeverLostByAccident() {
        for choice in [CaptureSound.system, .camera, .custom] {
            XCTAssertEqual(CaptureSoundPlan.steps(for: policy(choice, custom: "/tmp/a.wav")).last, .beep, "\(choice)")
        }
    }

    func testACustomChoiceWithNoUsableFileFallsBackAtOnce() {
        XCTAssertEqual(CaptureSoundPlan.steps(for: policy(.custom, custom: "")), [.camera, .system, .beep])
        XCTAssertEqual(CaptureSoundPlan.steps(for: policy(.custom, custom: "/tmp/notes.txt")), [.camera, .system, .beep], "not a kind of sound")
        XCTAssertNil(CaptureSoundFile.url(for: "  "))
        XCTAssertNotNil(CaptureSoundFile.url(for: "/tmp/Click.AIFF"))
    }

    func testDefaultsAreTheMacOSSoundWithNoCustomFile() {
        let p = SoundPolicy()
        XCTAssertEqual(p.choice, .system)
        XCTAssertEqual(p.customPath, "")
        XCTAssertNil(p.customURL)
        XCTAssertEqual(try JSONDecoder().decode(SoundPolicy.self, from: Data("{}".utf8)), p)
        XCTAssertEqual(try JSONDecoder().decode(SoundPolicy.self, from: Data(#"{"choice":"gone"}"#.utf8)).choice, .system, "a choice from a later version is not a crash")
    }

    // MARK: When it plays

    func testNothingPlaysWhenSoundsAreOff() {
        let backend = FakeSound()
        let outcome = CaptureSoundPlayer(backend: backend).play(enabled: false, policy: policy(.camera))
        XCTAssertEqual(outcome.result, .silent)
        XCTAssertNil(outcome.message)
        XCTAssertTrue(backend.played.isEmpty)
    }

    func testNoneIsSilentEvenWhenSoundsAreOn() {
        let backend = FakeSound()
        let player = CaptureSoundPlayer(backend: backend)
        XCTAssertEqual(player.play(enabled: true, policy: policy(.none)).result, .silent)
        XCTAssertEqual(player.preview(policy: policy(.none)).result, .silent)
        XCTAssertTrue(backend.played.isEmpty)
    }

    func testTheChosenSoundPlaysOnceAndNothingIsSaid() {
        let backend = FakeSound()
        let outcome = CaptureSoundPlayer(backend: backend).play(enabled: true, policy: policy(.camera))
        XCTAssertEqual(outcome.result, .played(.camera))
        XCTAssertEqual(backend.played, [.camera], "only the first that works")
        XCTAssertNil(outcome.message)
    }

    func testPreviewPlaysEvenWhileCaptureSoundsAreOff() {
        let backend = FakeSound()
        XCTAssertEqual(CaptureSoundPlayer(backend: backend).preview(policy: policy(.system)).result, .played(.system))
        XCTAssertEqual(backend.played, [.system])
    }

    // MARK: When a sound is unavailable

    func testAMissingCustomFileFallsBackToTheCameraAndSaysSo() {
        let backend = FakeSound()
        backend.failing = ["custom"]
        let outcome = CaptureSoundPlayer(backend: backend).play(enabled: true, policy: policy(.custom, custom: "/tmp/gone.wav"))
        XCTAssertEqual(outcome.result, .played(.camera))
        XCTAssertEqual(backend.played, [.custom(URL(fileURLWithPath: "/tmp/gone.wav")), .camera])
        XCTAssertEqual(outcome.message, "Could not play your sound file, so the camera shutter was played instead.")
    }

    func testAMissingSystemSoundFallsBackThroughTheChainToTheBeep() {
        let backend = FakeSound()
        backend.failing = ["system", "camera"]
        let outcome = CaptureSoundPlayer(backend: backend).play(enabled: true, policy: policy(.system))
        XCTAssertEqual(outcome.result, .played(.beep))
        XCTAssertEqual(backend.played, [.system, .camera, .beep])
        XCTAssertEqual(outcome.skipped, [.system, .camera])
        XCTAssertEqual(outcome.message, "Could not play the macOS screenshot sound, so the system beep was played instead.")
    }

    func testWhenNothingCanPlayItIsSaidPlainly() {
        let backend = FakeSound()
        backend.failing = ["custom", "system", "camera", "beep"]
        let outcome = CaptureSoundPlayer(backend: backend).play(enabled: true, policy: policy(.custom, custom: "/tmp/a.wav"))
        XCTAssertEqual(outcome.result, .failed)
        XCTAssertEqual(backend.played.count, 4, "every way was tried")
        XCTAssertEqual(outcome.message, "No sound could be played. Check the Mac's output volume and the sound file.")
    }

    // MARK: The camera sound

    func testTheCameraShutterIsMadeTheSameEveryTimeAndIsAudible() {
        let a = ShutterSynth.samples()
        XCTAssertEqual(a, ShutterSynth.samples(), "deterministic")
        XCTAssertEqual(a.count, Int(Double(ShutterSynth.sampleRate) * 0.16))
        let peak = a.map { abs($0) }.max() ?? 0
        XCTAssertGreaterThan(peak, 0.5, "not silent")
        XCTAssertLessThanOrEqual(peak, 0.81, "not clipped")
        XCTAssertGreaterThan(a.prefix(1_000).map { abs($0) }.reduce(0, +), a.suffix(1_000).map { abs($0) }.reduce(0, +), "it dies away")
    }

    func testTheCameraShutterIsAValidWAVFile() {
        let data = ShutterSynth.wav()
        let samples = ShutterSynth.samples().count
        XCTAssertEqual(String(decoding: data.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: data[8..<12], as: UTF8.self), "WAVE")
        XCTAssertEqual(String(decoding: data[12..<16], as: UTF8.self), "fmt ")
        XCTAssertEqual(String(decoding: data[36..<40], as: UTF8.self), "data")
        XCTAssertEqual(data.count, 44 + samples * 2)
        let riffSize = data[4..<8].enumerated().reduce(0) { $0 + Int($1.element) << (8 * $1.offset) }
        XCTAssertEqual(riffSize, data.count - 8)
    }

    func testTheRealBackendCanMakeTheCameraSoundFromMemory() {
        // Only that the sound can be created; nothing is played.
        XCTAssertNotNil(NSSound(data: ShutterSynth.wav()))
    }

    // MARK: Saved choice

    func testTheChoiceIsKeptWithTheCaptureSettings() throws {
        var delivery = CaptureDeliveryPolicy()
        delivery.sound = policy(.custom, custom: "/tmp/click.wav")
        let back = try JSONDecoder().decode(CaptureDeliveryPolicy.self, from: JSONEncoder().encode(delivery))
        XCTAssertEqual(back.sound.choice, .custom)
        XCTAssertEqual(back.sound.customPath, "/tmp/click.wav")
        XCTAssertEqual(try JSONDecoder().decode(CaptureDeliveryPolicy.self, from: Data("{}".utf8)).sound, SoundPolicy(), "older settings get the default")
    }
}
