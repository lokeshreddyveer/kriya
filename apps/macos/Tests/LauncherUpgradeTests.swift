import XCTest
@testable import Kriya

final class WebSearchTests: XCTestCase {
    func testAnAddressTypedAsOneWordIsRecognizedAndASentenceIsNot() {
        XCTAssertEqual(WebSearch.address(in: "apple.com")?.absoluteString, "https://apple.com")
        XCTAssertEqual(WebSearch.address(in: "github.com/lokeshreddyveer")?.host, "github.com")
        XCTAssertEqual(WebSearch.address(in: "https://example.org/a?b=1")?.absoluteString, "https://example.org/a?b=1")
        XCTAssertEqual(WebSearch.address(in: "localhost:3000")?.absoluteString, "http://localhost:3000")
        XCTAssertNil(WebSearch.address(in: "hello world.com"))
        XCTAssertNil(WebSearch.address(in: "12*8"))
        XCTAssertNil(WebSearch.address(in: "3.14"))
        XCTAssertNil(WebSearch.address(in: "notes.txt"), "a file name is not an address")
        XCTAssertNil(WebSearch.address(in: "localhostile"))
        XCTAssertNil(WebSearch.address(in: ""))
        XCTAssertNil(WebSearch.address(in: "javascript:alert(1)"))
    }

    func testAKeywordPicksTheSiteAndNeedsSomethingToSearchFor() {
        let hit = WebSearch.trigger(in: "yt  cute cats")
        XCTAssertEqual(hit?.engine.id, "youtube")
        XCTAssertEqual(hit?.query, "cute cats")
        XCTAssertEqual(WebSearch.trigger(in: "GH swift")?.engine.id, "github")
        XCTAssertNil(WebSearch.trigger(in: "yt"))
        XCTAssertNil(WebSearch.trigger(in: "yt   "))
        XCTAssertNil(WebSearch.trigger(in: "youtube cats"))
    }

    func testTheWordsAreEncodedSoTheyCannotChangeTheAddress() throws {
        let google = WebSearch.engine(id: "google")
        let url = try XCTUnwrap(WebSearch.url(for: google, query: "a&b=c #d?e 100%"))
        XCTAssertEqual(url.host, "www.google.com")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(items?.count, 1, "an ampersand in the words does not start a new parameter")
        XCTAssertEqual(items?.first?.value, "a&b=c #d?e 100%")
        XCTAssertNil(WebSearch.url(for: google, query: "   "))
        XCTAssertNil(WebSearch.url(for: google, query: String(repeating: "a", count: 501)))
        XCTAssertEqual(WebSearch.engine(id: "nonsense").id, "google")
    }

    func testEveryEngineHasAUniqueKeywordAndAValidTemplate() {
        let keywords = WebSearch.engines.map(\.keyword)
        XCTAssertEqual(Set(keywords).count, keywords.count)
        for engine in WebSearch.engines {
            XCTAssertTrue(engine.template.hasPrefix("https://"))
            XCTAssertNotNil(WebSearch.url(for: engine, query: "test"))
        }
    }
}

final class LauncherLayoutTests: XCTestCase {
    func testTheWindowIsABarAloneAndGrowsWithItsResultsUpToALimit() {
        let bare = PaletteLayout.height(sections: [], typed: false)
        let one = PaletteLayout.height(sections: ["Top hit"], typed: true)
        let three = PaletteLayout.height(sections: ["Top hit", "Results", "Results"], typed: true)
        let many = PaletteLayout.height(sections: Array(repeating: "Results", count: 30), typed: true)
        let eight = PaletteLayout.height(sections: Array(repeating: "Results", count: 8), typed: true)
        XCTAssertLessThan(bare, one)
        XCTAssertLessThan(one, three)
        XCTAssertEqual(many, eight, "more rows scroll instead of growing")
        XCTAssertLessThan(PaletteLayout.height(sections: [], typed: true), 200)
    }

