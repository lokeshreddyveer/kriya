import XCTest
@testable import Kriya

final class AutomationFlowTests: XCTestCase {
    private func make() throws -> (TestWorld, AutomationEngine) {
        let world = try TestWorld()
        let engine = AutomationEngine(store: WorkflowStore(core: world.core))
        engine.context = world.makeContext()
        return (world, engine)
    }

    private func save(_ engine: AutomationEngine, _ steps: [WorkflowStep], timeout: UInt32 = 30) throws -> Workflow {
        var w = engine.store.newWorkflow()
        w.name = "Flow"
        w.enabled = true
        w.timeoutSeconds = timeout
        w.steps = steps
        return try XCTUnwrap(engine.store.save(w))
    }

    private func run(_ engine: AutomationEngine, _ w: Workflow) async -> WorkflowRun {
        await engine.execute(w, source: "Test", input: "", depth: 0, test: true, dryRun: false, approvedForTest: true, progress: nil)
    }

    func testVariablesLoopsAndJavaScriptWorkTogether() async throws {
        let (world, engine) = try make()
        defer { world.cleanUp() }
        let store = engine.store
        let build = store.newStep(.setVariable(name: "acc", template: ""))
        let append = store.newStep(.setVariable(name: "acc", template: "{{acc}}{{loop}}"))
        let loop = store.newStep(.repeat(times: 3, steps: [append]))
        let read = store.newStep(.javaScript(source: "vars.acc"))
        let w = try save(engine, [build, loop, read])
        let result = await run(engine, w)
        XCTAssertEqual(result.status, .succeeded, result.error ?? "")
        XCTAssertEqual(result.steps.last?.message, "123", "the loop counted 1, 2, 3 into the variable")
    }

