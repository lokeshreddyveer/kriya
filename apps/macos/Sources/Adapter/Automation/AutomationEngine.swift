import AppKit
import Combine
import JavaScriptCore

extension Notification.Name {
    static let kriyaClipboardRecorded = Notification.Name("app.kriya.clipboardRecorded")
    static let kriyaWindowPlaced = Notification.Name("app.kriya.windowPlaced")
}

struct WorkflowError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// A run in progress, so it can be stopped.
final class RunHandle {
    let id = UUID().uuidString
    let workflowID: String
    let token = CancelToken()
    init(workflowID: String) { self.workflowID = workflowID }
    var isCancelled: Bool { token.isCancelled || Task.isCancelled }
    func cancel() { token.cancel() }
}

/// Runs workflows: checks they may run, evaluates conditions, carries out the steps one after another, enforces the time
/// limit, and writes down what happened. Everything a step can do goes through the same shared parts the rest of Kriya uses.
final class AutomationEngine: ObservableObject {
    let store: WorkflowStore
    @Published private(set) var running: [String: String] = [:]   // run id → workflow name
    @Published private(set) var isActive = false
    /// While true no trigger starts a workflow (test runs from the editor still work). Kept across launches, and shown in the pane.
    @Published private(set) var pausedAll = UserDefaults.standard.bool(forKey: "automation.pausedAll")

    var context: ServiceContext?
    var setFeature: (FeatureId, Bool) -> Void = { _, _ in }

    private let toast = Toast()
    private let lock = NSLock()
    private var handles: [String: RunHandle] = [:]
    private var starts: [String: [Date]] = [:]
    private var lastBlockedNote: [String: Date] = [:]
    private var hub: TriggerHub?

    /// Starts of one workflow within this window above this count are refused, so a loop of triggers cannot run away.
    private static let rateWindow: TimeInterval = 10
    private static let rateLimit = 8

    init(store: WorkflowStore) {
        self.store = store
    }

    // MARK: Lifecycle

    func start(context: ServiceContext) {
        guard !isActive else { return }
        self.context = context
        isActive = true
        let hub = TriggerHub(engine: self, context: context)
        self.hub = hub
        hub.update(store.workflows)
        store.$workflows
            .receive(on: DispatchQueue.main)
            .sink { [weak self] list in
                self?.hub?.update(list)
                self?.registerCommands(list)
            }
            .store(in: &cancellables)
        registerCommands(store.workflows)
        Log.info("Automation", "Automation started")
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        cancellables.removeAll()
        cancelAll()
        hub?.stop()
        hub = nil
        unregisterCommands()
        context = nil
    }

    private var cancellables = Set<AnyCancellable>()
    private var registered: Set<String> = []

    /// Every workflow can be run by name (`workflow.<id>`) from anything that runs commands: keyboard shortcuts, mouse
    /// button rules, gestures, the Finder menu, the selection bar and the command launcher.
    private func registerCommands(_ list: [Workflow]) {
        guard let executor = context?.executor else { return }
        unregisterCommands()
        executor.registerCommand("automation.macros") { [weak self] in self?.showMacroMenu() }
        registered.insert("automation.macros")
        executor.registerCommand("automation.pause_toggle") { [weak self] in DispatchQueue.main.async { guard let self else { return }; self.setPausedAll(!self.pausedAll) } }
        executor.registerCommand("automation.emergency_stop") { [weak self] in DispatchQueue.main.async { self?.emergencyStop() } }
        registered.insert("automation.pause_toggle")
        registered.insert("automation.emergency_stop")
        for workflow in list where workflow.enabled {
            let id = workflow.id
            let command = workflowCommand(workflow: workflow)
            executor.registerCommand(command) { [weak self] in self?.fire(id, source: "Command") }
            registered.insert(command)
        }
    }