    func testTheWindowStaysInsideTheScreenAndGrowsDownward() {
        let visible = CGRect(x: 0, y: 40, width: 1440, height: 860)
        let small = PaletteLayout.frame(height: 132, in: visible)
        XCTAssertTrue(visible.contains(small))
        XCTAssertEqual(small.midX, visible.midX, accuracy: 0.5)
        XCTAssertGreaterThan(small.minY, visible.midY, "it sits in the upper part of the screen")
        let grown = PaletteLayout.resized(small, toHeight: 520, in: visible)
        XCTAssertEqual(grown.maxY, small.maxY, accuracy: 0.001, "the top edge stays put")
        XCTAssertTrue(visible.contains(grown))
        let huge = PaletteLayout.resized(small, toHeight: 5000, in: visible)
        XCTAssertTrue(visible.contains(huge))
        let narrow = PaletteLayout.frame(height: 300, in: CGRect(x: 0, y: 0, width: 500, height: 600))
        XCTAssertLessThanOrEqual(narrow.width, 500)
    }

    private func candidate(_ id: String, _ title: String, _ category: LauncherCategory = .app) -> LauncherCandidate {
        LauncherCandidate(id: id, title: title, subtitle: "", keywords: [], category: category, queryScore: nil, rememberable: true)
    }

    func testAnEmptySearchSuggestsOpenAppsAfterPinsAndRecentsAndNeverIsBare() {
        var prefs = LauncherPrefsData()
        prefs.pinned = ["p"]
        prefs.usage["r"] = LauncherUsage(count: 3, last: Date())
        let items = [candidate("p", "Pinned"), candidate("r", "Recent"), candidate("a", "A"), candidate("b", "B")]
        let order = LauncherEngine.rank(items, query: "", prefs: prefs, suggestions: ["a", "b", "missing", "p"])
        XCTAssertEqual(order, ["p", "r", "a", "b"])
        XCTAssertEqual(LauncherEngine.startSection(for: "p", prefs: prefs), "Favorites")
        XCTAssertEqual(LauncherEngine.startSection(for: "r", prefs: prefs), "Recent")
        XCTAssertEqual(LauncherEngine.startSection(for: "a", prefs: prefs), "Suggested")
        XCTAssertEqual(LauncherEngine.rank(items, query: "", prefs: LauncherPrefsData()), [], "with nothing to suggest it is empty")
    }

    func testTheWebRowIsLastAndNeverBeatsARealMatch() {
        let items = [candidate("app", "Firefox"), candidate("web", "Search Google for “firefox”", .web)]
        var web = items[1]
        web = LauncherCandidate(id: web.id, title: web.title, subtitle: "", keywords: [], category: .web, queryScore: 10, rememberable: false)
        let order = LauncherEngine.rank([items[0], web], query: "firefox", prefs: LauncherPrefsData())
        XCTAssertEqual(order, ["app", "web"])
        var off = LauncherPrefsData()
        off.disabledCategories = [LauncherCategory.web.rawValue]
        XCTAssertEqual(LauncherEngine.rank([items[0], web], query: "firefox", prefs: off), ["app"])
    }
}

final class SwitcherCardsTests: XCTestCase {
    func testCardsWrapToTheScreenWidthAndRowsScrollPastALimit() {
        XCTAssertEqual(SwitcherLayout.columns(count: 3, maxWidth: 1400), 3)
        XCTAssertEqual(SwitcherLayout.columns(count: 30, maxWidth: 1400), 5)
        XCTAssertEqual(SwitcherLayout.columns(count: 7, maxWidth: 1400), 4, "two even rows, not five and two")
        XCTAssertEqual(SwitcherLayout.columns(count: 5, maxWidth: 1400), 5)
        XCTAssertEqual(SwitcherLayout.columns(count: 6, maxWidth: 1400), 3)
        XCTAssertEqual(SwitcherLayout.columns(count: 5, maxWidth: 100), 1, "never fewer than one")
        XCTAssertEqual(SwitcherLayout.columns(count: 0, maxWidth: 1400), 1)
        let few = SwitcherLayout.size(count: 4, maxWidth: 1400)
        let many = SwitcherLayout.size(count: 60, maxWidth: 1400)
        XCTAssertLessThan(few.width, many.width)
        XCTAssertLessThan(few.height, many.height)
        XCTAssertEqual(many.height, SwitcherLayout.size(count: 600, maxWidth: 1400).height, "after three rows it scrolls")
        XCTAssertLessThanOrEqual(many.width, 1400)
    }

