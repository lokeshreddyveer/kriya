import AppKit
import Combine

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
        for workflow in list where workflow.enabled {
            let id = workflow.id
            let command = workflowCommand(workflow: workflow)
            executor.registerCommand(command) { [weak self] in self?.fire(id, source: "Command") }
            registered.insert(command)
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
        progress: ((StepResult) -> Void)? = nil, completion: ((WorkflowRun) -> Void)? = nil
    ) {
        guard let workflow = store.workflow(workflowID) else { return }
        if !workflow.enabled && !test { return }
        Task { [weak self] in
            guard let self else { return }
            let run = await execute(workflow, source: source, input: input ?? "", depth: 0, test: test, dryRun: dryRun, approvedForTest: approvedForTest, progress: progress)
            await MainActor.run { completion?(run) }
        }
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
        progress: ((StepResult) -> Void)?
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
        var rc = RunContext(text: input, handle: handle, deadline: Date().addingTimeInterval(TimeInterval(workflow.timeoutSeconds)), depth: depth, dryRun: dryRun, test: test, approvedForTest: approvedForTest)
        var results: [StepResult] = []
        var status = RunStatus.succeeded
        var failure: String?
        for (index, step) in workflow.steps.enumerated() {
            if handle.isCancelled { status = .cancelled; failure = "Stopped."; break }
            if Date() >= rc.deadline { status = .timedOut; failure = "It ran for more than \(workflow.timeoutSeconds) seconds and was stopped."; break }
            let title = workflowStepSummary(step: step)
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
            if dryRun {
                record(.planned, "Would: " + step.kind.summary)
                continue
            }
            do {
                let message = try await perform(step.kind, &rc)
                record(.ok, message)
            } catch is CancellationError {
                record(.cancelled, "Stopped.")
                status = .cancelled
                failure = "Stopped."
                break
            } catch {
                let timedOut = Date() >= rc.deadline
                let cancelled = handle.isCancelled
                record(cancelled ? .cancelled : .failed, error.localizedDescription)
                if cancelled { status = .cancelled; failure = "Stopped."; break }
                if timedOut { status = .timedOut; failure = "It ran for more than \(workflow.timeoutSeconds) seconds and was stopped."; break }
                if step.onError == .stop {
                    status = .failed
                    failure = "Step \(index + 1) (\(title)): \(error.localizedDescription)"
                    break
                }
            }
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
        let deadline: Date
        let depth: Int
        let dryRun: Bool
        let test: Bool
        let approvedForTest: Bool
        var remaining: TimeInterval { max(1, deadline.timeIntervalSinceNow) }
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
            let output: String
            switch language {
            case .shell:
                output = try await runTool("/bin/zsh", ["-c", source, "kriya", rc.text], rc, environment: ["KRIYA_INPUT": rc.text])
            case .appleScript:
                let script = source.contains("on run") ? source : "on run argv\n\(source)\nend run"
                output = try await runTool("/usr/bin/osascript", ["-e", script, rc.text], rc, environment: ["KRIYA_INPUT": rc.text])
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
            toast.show(message)
            return nil

        case .textTransform(let ops):
            rc.text = try textApplyAll(ops: ops, text: rc.text)
            return nil

        case .copyText(let template):
            let text = render(template, selection: rc.text)
            await MainActor.run {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            return nil

        case .insertText(let template):
            guard AXIsProcessTrusted() else { throw WorkflowError("Accessibility permission is needed to type text.") }
            let text = render(template, selection: rc.text)
            let injector = context.keyboard.injector
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    injector.insert(text, cursorBack: 0)
                    continuation.resume()
                }
            }
            return nil
        }
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

    /// The shared action engine does what it can; anything that runs a program goes through the tool runner so it can be
    /// stopped and held to the time limit.
    private func runAction(_ action: Action, _ rc: RunContext, _ context: ServiceContext) async throws {
        for step in try planAction(action: action) {
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