    /// A menu at the pointer of the workflows that belong to a group, those for the app in front first.
    func showMacroMenu() {
        DispatchQueue.main.async {
            let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            let groups = workflowMacroMenu(workflows: self.store.workflows, frontApp: front)
            let menu = NSMenu(title: "Macros")
            menu.autoenablesItems = false
            let chosen = MenuChoice()
            var ids: [String] = []
            if groups.isEmpty {
                let none = NSMenuItem(title: "No macros for this app. Give a workflow a macro menu group.", action: nil, keyEquivalent: "")
                none.isEnabled = false
                menu.addItem(none)
            }
            for (position, group) in groups.enumerated() {
                if position > 0 { menu.addItem(.separator()) }
                let header = NSMenuItem(title: group.name, action: nil, keyEquivalent: "")
                header.isEnabled = false
                menu.addItem(header)
                for item in group.items {
                    let entry = NSMenuItem(title: item.name, action: #selector(MenuChoice.pick(_:)), keyEquivalent: "")
                    entry.target = chosen
                    entry.tag = ids.count
                    entry.indentationLevel = 1
                    ids.append(item.id)
                    menu.addItem(entry)
                }
            }
            NSApp.activate(ignoringOtherApps: true)
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
            if let index = chosen.index, ids.indices.contains(index) { self.fire(ids[index], source: "Macro menu") }
        }
    }

    private func unregisterCommands() {
        guard let executor = context?.executor else { return }
        for command in registered { executor.unregisterCommand(command) }
        registered.removeAll()
    }

    // MARK: Starting and stopping runs

    /// Starts a workflow. `input` is the text it works on (a selection, file paths, what was copied).
    func fire(
        _ workflowID: String, source: String, input: String? = nil, test: Bool = false, dryRun: Bool = false, approvedForTest: Bool = false,
        progress: ((StepResult) -> Void)? = nil, completion: ((WorkflowRun) -> Void)? = nil, debugger: WorkflowDebugger? = nil
    ) {
        guard let workflow = store.workflow(workflowID) else { return }
        if !workflow.enabled && !test { return }
        if pausedAll && !test {
            Log.info("Automation", "Skipped a run: automation is paused")
            return
        }
        Task { [weak self] in
            guard let self else { return }
            let run = await execute(workflow, source: source, input: input ?? "", depth: 0, test: test, dryRun: dryRun, approvedForTest: approvedForTest, progress: progress, debugger: debugger)
            await MainActor.run { completion?(run) }
        }
    }

    func setPausedAll(_ paused: Bool) {
        pausedAll = paused
        UserDefaults.standard.set(paused, forKey: "automation.pausedAll")
        AuditLog.shared.record(.setting, paused ? "All automation paused" : "Automation resumed")
        toast.show(paused ? "All automation paused" : "Automation resumed")
    }

    /// Pauses everything and stops what is running now.
    func emergencyStop() {
        let count = running.count
        cancelAll()
        setPausedAll(true)
        toast.show(count > 0 ? "Stopped \(count) running workflow\(count == 1 ? "" : "s") and paused automation" : "Automation paused")
    }

    func cancel(runID: String) {
        lock.lock()
        let handle = handles[runID]
        lock.unlock()
        handle?.cancel()
    }

    func cancelAll() {
        lock.lock()
        let all = Array(handles.values)
        lock.unlock()
        all.forEach { $0.cancel() }
    }

    func isRunning(_ workflowID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return handles.values.contains { $0.workflowID == workflowID }
    }

    // MARK: Running

    func execute(
        _ workflow: Workflow, source: String, input: String, depth: Int, test: Bool, dryRun: Bool, approvedForTest: Bool,
        progress: ((StepResult) -> Void)?, debugger: WorkflowDebugger? = nil
    ) async -> WorkflowRun {
        let started = SystemInfo.nowSeconds
        let clock = DispatchTime.now()
        func elapsed() -> UInt32 { UInt32(min(Double(UInt32.max), Double(DispatchTime.now().uptimeNanoseconds - clock.uptimeNanoseconds) / 1_000_000)) }
        func finish(_ status: RunStatus, _ error: String?, _ steps: [StepResult]) -> WorkflowRun {
            WorkflowRun(id: UUID().uuidString, workflowId: workflow.id, workflowName: workflow.name, revision: workflow.revision, trigger: source, startedAt: started,
                        durationMs: elapsed(), status: status, error: error, steps: steps, test: test || dryRun)
        }

        // 1. May it run at all?
        if !dryRun {
            if workflowNeedsAuthorization(workflow: workflow) && !(test && approvedForTest) {
                let run = finish(.blocked, "It runs code or controls other apps, so you need to authorize it first in Automation › Workflows.", [])
                recordAndReport(run, workflow)
                return run
            }
            if depth == 0, isRunning(workflow.id), !workflow.allowParallel {
                let run = finish(.blocked, "It was already running.", [])
                recordBlockedRarely(run, workflow)
                return run
            }
            if tooOften(workflow.id) {
                let run = finish(.blocked, "It started more than \(Self.rateLimit) times in \(Int(Self.rateWindow)) seconds, so this start was refused.", [])
                recordBlockedRarely(run, workflow)
                return run
            }
        }
        if let guardGroup = workflow.conditions, !(await conditionsHold(guardGroup)) {
            let run = finish(.skipped, nil, [])
            if test || dryRun { recordAndReport(run, workflow) }
            return run
        }

        let handle = RunHandle(workflowID: workflow.id)
        lock.lock()
        handles[handle.id] = handle
        lock.unlock()
        await MainActor.run { running[handle.id] = workflow.name }
        defer {
            lock.lock()
            handles[handle.id] = nil
            lock.unlock()
            Task { @MainActor [weak self] in self?.running[handle.id] = nil }
        }

        // 2. The steps.
        var rc = RunContext(text: input, handle: handle, deadline: Date().addingTimeInterval(TimeInterval(workflow.timeoutSeconds)), limitSeconds: Int(workflow.timeoutSeconds), depth: depth, dryRun: dryRun, test: test, approvedForTest: approvedForTest, debugger: debugger)
        var results: [StepResult] = []
        var status = RunStatus.succeeded
        var failure: String?
        if case .stop(let why, let message) = await runSteps(workflow.steps, prefix: "", rc: &rc, results: &results, progress: progress) {
            status = why
            failure = message
        }
        let run = finish(status, failure, results)
        recordAndReport(run, workflow)
        return run
    }

    // MARK: Safety

    /// Counts a start and says whether the workflow is starting too often.
    private func tooOften(_ id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        var recent = (starts[id] ?? []).filter { now.timeIntervalSince($0) < Self.rateWindow }
        recent.append(now)
        starts[id] = recent
        return recent.count > Self.rateLimit
    }

    private func recordAndReport(_ run: WorkflowRun, _ workflow: Workflow) {
        store.record(run)
        switch run.status {
        case .failed, .timedOut, .blocked:
            if !run.test { toast.show("“\(workflow.name)”: \(run.error ?? run.status.title)", isError: true) }
        default:
            break
        }
    }

    /// A blocked start can repeat many times a second; write it down once a minute.
    private func recordBlockedRarely(_ run: WorkflowRun, _ workflow: Workflow) {
        lock.lock()
        let last = lastBlockedNote[workflow.id]
        let due = last == nil || Date().timeIntervalSince(last!) > 60
        if due { lastBlockedNote[workflow.id] = Date() }
        lock.unlock()
        if due { recordAndReport(run, workflow) }
    }

    // MARK: Conditions

    @MainActor
    private func makeEvalContext() -> EvalContext {
        let calendar = Calendar.current
        let now = Date()
        let minute = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
        let apps = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        let enabled = FeatureId.all.filter { context?.config.isEnabled($0) == true }
        return EvalContext(
            frontApp: NSWorkspace.shared.frontmostApplication?.bundleIdentifier, minuteOfDay: UInt32(minute), weekday: UInt8(calendar.component(.weekday, from: now) - 1),
            displayCount: UInt32(NSScreen.screens.count), clipboardText: NSPasteboard.general.string(forType: .string), enabledFeatures: enabled, runningApps: apps
        )
    }

    private func conditionsHold(_ group: ConditionGroup) async -> Bool {
        let ctx = await MainActor.run { makeEvalContext() }
        return workflowEvaluate(group: group, context: ctx)
    }

    // MARK: Carrying out a step

    struct RunContext {
        var text: String
        let handle: RunHandle
        var deadline: Date
        /// The workflow's whole time limit, for saying so.
        let limitSeconds: Int
        /// Values kept by Keep-a-value, Ask and Choose steps, and `loop` inside a loop. `{{name}}` in a step's text becomes the value.
        var variables: [String: String] = [:]
        let depth: Int
        let dryRun: Bool
        let test: Bool
        let approvedForTest: Bool
        /// Set when a person is watching the run step by step.
        var debugger: WorkflowDebugger?
        var remaining: TimeInterval { max(1, deadline.timeIntervalSinceNow) }
    }

    /// How a list of steps ended: all done (or carried on past a failure), or the run must stop.
    enum Flow: Sendable {
        case proceed
        case stop(RunStatus, String?)
    }

    /// The person said no to a question, which ends the run without it being a failure.
    struct WorkflowDeclined: Error {}
    /// A step inside a loop or a group ended the run; it has already written its own result.
    struct ChildStopped: Error { let status: RunStatus; let message: String? }

    /// Carries out steps in order. Used for the whole workflow and again for the steps inside loops and groups, where `prefix`
    /// says where they are ("Round 2 · ").
    private func runSteps(_ steps: [WorkflowStep], prefix: String, rc: inout RunContext, results: inout [StepResult], progress: ((StepResult) -> Void)?) async -> Flow {
        for (index, step) in steps.enumerated() {
            if rc.handle.isCancelled { return .stop(.cancelled, "Stopped.") }
            if Date() >= rc.deadline { return .stop(.timedOut, "It ran for more than \(rc.limitSeconds) seconds and was stopped.") }
            let title = prefix + workflowStepSummary(step: step)
            let t0 = DispatchTime.now()
            func duration() -> UInt32 { UInt32(min(60_000_000.0, Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000_000)) }
            func record(_ status: StepStatus, _ message: String?) {
                let result = StepResult(index: UInt32(index), title: title, status: status, message: message, durationMs: duration())
                results.append(result)
                progress?(result)
            }
            if let when = step.when, !(await conditionsHold(when)) {
                record(.skipped, "Its condition did not hold.")
                continue
            }
            if rc.dryRun {
                record(.planned, "Would: " + step.kind.summary)
                let inner = step.kind.children
                if !inner.isEmpty { _ = await runSteps(inner, prefix: title + " › ", rc: &rc, results: &results, progress: progress) }
                continue
            }
            if let debugger = rc.debugger, !(await debugger.beforeStep(id: step.id, title: title, variables: rc.variables, text: rc.text)) {
                record(.cancelled, "Stopped in the debugger.")
                return .stop(.cancelled, "Stopped in the debugger.")
            }
            var attempt = 0
            while true {
                // A step's own time limit applies to it alone, inside the workflow's.
                var local = rc
                if let limit = step.timeoutSeconds { local.deadline = min(rc.deadline, Date().addingTimeInterval(TimeInterval(limit))) }
                do {
                    let message: String?
                    switch step.kind {
                    case .repeat(let times, let inner):
                        message = try await performRepeat(Int(times), inner, title: title, &local, &results, progress)
                    case .parallel(let branches):
                        message = try await performParallel(branches, title: title, &local, &results, progress)
                    default:
                        message = try await perform(step.kind, &local)
                    }
                    rc.text = local.text
                    rc.variables = local.variables
                    record(.ok, message)
                    break
                } catch is CancellationError {
                    record(.cancelled, "Stopped.")
                    return .stop(.cancelled, "Stopped.")
                } catch is WorkflowDeclined {
                    record(.cancelled, "You chose not to continue.")
                    return .stop(.cancelled, "You chose not to continue.")
                } catch let child as ChildStopped {
                    rc.text = local.text
                    rc.variables = local.variables
                    record(child.status == .cancelled ? .cancelled : .failed, child.message)
                    return .stop(child.status, child.message)
                } catch {
                    let cancelled = rc.handle.isCancelled
                    let timedOut = Date() >= rc.deadline
                    if !cancelled, !timedOut, attempt < Int(step.retries) {
                        attempt += 1
                        record(.failed, "Try \(attempt) of \(Int(step.retries) + 1) failed: \(error.localizedDescription). Trying again…")
                        try? await pause(Double(step.retryDelayMs) / 1000, rc.handle)
                        continue
                    }
                    let note = attempt > 0 ? " (after \(attempt + 1) tries)" : ""
                    record(cancelled ? .cancelled : .failed, error.localizedDescription + note)
                    if cancelled { return .stop(.cancelled, "Stopped.") }
                    if timedOut { return .stop(.timedOut, "It ran for more than \(rc.limitSeconds) seconds and was stopped.") }
                    if step.onError == .stop { return .stop(.failed, "Step \(prefix)\(index + 1) (\(title)): \(error.localizedDescription)") }
                    break
                }
            }
        }
        return .proceed
    }

    private func performRepeat(_ times: Int, _ steps: [WorkflowStep], title: String, _ rc: inout RunContext, _ results: inout [StepResult], _ progress: ((StepResult) -> Void)?) async throws -> String? {
        for round in 1...max(1, times) {
            rc.variables["loop"] = String(round)
            if case .stop(let status, let message) = await runSteps(steps, prefix: "\(title) › round \(round) · ", rc: &rc, results: &results, progress: progress) {
                throw ChildStopped(status: status, message: message)
            }
        }
        rc.variables["loop"] = nil
        return nil
    }

    /// Runs each branch at the same time, each with its own copy of the variables, and keeps the variables they set afterwards
    /// (the last branch wins a clash). The step stops the run if any branch does.
    private func performParallel(_ branches: [WorkflowStep], title: String, _ rc: inout RunContext, _ results: inout [StepResult], _ progress: ((StepResult) -> Void)?) async throws -> String? {
        let snapshot = rc
        var finished: [(Int, [StepResult], Flow, [String: String])] = []
        await withTaskGroup(of: (Int, [StepResult], Flow, [String: String]).self) { group in
            for (index, branch) in branches.enumerated() {
                group.addTask { [self] in
                    var branchContext = snapshot
                    branchContext.debugger = nil
                    var branchResults: [StepResult] = []
                    let flow = await runSteps([branch], prefix: "\(title) › ", rc: &branchContext, results: &branchResults, progress: progress)
                    return (index, branchResults, flow, branchContext.variables)
                }
            }
            for await item in group { finished.append(item) }
        }
        finished.sort { $0.0 < $1.0 }
        var stop: (RunStatus, String?)?
        for (_, branchResults, flow, variables) in finished {
            results.append(contentsOf: branchResults)
            rc.variables.merge(variables) { _, new in new }
            if stop == nil, case .stop(let status, let message) = flow { stop = (status, message) }
        }
        if let stop { throw ChildStopped(status: stop.0, message: stop.1) }
        return nil
    }

    private func perform(_ kind: StepKind, _ rc: inout RunContext) async throws -> String? {
        guard let context else { throw WorkflowError("Automation is switched off.") }
        switch kind {
        case .action(let action):
            try await runAction(action, rc, context)
            return nil

        case .quitApp(let id, let force):
            let apps = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            if apps.isEmpty { return "It was not running." }
            for app in apps { _ = force ? app.forceTerminate() : app.terminate() }
            return nil

        case .hideApp(let id):
            NSRunningApplication.runningApplications(withBundleIdentifier: id).forEach { _ = $0.hide() }
            return nil

        case .activateApp(let id):
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first else { throw WorkflowError("That app is not running.") }
            app.activate()
            return nil

        case .script(let language, let source):
            AuditLog.shared.record(.script, "Workflow script step (\(language == .shell ? "shell" : "AppleScript")) run")
            let output: String
            switch language {
            case .shell:
                output = try await runTool("/bin/zsh", ["-c", source, "kriya", rc.text], rc, environment: Self.environment(for: rc))
            case .appleScript:
                let script = source.contains("on run") ? source : "on run argv\n\(source)\nend run"
                output = try await runTool("/usr/bin/osascript", ["-e", script, rc.text], rc, environment: Self.environment(for: rc))
            }
            return output.isEmpty ? nil : String(output.prefix(200))

        case .system(let op, let value):
            try await runSystem(op, Int(value), rc)
            return nil

        case .switchMousePreset(let id):
            let known = await MainActor.run { context.mouse.preset(id) != nil }
            guard known else { throw WorkflowError("That mouse preset no longer exists.") }
            await MainActor.run { context.mouse.setDefaultPreset(id) }
            return nil

        case .setFeature(let feature, let enabled):
            await MainActor.run { setFeature(feature, enabled) }
            return nil

        case .setClipboardPaused(let paused):
            await MainActor.run { context.clipboard.setPaused(paused) }
            return nil

        case .delay(let ms):
            try await pause(min(Double(ms) / 1000, rc.remaining), rc.handle)
            return nil

        case .runWorkflow(let id):
            guard rc.depth < Int(workflowMaxChainDepth()) else { throw WorkflowError("Workflows are chained too deeply.") }
            guard let child = store.workflow(id) else { throw WorkflowError("That workflow no longer exists.") }
            let run = await execute(child, source: "Started by “\(rc.handle.workflowID)”", input: rc.text, depth: rc.depth + 1, test: rc.test, dryRun: false, approvedForTest: rc.approvedForTest, progress: nil)
            if run.status == .failed || run.status == .timedOut || run.status == .cancelled || run.status == .blocked {
                throw WorkflowError("“\(child.name)” did not finish: \(run.error ?? run.status.title)")
            }
            return nil

        case .notify(let message):
            toast.show(render(message, rc))
            return nil

        case .textTransform(let ops):
            rc.text = try textApplyAll(ops: ops, text: rc.text)
            return nil

        case .copyText(let template):
            let text = render(template, rc)
            await MainActor.run {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            return nil

        case .insertText(let template):
            guard AXIsProcessTrusted() else { throw WorkflowError("Accessibility permission is needed to type text.") }
            let text = render(template, rc)
            let injector = context.keyboard.injector
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    injector.insert(text, cursorBack: 0)
                    continuation.resume()
                }
            }
            return nil

        case .setVariable(let name, let template):
            rc.variables[name] = render(template, rc)
            return nil

        case .repeat, .parallel:
            // Carried out by `runSteps`, which has the results to add to.
            return nil

        case .confirm(let message):
            let text = render(message, rc)
            guard await Self.askToContinue(text) else { throw WorkflowDeclined() }
            return nil

        case .ask(let prompt, let variable):
            guard let answer = await Self.askForText(render(prompt, rc)) else { throw WorkflowDeclined() }
            rc.variables[variable] = answer
            return nil

        case .choose(let prompt, let options, let variable):
            guard let choice = await Self.chooseFromMenu(render(prompt, rc), options: options.map { render($0, rc) }) else { throw WorkflowDeclined() }
            rc.variables[variable] = choice
            return nil

        case .javaScript(let source):
            let output = try await Self.runJavaScript(source, input: rc.text, variables: rc.variables, seconds: rc.remaining)
            rc.text = output.text
            rc.variables = output.variables
            return output.text.isEmpty ? nil : String(output.text.prefix(200))
        }
    }

