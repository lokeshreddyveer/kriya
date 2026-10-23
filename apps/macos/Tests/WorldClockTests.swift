import XCTest
@testable import Kriya

final class WorldClockTests: XCTestCase {
    private let tokyo = TimeZone(identifier: "Asia/Tokyo")!
    private let ny = TimeZone(identifier: "America/New_York")!
    private let date = Date(timeIntervalSince1970: 1_700_000_000)   // 2023-11-14 22:13:20 UTC

    func testTimeFormats() {
        XCTAssertEqual(WorldClockFormat.time(date, in: tokyo, twentyFourHour: true), "07:13")
        XCTAssertEqual(WorldClockFormat.time(date, in: ny, twentyFourHour: false), "5:13 PM")
        XCTAssertEqual(WorldClockFormat.time(date, in: tokyo, twentyFourHour: true, seconds: true), "07:13:20")
    }

    func testDayAndDifference() {
        XCTAssertEqual(WorldClockFormat.dayDelta(date, in: tokyo, from: ny), 1)
        XCTAssertEqual(WorldClockFormat.dayWord(1), "Tomorrow")
        XCTAssertEqual(WorldClockFormat.difference(date, in: tokyo, from: ny), "+14 h")
        XCTAssertEqual(WorldClockFormat.difference(date, in: TimeZone(identifier: "Asia/Kolkata")!, from: TimeZone(identifier: "UTC")!), "+5 h 30 m")
        XCTAssertEqual(WorldClockFormat.difference(date, in: ny, from: ny), "Same time")
    }

    func testBarTextAndLabels() {
        let places = [ClockPlace(label: "TYO", zoneID: "Asia/Tokyo"), ClockPlace(label: "NYC", zoneID: "America/New_York"), ClockPlace(label: "BAD", zoneID: "Nowhere/Land")]
        XCTAssertEqual(WorldClockFormat.barText(places, date: date, twentyFourHour: true), "TYO 07:13   NYC 17:13")
        XCTAssertEqual(WorldClockFormat.defaultLabel(for: "new york"), "NEW")
    }
}
