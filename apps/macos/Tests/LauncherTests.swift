import XCTest
@testable import Kriya

final class FuzzyMatcherTests: XCTestCase {
    func testBetterMatchesScoreHigher() throws {
        let exact = try XCTUnwrap(FuzzyMatcher.score("safari", in: "Safari"))
        let prefix = try XCTUnwrap(FuzzyMatcher.score("saf", in: "Safari"))
        let wordStart = try XCTUnwrap(FuzzyMatcher.score("code", in: "Visual Studio Code"))
        let inside = try XCTUnwrap(FuzzyMatcher.score("fari", in: "Safari"))
        XCTAssertGreaterThan(exact, prefix)
        XCTAssertGreaterThan(prefix, wordStart)
        XCTAssertGreaterThan(wordStart, inside)
    }

    func testShortFormsAndSkippedLettersMatch() {
        XCTAssertNotNil(FuzzyMatcher.score("vsc", in: "Visual Studio Code"))
        XCTAssertNotNil(FuzzyMatcher.score("sysprf", in: "System Preferences"))
        XCTAssertNotNil(FuzzyMatcher.score("ffx", in: "Firefox"))
        XCTAssertNil(FuzzyMatcher.score("xyz", in: "Safari"))
        XCTAssertNil(FuzzyMatcher.score("safarix", in: "Safari"), "more letters than the name has")
        XCTAssertNil(FuzzyMatcher.score("zq", in: "bazaar and burqa wide"), "scattered inside different words is no match")
    }

    func testCaseSpacesAndEmptyQueries() {
        XCTAssertEqual(FuzzyMatcher.score("SAFARI", in: "safari"), FuzzyMatcher.score("safari", in: "SAFARI"))
        XCTAssertEqual(FuzzyMatcher.score("", in: "anything"), 0)
        XCTAssertNotNil(FuzzyMatcher.score("vis stu", in: "Visual Studio Code"))
    }

    func testBestLooksAtEveryText() throws {
        let best = try XCTUnwrap(FuzzyMatcher.best("chat", in: ["Messages", "iMessage chat"]))
        XCTAssertGreaterThan(best, 500)
        XCTAssertNil(FuzzyMatcher.best("zzz", in: ["Messages"]))
    }

    func testOddTextDoesNotCrash() {
        _ = FuzzyMatcher.score("i", in: "İstanbul")
        _ = FuzzyMatcher.score("🙂", in: "😀🙂")
        _ = FuzzyMatcher.score("a", in: "")
        _ = FuzzyMatcher.score("ß", in: "STRASSE")
    }
}

final class LauncherCalculatorTests: XCTestCase {
    func testArithmetic() {
        XCTAssertEqual(LauncherCalculator.evaluate("2+2"), "4")
        XCTAssertEqual(LauncherCalculator.evaluate("12*8"), "96")
        XCTAssertEqual(LauncherCalculator.evaluate("(1+2)*3-4/2"), "7")
        XCTAssertEqual(LauncherCalculator.evaluate("2^10"), "1024")
        XCTAssertEqual(LauncherCalculator.evaluate("2^3^2"), "512", "powers go right to left")
        XCTAssertEqual(LauncherCalculator.evaluate("-3 + 5"), "2")
        XCTAssertEqual(LauncherCalculator.evaluate("10 % 3"), "1")
        XCTAssertEqual(LauncherCalculator.evaluate("7/2"), "3.5")
        XCTAssertEqual(LauncherCalculator.evaluate("1,000 + 500"), "1500")
        XCTAssertEqual(LauncherCalculator.evaluate("6×7"), "42")
    }

    func testFunctionsAndPercentages() {
        XCTAssertEqual(LauncherCalculator.evaluate("sqrt(144)"), "12")
        XCTAssertEqual(LauncherCalculator.evaluate("abs(-5) + round(2.6)"), "8")
        XCTAssertEqual(LauncherCalculator.evaluate("20% of 150"), "30")
        XCTAssertEqual(LauncherCalculator.evaluate("2*pi"), LauncherCalculator.format(2 * Double.pi))
    }

