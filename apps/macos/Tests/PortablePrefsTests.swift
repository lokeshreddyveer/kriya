import XCTest
@testable import Kriya

final class PortablePrefsTests: XCTestCase {
    private func scratch() -> UserDefaults {
        let name = "kriya.test.portable.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    func testSettingsRoundTripWhateverTheirType() throws {
        let a = scratch(), b = scratch()
        a.set(Data([1, 2, 3]), forKey: "windowLocks.v1")
        a.set(6, forKey: "shelf.reminderLeadHours")
        a.set("auto", forKey: "capture.ocrLanguages")
        a.set(["x", "y"], forKey: "notes.pinned.v1")
        a.set(true, forKey: "selection.startInKeyboard")
        let packed = try XCTUnwrap(PortablePrefs.pack(from: a))
        XCTAssertEqual(PortablePrefs.apply(packed, to: b), 5)
        XCTAssertEqual(b.data(forKey: "windowLocks.v1"), Data([1, 2, 3]))
        XCTAssertEqual(b.integer(forKey: "shelf.reminderLeadHours"), 6)
        XCTAssertEqual(b.string(forKey: "capture.ocrLanguages"), "auto")
        XCTAssertEqual(b.stringArray(forKey: "notes.pinned.v1"), ["x", "y"])
        XCTAssertTrue(b.bool(forKey: "selection.startInKeyboard"))
    }

    func testOnlyListedKeysAreWrittenAndHistoryIsNeverPacked() throws {
        let a = scratch(), b = scratch()
        a.set("keep", forKey: "deviceTimeline.v1")
        a.set("keep", forKey: "usage.savedActions.v1")
        XCTAssertNil(PortablePrefs.pack(from: a), "nothing listed is saved, so nothing is packed")
        a.set(1, forKey: "powerSaving.mode")
        let packed = try XCTUnwrap(PortablePrefs.pack(from: a))
        XCTAssertFalse(packed.contains("deviceTimeline"))
        // A file that names a key outside the list cannot write it.
        let sneaky = try JSONSerialization.data(withJSONObject: ["auditLog.v1": Data([9]).base64EncodedString()])
        XCTAssertEqual(PortablePrefs.apply(String(decoding: sneaky, as: UTF8.self), to: b), 0)
        XCTAssertNil(b.object(forKey: "auditLog.v1"))
    }

    func testAnOldBackupHasNoPreferencesToApply() {
        XCTAssertNil(PortablePrefs.packed(inBackup: #"{"extras":{"workspaces":"{}"}}"#))
        XCTAssertEqual(PortablePrefs.packed(inBackup: #"{"extras":{"app_prefs":"{}"}}"#), "{}")
        XCTAssertNil(PortablePrefs.packed(inBackup: "not json"))
    }
}
