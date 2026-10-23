import XCTest
@testable import Kriya

final class UnitConverterTests: XCTestCase {
    func testCommonConversionsAreRight() {
        XCTAssertEqual(UnitConverter.convert("5 km to mi")?.copy, "3.1069")
        XCTAssertEqual(UnitConverter.convert("1 mile in km")?.copy, "1.6093")
        XCTAssertEqual(UnitConverter.convert("2.5 kg as lb")?.copy, "5.5116")
        XCTAssertEqual(UnitConverter.convert("1 gal to l")?.copy, "3.7854")
        XCTAssertEqual(UnitConverter.convert("1 gb to mb")?.copy, "1000")
        XCTAssertEqual(UnitConverter.convert("1 gib to mib")?.copy, "1024")
        XCTAssertEqual(UnitConverter.convert("90 min to h")?.copy, "1.5")
        XCTAssertEqual(UnitConverter.convert("60 mph to km/h")?.copy, "96.5606")
    }

    func testTemperaturesUseTheirOwnFormulas() {
        XCTAssertEqual(UnitConverter.convert("100 f in c")?.copy, "37.7778")
        XCTAssertEqual(UnitConverter.convert("0 c to f")?.copy, "32")
        XCTAssertEqual(UnitConverter.convert("0 c to k")?.copy, "273.15")
        XCTAssertEqual(UnitConverter.convert("-40 f to c")?.copy, "-40")
    }

    func testThingsThatAreNotConversionsAreLeftAlone() {
        XCTAssertNil(UnitConverter.convert("5 km to kg"), "different kinds of thing")
        XCTAssertNil(UnitConverter.convert("5 foo to bar"))
        XCTAssertNil(UnitConverter.convert("hello to world"))
        XCTAssertNil(UnitConverter.convert("12*8"))
        XCTAssertNil(UnitConverter.convert(String(repeating: "9", count: 200) + " km to mi"))
    }
}

final class CurrencyTests: XCTestCase {
    func testTheRequestIsParsedAndCodesAreChecked() {
        let ask = CurrencyConverter.parse("100 usd to eur")
        XCTAssertEqual(ask?.amount, 100)
        XCTAssertEqual(ask?.from, "USD")
        XCTAssertEqual(ask?.to, "EUR")
        XCTAssertNil(CurrencyConverter.parse("100 xyz to eur"))
        XCTAssertNil(CurrencyConverter.parse("100 usd to usd"))
        XCTAssertNil(CurrencyConverter.parse("100 km to mi"))
    }

    func testConvertingGoesThroughTheEuro() throws {
        let rates = ["USD": 1.10, "JPY": 160.0]
        XCTAssertEqual(try XCTUnwrap(CurrencyConverter.convert(amount: 110, from: "USD", to: "EUR", rates: rates)), 100, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(CurrencyConverter.convert(amount: 1, from: "EUR", to: "JPY", rates: rates)), 160, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(CurrencyConverter.convert(amount: 11, from: "USD", to: "JPY", rates: rates)), 1600, accuracy: 1e-6)
        XCTAssertNil(CurrencyConverter.convert(amount: 1, from: "USD", to: "GBP", rates: rates), "no rate for it")
        XCTAssertNil(CurrencyConverter.convert(amount: 1, from: "USD", to: "JPY", rates: ["USD": 0, "JPY": 1]))
    }

