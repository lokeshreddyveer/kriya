import XCTest
@testable import Kriya

final class LayoutDesignTests: XCTestCase {
    func testSnappingToAGrid() {
        XCTAssertEqual(LayoutDesign.snap(0.26, grid: 4), 0.25, accuracy: 0.0001)
        XCTAssertEqual(LayoutDesign.snap(0.99, grid: 4), 1, accuracy: 0.0001)
        XCTAssertEqual(LayoutDesign.snap(0.333, grid: 0), 0.333, accuracy: 0.0001, "no grid, no change")
    }

    func testADragMakesABoxInEitherDirectionAndStaysOnTheDisplay() {
        let size = CGSize(width: 400, height: 200)
        let forward = LayoutDesign.rect(from: CGPoint(x: 100, y: 50), to: CGPoint(x: 300, y: 150), in: size, grid: 0)
        let backward = LayoutDesign.rect(from: CGPoint(x: 300, y: 150), to: CGPoint(x: 100, y: 50), in: size, grid: 0)
        XCTAssertEqual(forward, backward)
        XCTAssertEqual(forward.minX, 0.25, accuracy: 0.001)
        XCTAssertEqual(forward.width, 0.5, accuracy: 0.001)
        let past = LayoutDesign.rect(from: CGPoint(x: 300, y: 100), to: CGPoint(x: 900, y: 900), in: size, grid: 0)
        XCTAssertLessThanOrEqual(past.maxX, 1.0001)
        XCTAssertLessThanOrEqual(past.maxY, 1.0001)
        XCTAssertEqual(LayoutDesign.rect(from: .zero, to: CGPoint(x: 5, y: 5), in: .zero, grid: 0), .zero)
    }

    func testABoxIsNeverTooSmallOrOffTheDisplay() {
        let tiny = LayoutDesign.clamp(CGRect(x: 0.5, y: 0.5, width: 0.001, height: 0.001))
        XCTAssertGreaterThanOrEqual(tiny.width, LayoutDesign.minimumSize)
        let off = LayoutDesign.clamp(CGRect(x: 0.9, y: 0.95, width: 0.5, height: 0.5))
        XCTAssertLessThanOrEqual(off.maxX, 1.0001)
        XCTAssertLessThanOrEqual(off.maxY, 1.0001)
        XCTAssertGreaterThanOrEqual(off.minX, 0)
    }

    func testResizingKeepsTheOppositeCornerStill() {
        let box = CGRect(x: 0.2, y: 0.2, width: 0.4, height: 0.4)
        let bigger = LayoutDesign.resized(box, corner: .bottomRight, to: CGPoint(x: 0.9, y: 0.8), grid: 0)
        XCTAssertEqual(bigger.minX, 0.2, accuracy: 0.001)
        XCTAssertEqual(bigger.minY, 0.2, accuracy: 0.001)
        XCTAssertEqual(bigger.maxX, 0.9, accuracy: 0.001)
        let fromTop = LayoutDesign.resized(box, corner: .topLeft, to: CGPoint(x: 0.1, y: 0.0), grid: 0)
        XCTAssertEqual(fromTop.maxX, 0.6, accuracy: 0.001)
        XCTAssertEqual(fromTop.maxY, 0.6, accuracy: 0.001)
        let crushed = LayoutDesign.resized(box, corner: .bottomRight, to: CGPoint(x: 0.2, y: 0.2), grid: 0)
        XCTAssertGreaterThanOrEqual(crushed.width, LayoutDesign.minimumSize)
        XCTAssertGreaterThanOrEqual(crushed.height, LayoutDesign.minimumSize)
    }

    func testMovingStopsAtTheEdges() {
        let box = CGRect(x: 0.5, y: 0.5, width: 0.4, height: 0.4)
        let right = LayoutDesign.moved(box, by: CGSize(width: 0.9, height: -0.9), grid: 0)
        XCTAssertEqual(right.maxX, 1, accuracy: 0.001)
        XCTAssertEqual(right.minY, 0, accuracy: 0.001)
        XCTAssertEqual(right.size, box.size)
    }

    func testEveryStartingPointFillsTheDisplayWithoutLeavingIt() {
        for template in LayoutDesign.Template.allCases {
            XCTAssertFalse(template.rects.isEmpty)
            for rect in template.rects {
                XCTAssertGreaterThanOrEqual(rect.minX, 0, template.rawValue)
                XCTAssertLessThanOrEqual(rect.maxX, 1.0001, template.rawValue)
                XCTAssertLessThanOrEqual(rect.maxY, 1.0001, template.rawValue)
            }
        }
        XCTAssertEqual(LayoutDesign.Template.thirds.rects.count, 3)
        XCTAssertEqual(LayoutDesign.Template.grid.rects.count, 6)
    }

    func testOverlapsAreFoundButTouchingEdgesAreNot() {
        let touching = [DesignRegion(rect: CGRect(x: 0, y: 0, width: 0.5, height: 1)), DesignRegion(rect: CGRect(x: 0.5, y: 0, width: 0.5, height: 1))]
        XCTAssertTrue(LayoutDesign.overlaps(touching).isEmpty)
        let covering = [DesignRegion(rect: CGRect(x: 0, y: 0, width: 0.6, height: 1)), DesignRegion(rect: CGRect(x: 0.4, y: 0, width: 0.6, height: 1))]
        XCTAssertEqual(LayoutDesign.overlaps(covering).count, 1)
    }

    func testWhyALayoutCannotBeSavedYet() {
        let withApp = DesignRegion(rect: CGRect(x: 0, y: 0, width: 0.5, height: 1), appID: "com.apple.Safari")
        XCTAssertNotNil(LayoutDesign.problem(name: "", regions: [withApp]))
        XCTAssertNotNil(LayoutDesign.problem(name: "Work", regions: []))
        XCTAssertNotNil(LayoutDesign.problem(name: "Work", regions: [DesignRegion(rect: withApp.rect)]), "a box needs an app")
        XCTAssertNil(LayoutDesign.problem(name: "Work", regions: [withApp]))
    }

    func testALayoutSurvivesBeingDrawnAndOpenedAgain() {
        var first = DesignRegion(rect: CGRect(x: 0, y: 0, width: 0.7, height: 1), appID: "com.apple.Safari")
        first.title = "Docs"
        let second = DesignRegion(rect: CGRect(x: 0.7, y: 0, width: 0.3, height: 1), appID: "com.apple.Notes")
        let entries = LayoutDesign.entries(from: [first, second], displayID: "d1")
        XCTAssertEqual(entries.map(\.appId), ["com.apple.Safari", "com.apple.Notes"])
        XCTAssertEqual(entries[0].title, "Docs")
        XCTAssertEqual(entries[1].frame.x, 0.7, accuracy: 0.0001)
        let back = LayoutDesign.regions(from: entries + [LayoutEntry(appId: "x", title: "", displayId: "d2", frame: Rect(x: 0, y: 0, width: 1, height: 1))], displayID: "d1")
        XCTAssertEqual(back.count, 2, "only the boxes on that display")
        XCTAssertEqual(back[0].appID, "com.apple.Safari")
        XCTAssertEqual(back[0].rect.width, 0.7, accuracy: 0.0001)
    }
}