    func testArrowsMoveAcrossTheGridAndStopAtTheEdges() {
        // Seven cards, three to a row:  0 1 2 / 3 4 5 / 6
        XCTAssertEqual(SwitcherLayout.move(from: 1, .right, count: 7, columns: 3), 2)
        XCTAssertEqual(SwitcherLayout.move(from: 6, .right, count: 7, columns: 3), 0, "right from the last wraps to the first")
        XCTAssertEqual(SwitcherLayout.move(from: 0, .left, count: 7, columns: 3), 6)
        XCTAssertEqual(SwitcherLayout.move(from: 1, .down, count: 7, columns: 3), 4)
        XCTAssertEqual(SwitcherLayout.move(from: 5, .down, count: 7, columns: 3), 5, "nothing below: stays")
        XCTAssertEqual(SwitcherLayout.move(from: 4, .up, count: 7, columns: 3), 1)
        XCTAssertEqual(SwitcherLayout.move(from: 1, .up, count: 7, columns: 3), 1)
        XCTAssertEqual(SwitcherLayout.move(from: 0, .right, count: 0, columns: 3), 0)
        XCTAssertEqual(SwitcherLayout.move(from: 99, .left, count: 3, columns: 3), 1, "a stale index is brought back in range")
    }

    func testTheBacktickGoesToTheNextWindowOfTheSameApp() {
        let apps = ["a", "b", "a", "c", "a"]
        XCTAssertEqual(SwitcherLayout.nextOfSameApp(from: 0, appIDs: apps), 2)
        XCTAssertEqual(SwitcherLayout.nextOfSameApp(from: 4, appIDs: apps), 0, "wraps around")
        XCTAssertNil(SwitcherLayout.nextOfSameApp(from: 1, appIDs: apps), "the only window of its app")
        XCTAssertNil(SwitcherLayout.nextOfSameApp(from: 0, appIDs: ["a"]))
        XCTAssertNil(SwitcherLayout.nextOfSameApp(from: 9, appIDs: apps))
    }
}

final class HomebrewSearchTests: XCTestCase {
    func testSearchResultsPutTheExactNameFirstThenTheOnesThatStartWithIt() {
        let ranked = HomebrewParsing.rank(["firefox@beta", "librewolf-firefox", "firefox", "firefox-developer", "my-firefox-tool"], query: "Firefox")
        XCTAssertEqual(ranked.first, "firefox")
        XCTAssertEqual(Array(ranked.prefix(3)), ["firefox", "firefox@beta", "firefox-developer"])
        XCTAssertEqual(HomebrewParsing.rank(["vlc", "vlc-x"], query: "visual studio"), ["vlc", "vlc-x"], "no match keeps the order")
    }

    func testDetailsAreReadFromBrewsJsonAndBadOnesAreDropped() {
        let json = #"{"casks":[{"token":"firefox","name":["Mozilla Firefox"],"desc":"Web browser","homepage":"https://www.mozilla.org/firefox/","version":"158.0.1"},{"token":"BAD NAME","name":["x"]},{"token":"vlc","name":[],"desc":null}]}"#
        let infos = HomebrewParsing.parseInfo(Data(json.utf8))
        XCTAssertEqual(infos.map(\.token), ["firefox", "vlc"])
        XCTAssertEqual(infos[0].name, "Mozilla Firefox")
        XCTAssertEqual(infos[0].description, "Web browser")
        XCTAssertEqual(infos[1].name, "vlc", "no name falls back to the token")
        XCTAssertTrue(HomebrewParsing.parseInfo(Data("not json".utf8)).isEmpty)
        XCTAssertTrue(HomebrewParsing.featured.allSatisfy(HomebrewParsing.isValidToken))
    }
}