    func testTheServiceAnswerIsReadCarefully() {
        let good = Data(#"{"amount":1.0,"base":"EUR","date":"2026-10-22","rates":{"USD":1.1,"JPY":160.5,"BAD":-1,"TOOLONG":2}}"#.utf8)
        let parsed = CurrencyConverter.parseRates(good)
        XCTAssertEqual(parsed?.date, "2026-10-22")
        XCTAssertEqual(parsed?.rates["USD"], 1.1)
        XCTAssertNil(parsed?.rates["BAD"], "a rate must be positive")
        XCTAssertNil(parsed?.rates["TOOLONG"])
        XCTAssertNil(CurrencyConverter.parseRates(Data("nope".utf8)))
        XCTAssertNil(CurrencyConverter.parseRates(Data(#"{"rates":{}}"#.utf8)))
    }
}

final class TimeZoneToolTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_792_800_000)   // a fixed moment

    func testAPlaceNameBecomesATimeZone() {
        XCTAssertEqual(TimeZoneTool.zone(named: "Tokyo")?.identifier, "Asia/Tokyo")
        XCTAssertEqual(TimeZoneTool.zone(named: "NYC")?.identifier, "America/New_York")
        XCTAssertEqual(TimeZoneTool.zone(named: "kolkata")?.identifier, "Asia/Kolkata")
        XCTAssertNil(TimeZoneTool.zone(named: "narnia"))
        XCTAssertNil(TimeZoneTool.zone(named: ""))
    }

    func testTimeInAPlaceAndConvertingATimeBetweenPlaces() throws {
        let tokyo = try XCTUnwrap(TimeZoneTool.answer("time in tokyo", now: now))
        XCTAssertTrue(tokyo.subtitle.contains("Tokyo") && tokyo.subtitle.contains("GMT+9"), tokyo.subtitle)
        XCTAssertNotNil(TimeZoneTool.answer("london time", now: now))
        let converted = try XCTUnwrap(TimeZoneTool.answer("3pm london to tokyo", now: now))
        XCTAssertTrue(converted.title.hasSuffix("PM") || converted.title.hasSuffix("AM"))
        XCTAssertNotNil(TimeZoneTool.answer("15:30 nyc in delhi", now: now))
        XCTAssertNil(TimeZoneTool.answer("25pm london to tokyo", now: now))
        XCTAssertNil(TimeZoneTool.answer("time in narnia", now: now))
        XCTAssertNil(TimeZoneTool.answer("hello", now: now))
    }

    func testTheSameClockTimeShiftsByTheRightNumberOfHours() throws {
        // 12:00 in UTC is 21:00 in Tokyo (UTC+9), the same calendar day.
        let r = try XCTUnwrap(TimeZoneTool.answer("12 utc to tokyo", now: now))
        XCTAssertTrue(r.title.contains("9:00 PM"), r.title)
    }
}

final class ColorToolTests: XCTestCase {
    func testColoursAreReadInTheCommonForms() {
        XCTAssertEqual(ColorTool.parse("#ff8800").map { [$0.r, $0.g, $0.b] }, [255, 136, 0])
        XCTAssertEqual(ColorTool.parse("#f80").map { [$0.r, $0.g, $0.b] }, [255, 136, 0])
        XCTAssertEqual(ColorTool.parse("FF8800").map { [$0.r, $0.g, $0.b] }, [255, 136, 0])
        XCTAssertEqual(ColorTool.parse("rgb(1, 2, 3)").map { [$0.r, $0.g, $0.b] }, [1, 2, 3])
        XCTAssertNil(ColorTool.parse("rgb(1, 2, 300)"))
        XCTAssertNil(ColorTool.parse("abc"), "a bare three letters is a word, not a colour")
        XCTAssertNil(ColorTool.parse("#12345"))
        XCTAssertNil(ColorTool.parse("hello"))
    }

    func testConvertingBetweenForms() {
        XCTAssertEqual(ColorTool.hex((255, 136, 0)), "#FF8800")
        XCTAssertEqual(ColorTool.hsl((255, 0, 0)), "hsl(0, 100%, 50%)")
        XCTAssertEqual(ColorTool.hsl((128, 128, 128)), "hsl(0, 0%, 50%)")
        XCTAssertEqual(ColorTool.results(for: "#00f").map(\.title), ["#0000FF", "rgb(0, 0, 255)", "hsl(240, 100%, 50%)"])
    }
}

final class TextToolTests: XCTestCase {
    func testEncodingsRoundTrip() {
        XCTAssertEqual(TextTool.answer("base64 hello").first?.copy, "aGVsbG8=")
        XCTAssertEqual(TextTool.answer("base64 decode aGVsbG8=").first?.copy, "hello")
        XCTAssertEqual(TextTool.answer("b64d aGVsbG8").first?.copy, "hello", "missing padding is forgiven")
        XCTAssertEqual(TextTool.answer("urlencode a b&c").first?.copy, "a%20b%26c")
        XCTAssertEqual(TextTool.answer("urldecode a%20b").first?.copy, "a b")
        XCTAssertTrue(TextTool.answer("base64 decode !!!").isEmpty)
    }

    func testHashesAndCasesAndCounts() {
        XCTAssertEqual(TextTool.answer("sha256 abc").first?.copy, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(TextTool.answer("md5 abc").first?.copy, "900150983cd24fb0d6963f7d28e17f72")
        XCTAssertEqual(TextTool.answer("upper hello world").first?.copy, "HELLO WORLD")
        XCTAssertEqual(TextTool.answer("slug Héllo, Wörld!").first?.copy, "hello-world")
        XCTAssertEqual(TextTool.answer("count one two three").first?.copy, "13 characters, 3 words")
        XCTAssertEqual(TextTool.answer("reverse abc").first?.copy, "cba")
        XCTAssertEqual(TextTool.answer("timestamp 0").first?.copy, "1970-01-01T00:00:00Z")
        XCTAssertTrue(TextTool.answer(#"json {"b":1,"a":[2]}"#).first?.copy.contains("\"a\"") == true)
    }

    func testOrdinaryWordsAreNotTools() {
        XCTAssertTrue(TextTool.answer("hello world").isEmpty)
        XCTAssertTrue(TextTool.answer("upper").isEmpty)
        XCTAssertTrue(TextTool.answer("sha256   ").isEmpty)
        XCTAssertTrue(TextTool.answer("base64 " + String(repeating: "a", count: 6000)).isEmpty)
    }
}

final class GeneratorToolTests: XCTestCase {
    func testAPasswordHasEveryKindOfCharacterAndTheRightLength() {
        for length in [8, 20, 64] {
            let p = GeneratorTool.password(length: length)
            XCTAssertEqual(p.count, length)
            XCTAssertTrue(p.contains { $0.isLowercase } && p.contains { $0.isUppercase } && p.contains { $0.isNumber } && p.contains { "!@#$%^&*-_=+?".contains($0) })
        }
        XCTAssertEqual(GeneratorTool.password(length: 2).count, 8, "never short")
        XCTAssertEqual(GeneratorTool.password(length: 500).count, 64)
        XCTAssertNotEqual(GeneratorTool.password(length: 20), GeneratorTool.password(length: 20))
    }

    func testTheCommandsAreRecognizedAndMarkedSensitiveWhereNeeded() {
        XCTAssertEqual(GeneratorTool.answer("uuid").first?.copy.count, 36)
        let pw = GeneratorTool.answer("password 24").first
        XCTAssertEqual(pw?.copy.count, 24)
        XCTAssertEqual(pw?.sensitive, true)
        XCTAssertEqual(GeneratorTool.answer("lorem 2").first?.copy.components(separatedBy: "\n\n").count, 2)
        XCTAssertTrue(GeneratorTool.answer("password abc").isEmpty)
        XCTAssertTrue(GeneratorTool.answer("uuid 3").isEmpty)
        XCTAssertTrue(GeneratorTool.answer("hello").isEmpty)
    }
}

final class MeetingLinkTests: XCTestCase {
    func testVideoLinksAreFoundInAnEventsText() {
        XCTAssertEqual(MeetingLink.extract(from: [nil, "Join: https://us02web.zoom.us/j/123456?pwd=abc today"])?.host, "us02web.zoom.us")
        XCTAssertEqual(MeetingLink.extract(from: ["https://meet.google.com/abc-defg-hij"])?.absoluteString, "https://meet.google.com/abc-defg-hij")
        XCTAssertNotNil(MeetingLink.extract(from: ["https://teams.microsoft.com/l/meetup-join/19%3ameeting"]))
        XCTAssertNil(MeetingLink.extract(from: ["Lunch at the usual place", nil, ""]))
        XCTAssertNil(MeetingLink.extract(from: ["https://example.com/zoom.us"]))
    }

    func testTheEarliestLinkInTheTextWins() {
        let text = "Backup: https://meet.google.com/aaa-bbbb-ccc  Main: https://zoom.us/j/9"
        XCTAssertEqual(MeetingLink.extract(from: [text])?.host, "meet.google.com")
    }

    func testRelativeTimes() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(MeetingLink.relative(now.addingTimeInterval(12 * 60), now: now), "in 12 min")
        XCTAssertEqual(MeetingLink.relative(now.addingTimeInterval(30), now: now), "now")
        XCTAssertEqual(MeetingLink.relative(now.addingTimeInterval(-5 * 60), now: now), "started 5 min ago")
        XCTAssertEqual(MeetingLink.relative(now.addingTimeInterval(125 * 60), now: now), "in 2 h 5 min")
        XCTAssertEqual(MeetingLink.relative(now.addingTimeInterval(180 * 60), now: now), "in 3 h")
    }
}

final class QuicklinkTests: XCTestCase {
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "kriya-tests-\(UUID().uuidString)")! }

    func testTheWordsAreEncodedAndOnlyWebAddressesAreAllowed() throws {
        let link = Quicklink(name: "GitHub", keyword: "gh", template: "https://github.com/search?q={query}")
        let url = try XCTUnwrap(link.url(for: "a&b=c d"))
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "a&b=c d")
        XCTAssertNil(Quicklink(name: "x", keyword: "", template: "file:///etc/passwd").url(for: "x"))
        XCTAssertNil(Quicklink(name: "x", keyword: "", template: "javascript:alert({query})").url(for: "x"))
        XCTAssertNil(Quicklink(name: "x", keyword: "", template: "kriya://finder/run?x={query}").url(for: "x"))
    }

    func testAKeywordNeedsAQueryAndWordsAfterIt() {
        let links = [Quicklink(name: "GH", keyword: "gh", template: "https://github.com/search?q={query}"), Quicklink(name: "Docs", keyword: "docs", template: "https://example.com")]
        XCTAssertEqual(LauncherExtraMatch.quicklink(in: "gh swift ui", among: links)?.query, "swift ui")
        XCTAssertNil(LauncherExtraMatch.quicklink(in: "gh", among: links))
        XCTAssertNil(LauncherExtraMatch.quicklink(in: "docs thing", among: links), "that link has no place for words")
        XCTAssertNil(LauncherExtraMatch.quicklink(in: "zz thing", among: links))
    }

    func testSavingChecksNamesKeywordsAndClashes() {
        let extras = LauncherExtras(defaults: defaults())
        XCTAssertNotNil(extras.save(Quicklink(name: "", keyword: "x", template: "https://a.com/{query}")))
        XCTAssertNotNil(extras.save(Quicklink(name: "A", keyword: "two words", template: "https://a.com")))
        XCTAssertNotNil(extras.save(Quicklink(name: "A", keyword: "yt", template: "https://a.com/{query}")), "a built-in search word")
        XCTAssertNotNil(extras.save(Quicklink(name: "A", keyword: "x", template: "ftp://a.com")))
        XCTAssertNil(extras.save(Quicklink(name: "Mine", keyword: "MINE", template: "https://a.com/{query}")))
        XCTAssertEqual(extras.quicklinks.last?.keyword, "mine", "kept in lower case")
        XCTAssertNotNil(extras.save(Quicklink(name: "Other", keyword: "mine", template: "https://b.com/{query}")), "the word is taken")
    }

    func testScriptsAndQuicklinksCannotShareAWordAndSurviveARestart() {
        let store = defaults()
        let extras = LauncherExtras(defaults: store)
        XCTAssertNil(extras.save(ScriptCommand(name: "Greet", keyword: "hi", source: "echo hi $1")))
        XCTAssertNotNil(extras.save(Quicklink(name: "X", keyword: "hi", template: "https://a.com/{query}")))
        XCTAssertNotNil(extras.save(ScriptCommand(name: "Empty", keyword: "e", source: "   ")))
        let again = LauncherExtras(defaults: store)
        XCTAssertEqual(again.scripts.map(\.name), ["Greet"])
        XCTAssertEqual(LauncherExtraMatch.script(in: "hi there", among: again.scripts)?.argument, "there")
        XCTAssertEqual(LauncherExtraMatch.script(in: "hi", among: again.scripts)?.argument, "")
        XCTAssertNil(LauncherExtraMatch.script(in: "hello there", among: again.scripts))
        let id = try! XCTUnwrap(again.scripts.first).id
        again.deleteScript(id)
        XCTAssertTrue(LauncherExtras(defaults: store).scripts.isEmpty)
    }
}