    func testThingsThatAreNotSumsAreLeftAlone() {
        for text in ["", "hello", "2", "safari 2", "1/0", "sqrt(-1)", "((((", "2+", "5 5", "ln(0)", "unknown(3)", String(repeating: "9", count: 300) + "+1"] {
            XCTAssertNil(LauncherCalculator.evaluate(text), text)
        }
    }

    func testDeepNestingDoesNotCrash() {
        let deep = String(repeating: "(", count: 500) + "1" + String(repeating: ")", count: 500)
        XCTAssertNil(LauncherCalculator.evaluate(deep + "+1"))
    }
}

final class LauncherTimerParserTests: XCTestCase {
    func testTimesAreUnderstood() {
        XCTAssertEqual(LauncherTimerParser.seconds(from: "timer 5m"), 300)
        XCTAssertEqual(LauncherTimerParser.seconds(from: "timer 90 seconds"), 90)
        XCTAssertEqual(LauncherTimerParser.seconds(from: "timer 1h30m"), 5400)
        XCTAssertEqual(LauncherTimerParser.seconds(from: "10 min timer"), 600)
        XCTAssertEqual(LauncherTimerParser.seconds(from: "timer 2"), 120, "a bare number is minutes")
        XCTAssertEqual(LauncherTimerParser.seconds(from: "Timer 1.5 hours"), 5400)
    }

    func testNonTimersAndExtremesAreRefused() {
        for text in ["timer", "timer abc", "timer 5 apples", "timer 0", "timer 25h", "5m", "set an alarm"] {
            XCTAssertNil(LauncherTimerParser.seconds(from: text), text)
        }
    }

    func testDescribe() {
        XCTAssertEqual(LauncherTimerParser.describe(90), "1 minute 30 seconds")
        XCTAssertEqual(LauncherTimerParser.describe(3600), "1 hour")
        XCTAssertEqual(LauncherTimerParser.describe(1), "1 second")
    }
}

