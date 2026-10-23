import XCTest
@testable import Kriya

final class TreemapTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)

    func testTilesFillTheBoundsAndStayInside() {
        let items = (1...12).map { Treemap.Item(id: "i\($0)", size: Double($0 * 10)) }
        let tiles = Treemap.layout(items, in: bounds)
        XCTAssertEqual(tiles.count, 12)
        XCTAssertEqual(tiles.reduce(0) { $0 + $1.rect.width * $1.rect.height }, bounds.width * bounds.height, accuracy: 1)
        for t in tiles { XCTAssertTrue(bounds.insetBy(dx: -0.01, dy: -0.01).contains(t.rect), "\(t)") }
    }

    func testAreaFollowsSize() {
        let tiles = Treemap.layout([Treemap.Item(id: "big", size: 300), Treemap.Item(id: "small", size: 100)], in: bounds)
        let big = tiles.first { $0.id == "big" }!.rect, small = tiles.first { $0.id == "small" }!.rect
        XCTAssertEqual(big.width * big.height / (small.width * small.height), 3, accuracy: 0.01)
    }

    func testNoTwoTilesOverlap() {
        let items = (1...20).map { Treemap.Item(id: "i\($0)", size: Double(1 + ($0 * 37) % 90)) }
        let tiles = Treemap.layout(items, in: bounds)
        for (i, a) in tiles.enumerated() { for b in tiles[(i + 1)...] {
            let both = a.rect.intersection(b.rect)
            XCTAssertTrue(both.isNull || both.width * both.height < 0.5, "\(a.id) overlaps \(b.id)")
        } }
    }

    func testEmptyAndZeroSizesGiveNothing() {
        XCTAssertTrue(Treemap.layout([], in: bounds).isEmpty)
        XCTAssertTrue(Treemap.layout([Treemap.Item(id: "z", size: 0)], in: bounds).isEmpty)
        XCTAssertTrue(Treemap.layout([Treemap.Item(id: "a", size: 5)], in: .zero).isEmpty)
    }

    func testSmallItemsAreGathered() {
        let items = [Treemap.Item(id: "a", size: 900), Treemap.Item(id: "b", size: 90), Treemap.Item(id: "c", size: 4), Treemap.Item(id: "d", size: 6)]
        let grouped = Treemap.grouped(items)
        XCTAssertEqual(grouped.map(\.id), ["a", "b", "__other__"])
        XCTAssertEqual(grouped.last?.size, 10)
    }
}
