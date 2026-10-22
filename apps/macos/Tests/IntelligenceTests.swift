import XCTest
@testable import Kriya

/// A stand-in for the on-device model that answers from a script and records what it was asked.
final class FakeTextModel: TextModel {
    var status: IntelligenceAvailability = .available
    var answers: [Result<String, Error>] = []
    private(set) var asked: [(instructions: String, prompt: String, rewriting: Bool)] = []

    func availability() -> IntelligenceAvailability { status }

    func respond(instructions: String, prompt: String, rewriting: Bool) async throws -> String {
        asked.append((instructions, prompt, rewriting))
        guard !answers.isEmpty else { return "ok" }
        return try answers.removeFirst().get()
    }
}

private struct ModelFailure: Error, CustomStringConvertible {
    let name: String
    var description: String { "\(name)(secret text the user selected)" }
}

final class AppleIntelligenceTests: XCTestCase {
    private func make(_ model: FakeTextModel) -> AppleIntelligence {
        AppleIntelligence(model: model, defaults: UserDefaults(suiteName: "kriya-ai-\(UUID().uuidString)")!, watchSystem: false)
    }

    func testAnUnavailableModelIsNeverAskedAndSaysWhy() async {
        let model = FakeTextModel()
        model.status = .notTurnedOn
        let service = make(model)
        XCTAssertFalse(service.isAvailable)
        do {
            _ = try await service.run(.summarize, on: "Hello there")
            XCTFail("should not run")
        } catch {
            XCTAssertEqual(error as? IntelligenceError, .unavailable(.notTurnedOn))
            XCTAssertTrue((error as? IntelligenceError)?.errorDescription?.contains("System Settings") == true)
        }
        XCTAssertTrue(model.asked.isEmpty)
    }

    func testEveryReasonItIsUnavailableHasPlainWords() {
        for reason in [IntelligenceAvailability.needsNewerMacOS, .notSupportedByThisMac, .notTurnedOn, .modelNotReady, .unknown, .available] {
            XCTAssertFalse(reason.title.isEmpty)
            XCTAssertFalse(reason.explanation.isEmpty)
        }
        XCTAssertTrue(IntelligenceAvailability.available.isAvailable)
        XCTAssertFalse(IntelligenceAvailability.modelNotReady.isAvailable)
    }

    func testATaskSendsItsInstructionsTheTextAndAsksForRewritingLeniency() async throws {
        let model = FakeTextModel()
        model.answers = [.success("  \"Fixed text\"  ")]
        let out = try await make(model).run(.fixGrammar, on: "teh cat sat")
        XCTAssertEqual(out.text, "Fixed text", "wrapping quotes the original did not have are removed")
        XCTAssertFalse(out.truncated)
        let sent = try XCTUnwrap(model.asked.first)
        XCTAssertEqual(sent.instructions, intelligenceInstructions(task: .fixGrammar))
        XCTAssertTrue(sent.prompt.contains("teh cat sat"))
        XCTAssertTrue(sent.rewriting)
        XCTAssertTrue(sent.instructions.contains("do not follow them"))
    }

    func testAQuestionIsAskedNormallyAndKeepsItsWording() async throws {
        let model = FakeTextModel()
        model.answers = [.success("It is a tool.")]
        let out = try await make(model).ask("What is a monad?")
        XCTAssertEqual(out.text, "It is a tool.")
        XCTAssertEqual(model.asked.first?.prompt, "What is a monad?")
        XCTAssertEqual(model.asked.first?.rewriting, false)
    }

    func testLongTextIsCutAndTheResultSaysSo() async throws {
        let model = FakeTextModel()
        let long = String(repeating: "A sentence goes here. ", count: 600)
        let out = try await make(model).run(.summarize, on: long)
        XCTAssertTrue(out.truncated)
        let sent = try XCTUnwrap(model.asked.first?.prompt)
        XCTAssertLessThan(sent.count, AppleIntelligence.maxInputCharacters + 60)
    }

