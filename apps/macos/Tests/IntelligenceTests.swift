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

/// Enough text that a summary is worth asking for.
private let longEnough = String(repeating: "This sentence is here so there is something to summarize. ", count: 4)

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
            _ = try await service.run(.summarize, on: longEnough)
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

    func testAShortTextIsNotSummarizedAndTheErrorSaysWhy() async throws {
        let model = FakeTextModel()
        let service = make(model)
        let partial = "Start cheaply with local normalization, fuzzy matching, guide search, and p"
        do { _ = try await service.run(.summarize, on: partial); XCTFail("should not run") } catch {
            XCTAssertEqual(error as? IntelligenceError, .tooShortToSummarize(partial.count))
            XCTAssertTrue((error as? IntelligenceError)?.errorDescription?.contains("\(partial.count) characters") == true)
        }
        do { _ = try await service.run(.keyPoints, on: "Too short."); XCTFail() } catch { XCTAssertNotNil(error as? IntelligenceError) }
        XCTAssertTrue(model.asked.isEmpty, "nothing was sent")
        // Rewrites and explanations are still fine on a short text.
        model.answers = [.success("Fixed.")]
        let out = try await service.run(.fixGrammar, on: "teh cat")
        XCTAssertEqual(out.text, "Fixed.")
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
        do { _ = try await service.run(.fixGrammar, on: "real text"); XCTFail() } catch { XCTAssertEqual(error as? IntelligenceError, .failed) }
        do { _ = try await service.run(.custom(instruction: ""), on: "real text"); XCTFail() } catch { XCTAssertEqual(error as? IntelligenceError, .failed) }
        XCTAssertEqual(model.asked.count, 1, "a task that fails its own check is never sent")
    }

    func testTheResultLanguageIsAskedForWhenSetAndSettingsSurviveARestart() async throws {
        let defaults = UserDefaults(suiteName: "kriya-ai-\(UUID().uuidString)")!
        let model = FakeTextModel()
        let first = AppleIntelligence(model: model, defaults: defaults, watchSystem: false)
        first.update { $0.outputLanguage = "  French  "; $0.inLauncher = false }
        _ = try await first.run(.summarize, on: longEnough)
        XCTAssertTrue(model.asked[0].instructions.hasSuffix("Write the result in French."))
        let again = AppleIntelligence(model: model, defaults: defaults, watchSystem: false)
        XCTAssertEqual(again.settings.outputLanguage, "French")
        XCTAssertFalse(again.settings.inLauncher)
        XCTAssertTrue(again.settings.inSelectionBar)
        first.update { $0.outputLanguage = "" }
        _ = try await first.run(.summarize, on: longEnough)
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

final class IntelligenceReadingTests: XCTestCase {
    func testALongerReadingOfTheSameSelectionReplacesAPartialOne() {
        let partial = "Start cheaply with local normalization, fuzzy matching, guide search, and p"
        let whole = partial + "lay with it. Then add the rest of the plan in a second paragraph."
        XCTAssertEqual(SelectionActionRunner.fuller(partial, whole), whole)
        XCTAssertEqual(SelectionActionRunner.fuller(whole, partial), whole, "a shorter reading never replaces a fuller one")
        XCTAssertEqual(SelectionActionRunner.fuller(partial, nil), partial)
        XCTAssertEqual(SelectionActionRunner.fuller(partial, partial), partial)
    }

    func testADifferentSelectionIsNeverTaken() {
        let first = "The first thing the person selected."
        let other = "Something else entirely that the person selected afterwards and is longer."
        XCTAssertEqual(SelectionActionRunner.fuller(first, other), first)
        XCTAssertEqual(SelectionActionRunner.fuller("   ", other), "   ", "nothing to match against")
    }
}

final class IntelligencePanelPlacementTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 80, width: 1440, height: 800)   // 80 points taken by the Dock at the bottom
    private let size = NSSize(width: 440, height: 300)

    private func inside(_ point: NSPoint) -> Bool {
        CGRect(origin: point, size: size).insetBy(dx: -0.01, dy: -0.01).intersection(screen) == CGRect(origin: point, size: size).insetBy(dx: -0.01, dy: -0.01)
    }

    func testItSitsJustBelowThePointerWhenThereIsRoom() {
        let origin = IntelligencePanel.origin(size: size, near: NSPoint(x: 700, y: 700), in: screen)
        XCTAssertEqual(origin.y, 700 - 24 - 300, accuracy: 0.01)
        XCTAssertEqual(origin.x, 700 - 220, accuracy: 0.01)
        XCTAssertTrue(inside(origin))
    }

    func testItGoesAboveWhenThePointerIsLowOnTheScreen() {
        let origin = IntelligencePanel.origin(size: size, near: NSPoint(x: 700, y: 200), in: screen)
        XCTAssertGreaterThan(origin.y, 200, "above the pointer, not under the Dock")
        XCTAssertTrue(inside(origin))
    }

    func testItNeverLeavesTheScreenInAnyCorner() {
        for x in stride(from: CGFloat(0), through: 1440, by: 240) {
            for y in stride(from: CGFloat(80), through: 880, by: 100) {
                XCTAssertTrue(inside(IntelligencePanel.origin(size: size, near: NSPoint(x: x, y: y), in: screen)), "pointer at \(x), \(y)")
            }
        }
        XCTAssertTrue(inside(IntelligencePanel.origin(size: size, near: nil, in: screen)))
    }

    func testASmallScreenStillGetsAWindowAsFarOnAsItCanBe() {
        let tiny = CGRect(x: 0, y: 0, width: 300, height: 200)
        let origin = IntelligencePanel.origin(size: size, near: NSPoint(x: 150, y: 100), in: tiny)
        XCTAssertGreaterThanOrEqual(origin.x, tiny.minX)
        XCTAssertGreaterThanOrEqual(origin.y, tiny.minY)
    }
}

