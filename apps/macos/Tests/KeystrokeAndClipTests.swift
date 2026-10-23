import XCTest
@testable import Kriya

final class KeystrokeRecordingTests: XCTestCase {
    private func key(_ code: UInt16, _ mods: UInt64 = 0, _ time: Double) -> RecordedKey { RecordedKey(keyCode: code, modifiers: mods, time: time) }

    func testOneKeyBecomesAKeyPressAndSeveralBecomeASequence() throws {
        XCTAssertEqual(KeystrokeRecording.action(from: [key(8, 8, 0)]), .keyPress(keyCode: 8, modifiers: 8))
        let action = try XCTUnwrap(KeystrokeRecording.action(from: [key(8, 8, 0), key(48, 0, 0.2), key(9, 8, 0.4)]))
        guard case .sequence(let steps, let delay) = action else { return XCTFail("a sequence") }
        XCTAssertEqual(steps.count, 3)
        XCTAssertEqual(steps[1], .keyPress(keyCode: 48, modifiers: 0))
        XCTAssertEqual(delay, 200)
        XCTAssertNil(KeystrokeRecording.action(from: []))
    }

    func testModifierOnlyPressesAreDroppedAndTheLengthIsCapped() {
        XCTAssertTrue(KeystrokeRecording.cleaned([key(55, 8, 0), key(56, 1, 0.1), key(59, 2, 0.2)]).isEmpty, "⌘, shift and control on their own")
        let many = (0..<80).map { key(UInt16($0 % 40), 0, Double($0) * 0.05) }
        XCTAssertEqual(KeystrokeRecording.cleaned(many).count, KeystrokeRecording.maxSteps)
        XCTAssertEqual(KeystrokeRecording.action(from: [key(55, 8, 0)]), nil)
    }

    func testThePauseFollowsTheTypistAndStaysInRange() {
        XCTAssertEqual(KeystrokeRecording.delay(for: [key(0, 0, 0)]), 80, "nothing to measure")
        XCTAssertEqual(KeystrokeRecording.delay(for: [key(0, 0, 0), key(1, 0, 0.001), key(2, 0, 0.002)]), 30, "never faster than 30 ms")
        XCTAssertEqual(KeystrokeRecording.delay(for: [key(0, 0, 0), key(1, 0, 9), key(2, 0, 18)]), 1500, "never slower than 1.5 s")
        // The middle gap, so one long pause does not slow everything.
        XCTAssertEqual(KeystrokeRecording.delay(for: [key(0, 0, 0), key(1, 0, 0.1), key(2, 0, 0.2), key(3, 0, 5.0)]), 100)
    }

    func testTheSummaryNamesTheFirstKeys() {
        XCTAssertTrue(KeystrokeRecording.summary([key(8, 8, 0), key(9, 8, 1)]).hasPrefix("2 keys:"))
        XCTAssertEqual(KeystrokeRecording.summary([]), "0 keys")
        XCTAssertTrue(KeystrokeRecording.summary((0..<10).map { key(UInt16($0), 0, Double($0)) }).hasSuffix("…"))
    }
}

final class SettingsSyncTests: XCTestCase {
    private func file(_ name: String, _ seconds: Double) -> BackupFileInfo {
        BackupFileInfo(url: URL(fileURLWithPath: "/tmp/\(name).\(BackupManager.fileExtension)"), date: Date(timeIntervalSince1970: seconds))
    }

    func testAnotherMacsNewerCopyIsOfferedButYourOwnAndOlderOnesAreNot() {
        let files = [file("Kriya – Studio", 500), file("Kriya – Laptop", 900), file("Kriya – Old Mac", 100)]
        XCTAssertEqual(SettingsSync.newerFromOtherMac(files: files, thisMac: "Studio", dismissedAt: nil)?.name, "Kriya – Laptop.\(BackupManager.fileExtension)")
        XCTAssertNil(SettingsSync.newerFromOtherMac(files: files, thisMac: "Laptop", dismissedAt: nil), "this Mac's own copy is the newest")
    }

    func testNotNowHidesThatCopyUntilANewerOneArrives() {
        let files = [file("Kriya – Studio", 500), file("Kriya – Laptop", 900)]
        XCTAssertNil(SettingsSync.newerFromOtherMac(files: files, thisMac: "Studio", dismissedAt: Date(timeIntervalSince1970: 900)))
        let later = files + [file("Kriya – Tablet", 1200)]
        XCTAssertEqual(SettingsSync.newerFromOtherMac(files: later, thisMac: "Studio", dismissedAt: Date(timeIntervalSince1970: 900))?.name, "Kriya – Tablet.\(BackupManager.fileExtension)")
    }

    func testWithNoCopyOfItsOwnAnyOtherMacsCopyIsOfferedAndStrangersAreIgnored() {
        XCTAssertEqual(SettingsSync.newerFromOtherMac(files: [file("Kriya – Laptop", 900)], thisMac: "Studio", dismissedAt: nil)?.date, Date(timeIntervalSince1970: 900))
        XCTAssertNil(SettingsSync.newerFromOtherMac(files: [file("Something else", 900)], thisMac: "Studio", dismissedAt: nil))
        XCTAssertNil(SettingsSync.newerFromOtherMac(files: [], thisMac: "Studio", dismissedAt: nil))
        XCTAssertEqual(SettingsSync.newerFromOtherMac(files: [file("kriya – laptop", 900), file("KRIYA – STUDIO", 100)], thisMac: "Studio", dismissedAt: nil)?.date, Date(timeIntervalSince1970: 900), "names are compared without case")
    }
}
