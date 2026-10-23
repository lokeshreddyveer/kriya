import XCTest
@testable import Kriya

final class SafariInboxTests: XCTestCase {
    private func data(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }

    func testOnlyOurOwnFileNamesAreRead() {
        XCTAssertTrue(SafariInbox.isInboxName(SafariInbox.newName()))
        XCTAssertFalse(SafariInbox.isInboxName("safari-../../x.json"))
        XCTAssertFalse(SafariInbox.isInboxName("page-" + String(repeating: "a", count: 32) + ".json"))
        XCTAssertFalse(SafariInbox.isInboxName("safari-ABC.json"))
    }

    func testAFileIsAcceptableOnlyWhenSmallRecentRegularAndOurs() {
        let name = SafariInbox.newName()
        XCTAssertTrue(SafariInbox.isAcceptable(name: name, size: 100, age: 5, isRegular: true, ownedByUser: true))
        XCTAssertFalse(SafariInbox.isAcceptable(name: name, size: SafariInbox.maxFileBytes + 1, age: 5, isRegular: true, ownedByUser: true))
        XCTAssertFalse(SafariInbox.isAcceptable(name: name, size: 100, age: SafariInbox.maxAge + 1, isRegular: true, ownedByUser: true))
        XCTAssertFalse(SafariInbox.isAcceptable(name: name, size: 100, age: 5, isRegular: false, ownedByUser: true), "a link or folder")
        XCTAssertFalse(SafariInbox.isAcceptable(name: name, size: 100, age: 5, isRegular: true, ownedByUser: false))
    }

    func testRequestsAreCheckedLikeEveryOtherBrowserRequest() throws {
        guard case .success(.open(let url, let title)) = SafariInbox.interpret(data(["type": "open", "url": "https://example.com/a", "title": "A"])) else { return XCTFail() }
        XCTAssertEqual(url.absoluteString, "https://example.com/a")
        XCTAssertEqual(title, "A")
        if case .success = SafariInbox.interpret(data(["type": "open", "url": "javascript:alert(1)"])) { XCTFail("only web addresses") }
        if case .success = SafariInbox.interpret(data(["type": "open", "url": "file:///etc/passwd"])) { XCTFail("no files") }
        if case .success = SafariInbox.interpret(data(["type": "run", "command": "x"])) { XCTFail("unknown kind") }
        if case .success = SafariInbox.interpret(Data("not json".utf8)) { XCTFail("not json") }
        if case .success = SafariInbox.interpret(data(["type": "selection", "text": "   "])) { XCTFail("empty text") }
    }

    func testAPageNeedsTextAndAKnownAction() {
        let good: [String: Any] = ["type": "page", "as": "copy", "url": "https://example.com", "title": "T", "markdown": "# Hi"]
        guard case .success(.page(let clip, let action)) = SafariInbox.interpret(data(good)) else { return XCTFail() }
        XCTAssertEqual(clip.title, "T")
        XCTAssertEqual(action, .copy)
        var noText = good; noText["markdown"] = " "
        if case .success = SafariInbox.interpret(data(noText)) { XCTFail() }
        var badAction = good; badAction["as"] = "delete"
        if case .success = SafariInbox.interpret(data(badAction)) { XCTFail() }
    }

    func testAnOversizedFileIsRefusedBeforeItIsParsed() {
        let big = Data(repeating: 0x20, count: SafariInbox.maxFileBytes + 1)
        if case .success = SafariInbox.interpret(big) { XCTFail() }
    }
}