final class LauncherEngineTests: XCTestCase {
    private func item(_ id: String, _ title: String, _ category: LauncherCategory = .app, subtitle: String = "", keywords: [String] = [], queryScore: Int? = nil) -> LauncherCandidate {
        LauncherCandidate(id: id, title: title, subtitle: subtitle, keywords: keywords, category: category, queryScore: queryScore, rememberable: true)
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testBetterMatchesComeFirstAndNonMatchesAreDropped() {
        let items = [item("a", "Safari"), item("b", "Sound Settings"), item("c", "Calendar"), item("d", "Xcode")]
        let order = LauncherEngine.rank(items, query: "sa", prefs: LauncherPrefsData(), now: now)
        XCTAssertEqual(order.first, "a")
        XCTAssertFalse(order.contains("d"))
        XCTAssertTrue(LauncherEngine.rank(items, query: "qqq", prefs: LauncherPrefsData(), now: now).isEmpty)
    }

    func testAShortNameWinsOverBetterMatches() {
        let items = [item("firefox", "Firefox"), item("ff", "Final Fantasy Fan Page"), item("fx", "ff")]
        var prefs = LauncherPrefsData()
        prefs.aliases["ff"] = "firefox"
        XCTAssertEqual(LauncherEngine.rank(items, query: "ff", prefs: prefs, now: now).first, "firefox")
        XCTAssertEqual(LauncherEngine.rank(items, query: " FF ", prefs: prefs, now: now).first, "firefox", "case and spaces do not matter")
    }

    func testUseAndPinsBreakTies() {
        let items = [item("one", "Notes"), item("two", "Notepad")]
        XCTAssertEqual(LauncherEngine.rank(items, query: "note", prefs: LauncherPrefsData(), now: now).first, "one")
        var used = LauncherPrefsData()
        for _ in 0..<5 { used = LauncherEngine.recording("two", in: used, now: now) }
        XCTAssertEqual(LauncherEngine.rank(items, query: "note", prefs: used, now: now).first, "two")
        var pinned = LauncherPrefsData()
        pinned.pinned = ["two"]
        XCTAssertEqual(LauncherEngine.rank(items, query: "note", prefs: pinned, now: now).first, "two")
    }

    func testAnEmptySearchShowsPinnedThenWhatIsUsed() {
        let items = (1...12).map { item("i\($0)", "Item \($0)") }
        var prefs = LauncherPrefsData()
        prefs.pinned = ["i9", "i3", "gone"]
        for index in [5, 5, 5, 7, 7, 2] { prefs = LauncherEngine.recording("i\(index)", in: prefs, now: now) }
        prefs = LauncherEngine.recording("i9", in: prefs, now: now)
        let order = LauncherEngine.rank(items, query: "", prefs: prefs, now: now)
        XCTAssertEqual(Array(order.prefix(2)), ["i9", "i3"], "pinned first, in the order pinned, and only what exists")
        XCTAssertEqual(Array(order.dropFirst(2).prefix(3)), ["i5", "i7", "i2"], "then the most used")
        XCTAssertFalse(order.contains("gone"))
        XCTAssertTrue(LauncherEngine.rank(items, query: "", prefs: LauncherPrefsData(), now: now).isEmpty, "nothing to show before any use")
    }

    func testTurnedOffKindsAreNeverShown() {
        let items = [item("a", "Notes", .app), item("f", "Notes.txt", .file, queryScore: 200)]
        var prefs = LauncherPrefsData()
        prefs.disabledCategories = [LauncherCategory.file.rawValue]
        XCTAssertEqual(LauncherEngine.rank(items, query: "notes", prefs: prefs, now: now), ["a"])
        prefs.pinned = ["f"]
        XCTAssertEqual(LauncherEngine.rank(items, query: "", prefs: prefs, now: now), [], "not even when pinned")
    }

    func testResultsFromWhatWasTypedUseTheirOwnScoreAndASumComesFirst() {
        let items = [item("app", "Calculator", .app), item("calc", "42", .calculator, queryScore: 1000), item("file", "calc-notes.txt", .file, queryScore: 200)]
        let order = LauncherEngine.rank(items, query: "6*7", prefs: LauncherPrefsData(), now: now)
        XCTAssertEqual(order.first, "calc")
        XCTAssertFalse(order.contains("app"), "an app that does not match is not shown")
    }

    func testMatchesInKeywordsAndSubtitles() {
        let items = [item("p", "Open Settings: Keyboard", .setting, subtitle: "Settings", keywords: ["hotkeys", "shortcuts"])]
        XCTAssertEqual(LauncherEngine.rank(items, query: "hotkeys", prefs: LauncherPrefsData(), now: now), ["p"])
        XCTAssertEqual(LauncherEngine.rank(items, query: "settings", prefs: LauncherPrefsData(), now: now), ["p"])
    }

    func testHistoryIsKeptToAFixedSize() {
        var prefs = LauncherPrefsData()
        for index in 0..<(LauncherEngine.maxRemembered + 50) {
            prefs = LauncherEngine.recording("id\(index)", in: prefs, now: now.addingTimeInterval(TimeInterval(index)))
        }
        XCTAssertEqual(prefs.usage.count, LauncherEngine.maxRemembered)
        XCTAssertNotNil(prefs.usage["id\(LauncherEngine.maxRemembered + 49)"], "the newest is kept")
        XCTAssertNil(prefs.usage["id0"], "the oldest is forgotten")
    }
}

final class LauncherPrefsTests: XCTestCase {
    private func suite() -> UserDefaults { UserDefaults(suiteName: "kriya-launcher-tests-\(UUID().uuidString)")! }

    func testChoicesSurviveARestart() {
        let defaults = suite()
        let first = LauncherPrefs(defaults: defaults)
        first.togglePin("app:one", title: "One")
        first.togglePin("app:two", title: "Two")
        XCTAssertTrue(first.setAlias("  Fox ", for: "app:one", title: "One"))
        first.setEnabled(.file, false)
        first.record("app:two")
        let second = LauncherPrefs(defaults: defaults)
        XCTAssertEqual(second.data.pinned, ["app:one", "app:two"])
        XCTAssertEqual(second.alias(for: "app:one"), "fox")
        XCTAssertEqual(second.data.titles["app:one"], "One")
        XCTAssertFalse(second.data.isEnabled(.file))
        XCTAssertEqual(second.data.usage["app:two"]?.count, 1)
    }

