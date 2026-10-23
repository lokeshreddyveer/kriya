import XCTest
@testable import Kriya

final class SnippetPreprocessorTests: XCTestCase {
    private func env(_ snippets: [String: String] = [:]) -> SnippetPreprocessor.Environment {
        var e = SnippetPreprocessor.Environment()
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        e.calendar = cal
        e.now = Date(timeIntervalSince1970: 1_710_460_800)   // Friday 2024-03-15
        e.snippet = { snippets[$0] }
        e.counter = { _ in 7 }
        e.clipboard = "Hello World"
        e.random = { $0.lowerBound }
        return e
    }

    func testNestedSnippetsResolveAndStopAtCycles() {
        XCTAssertEqual(SnippetPreprocessor.process("Hi {snippet:sig}", env(["sig": "Best, {snippet:name}", "name": "Lokesh"])), "Hi Best, Lokesh")
        XCTAssertEqual(SnippetPreprocessor.process("{snippet:a}", env(["a": "x{snippet:a}"])), "x{snippet:a}", "a snippet that includes itself is left alone")
        XCTAssertEqual(SnippetPreprocessor.process("{snippet:none}", env()), "{snippet:none}")
    }

    func testWorkdaysSkipWeekends() {
        XCTAssertEqual(SnippetPreprocessor.process("{workday+1}", env()), "2024-03-18", "Friday plus one working day is Monday")
        XCTAssertEqual(SnippetPreprocessor.process("{workday+5:d MMM}", env()), "22 Mar")
        XCTAssertEqual(SnippetPreprocessor.process("{workday-1}", env()), "2024-03-14")
    }

    func testRandomCounterAndClipboardFilters() {
        XCTAssertEqual(SnippetPreprocessor.process("{random:5-9}", env()), "5")
        XCTAssertEqual(SnippetPreprocessor.process("{random:9-5}", env()), "{random:9-5}")
        XCTAssertEqual(SnippetPreprocessor.process("INV-{counter:invoice}", env()), "INV-7")
        XCTAssertEqual(SnippetPreprocessor.process("{clipboard:upper} {clipboard:snake} {clipboard:nothing}", env()), "HELLO WORLD hello_world {clipboard:nothing}")
    }

    func testLiteralBracesAndOtherPlaceholdersSurvive() {
        XCTAssertEqual(SnippetPreprocessor.process("{{snippet:a}} {date} {cursor}", env(["a": "x"])), "{{snippet:a}} {date} {cursor}")
    }

    func testCountersAdvanceOncePerInsert() {
        let d = UserDefaults(suiteName: "kriya.test.\(UUID().uuidString)")!
        XCTAssertEqual(SnippetCounters.peek("n", defaults: d), 1)
        SnippetCounters.advance(in: "{counter:n} and {counter:n}", defaults: d)
        XCTAssertEqual(SnippetCounters.peek("n", defaults: d), 2)
    }
}
