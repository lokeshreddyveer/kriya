import XCTest
@testable import Kriya

final class SharedClipboardTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testFileNamesRoundTrip() throws {
        let name = SharedClipboard.fileName(deviceID: "ab12cd34", at: now)
        let parsed = try XCTUnwrap(SharedClipboard.parse(name))
        XCTAssertEqual(parsed.deviceID, "ab12cd34")
        XCTAssertEqual(parsed.date.timeIntervalSince1970, now.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertNil(SharedClipboard.parse("notes.txt"))
        XCTAssertNil(SharedClipboard.parse("abc-dev.kriyaclip"))
    }

    func testOnlyFreshFilesFromOtherMacsAreTaken() {
        let mine = SharedClipboard.fileName(deviceID: "me", at: now.addingTimeInterval(-5))
        let theirs = SharedClipboard.fileName(deviceID: "other", at: now.addingTimeInterval(-30))
        let newer = SharedClipboard.fileName(deviceID: "third", at: now.addingTimeInterval(-10))
        let stale = SharedClipboard.fileName(deviceID: "old", at: now.addingTimeInterval(-3000))
        let all = [mine, theirs, newer, stale]
        XCTAssertEqual(SharedClipboard.newestForMe(all, myID: "me", after: now.addingTimeInterval(-100), now: now), newer)
        XCTAssertNil(SharedClipboard.newestForMe(all, myID: "me", after: now.addingTimeInterval(-5), now: now), "already seen")
        XCTAssertEqual(SharedClipboard.expired(all, now: now), [stale])
    }

    func testSendableAndPreview() {
        XCTAssertFalse(SharedClipboard.isSendable("  \n"))
        XCTAssertFalse(SharedClipboard.isSendable(nil))
        XCTAssertFalse(SharedClipboard.isSendable(String(repeating: "x", count: 200_000)))
        XCTAssertTrue(SharedClipboard.isSendable("hello"))
        XCTAssertEqual(SharedClipboard.preview("first line\nsecond"), "first line")
    }

    func testSealedPayloadOpensOnlyWithTheSamePassphrase() throws {
        let payload = SharedClipboard.Payload(from: "Studio", text: "secret text")
        let json = String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
        let data = try BackupCrypto.seal(json, passphrase: "correct horse", iterations: 20_000)
        XCTAssertEqual(try JSONDecoder().decode(SharedClipboard.Payload.self, from: Data(try BackupCrypto.open(data, passphrase: "correct horse").utf8)), payload)
        XCTAssertThrowsError(try BackupCrypto.open(data, passphrase: "wrong horse!"))
    }
}
