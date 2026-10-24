import XCTest
@testable import Kriya

/// Choosing an area: dragging, fixed shapes, centre-out, snapping and the keyboard. Numbers only; no screen is needed.
final class SelectionGeometryTests: XCTestCase {
    func testADragGivesTheSameAreaInEveryDirection() {
        let a = CGPoint(x: 100, y: 100)
        XCTAssertEqual(SelectionGeometry.rect(from: a, to: CGPoint(x: 160, y: 130)), CGRect(x: 100, y: 100, width: 60, height: 30))
        XCTAssertEqual(SelectionGeometry.rect(from: a, to: CGPoint(x: 40, y: 70)), CGRect(x: 40, y: 70, width: 60, height: 30))
        XCTAssertEqual(SelectionGeometry.rect(from: a, to: CGPoint(x: 160, y: 70)), CGRect(x: 100, y: 70, width: 60, height: 30))
        XCTAssertEqual(SelectionGeometry.rect(from: a, to: a), CGRect(x: 100, y: 100, width: 0, height: 0))
    }

    func testHoldingOptionGrowsTheAreaFromTheCentre() {
        let r = SelectionGeometry.rect(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 130, y: 120), fromCenter: true)
        XCTAssertEqual(r, CGRect(x: 70, y: 80, width: 60, height: 40))
        XCTAssertEqual(CGPoint(x: r.midX, y: r.midY), CGPoint(x: 100, y: 100), "the anchor stays in the middle")
    }

    func testAFixedShapeKeepsItsRatioWhicheverWayYouPull() {
        let anchor = CGPoint(x: 0, y: 0)
        var r = SelectionGeometry.rect(from: anchor, to: CGPoint(x: 100, y: 30), ratio: 1)
        XCTAssertEqual(r.size, CGSize(width: 100, height: 100), "a square follows the bigger pull")
        r = SelectionGeometry.rect(from: anchor, to: CGPoint(x: -100, y: 30), ratio: 1)
        XCTAssertEqual(r, CGRect(x: -100, y: 0, width: 100, height: 100), "and goes the way you pulled")
        r = SelectionGeometry.rect(from: anchor, to: CGPoint(x: 160, y: 10), ratio: 16.0 / 9.0)
        XCTAssertEqual(r.width, 160, accuracy: 0.001); XCTAssertEqual(r.height, 90, accuracy: 0.001)
        r = SelectionGeometry.rect(from: anchor, to: CGPoint(x: 10, y: 90), ratio: 16.0 / 9.0)
        XCTAssertEqual(r.height / r.width, 9.0 / 16.0, accuracy: 0.001, "pulling down mostly still gives the shape")
        r = SelectionGeometry.rect(from: CGPoint(x: 50, y: 50), to: CGPoint(x: 70, y: 60), fromCenter: true, ratio: 1)
        XCTAssertEqual(r, CGRect(x: 30, y: 30, width: 40, height: 40), "centre-out and a fixed shape together")
    }

    func testTheShapesGoRound() {
        var shape = SelectionGeometry.shapes[0]
        var seen: [String] = []
        for _ in 0..<SelectionGeometry.shapes.count { seen.append(shape.id); shape = SelectionGeometry.nextShape(after: shape) }
        XCTAssertEqual(seen, SelectionGeometry.shapes.map(\.id))
        XCTAssertEqual(shape, SelectionGeometry.shapes[0], "after the last, free again")
        XCTAssertNil(SelectionGeometry.shapes[0].ratio)
    }

    func testAnAreaIsKeptOnTheScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        XCTAssertEqual(SelectionGeometry.clamped(CGRect(x: 950, y: -20, width: 100, height: 100), to: screen), CGRect(x: 900, y: 0, width: 100, height: 100))
        XCTAssertEqual(SelectionGeometry.clamped(CGRect(x: -50, y: 0, width: 2000, height: 100), to: screen), CGRect(x: 0, y: 0, width: 1000, height: 100))
    }

    func testEdgesSnapToTheScreenAndWindowsWhenCloseAndNotOtherwise() {
        let (xs, ys) = SelectionGeometry.edges(display: CGRect(x: 0, y: 0, width: 200, height: 100), windows: [CGRect(x: 50, y: 20, width: 100, height: 60)])
        XCTAssertEqual(xs, [0, 50, 150, 200])
        XCTAssertEqual(ys, [0, 20, 80, 100])
        let near = SelectionGeometry.snapped(CGRect(x: 3, y: 22, width: 195, height: 55), xs: xs, ys: ys)
        XCTAssertEqual(near, CGRect(x: 0, y: 20, width: 200, height: 60), "both ends snap, so the size changes too: 3→0, 198→200, 22→20, 77→80")
        let far = SelectionGeometry.snapped(CGRect(x: 20, y: 40, width: 100, height: 20), xs: xs, ys: ys)
        XCTAssertEqual(far, CGRect(x: 20, y: 40, width: 100, height: 20), "nothing within reach: untouched")
        let pick = SelectionGeometry.snapped(CGRect(x: 47, y: 0, width: 10, height: 10), xs: [45, 50], ys: [], distance: 6)
        XCTAssertEqual(pick.minX, 45, "the nearer of two candidates wins: 47 is 2 from 45 and 3 from 50")
    }

    func testCommonSizesAreRecognisedWithinAFewPoints() {
        XCTAssertEqual(SelectionGeometry.commonSize(for: CGRect(x: 0, y: 0, width: 1918, height: 1083)), CGSize(width: 1920, height: 1080))
        XCTAssertNil(SelectionGeometry.commonSize(for: CGRect(x: 0, y: 0, width: 1900, height: 1080)))
        XCTAssertNil(SelectionGeometry.commonSize(for: CGRect(x: 0, y: 0, width: 1920, height: 1000)), "both directions must be close")
    }

    func testTheKeyboardMovesAndResizesWithinTheScreen() {
        let screen = CGRect(x: 0, y: 0, width: 400, height: 300)
        let start = CGRect(x: 100, y: 100, width: 100, height: 50)
        XCTAssertEqual(SelectionGeometry.moved(start, dx: 1, dy: 0, within: screen), CGRect(x: 101, y: 100, width: 100, height: 50))
        XCTAssertEqual(SelectionGeometry.moved(start, dx: 10, dy: -10, within: screen), CGRect(x: 110, y: 90, width: 100, height: 50))
        XCTAssertEqual(SelectionGeometry.moved(start, dx: 1000, dy: 1000, within: screen), CGRect(x: 300, y: 250, width: 100, height: 50), "it stops at the edge")
        XCTAssertEqual(SelectionGeometry.resized(start, dw: 10, dh: 0, within: screen), CGRect(x: 100, y: 100, width: 110, height: 50))
        XCTAssertEqual(SelectionGeometry.resized(start, dw: -1000, dh: -1000, within: screen).size, CGSize(width: 8, height: 8), "never smaller than the minimum")
        XCTAssertEqual(SelectionGeometry.resized(start, dw: 1000, dh: 1000, within: screen), CGRect(x: 100, y: 100, width: 300, height: 200), "never past the edge")
        let kept = SelectionGeometry.resized(CGRect(x: 0, y: 0, width: 160, height: 90), dw: 16, dh: 0, within: screen, ratio: 16.0 / 9.0)
        XCTAssertEqual(kept.width / kept.height, 16.0 / 9.0, accuracy: 0.001, "a fixed shape stays that shape")
        let pinned = SelectionGeometry.resized(CGRect(x: 0, y: 250, width: 160, height: 40), dw: 100, dh: 0, within: screen, ratio: 4)
        XCTAssertEqual(pinned.width / pinned.height, 4, accuracy: 0.001, "even when an edge stops it")
        XCTAssertTrue(SelectionGeometry.isUsable(CGRect(x: 0, y: 0, width: 8, height: 8)))
        XCTAssertFalse(SelectionGeometry.isUsable(CGRect(x: 0, y: 0, width: 7, height: 100)))
    }

    func testAnAreaBecomesTheRightPartOfAPicture() {
        let area = CGRect(x: 10, y: 20, width: 100, height: 50)
        XCTAssertEqual(SelectionGeometry.cropRect(for: area, scale: 2, displayHeight: 300, topLeft: true), CGRect(x: 20, y: 40, width: 200, height: 100))
        // From the bottom: the area's top edge is 300 − 70 = 230 points from the top.
        XCTAssertEqual(SelectionGeometry.cropRect(for: area, scale: 2, displayHeight: 300, topLeft: false), CGRect(x: 20, y: 460, width: 200, height: 100))
        XCTAssertEqual(SelectionGeometry.cropRect(for: area, scale: 1, displayHeight: 300, topLeft: true), CGRect(x: 10, y: 20, width: 100, height: 50))
    }

    func testTheSizeLabelShowsPixelsOnlyWhenTheyDiffer() {
        XCTAssertEqual(SelectionGeometry.sizeLabel(CGRect(x: 0, y: 0, width: 640, height: 480), scale: 1), "640 × 480")
        XCTAssertEqual(SelectionGeometry.sizeLabel(CGRect(x: 0, y: 0, width: 640, height: 480), scale: 2), "640 × 480  (1280 × 960 px)")
    }
}
