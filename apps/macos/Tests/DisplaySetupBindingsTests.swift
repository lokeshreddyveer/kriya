import XCTest
@testable import Kriya

final class DisplaySetupBindingsTests: XCTestCase {
    private func make() -> DisplaySetupBindings { DisplaySetupBindings(defaults: UserDefaults(suiteName: "kriya.test.\(UUID().uuidString)")!) }

    func testBindToggleAndReplace() {
        let b = make()
        b.toggle(layout: "a", setup: "docked")
        XCTAssertEqual(b.layoutID(forSetup: "docked"), "a")
        b.toggle(layout: "b", setup: "docked")
        XCTAssertEqual(b.layoutID(forSetup: "docked"), "b", "one layout per setup")
        b.toggle(layout: "b", setup: "docked")
        XCTAssertNil(b.layoutID(forSetup: "docked"))
    }

    func testPruneDropsDeletedLayouts() {
        let b = make()
        b.toggle(layout: "a", setup: "x"); b.toggle(layout: "b", setup: "y")
        b.prune(existing: ["b"])
        XCTAssertNil(b.layoutID(forSetup: "x"))
        XCTAssertEqual(b.layoutID(forSetup: "y"), "b")
    }
}
