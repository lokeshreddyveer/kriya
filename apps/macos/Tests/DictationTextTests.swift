import XCTest
@testable import Kriya

final class DictationTextTests: XCTestCase {
    func testSpokenPunctuationBecomesPunctuation() {
        XCTAssertEqual(DictationText.process("hello comma how are you question mark"), "Hello, how are you?")
        XCTAssertEqual(DictationText.process("first line new line second line period"), "First line\nSecond line.")
        XCTAssertEqual(DictationText.process("one new paragraph two"), "One\n\nTwo")
    }

    func testSentencesGetCapitals() {
        XCTAssertEqual(DictationText.process("it works. really? yes"), "It works. Really? Yes")
    }

    func testPlainTextAndEmptyInput() {
        XCTAssertEqual(DictationText.process("  the period of time  ", spokenPunctuation: false), "The period of time")
        XCTAssertEqual(DictationText.process("   "), "")
    }
}
