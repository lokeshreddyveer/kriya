import XCTest
@testable import Kriya

final class LauncherAppearanceTests: XCTestCase {
    func testEveryThemeHasAUsableLook() {
        for theme in LauncherTheme.allCases {
            XCTAssertFalse(theme.title.isEmpty)
            if case .solid(let r, let g, let b) = theme.background { XCTAssertTrue([r, g, b].allSatisfy { (0...1).contains($0) }) }
        }
        XCTAssertEqual(LauncherTheme.glass.appearance, .system)
        XCTAssertEqual(LauncherTheme.paper.appearance, .light, "a light flat colour needs dark text")
        XCTAssertEqual(LauncherTheme.midnight.appearance, .dark)
    }

    func testAccentsAreColoursExceptNeutral() {
        XCTAssertNil(LauncherAccent.neutral.rgb)
        for accent in LauncherAccent.allCases where accent != .neutral { XCTAssertNotNil(accent.rgb) }
    }

    func testChoicesAreRemembered() {
        let theme = LauncherTheme.current, accent = LauncherAccent.current
        defer { LauncherTheme.current = theme; LauncherAccent.current = accent }
        LauncherTheme.current = .graphite; LauncherAccent.current = .purple
        XCTAssertEqual(LauncherTheme.current, .graphite)
        XCTAssertEqual(LauncherAccent.current, .purple)
    }
}