final class PointerPresentationTests: XCTestCase {
    func testPresentationAndSpotlightWorkEvenWithTheMasterSwitchOff() throws {
        let world = try TestWorld()
        defer { world.cleanUp() }
        let store = PointerEffectsStore(core: world.core)
        XCTAssertFalse(store.config.enabled)
        XCTAssertFalse(store.presentationOn)
        store.update { $0.presentationKey = 35; $0.presentationModifiers = 0; $0.spotlightKey = 1; $0.spotlightModifiers = 8 }
        XCTAssertNil(store.config.presentationKey, "a shortcut with no modifier is refused")
        XCTAssertEqual(store.config.spotlightKey, 1)
    }
}

final class SwitcherUpgradeTests: XCTestCase {
    func testTheHighlightStartsOnThePreviousWindowOrTheLastWhenGoingBackwards() {
        XCTAssertEqual(SwitcherLayout.startIndex(count: 5, backwards: false), 1)
        XCTAssertEqual(SwitcherLayout.startIndex(count: 5, backwards: true), 4)
        XCTAssertEqual(SwitcherLayout.startIndex(count: 1, backwards: true), 0)
        XCTAssertEqual(SwitcherLayout.startIndex(count: 0, backwards: false), 0)
    }

    func testDigitsPickTheFirstNineCardsAndNothingElse() {
        XCTAssertEqual(SwitcherLayout.index(forDigit: "3", count: 5), 2)
        XCTAssertNil(SwitcherLayout.index(forDigit: "6", count: 5), "past the end")
        XCTAssertNil(SwitcherLayout.index(forDigit: "0", count: 5))
        XCTAssertNil(SwitcherLayout.index(forDigit: "a", count: 5))
        XCTAssertNil(SwitcherLayout.index(forDigit: "12", count: 20))
    }

    func testTheSizeSettingScalesTheCardsAndIsKeptInRange() {
        XCTAssertGreaterThan(SwitcherMetrics(scale: 1.4).cardWidth, SwitcherMetrics(scale: 1).cardWidth)
        XCTAssertLessThan(SwitcherMetrics(scale: 0.8).cardWidth, SwitcherMetrics(scale: 1).cardWidth)
        XCTAssertEqual(SwitcherMetrics(scale: 99).scale, 1.5)
        XCTAssertEqual(SwitcherMetrics(scale: 0).scale, 0.7)
        XCTAssertEqual(SwitcherMetrics(scale: .nan).scale, 1)
        let small = SwitcherLayout.size(count: 8, maxWidth: 1400, scale: 0.8)
        let big = SwitcherLayout.size(count: 8, maxWidth: 1400, scale: 1.4)
        XCTAssertLessThan(small.height, big.height)
        XCTAssertLessThan(SwitcherLayout.columns(count: 30, maxWidth: 1400, scale: 1.4), SwitcherLayout.columns(count: 30, maxWidth: 1400, scale: 0.8))
    }

    func testTypingMakesRoomForTheSearchBarAndAShortScreenScrollsInsteadOfOverflowing() {
        let plain = SwitcherLayout.size(count: 4, maxWidth: 1400)
        let searching = SwitcherLayout.size(count: 4, maxWidth: 1400, searching: true)
        XCTAssertGreaterThan(searching.height, plain.height)
        let tall = SwitcherLayout.size(count: 20, maxWidth: 1000)
        let short = SwitcherLayout.size(count: 20, maxWidth: 1000, maxHeight: 420)
        XCTAssertLessThanOrEqual(short.height, 420)
        XCTAssertLessThan(short.height, tall.height)
        XCTAssertGreaterThan(SwitcherLayout.size(count: 1, maxWidth: 1000, maxHeight: 50).height, 0, "never nothing")
    }
}
