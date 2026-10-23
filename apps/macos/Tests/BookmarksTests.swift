import XCTest
@testable import Kriya

final class BookmarksTests: XCTestCase {
    func testChromiumBookmarksAreFoundInNestedFolders() throws {
        let json = #"{"roots":{"bookmark_bar":{"type":"folder","children":[{"type":"url","name":"Swift","url":"https://swift.org"},{"type":"folder","children":[{"type":"url","name":"Apple","url":"https://apple.com"}]}]},"other":{"type":"folder","children":[]}}}"#
        let found = BookmarkParser.chromium(Data(json.utf8), source: "Chrome")
        XCTAssertEqual(Set(found.map(\.url)), ["https://swift.org", "https://apple.com"])
        XCTAssertTrue(BookmarkParser.chromium(Data("nope".utf8), source: "x").isEmpty)
    }

    func testSafariBookmarksAreFound() throws {
        let plist: [String: Any] = ["Children": [["URLString": "https://a.com", "URIDictionary": ["title": "A site"]], ["Children": [["URLString": "https://b.com", "URIDictionary": ["title": "B site"]]]]]]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        XCTAssertEqual(BookmarkParser.safari(data).map(\.title).sorted(), ["A site", "B site"])
    }

    func testSearchRanksTitlesAndIgnoresShortQueries() {
        let all = [Bookmark(title: "Swift language", url: "https://swift.org", source: "x"), Bookmark(title: "Cooking", url: "https://food.com/swift-rolls", source: "x")]
        XCTAssertEqual(BookmarkParser.search("swift", in: all).first?.title, "Swift language")
        XCTAssertTrue(BookmarkParser.search("s", in: all).isEmpty)
    }

    func testLargeTypeShrinksForLongText() {
        let size = NSSize(width: 1600, height: 700)
        XCTAssertGreaterThan(LargeType.fontSize(for: "Hi", in: size), LargeType.fontSize(for: String(repeating: "word ", count: 80), in: size))
        XCTAssertGreaterThanOrEqual(LargeType.fontSize(for: String(repeating: "x", count: 5000), in: size), 28)
    }
}