    func testAFailingStepIsTriedAgainThenGivenUp() async throws {
        let (world, engine) = try make()
        defer { world.cleanUp() }
        var failing = engine.store.newStep(.textTransform(ops: [.jsonFormat]))
        failing.retries = 2
        failing.retryDelayMs = 0
        let w = try save(engine, [failing])
        let result = await engine.execute(w, source: "Test", input: "not json", depth: 0, test: true, dryRun: false, approvedForTest: true, progress: nil)
        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.steps.filter { $0.status == .failed }.count, 3, "the first try and two more")
        XCTAssertTrue(result.steps.last?.message?.contains("after 3 tries") ?? false)
    }

    func testParallelStepsAllRun() async throws {
        let (world, engine) = try make()
        defer { world.cleanUp() }
        let a = engine.store.newStep(.setVariable(name: "a", template: "1"))
        let b = engine.store.newStep(.setVariable(name: "b", template: "2"))
        let both = engine.store.newStep(.parallel(steps: [a, b]))
        let read = engine.store.newStep(.javaScript(source: "vars.a + vars.b"))
        let result = await run(engine, try save(engine, [both, read]))
        XCTAssertEqual(result.status, .succeeded, result.error ?? "")
        XCTAssertEqual(result.steps.last?.message, "12")
    }

    func testAJavaScriptErrorFailsTheStepWithItsMessage() async throws {
        let (world, engine) = try make()
        defer { world.cleanUp() }
        let w = try save(engine, [engine.store.newStep(.javaScript(source: "throw new Error('boom')"))])
        let result = await run(engine, w)
        XCTAssertEqual(result.status, .failed)
        XCTAssertTrue(result.error?.contains("boom") ?? false)
    }

    func testAStepTimeLimitStopsASlowStep() async throws {
        let (world, engine) = try make()
        defer { world.cleanUp() }
        var slow = engine.store.newStep(.script(language: .shell, source: "sleep 20"))
        slow.timeoutSeconds = 1
        let started = Date()
        let result = await run(engine, try save(engine, [slow], timeout: 60))
        XCTAssertEqual(result.status, .failed)
        XCTAssertLessThan(Date().timeIntervalSince(started), 15)
    }

    func testAddingTheSameLoopTwiceGivesDifferentStepIDs() {
        let template = workflowStepCatalog().first { template in
            if case .repeat = template.kind { return true }
            return false
        }
        guard let kind = template?.kind else { return XCTFail("the catalog has a loop") }
        let first = WorkflowStore.withFreshIDs(kind).children.map(\.id)
        let second = WorkflowStore.withFreshIDs(kind).children.map(\.id)
        XCTAssertFalse(first.isEmpty)
        XCTAssertTrue(Set(first).isDisjoint(with: Set(second)))
    }

    func testTheMacroMenuListsThisAppsGroupsFirst() throws {
        let world = try TestWorld()
        defer { world.cleanUp() }
        let store = WorkflowStore(core: world.core)
        var general = store.newWorkflow()
        general.id = "g"; general.name = "Everywhere"; general.enabled = true; general.group = "Tools"
        general.steps = [store.newStep(.delay(ms: 1))]
        var specific = general
        specific.id = "s"; specific.name = "Only Safari"; specific.group = "Page"; specific.appIds = ["com.apple.Safari"]
        XCTAssertEqual(workflowMacroMenu(workflows: [general, specific], frontApp: "com.apple.Safari").map(\.name), ["Page", "Tools"])
        XCTAssertEqual(workflowMacroMenu(workflows: [general, specific], frontApp: "com.apple.Notes").map(\.name), ["Tools"])
    }

    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: @MainActor () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if await MainActor.run(body: condition) { return true }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        return await MainActor.run(body: condition)
    }

    func testTheDebuggerWaitsBeforeEachStepShowsVariablesAndCanBeStopped() async throws {
        let (world, engine) = try make()
        defer { world.cleanUp() }
        let first = engine.store.newStep(.setVariable(name: "a", template: "1"))
        let second = engine.store.newStep(.setVariable(name: "b", template: "2"))
        let third = engine.store.newStep(.setVariable(name: "c", template: "3"))
        let w = try save(engine, [first, second, third])
        let debugger = WorkflowDebugger(stepping: true)
        let finished = expectation(description: "the run ended")
        final class Outcome { var status: RunStatus? }
        let outcome = Outcome()
        Task {
            let run = await engine.execute(w, source: "Test", input: "", depth: 0, test: true, dryRun: false, approvedForTest: true, progress: nil, debugger: debugger)
            outcome.status = run.status
            finished.fulfill()
        }
        let waitingAtFirst = await waitUntil { debugger.isWaiting }
        XCTAssertTrue(waitingAtFirst, "it waits before the first step")
        let startedWithNothing = await MainActor.run { debugger.variables.isEmpty }
        XCTAssertTrue(startedWithNothing)
        debugger.step()
        let sawA = await waitUntil { debugger.isWaiting && debugger.variables.contains { $0.name == "a" && $0.value == "1" } }
        XCTAssertTrue(sawA, "after one step the variable is there, and it waits again")
        debugger.stop()
        await fulfillment(of: [finished], timeout: 5)
        XCTAssertEqual(outcome.status, .cancelled)
    }

    func testABreakpointLetsTheRunGoOnUntilItIsReached() async throws {
        let (world, engine) = try make()
        defer { world.cleanUp() }
        let steps = ["a", "b", "c"].map { engine.store.newStep(.setVariable(name: $0, template: $0.uppercased())) }
        let w = try save(engine, steps)
        let debugger = WorkflowDebugger(stepping: false, breakpoints: [steps[2].id])
        let finished = expectation(description: "the run ended")
        Task {
            _ = await engine.execute(w, source: "Test", input: "", depth: 0, test: true, dryRun: false, approvedForTest: true, progress: nil, debugger: debugger)
            finished.fulfill()
        }
        let atThird = await waitUntil { debugger.isWaiting }
        XCTAssertTrue(atThird)
        let names = await MainActor.run { debugger.variables.map(\.name) }
        XCTAssertEqual(names, ["a", "b"], "the first two ran without stopping")
        debugger.resume()
        await fulfillment(of: [finished], timeout: 5)
    }

    func testVariablesFillAnAddressToOpenAndAreEncoded() throws {
        let (world, engine) = try make()
        defer { world.cleanUp() }
        _ = engine
        var rc = AutomationEngine.RunContext(text: "", handle: RunHandle(workflowID: "w"), deadline: Date().addingTimeInterval(5), limitSeconds: 5, depth: 0, dryRun: false, test: true, approvedForTest: true)
        rc.variables = ["q": "a&b c/d"]
        let replaced = AutomationEngine.substitutingVariables(in: .openUrl(url: "https://duckduckgo.com/?q={{q}}"), rc)
        XCTAssertEqual(replaced, .openUrl(url: "https://duckduckgo.com/?q=a%26b%20c%2Fd"))
        XCTAssertEqual(AutomationEngine.substitutingVariables(in: .openUrl(url: "https://example.com"), rc), .openUrl(url: "https://example.com"))
    }

    func testTemplatesBecomeNewWorkflowsWithTheirOwnIDs() throws {
        let world = try TestWorld()
        defer { world.cleanUp() }
        let store = WorkflowStore(core: world.core)
        let templates = workflowTemplates()
        XCTAssertGreaterThanOrEqual(templates.count, 5)
        for template in templates {
            let first = store.workflow(from: template)
            let second = store.workflow(from: template)
            XCTAssertNotEqual(first.id, second.id)
            XCTAssertTrue(Set(first.steps.map(\.id)).isDisjoint(with: Set(second.steps.map(\.id))))
            XCTAssertFalse(first.enabled)
            XCTAssertNil(workflowProblem(workflow: first), template.title)
        }
    }

    func testAPackageIsDescribedBeforeItIsImported() throws {
        let world = try TestWorld()
        defer { world.cleanUp() }
        let store = WorkflowStore(core: world.core)
        // A workflow can only be saved while the one it starts exists; the package then travels without it.
        var helper = store.newWorkflow()
        helper.name = "Helper"
        helper.steps = [store.newStep(.script(language: .shell, source: "ls"))]
        let savedHelper = try XCTUnwrap(store.save(helper), store.lastError ?? "no reason given")
        var w = store.newWorkflow()
        w.name = "Calls a helper"
        w.steps = [store.newStep(.runWorkflow(workflowId: savedHelper.id)), store.newStep(.script(language: .shell, source: "ls"))]
        let saved = try XCTUnwrap(store.save(w), store.lastError ?? "no reason given")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("kriya-pkg-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try store.export([saved.id], to: file)
        // Read on another Mac, which does not have the helper.
        let other = try TestWorld()
        defer { other.cleanUp() }
        let report = WorkflowStore(core: other.core).report(for: file)
        XCTAssertEqual(report.workflows, ["Calls a helper"])
        XCTAssertEqual(report.missingWorkflows, [savedHelper.id])
        XCTAssertFalse(report.riskySteps.isEmpty)
        XCTAssertFalse(store.report(for: FileManager.default.temporaryDirectory.appendingPathComponent("nothing-here.json")).problems.isEmpty)
    }

    func testVariablesFillInTextAndUnknownNamesStay() {
        XCTAssertEqual(workflowRenderVariables(template: "Hi {{who}} {{missing}}", names: ["who"], values: ["Ann"]), "Hi Ann {{missing}}")
    }
}