    // MARK: Asking the person

    @MainActor
    private static func frontAlert(_ alert: NSAlert) -> NSApplication.ModalResponse {
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal()
    }

    private static func askToContinue(_ message: String) async -> Bool {
        await MainActor.run {
            let alert = NSAlert()
            alert.messageText = message
            alert.addButton(withTitle: "Continue")
            alert.addButton(withTitle: "Stop")
            return frontAlert(alert) == .alertFirstButtonReturn
        }
    }

    private static func askForText(_ prompt: String) async -> String? {
        await MainActor.run {
            let alert = NSAlert()
            alert.messageText = prompt
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
            alert.accessoryView = field
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = field
            return frontAlert(alert) == .alertFirstButtonReturn ? field.stringValue : nil
        }
    }

    /// A menu at the pointer. Nil if it is dismissed without a choice.
    private static func chooseFromMenu(_ title: String, options: [String]) async -> String? {
        await MainActor.run {
            let menu = NSMenu(title: title)
            menu.autoenablesItems = false
            if !title.isEmpty {
                let header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                header.isEnabled = false
                menu.addItem(header)
                menu.addItem(.separator())
            }
            let chosen = MenuChoice()
            for (index, option) in options.enumerated() {
                let item = NSMenuItem(title: option, action: #selector(MenuChoice.pick(_:)), keyEquivalent: "")
                item.target = chosen
                item.tag = index
                menu.addItem(item)
            }
            NSApp.activate(ignoringOtherApps: true)
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
            return chosen.index.flatMap { options.indices.contains($0) ? options[$0] : nil }
        }
    }

    /// Runs JavaScript with `input` and `vars`. The script has no way to reach files, the network or other apps. It is run on
    /// its own thread and given up on if it takes longer than `seconds`.
    private static func runJavaScript(_ source: String, input: String, variables: [String: String], seconds: TimeInterval) async throws -> (text: String, variables: [String: String]) {
        try await withCheckedThrowingContinuation { continuation in
            let box = JavaScriptRun()
            DispatchQueue.global(qos: .userInitiated).async {
                let context = JSContext()
                var failure: String?
                context?.exceptionHandler = { _, exception in failure = exception?.toString() }
                context?.setObject(input, forKeyedSubscript: "input" as NSString)
                context?.setObject(variables, forKeyedSubscript: "vars" as NSString)
                let value = context?.evaluateScript(source)
                if let failure {
                    box.finish(.failure(WorkflowError("JavaScript: \(failure)")), continuation)
                    return
                }
                var text = input
                if let value, !value.isUndefined, !value.isNull { text = value.toString() ?? input }
                var next = variables
                if let object = context?.objectForKeyedSubscript("vars")?.toDictionary() as? [String: Any] {
                    for (key, any) in object where any is String || any is NSNumber { next[key] = "\(any)" }
                }
                box.finish(.success((text, next)), continuation)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + max(1, seconds)) {
                box.finish(.failure(WorkflowError("The JavaScript ran too long and was given up on.")), continuation)
            }
        }
    }

    /// `{{name}}` in an address to open becomes the variable's value, encoded so it stays one part of the address.
    static func substitutingVariables(in action: Action, _ rc: RunContext) -> Action {
        guard case .openUrl(let url) = action, url.contains("{{") else { return action }
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=#?/;:@$,")
        let names = Array(rc.variables.keys)
        let values = names.map { (rc.variables[$0] ?? "").addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }
        return .openUrl(url: workflowRenderVariables(template: url, names: names, values: values))
    }

    /// What a script sees: the workflow's text as KRIYA_INPUT and each variable as KRIYA_VAR_<NAME>.
    private static func environment(for rc: RunContext) -> [String: String] {
        var environment = ["KRIYA_INPUT": rc.text]
        for (name, value) in rc.variables { environment["KRIYA_VAR_" + name.uppercased()] = value }
        return environment
    }

    /// Waits, in short slices, so a stop takes effect within a fraction of a second.
    private func pause(_ seconds: TimeInterval, _ handle: RunHandle) async throws {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if handle.isCancelled { throw CancellationError() }
            try await Task.sleep(nanoseconds: UInt64(min(0.05, max(0, end.timeIntervalSinceNow)) * 1_000_000_000))
        }
        if handle.isCancelled { throw CancellationError() }
    }