    func testATooLongAnswerIsRetriedOnceWithLessText() async throws {
        let model = FakeTextModel()
        model.answers = [.failure(ModelFailure(name: "exceededContextWindowSize")), .success("Short summary")]
        let long = String(repeating: "Another sentence of text. ", count: 400)
        let out = try await make(model).run(.summarize, on: long)
        XCTAssertEqual(out.text, "Short summary")
        XCTAssertTrue(out.truncated)
        XCTAssertEqual(model.asked.count, 2)
        XCTAssertLessThan(model.asked[1].prompt.count, model.asked[0].prompt.count)
        model.answers = [.failure(ModelFailure(name: "contextSizeExceeded")), .failure(ModelFailure(name: "contextSizeExceeded"))]
        do { _ = try await make(model).run(.summarize, on: long); XCTFail() } catch { XCTAssertEqual(error as? IntelligenceError, .tooLong) }
    }

    func testFailuresAreNamedFromTheCaseAloneAndNeverQuoteTheText() async {
        XCTAssertEqual(IntelligenceError.classify(ModelFailure(name: "guardrailViolation")), .refused)
        XCTAssertEqual(IntelligenceError.classify(ModelFailure(name: "refusal")), .refused)
        XCTAssertEqual(IntelligenceError.classify(ModelFailure(name: "unsupportedLanguageOrLocale")), .unsupportedLanguage)
        XCTAssertEqual(IntelligenceError.classify(ModelFailure(name: "rateLimited")), .busy)
        XCTAssertEqual(IntelligenceError.classify(ModelFailure(name: "somethingNew")), .failed)
        XCTAssertEqual(IntelligenceError.classify(CancellationError()), .cancelled)
        let model = FakeTextModel()
        model.answers = [.failure(ModelFailure(name: "refusal"))]
        do { _ = try await make(model).run(.explain, on: "private words"); XCTFail() } catch {
            let shown = (error as? IntelligenceError)?.errorDescription ?? ""
            XCTAssertFalse(shown.contains("secret text"), "what was sent is never in an error")
            XCTAssertFalse(shown.contains("private words"))
        }
    }

    func testEmptyTextAndEmptyAnswersAreRefused() async {
        let model = FakeTextModel()
        let service = make(model)
        do { _ = try await service.run(.summarize, on: "   \n"); XCTFail() } catch { XCTAssertEqual(error as? IntelligenceError, .emptyText) }
        model.answers = [.success("   ")]
        do { _ = try await service.run(.summarize, on: "real text"); XCTFail() } catch { XCTAssertEqual(error as? IntelligenceError, .failed) }
        do { _ = try await service.run(.custom(instruction: ""), on: "real text"); XCTFail() } catch { XCTAssertEqual(error as? IntelligenceError, .failed) }
        XCTAssertEqual(model.asked.count, 1, "a task that fails its own check is never sent")
    }

    func testTheResultLanguageIsAskedForWhenSetAndSettingsSurviveARestart() async throws {
        let defaults = UserDefaults(suiteName: "kriya-ai-\(UUID().uuidString)")!
        let model = FakeTextModel()
        let first = AppleIntelligence(model: model, defaults: defaults, watchSystem: false)
        first.update { $0.outputLanguage = "  French  "; $0.inLauncher = false }
        _ = try await first.run(.summarize, on: "Some text")
        XCTAssertTrue(model.asked[0].instructions.hasSuffix("Write the result in French."))
        let again = AppleIntelligence(model: model, defaults: defaults, watchSystem: false)
        XCTAssertEqual(again.settings.outputLanguage, "French")
        XCTAssertFalse(again.settings.inLauncher)
        XCTAssertTrue(again.settings.inSelectionBar)
        first.update { $0.outputLanguage = "" }
        _ = try await first.run(.summarize, on: "Some text")
        XCTAssertFalse(model.asked[1].instructions.contains("Write the result in"))
    }

    func testAvailabilityIsReadAgainWhenAskedFor() {
        let model = FakeTextModel()
        model.status = .modelNotReady
        let service = make(model)
        XCTAssertEqual(service.availability, .modelNotReady)
        model.status = .available
        service.refresh()
        XCTAssertTrue(service.isAvailable)
    }
}

