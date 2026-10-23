import XCTest
@testable import Kriya

final class DialogFoldersTests: XCTestCase {
    func testOrderAndNoRepeats() {
        let list = DialogFolders.choices(finder: "/a/work/", windows: ["/a/work", "/b"], favorites: ["/b", "/c"], recents: ["/c", "/d"], exists: { _ in true })
        XCTAssertEqual(list.map(\.path), ["/a/work", "/b", "/c", "/d"])
        XCTAssertEqual(list.map(\.kind), [.finder, .window, .favorite, .recent])
    }

    func testMissingFoldersAreDropped() {
        let list = DialogFolders.choices(finder: nil, windows: [], favorites: ["/gone", "/here"], recents: [], exists: { $0 == "/here" })
        XCTAssertEqual(list.map(\.path), ["/here"])
    }

    func testDialogDetection() {
        XCTAssertTrue(DialogFolders.looksLikeDialog(role: "AXSheet", subrole: nil, title: nil))
        XCTAssertTrue(DialogFolders.looksLikeDialog(role: "AXWindow", subrole: "AXDialog", title: nil))
        XCTAssertTrue(DialogFolders.looksLikeDialog(role: "AXWindow", subrole: "AXStandardWindow", title: "Save"))
        XCTAssertTrue(DialogFolders.looksLikeDialog(role: "AXWindow", subrole: "AXStandardWindow", title: "Open Recent"))
        XCTAssertFalse(DialogFolders.looksLikeDialog(role: "AXWindow", subrole: "AXStandardWindow", title: "Safari — Home"))
        XCTAssertFalse(DialogFolders.looksLikeDialog(role: nil, subrole: nil, title: "Opening Hours"))
    }
}