    private func render(_ template: String, selection: String) -> String {
        var ctx = SnippetInserter.context(prompts: [])
        ctx.selection = selection
        return renderSnippet(body: template, context: ctx).text
    }

    /// Puts the workflow's variables into the text first, then the snippet placeholders ({selection}, {date}, …).
    private func render(_ template: String, _ rc: RunContext) -> String {
        let names = Array(rc.variables.keys)
        let withVariables = workflowRenderVariables(template: template, names: names, values: names.map { rc.variables[$0] ?? "" })
        return render(withVariables, selection: rc.text)
    }

    /// The shared action engine does what it can; anything that runs a program goes through the tool runner so it can be
    /// stopped and held to the time limit.
    private func runAction(_ action: Action, _ rc: RunContext, _ context: ServiceContext) async throws {
        for step in try planAction(action: Self.substitutingVariables(in: action, rc)) {
            switch step {
            case .delay(let ms):
                try await pause(min(Double(ms) / 1000, rc.remaining), rc.handle)
            case .run(let single):
                if rc.handle.isCancelled { throw CancellationError() }
                switch single {
                case .runShell(let script):
                    try await runTool("/bin/zsh", ["-c", script], rc, environment: ["KRIYA_INPUT": rc.text])
                case .runScript(let language, let source):
                    guard language == .appleScript else { throw WorkflowError("PowerShell scripts run only on Windows.") }
                    try await runTool("/usr/bin/osascript", ["-e", source], rc, environment: ["KRIYA_INPUT": rc.text])
                case .runShortcut(let name):
                    try await runTool("/usr/bin/shortcuts", ["run", name], rc, environment: [:])
                default:
                    if case .failure(let message) = await context.executor.perform(single) { throw WorkflowError(message) }
                }
            }
        }
    }

