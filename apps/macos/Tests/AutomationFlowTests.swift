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

    func testVariablesFillInTextAndUnknownNamesStay() {
        XCTAssertEqual(workflowRenderVariables(template: "Hi {{who}} {{missing}}", names: ["who"], values: ["Ann"]), "Hi Ann {{missing}}")
    }
}
