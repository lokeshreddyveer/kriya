import XCTest
@testable import Kriya

final class WebResearchTests: XCTestCase {
    func testTheWikipediaToAskFollowsTheScriptOfTheQuestion() {
        XCTAssertEqual(WebResearch.languages(for: "who directed Baahubali"), ["en"])
        XCTAssertEqual(WebResearch.languages(for: "బాహుబలి దర్శకుడు ఎవరు"), ["te", "en"])
        XCTAssertEqual(WebResearch.languages(for: "latest Telugu movie cast"), ["te", "en"])
        XCTAssertEqual(WebResearch.languages(for: "தமிழ் படம்"), ["ta", "en"])
        XCTAssertEqual(WebResearch.languages(for: "తెలుగు tamil hindi").count, 2, "never more than two")
    }

    func testTheRequestAsksWikipediaOnlyAndCarriesOnlyTheQuestion() throws {
        let url = try XCTUnwrap(WebResearch.requestURL(question: "Baahubali cast & crew", language: "te"))
        XCTAssertEqual(url.host, "te.wikipedia.org")
        XCTAssertEqual(url.scheme, "https")
        let items = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["gsrsearch"], "Baahubali cast & crew")
        XCTAssertEqual(items["explaintext"], "1")
        XCTAssertNil(WebResearch.requestURL(question: " ", language: "en"))
        XCTAssertNil(WebResearch.requestURL(question: "x", language: "en.evil.com"), "the language cannot change the host")
        XCTAssertNil(WebResearch.requestURL(question: String(repeating: "a", count: WebResearch.maxQuestionCharacters + 1), language: "en"))
    }

    func testAnAnswerBecomesSourcesBestFirstAndForeignAddressesAreDropped() {
        let json = """
        {"query":{"pages":[
          {"pageid":2,"title":"Second","index":2,"fullurl":"https://en.wikipedia.org/wiki/Second","extract":"Second text."},
          {"pageid":1,"title":"First","index":1,"fullurl":"https://en.wikipedia.org/wiki/First","extract":"First text."},
          {"pageid":3,"title":"Evil","index":3,"fullurl":"https://evil.example.com/x","extract":"Not wikipedia."},
          {"pageid":4,"title":"Empty","index":4,"fullurl":"https://en.wikipedia.org/wiki/Empty","extract":"  "}
        ]}}
        """
        let sources = WebResearch.parse(Data(json.utf8))
        XCTAssertEqual(sources.map(\.title), ["First", "Second"])
        XCTAssertTrue(WebResearch.parse(Data("not json".utf8)).isEmpty)
        XCTAssertTrue(WebResearch.parse(Data(#"{"query":{}}"#.utf8)).isEmpty)
    }

    func testSourcesFromTwoLanguagesAreInterleavedWithoutRepeats() {
        func source(_ name: String) -> ResearchSource { ResearchSource(title: name, url: "https://x.wikipedia.org/wiki/\(name)", extract: name) }
        let merged = WebResearch.merge([[source("a1"), source("a2"), source("a3")], [source("b1"), source("a1"), source("b2")]])
        XCTAssertEqual(merged.map(\.title), ["a1", "b1", "a2", "a3"])
        XCTAssertEqual(WebResearch.merge([]).count, 0)
    }

    func testThePromptNumbersTheSourcesAndTheInstructionsForbidGuessing() {
        let sources = [ResearchSource(title: "Baahubali", url: "https://en.wikipedia.org/wiki/Baahubali", extract: "A film.")]
        let prompt = WebResearch.prompt(question: "who directed it", sources: sources)
        XCTAssertTrue(prompt.contains("[1] Baahubali (https://en.wikipedia.org/wiki/Baahubali)"))
        XCTAssertTrue(prompt.hasPrefix("Question: who directed it"))
        XCTAssertTrue(WebResearch.instructions.contains("do not guess"))
        XCTAssertEqual(WebResearch.sourceLines(sources), "[1] Baahubali: https://en.wikipedia.org/wiki/Baahubali")
    }

    func testTheLauncherSeesAResearchQuestion() {
        XCTAssertEqual(LauncherSources.researchQuestion(in: "research who directed Baahubali"), "who directed Baahubali")
        XCTAssertEqual(LauncherSources.researchQuestion(in: "Lookup  Telugu film"), "Telugu film")
        XCTAssertNil(LauncherSources.researchQuestion(in: "research"))
        XCTAssertNil(LauncherSources.researchQuestion(in: "research ab"))
        XCTAssertNil(LauncherSources.researchQuestion(in: "ask something"))
    }

    private struct FakeFetcher: ResearchFetching {
        var found: [ResearchSource]
        var fails = false
        func sources(for question: String) async throws -> [ResearchSource] {
            if fails { throw URLError(.notConnectedToInternet) }
            return found
        }
    }

    private struct FakeModel: TextModel {
        func availability() -> IntelligenceAvailability { .available }
        func respond(instructions: String, prompt: String, rewriting: Bool) async throws -> String { "He directed it [1]." }
    }

    private func service(on: Bool) -> AppleIntelligence {
        let defaults = UserDefaults(suiteName: "kriya-research-\(UUID().uuidString)")!
        let ai = AppleIntelligence(model: FakeModel(), defaults: defaults, watchSystem: false)
        ai.update { $0.webResearchOn = on ? true : nil }
        return ai
    }

    func testResearchIsOffUntilTurnedOnAndNeverTouchesTheFetcherThen() async throws {
        let output = try await service(on: false).research("x y z", fetcher: FakeFetcher(found: [], fails: true))
        XCTAssertTrue(output.text.contains("Web research is off"))
    }

    func testResearchAnswersFromSourcesAndListsThem() async throws {
        let source = ResearchSource(title: "Baahubali", url: "https://en.wikipedia.org/wiki/Baahubali", extract: "Directed by S. S. Rajamouli.")
        let output = try await service(on: true).research("who directed Baahubali", fetcher: FakeFetcher(found: [source]))
        XCTAssertTrue(output.text.contains("He directed it [1]."))
        XCTAssertTrue(output.text.contains("Sources:\n[1] Baahubali: https://en.wikipedia.org/wiki/Baahubali"))
    }

    func testResearchSaysSoWhenNothingIsFoundInsteadOfGuessing() async throws {
        let none = try await service(on: true).research("zzzz qqqq", fetcher: FakeFetcher(found: []))
        XCTAssertTrue(none.text.contains("No Wikipedia article matched"))
        let offline = try await service(on: true).research("zzzz qqqq", fetcher: FakeFetcher(found: [], fails: true))
        XCTAssertTrue(offline.text.contains("could not reach Wikipedia"))
    }

    func testSettingsSavedBeforeWebResearchStillLoad() throws {
        let old = #"{"inSelectionBar":true,"inLauncher":true,"onClipboardItems":true,"outputLanguage":"French"}"#
        let decoded = try JSONDecoder().decode(IntelligenceSettings.self, from: Data(old.utf8))
        XCTAssertEqual(decoded.outputLanguage, "French")
        XCTAssertNil(decoded.webResearchOn)
    }
}