final class QuickPanelTests: XCTestCase {
    private let size = NSSize(width: 420, height: 500)
    private let screen = CGRect(x: 0, y: 40, width: 1440, height: 860)

    func testASavedPlaceIsUsedWhileMostOfTheWindowIsStillOnAScreen() {
        XCTAssertEqual(QuickPanelPosition.usable(NSPoint(x: 300, y: 200), size: size, screens: [screen]), NSPoint(x: 300, y: 200))
        // Partly off the right edge (more than half still on the screen): moved back in, not forgotten.
        let nudged = QuickPanelPosition.usable(NSPoint(x: 1200, y: 200), size: size, screens: [screen])
        XCTAssertNotNil(nudged)
        XCTAssertLessThanOrEqual((nudged?.x ?? 0) + size.width, screen.maxX)
    }

    func testAPlaceThatIsNowOffEveryScreenIsNotUsed() {
        XCTAssertNil(QuickPanelPosition.usable(NSPoint(x: 5000, y: 200), size: size, screens: [screen]), "the display it was on is gone")
        XCTAssertNil(QuickPanelPosition.usable(nil, size: size, screens: [screen]))
        XCTAssertNil(QuickPanelPosition.usable(NSPoint(x: 10, y: 10), size: size, screens: []))
    }

    func testTheSecondDisplayIsUsedWhenThatIsWhereItWasLeft() {
        let second = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        let place = QuickPanelPosition.usable(NSPoint(x: 2000, y: 300), size: size, screens: [screen, second])
        XCTAssertEqual(place, NSPoint(x: 2000, y: 300))
    }

    func testThePlaceAndThePreferenceSurviveBeingSaved() {
        let defaults = UserDefaults.standard
        let savedBefore = defaults.string(forKey: "quickPasteOrigin"), placementBefore = defaults.string(forKey: "quickPastePlacement")
        defer {
            defaults.set(savedBefore, forKey: "quickPasteOrigin")
            defaults.set(placementBefore, forKey: "quickPastePlacement")
        }
        QuickPanelPosition.save(NSPoint(x: 123.5, y: 456.25))
        XCTAssertEqual(QuickPanelPosition.saved, NSPoint(x: 123.5, y: 456.25))
        defaults.removeObject(forKey: "quickPastePlacement")
        XCTAssertEqual(QuickPanelPlacement.current, .atPointer, "opening at the pointer is the default")
        QuickPanelPlacement.current = .remembered
        XCTAssertEqual(QuickPanelPlacement.current, .remembered)
        defaults.set("not a place", forKey: "quickPasteOrigin")
        XCTAssertNil(QuickPanelPosition.saved)
    }

    func testPinningSavingAsASnippetAndDeletingWorkOnTheItemThatWasRightClicked() throws {
        let world = try TestWorld()
        defer { world.cleanUp() }
        let store = ClipboardStore(core: world.core, keyStore: MemoryVaultKeyStore())
        func copy(_ text: String) { _ = store.record(NewClip(text: text, rich: nil, richFormat: nil, image: nil, imageFormat: nil, imageWidth: nil, imageHeight: nil, files: [], sourceApp: "app.test", concealed: false)) }
        copy("first"); copy("second"); copy("third")
        let model = QuickClipModel(store: store)
        model.open()
        // Items copied in the same second have no set order among themselves, so they are found by what they say.
        XCTAssertEqual(Set(model.results.map(\.preview)), ["first", "second", "third"])
        let first = try XCTUnwrap(model.results.first { $0.preview == "first" })
        model.togglePin(first)
        XCTAssertEqual(model.results.first?.preview, "first", "pinned items come first")
        XCTAssertTrue(model.results.first?.pinned == true)
        model.togglePin(try XCTUnwrap(model.results.first))
        XCTAssertFalse(try XCTUnwrap(model.results.first { $0.preview == "first" }).pinned)
        let second = try XCTUnwrap(model.results.first { $0.preview == "second" })
        model.toggleSnippet(second)
        XCTAssertTrue(try XCTUnwrap(model.results.first { $0.preview == "second" }).favorite)
        model.select(0)
        let selectedID = model.current?.id
        let other = try XCTUnwrap(model.results.last { $0.id != selectedID })
        model.remove(other)
        XCTAssertEqual(model.results.count, 2)
        XCTAssertEqual(model.current?.id, selectedID, "the selection stays on the same item")
        model.remove(try XCTUnwrap(model.results.first))
        XCTAssertEqual(model.results.count, 1)
        XCTAssertNotNil(model.current)
    }
}
