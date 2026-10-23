import XCTest
@testable import Kriya

final class APICommandTests: XCTestCase {
    private func command(url: String = "https://api.example.com/find?q={query}", method: APICommand.Method = .get) -> APICommand {
        APICommand(name: "Find", keyword: "find", method: method, url: url)
    }

    func testWordsAreEncodedIntoTheAddressAndCannotChangeIt() throws {
        let request = try XCTUnwrap(command().request(for: "a&b=c d#x", headerValues: [:]))
        let text = try XCTUnwrap(request.url?.absoluteString)
        XCTAssertEqual(text, "https://api.example.com/find?q=a%26b%3Dc%20d%23x")
        XCTAssertEqual(request.httpMethod, "GET")
    }

    func testTheBodyHasTheWordsEscapedForJSON() throws {
        var post = command(method: .post)
        post.body = #"{"text": "{query}"}"#
        let request = try XCTUnwrap(post.request(for: "say \"hi\"\nnow", headerValues: [:]))
        let body = try XCTUnwrap(request.httpBody.flatMap { String(data: $0, encoding: .utf8) })
        XCTAssertEqual(body, #"{"text": "say \"hi\"\nnow"}"#)
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    func testHeadersAreSentWhenTheyHaveAValue() throws {
        var c = command()
        c.headerNames = ["Authorization", "X-Empty"]
        let request = try XCTUnwrap(c.request(for: "x", headerValues: ["Authorization": "Bearer abc", "X-Empty": ""]))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer abc")
        XCTAssertNil(request.value(forHTTPHeaderField: "X-Empty"))
    }

    func testOnlySafeAddressesAreAllowed() {
        XCTAssertNil(command().problem)
        XCTAssertNotNil(command(url: "http://api.example.com/{query}").problem, "plain http is refused for other sites")
        XCTAssertNil(command(url: "http://localhost:3000/{query}").problem)
        XCTAssertNotNil(command(url: "file:///etc/passwd").problem)
        XCTAssertNotNil(command(url: "javascript:alert(1)").problem)
        XCTAssertNil(command(url: "https://api.example.com/find?q={query}").request(for: String(repeating: "a", count: 600), headerValues: [:]), "very long input is refused")
    }

    func testNamesAndKeywordsAreChecked() {
        var c = command()
        c.keyword = "g"
        XCTAssertNotNil(c.problem, "a search site's keyword is taken")
        c.keyword = "two words"
        XCTAssertNotNil(c.problem)
        c.keyword = "ok"
        c.headerNames = ["Bad Header!"]
        XCTAssertNotNil(c.problem)
        XCTAssertTrue(APICommand.looksSecret("Authorization"))
        XCTAssertTrue(APICommand.looksSecret("X-Api-Key"))
        XCTAssertFalse(APICommand.looksSecret("Accept"))
    }

    func testAPartOfAJSONAnswerIsPickedByPath() {
        let data = Data(#"{"data":{"items":[{"name":"first","n":3},{"name":"second"}],"ok":true,"none":null}}"#.utf8)
        XCTAssertEqual(JSONResult.extract(data, path: "data.items.0.name"), "first")
        XCTAssertEqual(JSONResult.extract(data, path: "data.items.1.name"), "second")
        XCTAssertEqual(JSONResult.extract(data, path: "data.items.0.n"), "3")
        XCTAssertEqual(JSONResult.extract(data, path: "data.ok"), "true")
        XCTAssertEqual(JSONResult.extract(data, path: "data.none"), "null")
        XCTAssertNil(JSONResult.extract(data, path: "data.items.5.name"))
        XCTAssertNil(JSONResult.extract(data, path: "data.missing"))
        XCTAssertTrue(JSONResult.extract(data, path: "data.items.0")?.contains("\"name\"") ?? false, "an object comes back as JSON text")
        XCTAssertEqual(JSONResult.extract(Data("plain words".utf8), path: ""), "plain words")
        XCTAssertNil(JSONResult.extract(Data("plain words".utf8), path: "a.b"))
    }
}

final class SearchHistoryTests: XCTestCase {
    func testTheSameSearchMovesToTheFrontAndIsCounted() {
        var history = SearchHistory()
        history.record("swift concurrency")
        history.record("rust")
        history.record("Swift Concurrency")
        XCTAssertEqual(history.entries.map(\.text), ["Swift Concurrency", "rust"])
        XCTAssertEqual(history.entries[0].count, 2)
    }

    func testShortLongAndSecretLookingTextIsNotKept() {
        var history = SearchHistory()
        history.record("a")
        history.record(String(repeating: "x", count: 200))
        history.record("sk1234567890abcdefghijklmnop")
        history.record("  ")
        XCTAssertTrue(history.entries.isEmpty)
        history.record("long normal sentence with spaces and 123 numbers inside it")
        XCTAssertEqual(history.entries.count, 1)
    }

    func testOnlyTheLatestAreKept() {
        var history = SearchHistory()
        for i in 0..<(SearchHistory.maxEntries + 20) { history.record("search \(i)") }
        XCTAssertEqual(history.entries.count, SearchHistory.maxEntries)
        XCTAssertEqual(history.entries[0].text, "search \(SearchHistory.maxEntries + 19)")
    }

    func testMatchingFindsPastWords() {
        var history = SearchHistory()
        history.record("holiday flights")
        history.record("flight status")
        history.record("recipes")
        XCTAssertEqual(history.matching("flight").map(\.text), ["flight status", "holiday flights"])
        XCTAssertEqual(history.matching("").count, 3)
    }

    func testSteppingWithTheArrowsGoesBackAndReturnsToWhatWasTyped() {
        XCTAssertEqual(SearchHistory.older(nil, count: 3), 0)
        XCTAssertEqual(SearchHistory.older(0, count: 3), 1)
        XCTAssertEqual(SearchHistory.older(2, count: 3), 2, "stops at the oldest")
        XCTAssertNil(SearchHistory.older(nil, count: 0))
        XCTAssertEqual(SearchHistory.newer(2), 1)
        XCTAssertNil(SearchHistory.newer(0), "back to what was typed")
        XCTAssertNil(SearchHistory.newer(nil))
    }

    func testTheStoreRecordsOnlyWhenOnAndForgetsWhenTurnedOff() {
        let defaults = UserDefaults(suiteName: "kriya-history-\(UUID().uuidString)")!
        let store = SearchHistoryStore(defaults: defaults)
        store.record("never saved")
        XCTAssertTrue(store.history.entries.isEmpty, "off by default")
        store.isEnabled = true
        store.record("saved words")
        XCTAssertEqual(SearchHistoryStore(defaults: defaults).history.entries.count, 1, "it survives a restart")
        store.isEnabled = false
        XCTAssertTrue(SearchHistoryStore(defaults: defaults).history.entries.isEmpty, "turning it off erases it")
    }
}

final class BrowserTabsTests: XCTestCase {
    private let sep = "\u{1F}"

    func testTabsAreReadFromTheBrowsersAnswer() {
        let output = "1\(sep)1\(sep)Apple\(sep)https://apple.com/\n1\(sep)2\(sep)Start Page\(sep)\n2\(sep)1\(sep)Docs page\(sep)https://docs.example.com/a?x=1\nnonsense\n"
        let tabs = BrowserTabs.parse(output, browser: .safari)
        XCTAssertEqual(tabs.map(\.url), ["https://apple.com/", "https://docs.example.com/a?x=1"], "a tab with no address and a broken line are dropped")
        XCTAssertEqual(tabs[1].window, 2)
        XCTAssertEqual(tabs[0].id, "Safari:1:1")
    }

    func testTabsAreFoundByEveryWord() {
        let tabs = [
            BrowserTab(browser: .chrome, window: 1, tab: 1, title: "Swift Forums", url: "https://forums.swift.org"),
            BrowserTab(browser: .chrome, window: 1, tab: 2, title: "Rust Blog", url: "https://blog.rust-lang.org"),
        ]
        XCTAssertEqual(BrowserTabs.matching(tabs, query: "swift forums").map(\.tab), [1])
        XCTAssertEqual(BrowserTabs.matching(tabs, query: "rust-lang").map(\.tab), [2])
        XCTAssertTrue(BrowserTabs.matching(tabs, query: "swift rust").isEmpty)
        XCTAssertTrue(BrowserTabs.matching(tabs, query: "  ").isEmpty)
    }

    func testTheScriptsNameTheRightBrowserAndTab() {
        XCTAssertTrue(BrowserTabs.listScript(for: .safari).contains("tell application \"Safari\""))
        XCTAssertTrue(BrowserTabs.listScript(for: .safari).contains("name of t"))
        XCTAssertTrue(BrowserTabs.listScript(for: .chrome).contains("title of t"))
        let tab = BrowserTab(browser: .chrome, window: 2, tab: 5, title: "x", url: "https://x.com")
        XCTAssertTrue(BrowserTabs.activateScript(for: tab).contains("set active tab index of window 2 to 5"))
        let safari = BrowserTab(browser: .safari, window: 1, tab: 3, title: "x", url: "https://x.com")
        XCTAssertTrue(BrowserTabs.activateScript(for: safari).contains("set current tab of window 1 to tab 3 of window 1"))
    }
}