    func testPinsMoveAndANameBelongsToOneResult() {
        let prefs = LauncherPrefs(defaults: suite())
        for id in ["a", "b", "c"] { prefs.togglePin(id) }
        prefs.movePinned("c", by: -2)
        XCTAssertEqual(prefs.data.pinned, ["c", "a", "b"])
        prefs.movePinned("c", by: -5)
        XCTAssertEqual(prefs.data.pinned.first, "c", "it stops at the top")
        prefs.setAlias("x", for: "a")
        prefs.setAlias("x", for: "b")
        XCTAssertEqual(prefs.data.aliases, ["x": "b"], "a word names one result")
        prefs.setAlias("y", for: "b")
        XCTAssertEqual(prefs.data.aliases, ["y": "b"], "a result has one name")
        prefs.setAlias("", for: "b")
        XCTAssertTrue(prefs.data.aliases.isEmpty)
        XCTAssertFalse(prefs.setAlias(String(repeating: "x", count: 21), for: "a"))
    }

    func testForgettingAndResetting() {
        let prefs = LauncherPrefs(defaults: suite())
        prefs.record("a"); prefs.togglePin("a"); prefs.setEnabled(.app, false)
        prefs.clearHistory()
        XCTAssertTrue(prefs.data.usage.isEmpty)
        XCTAssertEqual(prefs.data.pinned, ["a"])
        prefs.reset()
        XCTAssertEqual(prefs.data, LauncherPrefsData())
    }

    func testDamagedSavedDataStartsFresh() {
        let defaults = suite()
        defaults.set(Data("garbage".utf8), forKey: "launcherPrefs.v1")
        XCTAssertEqual(LauncherPrefs(defaults: defaults).data, LauncherPrefsData())
    }
}

final class LauncherFilesAndEmojiTests: XCTestCase {
    func testOnlyOrdinaryQueriesAreHandedToSpotlight() {
        XCTAssertTrue(LauncherFileSearch.isSearchable("report"))
        XCTAssertFalse(LauncherFileSearch.isSearchable("ab"))
        XCTAssertFalse(LauncherFileSearch.isSearchable("-onlyin"), "not something that could be read as an option")
        XCTAssertFalse(LauncherFileSearch.isSearchable(String(repeating: "a", count: 61)))
        XCTAssertFalse(LauncherFileSearch.isSearchable("a\0b"))
    }

    func testHiddenLibraryAndBuildFilesAreLeftOut() {
        let home = "/Users/me"
        XCTAssertTrue(LauncherFileSearch.isWorthShowing("/Users/me/Documents/report.pdf", home: home))
        XCTAssertFalse(LauncherFileSearch.isWorthShowing("/Users/me/.ssh/config", home: home))
        XCTAssertFalse(LauncherFileSearch.isWorthShowing("/Users/me/Library/Mail/x.emlx", home: home))
        XCTAssertFalse(LauncherFileSearch.isWorthShowing("/Users/me/project/node_modules/a/index.js", home: home))
        XCTAssertFalse(LauncherFileSearch.isWorthShowing("/Users/me/Downloads/Thing.app", home: home), "apps are found as apps")
        XCTAssertTrue(LauncherFileSearch.isWorthShowing("/Users/me/Documents/My Library Notes.txt", home: home), "only whole folder names count")
    }

    func testEmojiAreFoundByNameAndPurpose() {
        XCTAssertEqual(LauncherEmoji.search("thumb").first?.emoji, "👍")
        XCTAssertTrue(LauncherEmoji.search("rocket").map(\.emoji).contains("🚀"))
        XCTAssertTrue(LauncherEmoji.search("celebrate").map(\.emoji).contains("🎉"))
        XCTAssertTrue(LauncherEmoji.search("x").isEmpty, "one letter is too little")
        XCTAssertTrue(LauncherEmoji.search("qwertyuiop").isEmpty)
        XCTAssertEqual(Set(LauncherEmoji.table.map(\.emoji)).count, LauncherEmoji.table.count, "no emoji is listed twice")
    }

    func testClipboardItemsAreShownOnOneLine() {
        XCTAssertEqual(LauncherSources.oneLine("  first\n\n  second  "), "first second")
        XCTAssertEqual(LauncherSources.oneLine("line one\nline two"), "line one line two")
        XCTAssertEqual(LauncherSources.oneLine(String(repeating: "a", count: 200)).count, 91)
        XCTAssertEqual(LauncherSources.oneLine(""), "")
    }
}
