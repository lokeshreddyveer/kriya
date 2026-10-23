import XCTest
@testable import Kriya

final class AudioAndFilterTests: XCTestCase {
    func testVolumeRequestsAreParsed() {
        XCTAssertEqual(AudioMath.request(in: "volume 40"), .set(40))
        XCTAssertEqual(AudioMath.request(in: "vol 40%"), .set(40))
        XCTAssertEqual(AudioMath.request(in: "volume up"), .up)
        XCTAssertEqual(AudioMath.request(in: "volume mute"), .mute)
        XCTAssertNil(AudioMath.request(in: "volumes"))
    }

    func testStepsStayInRange() {
        XCTAssertEqual(AudioMath.stepped(0.99, up: true), 1, accuracy: 0.0001)
        XCTAssertEqual(AudioMath.stepped(0.01, up: false), 0, accuracy: 0.0001)
    }

    func testFiltersChangeText() {
        XCTAssertEqual(TextFilter.upper.apply(to: "ab"), "AB")
        XCTAssertEqual(TextFilter.sortLines.apply(to: "b\na"), "a\nb")
        XCTAssertEqual(TextFilter.uniqueLines.apply(to: "a\na\nb"), "a\nb")
        XCTAssertEqual(TextFilter.numbered.apply(to: "a\nb"), "1. a\n2. b")
    }

    func testDoubleTapWindow() {
        let now = Date()
        XCTAssertTrue(ClipboardMerge.isDoubleTap(first: now, second: now.addingTimeInterval(0.2)))
        XCTAssertFalse(ClipboardMerge.isDoubleTap(first: now, second: now.addingTimeInterval(1)))
        XCTAssertFalse(ClipboardMerge.isDoubleTap(first: nil, second: now))
    }

    func testWholeWordRanksAbove() {
        XCTAssertGreaterThan(FuzzyMatcher.score("app", in: "App Store") ?? 0, FuzzyMatcher.score("app", in: "Apple Music") ?? 0)
    }
}
