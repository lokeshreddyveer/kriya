import XCTest
@testable import Kriya

final class FocusSessionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    func testStartsOnlyWhatIsNeededAndRemembersIt() {
        var c = FocusSessionConfig(); c.quitAppIDs = ["com.slack"]; c.startShortcut = "On"; c.endShortcut = "Off"; c.minutes = 30
        let plan = FocusPlan.start(c, dockHidden: false, desktopIconsShown: true, now: now)
        XCTAssertEqual(plan.steps, [.setDockHidden(true), .setDesktopIcons(false), .quit("com.slack"), .shortcut("On")])
        XCTAssertEqual(plan.state.endsAt, now.addingTimeInterval(1800))
        XCTAssertEqual(FocusPlan.end(plan.state), [.setDockHidden(false), .setDesktopIcons(true), .shortcut("Off")])
    }

    func testSettingsAlreadyAsWantedAreLeftAlone() {
        let plan = FocusPlan.start(FocusSessionConfig(), dockHidden: true, desktopIconsShown: false, now: now)
        XCTAssertTrue(plan.steps.isEmpty)
        XCTAssertTrue(FocusPlan.end(plan.state).isEmpty, "ending must not undo what the person had set themselves")
    }

    func testMinutesAreKeptInRange() {
        var c = FocusSessionConfig(); c.minutes = 9999
        XCTAssertEqual(c.clamped.minutes, 480)
        c.minutes = 0
        XCTAssertEqual(c.clamped.minutes, 1)
    }

    func testRemainingAndRequests() {
        XCTAssertEqual(FocusPlan.remaining(until: now.addingTimeInterval(1450), now: now), "24:10 left")
        XCTAssertEqual(FocusPlan.remaining(until: now.addingTimeInterval(7500), now: now), "2 h 05 m left")
        XCTAssertEqual(FocusPlan.request("focus"), .start(nil))
        XCTAssertEqual(FocusPlan.request("focus 45"), .start(45))
        XCTAssertEqual(FocusPlan.request("focus 45m"), .start(45))
        XCTAssertEqual(FocusPlan.request("focus off"), .stop)
        XCTAssertNil(FocusPlan.request("focus abc"))
        XCTAssertNil(FocusPlan.request("hello"))
    }
}
