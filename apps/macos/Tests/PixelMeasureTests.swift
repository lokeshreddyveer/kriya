import XCTest
@testable import Kriya

final class PixelMeasureTests: XCTestCase {
    /// A 10 by 6 picture, white, with a 4 by 2 red box at x 3...6, y 2...3.
    private func grid() -> PixelGrid {
        var bytes = [UInt8](repeating: 255, count: 10 * 6 * 4)
        for y in 2...3 { for x in 3...6 { let i = (y * 10 + x) * 4; bytes[i] = 255; bytes[i + 1] = 0; bytes[i + 2] = 0 } }
        return PixelGrid(width: 10, height: 6, bytes: bytes)
    }

    func testColorsAndHex() {
        XCTAssertEqual(grid().hex(x: 4, y: 2), "#FF0000")
        XCTAssertEqual(grid().hex(x: 0, y: 0), "#FFFFFF")
        XCTAssertNil(grid().hex(x: 10, y: 0))
    }

    func testRunStopsAtTheEdge() {
        let g = grid()
        XCTAssertEqual(g.run(fromX: 4, y: 2, dx: 1, dy: 0), 2, "red continues to x 6")
        XCTAssertEqual(g.run(fromX: 4, y: 2, dx: -1, dy: 0), 1)
        XCTAssertEqual(g.run(fromX: 0, y: 0, dx: 1, dy: 0), 9, "white runs to the end of the row")
    }

    func testRegionFindsTheBox() {
        let r = grid().region(around: 5, y: 3)
        XCTAssertEqual(r?.x, 3); XCTAssertEqual(r?.y, 2); XCTAssertEqual(r?.width, 4); XCTAssertEqual(r?.height, 2)
    }

    func testRectAndLabel() {
        XCTAssertEqual(PixelMeasure.rect(from: CGPoint(x: 10, y: 20), to: CGPoint(x: 4, y: 5)), CGRect(x: 4, y: 5, width: 6, height: 15))
        XCTAssertEqual(PixelMeasure.label(widthPixels: 240, heightPixels: 120, scale: 1), "240 × 120 px")
        XCTAssertEqual(PixelMeasure.label(widthPixels: 241, heightPixels: 120, scale: 2), "241 × 120 px  (120.5 × 60 pt)")
    }
}
