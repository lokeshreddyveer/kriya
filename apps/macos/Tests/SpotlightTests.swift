import XCTest
@testable import Kriya

final class SpotlightTests: XCTestCase {
    func testTheBrightAreaIsCenteredOnThePointer() {
        let circle = SpotlightGeometry.hole(center: CGPoint(x: 500, y: 300), size: 200, shape: .circle)
        XCTAssertEqual(circle, CGRect(x: 400, y: 200, width: 200, height: 200))
        let wide = SpotlightGeometry.hole(center: CGPoint(x: 500, y: 300), size: 200, shape: .roundedRectangle)
        XCTAssertEqual(wide.midX, 500, accuracy: 0.001)
        XCTAssertEqual(wide.midY, 300, accuracy: 0.001)
        XCTAssertGreaterThan(wide.width, wide.height, "the rectangle is wider than it is tall")
    }

    func testACircleHasFullyRoundedEndsAndARectangleSoftCorners() {
        let circle = SpotlightGeometry.hole(center: .zero, size: 200, shape: .circle)
        XCTAssertEqual(SpotlightGeometry.cornerRadius(for: circle, shape: .circle), 100)
        let wide = SpotlightGeometry.hole(center: .zero, size: 900, shape: .roundedRectangle)
        XCTAssertLessThanOrEqual(SpotlightGeometry.cornerRadius(for: wide, shape: .roundedRectangle), 28, "corners stay soft, however large it is")
    }

    func testOnlyTheOutsideIsDimmed() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let path = SpotlightGeometry.dimPath(bounds: bounds, hole: SpotlightGeometry.hole(center: CGPoint(x: 500, y: 300), size: 200, shape: .circle), shape: .circle)
        XCTAssertFalse(path.contains(CGPoint(x: 500, y: 300), using: .evenOdd), "the pointer is in the bright part")
        XCTAssertFalse(path.contains(CGPoint(x: 590, y: 300), using: .evenOdd), "still inside the circle")
        XCTAssertTrue(path.contains(CGPoint(x: 700, y: 300), using: .evenOdd), "outside is dark")
        XCTAssertTrue(path.contains(CGPoint(x: 405, y: 205), using: .evenOdd), "the corner of the circle's square is dark")
        XCTAssertTrue(path.contains(CGPoint(x: 10, y: 10), using: .evenOdd))
    }

    func testADisplayThePointerIsNotOnIsDimmedCompletely() {
        let other = CGRect(x: 0, y: 0, width: 1000, height: 600)
        // The pointer is 3000 points to the left of this display: the bright area does not reach it.
        let far = SpotlightGeometry.hole(center: CGPoint(x: -3000, y: 300), size: 300, shape: .circle)
        let path = SpotlightGeometry.dimPath(bounds: other, hole: far, shape: .circle)
        XCTAssertTrue(path.contains(CGPoint(x: 500, y: 300), using: .evenOdd))
        XCTAssertTrue(path.contains(CGPoint(x: 5, y: 300), using: .evenOdd))
    }

    func testABrightAreaOverTheEdgeLightsBothDisplays() {
        // The pointer sits on the right edge of the left display (x=1000), so the next display, which starts at 1000, sees half of it.
        let left = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let right = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let onLeft = SpotlightGeometry.dimPath(bounds: left, hole: SpotlightGeometry.hole(center: CGPoint(x: 1000, y: 300), size: 300, shape: .circle), shape: .circle)
        let onRight = SpotlightGeometry.dimPath(bounds: right, hole: SpotlightGeometry.hole(center: CGPoint(x: 0, y: 300), size: 300, shape: .circle), shape: .circle)
        XCTAssertFalse(onLeft.contains(CGPoint(x: 950, y: 300), using: .evenOdd))
        XCTAssertFalse(onRight.contains(CGPoint(x: 50, y: 300), using: .evenOdd))
        XCTAssertTrue(onLeft.contains(CGPoint(x: 700, y: 300), using: .evenOdd))
    }

    func testTheSpotlightIsACommandSoItCanHaveAShortcut() {
        XCTAssertTrue(PointerEffects.commands.contains { $0.command == "pointer.spotlight" })
        XCTAssertTrue(PointerEffects.commands.contains { $0.command == "pointer.presentation" })
    }

    func testTheSpotlightSettingsAreSavedAndKeptInBounds() throws {
        let world = try TestWorld()
        defer { world.cleanUp() }
        let store = PointerEffectsStore(core: world.core)
        XCTAssertEqual(store.config.spotlightShape, .circle)
        store.update { $0.spotlightShape = .roundedRectangle; $0.spotlightSize = 5000; $0.spotlightDim = 0 }
        let reloaded = PointerEffectsStore(core: world.core)
        XCTAssertEqual(reloaded.config.spotlightShape, .roundedRectangle)
        XCTAssertEqual(reloaded.config.spotlightSize, 900)
        XCTAssertEqual(reloaded.config.spotlightDim, 0.1, accuracy: 0.0001)
    }
}
