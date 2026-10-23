import XCTest
@testable import Kriya

final class PaletteLayoutPlacementTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1600, height: 900)

    func testTopMatchesTheOriginalPlace() {
        XCTAssertEqual(PaletteLayout.frame(height: 300, in: screen, placement: .top, pointer: .zero, saved: nil), PaletteLayout.frame(height: 300, in: screen))
    }

    func testCenterKeepsTheTopStillWhileItGrows() {
        let small = PaletteLayout.frame(height: 132, in: screen, placement: .center, pointer: .zero, saved: nil)
        let big = PaletteLayout.frame(height: 500, in: screen, placement: .center, pointer: .zero, saved: nil)
        XCTAssertEqual(small.maxY, big.maxY, accuracy: 0.5)
        XCTAssertEqual(small.midX, 800, accuracy: 0.5)
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
