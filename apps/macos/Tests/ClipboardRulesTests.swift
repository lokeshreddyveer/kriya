import XCTest
@testable import Kriya

final class ClipboardRulesTests: XCTestCase {
    func testTrackingIsRemovedAndTheRestKept() {
        XCTAssertEqual(LinkCleaner.cleanLink("https://example.com/a?utm_source=x&id=5&fbclid=abc"), "https://example.com/a?id=5")
        XCTAssertEqual(LinkCleaner.cleanLink("https://example.com/a?utm_source=x&gclid=1"), "https://example.com/a")
        XCTAssertEqual(LinkCleaner.cleanLink("https://example.com/a?q=swift"), "https://example.com/a?q=swift")
        XCTAssertEqual(LinkCleaner.clean("see https://x.com/p?utm_medium=a. then https://y.com/?igshid=2 done"), "see https://x.com/p. then https://y.com/ done")
        XCTAssertEqual(LinkCleaner.clean("no links here"), "no links here")
    }

    func testRulesApplyOnlyToTheirApps() {
        let rule = ClipboardRule(name: "Mail", apps: ["com.apple.mail"], actions: [.trimEnds, .upper])
        XCTAssertEqual(ClipboardRules.apply([rule], to: "  hi  ", sourceApp: "com.apple.mail").text, "HI")
        XCTAssertFalse(ClipboardRules.apply([rule], to: "  hi  ", sourceApp: "com.other").changed)
        XCTAssertFalse(ClipboardRules.apply([rule], to: "  hi  ", sourceApp: nil).changed)
        var off = rule; off.enabled = false
        XCTAssertFalse(ClipboardRules.apply([off], to: "x", sourceApp: "com.apple.mail").changed)
    }

    func testPlainTextRuleAsksForFormattingToGoEvenIfWordsStaySame() {
        let rule = ClipboardRule(name: "Plain", actions: [.plainText])
        let outcome = ClipboardRules.apply([rule], to: "same", sourceApp: nil)
        XCTAssertFalse(outcome.changed)
        XCTAssertTrue(outcome.wantsPlain)
    }

    func testStorePersists() {
        let d = UserDefaults(suiteName: "kriya.test.\(UUID().uuidString)")!
        let store = ClipboardRuleStore(defaults: d)
        store.rules = [ClipboardRule(name: "A", actions: [.stripTracking])]
        XCTAssertEqual(ClipboardRuleStore(defaults: d).rules.map(\.name), ["A"])
    }
}