    @discardableResult
    private func runTool(_ executable: String, _ arguments: [String], _ rc: RunContext, environment: [String: String]) async throws -> String {
        let token = rc.handle.token
        let seconds = rc.remaining
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try ToolRunner.run(executable, arguments, environment: environment, timeout: seconds, cancel: token))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func runSystem(_ op: SystemOp, _ value: Int, _ rc: RunContext) async throws {
        switch op {
        case .lockScreen:
            guard AXIsProcessTrusted() else { throw WorkflowError("Accessibility permission is needed to lock the screen.") }
            let source = CGEventSource(stateID: .hidSystemState)
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 12, keyDown: down) else { continue }
                event.flags = [.maskControl, .maskCommand]
                event.setIntegerValueField(.eventSourceUserData, value: EventMonitor.syntheticMarker)
                event.post(tap: .cghidEventTap)
            }
        case .sleepDisplay: try await runTool("/usr/bin/pmset", ["displaysleepnow"], rc, environment: [:])
        case .sleep: try await runTool("/usr/bin/pmset", ["sleepnow"], rc, environment: [:])
        case .startScreenSaver: try await runTool("/usr/bin/open", ["-a", "ScreenSaverEngine"], rc, environment: [:])
        case .toggleAppearance:
            try await runTool("/usr/bin/osascript", ["-e", "tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode"], rc, environment: [:])
        case .mute: try await runTool("/usr/bin/osascript", ["-e", "set volume output muted true"], rc, environment: [:])
        case .unmute: try await runTool("/usr/bin/osascript", ["-e", "set volume output muted false"], rc, environment: [:])
        case .setVolume: try await runTool("/usr/bin/osascript", ["-e", "set volume output volume \(max(0, min(100, value)))"], rc, environment: [:])
        case .openSystemSettings:
            await MainActor.run { _ = NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:")!) }
        }
    }
}

/// Remembers which item of a pop-up menu was picked.
private final class MenuChoice: NSObject {
    var index: Int?
    @objc func pick(_ sender: NSMenuItem) { index = sender.tag }
}

/// Lets a JavaScript run and its time limit race, and answers only once.
private final class JavaScriptRun {
    private let lock = NSLock()
    private var done = false

    func finish(_ result: Result<(text: String, variables: [String: String]), Error>, _ continuation: CheckedContinuation<(text: String, variables: [String: String]), Error>) {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        guard first else { return }
        continuation.resume(with: result)
    }
}
