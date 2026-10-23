import XCTest
@testable import Kriya

final class CaptureHistoryTests: XCTestCase {
    func testNewestFirstAndOnlyCaptureFiles() {
        let now = Date()
        let files: [(path: String, date: Date)] = [("/c/a.png", now.addingTimeInterval(-300)), ("/c/notes.txt", now), ("/c/b.mov", now.addingTimeInterval(-10)), ("/c/c.GIF", now.addingTimeInterval(-60))]
        let list = CaptureHistory.recent(files, limit: 10)
        XCTAssertEqual(list.map(\.name), ["b.mov", "c.GIF", "a.png"])
        XCTAssertTrue(list[0].isMovie)
        XCTAssertFalse(list[1].isMovie)
        XCTAssertEqual(CaptureHistory.recent(files, limit: 1).count, 1)
    }
}
