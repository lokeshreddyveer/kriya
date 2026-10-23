import XCTest
@testable import Kriya

final class PaletteLayoutPlacementTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1600, height: 900)

    func testTopMatchesTheOriginalPlace() {
        XCTAssertEqual(PaletteLayout.frame(height: 300, in: screen, placement: .top, pointer: .zero, saved: nil), PaletteLayout.frame(height: 300, in: screen))
    }

    func testCenterPutsTheSearchBarInTheMiddleAndKeepsTheTopStill() {
        let small = PaletteLayout.frame(height: 132, in: screen, placement: .center, pointer: .zero, saved: nil)
        let big = PaletteLayout.frame(height: 300, in: screen, placement: .center, pointer: .zero, saved: nil)
        XCTAssertEqual(small.maxY, big.maxY, accuracy: 0.5)
        XCTAssertEqual(small.midX, 800, accuracy: 0.5)
        // The pill's middle is the screen's middle.
        let pillMid = small.maxY - PaletteLayout.shadowInset - PaletteLayout.searchHeight / 2
        XCTAssertEqual(pillMid, screen.midY, accuracy: 0.5)
    }

    func testCornersHugTheirEdges() {
        let tl = PaletteLayout.frame(height: 300, in: screen, placement: .topLeft, pointer: .zero, saved: nil)
        let tr = PaletteLayout.frame(height: 300, in: screen, placement: .topRight, pointer: .zero, saved: nil)
        XCTAssertEqual(tl.minX, 12, accuracy: 0.5)
        XCTAssertEqual(tr.maxX, 1588, accuracy: 0.5)
        XCTAssertEqual(tl.maxY, screen.maxY - 12, accuracy: 0.5)
    }

    func testBottomPlacementsKeepTheBottomStillAndGrowUp() {
        for placement in [PaletteLayout.Placement.bottomLeft, .bottom, .bottomRight] {
            let small = PaletteLayout.frame(height: 132, in: screen, placement: placement, pointer: .zero, saved: nil)
            let big = PaletteLayout.frame(height: 500, in: screen, placement: placement, pointer: .zero, saved: nil)
            XCTAssertEqual(small.minY, big.minY, accuracy: 0.5)
            XCTAssertGreaterThan(big.maxY, small.maxY)
            XCTAssertTrue(screen.contains(big))
        }
        let tall = PaletteLayout.frame(height: 5000, in: screen, placement: .bottom, pointer: .zero, saved: nil)
        XCTAssertTrue(screen.contains(tall))
    }

    func testResizingUpwardKeepsTheBottom() {
        let start = PaletteLayout.frame(height: 132, in: screen, placement: .bottom, pointer: .zero, saved: nil)
        let grown = PaletteLayout.resized(start, toHeight: 500, in: screen, growsUp: true)
        XCTAssertEqual(grown.minY, start.minY, accuracy: 0.5)
        XCTAssertEqual(grown.height, 500, accuracy: 0.5)
    }

    func testPointerPlacementFollowsThePointerButStaysOnScreen() {
        let near = PaletteLayout.frame(height: 200, in: screen, placement: .pointer, pointer: CGPoint(x: 400, y: 600), saved: nil)
        XCTAssertEqual(near.midX, 400, accuracy: 0.5)
        let corner = PaletteLayout.frame(height: 200, in: screen, placement: .pointer, pointer: CGPoint(x: 1590, y: 5), saved: nil)
        XCTAssertTrue(screen.contains(corner))
    }

    func testRememberedUsesTheSavedPointAndFallsBackToTop() {
        let r = PaletteLayout.frame(height: 200, in: screen, placement: .remembered, pointer: .zero, saved: CGPoint(x: 500, y: 700))
        XCTAssertEqual(r.midX, 500, accuracy: 0.5)
        XCTAssertEqual(r.maxY, 700, accuracy: 0.5)
        XCTAssertEqual(PaletteLayout.frame(height: 200, in: screen, placement: .remembered, pointer: .zero, saved: nil), PaletteLayout.frame(height: 200, in: screen))
    }

    func testTooHighASavedPlaceIsPulledBackInside() {
        let r = PaletteLayout.frame(height: 200, in: screen, placement: .remembered, pointer: .zero, saved: CGPoint(x: -900, y: 5000))
        XCTAssertTrue(screen.contains(r))
    }
}