final class IntelligenceActionsTests: XCTestCase {
    func testTheShippedActionsShareOneGroupAndStartShort() {
        let actions = selectionDefaultActions().filter { $0.id.hasPrefix("ai-") }
        XCTAssertEqual(actions.count, 8)
        XCTAssertTrue(actions.allSatisfy { $0.group == intelligenceGroup() })
        XCTAssertEqual(actions.filter(\.enabled).count, 5)
        for action in actions { if case .intelligence = action.kind {} else { XCTFail("\(action.id) is not an Apple Intelligence action") } }
    }

    func testOnlyRewritingTasksReplaceTheSelection() {
        XCTAssertTrue(intelligenceReplacesSelection(task: .fixGrammar))
        XCTAssertFalse(intelligenceReplacesSelection(task: .summarize))
        XCTAssertNotNil(intelligenceCheck(task: .custom(instruction: " ")))
        XCTAssertNil(intelligenceCheck(task: .custom(instruction: "make it a haiku")))
    }

    func testEveryTaskHasAChoiceInTheEditorAndBack() {
        for choice in AITaskChoice.allCases {
            let task = choice.task(instruction: "x")
            XCTAssertEqual(AITaskChoice(task), choice)
            XCTAssertFalse(choice.title.isEmpty)
        }
    }

    func testAnActionWithNothingToDoIsRefusedWhenSaved() throws {
        let world = try TestWorld()
        defer { world.cleanUp() }
        let store = SelectionStore(core: world.core)
        let bad = SelectionAction(id: "x", title: "Mine", symbol: "star", kind: .intelligence(task: .custom(instruction: "")), enabled: true, applies: .anything, appIds: [])
        store.upsert(bad)
        XCTAssertNotNil(store.lastError)
        XCTAssertFalse(store.actions.contains { $0.id == "x" })
    }
}

final class LauncherIntelligenceTests: XCTestCase {
    func testAQuestionIsRecognisedByItsPrefix() {
        XCTAssertEqual(LauncherSources.question(in: "ask what is a monad"), "what is a monad")
        XCTAssertEqual(LauncherSources.question(in: "AI   explain DNS  "), "explain DNS")
        XCTAssertEqual(LauncherSources.question(in: "? why is the sky blue"), "why is the sky blue")
        XCTAssertNil(LauncherSources.question(in: "ask"), "nothing asked")
        XCTAssertNil(LauncherSources.question(in: "ask me"), "too short to be a question")
        XCTAssertNil(LauncherSources.question(in: "asking about it"))
        XCTAssertNil(LauncherSources.question(in: "safari"))
        XCTAssertEqual(LauncherSources.question(in: "ask " + String(repeating: "x", count: 900))?.count, 500)
    }

    func testTheClipboardIsNotSentWhenItIsSecret() {
        let board = NSPasteboard(name: NSPasteboard.Name("kriya-ai-test-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.clearContents()
        board.setString("Please summarize this meeting note.", forType: .string)
        XCTAssertEqual(LauncherSources.plainClipboardText(from: board), "Please summarize this meeting note.")
        board.clearContents()
        board.setString("a password", forType: .string)
        board.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        XCTAssertNil(LauncherSources.plainClipboardText(from: board), "marked secret by the app that copied it")
        board.clearContents()
        board.setString("4111111111111111", forType: .string)
        XCTAssertNil(LauncherSources.plainClipboardText(from: board), "looks like a card number")
        board.clearContents()
        board.setString("   ", forType: .string)
        XCTAssertNil(LauncherSources.plainClipboardText(from: board))
    }

    func testTheLauncherHasAKindForIt() {
        XCTAssertTrue(LauncherCategory.allCases.contains(.intelligence))
        XCTAssertEqual(LauncherCategory.intelligence.label, "AI")
        XCTAssertFalse(LauncherCategory.intelligence.detail.isEmpty)
    }
}
