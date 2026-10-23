import AppKit
import Combine
import SwiftUI

extension Workflow: Identifiable {}
extension WorkflowRun: Identifiable {}
extension StepTemplate: Identifiable { public var id: String { category + title } }
extension TriggerTemplate: Identifiable { public var id: String { category + title } }
extension ConditionTemplate: Identifiable { public var id: String { title } }

extension RunStatus {
    var title: String {
        switch self {
        case .succeeded: return "Succeeded"
        case .failed: return "Failed"
        case .cancelled: return "Stopped"
        case .timedOut: return "Timed out"
        case .blocked: return "Not started"
        case .skipped: return "Skipped"
        }
    }

    var symbol: String {
        switch self {
        case .succeeded: return "checkmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        case .cancelled: return "stop.circle.fill"
        case .timedOut: return "clock.badge.exclamationmark.fill"
        case .blocked: return "hand.raised.fill"
        case .skipped: return "arrow.uturn.right.circle"
        }
    }

    var color: Color {
        switch self {
        case .succeeded: return .green
        case .failed: return .red
        case .cancelled, .timedOut, .blocked: return .orange
        case .skipped: return .secondary
        }
    }
}

extension StepStatus {
    var symbol: String {
        switch self {
        case .ok: return "checkmark.circle.fill"
        case .skipped: return "arrow.uturn.right.circle"
        case .failed: return "xmark.octagon.fill"
        case .cancelled: return "stop.circle.fill"
        case .planned: return "list.bullet.circle"
        }
    }

    var color: Color {
        switch self {
        case .ok: return .green
        case .failed: return .red
        case .cancelled: return .orange
        case .skipped, .planned: return .secondary
        }
    }
}

extension WorkflowTrigger {
    var title: String { workflowTriggerTitle(trigger: self) }
}

extension StepKind {
    var risk: StepRisk { workflowStepRisk(kind: self) }
    var summary: String { workflowStepSummary(step: WorkflowStep(id: "", label: nil, when: nil, onError: .stop, kind: self)) }

    /// The steps inside a loop or a group of steps that run side by side.
    var children: [WorkflowStep] {
        switch self {
        case .repeat(_, let steps): return steps
        case .parallel(let steps): return steps
        default: return []
        }
    }
}

/// Workflows and their history. The automation engine reads `current` from any thread.
final class WorkflowStore: ObservableObject {
    @Published private(set) var workflows: [Workflow] = []
    @Published private(set) var runs: [WorkflowRun] = []
    @Published var lastError: String?

    private let core: KriyaCore
    private let lock = NSLock()
    private var snapshot: [Workflow] = []   // guarded by lock

    init(core: KriyaCore) {
        self.core = core
        reload()
    }

    func reload() {
        do {
            workflows = try core.workflows()
            runs = try core.workflowRuns(workflowId: nil, limit: 300)
        } catch {
            Log.error("Automation", "Could not load workflows: \(error.userMessage)")
        }
        lock.lock()
        snapshot = workflows
        lock.unlock()
    }

    func reloadRuns() {
        runs = (try? core.workflowRuns(workflowId: nil, limit: 300)) ?? runs
    }

    var current: [Workflow] {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }

    func workflow(_ id: String) -> Workflow? { current.first { $0.id == id } }

    func newWorkflow() -> Workflow {
        Workflow(
            id: UUID().uuidString, name: "", notes: nil, enabled: false, trigger: .manual, conditions: nil, steps: [], timeoutSeconds: 60,
            allowParallel: false, schemaVersion: 1, revision: 0, authorizedFingerprint: nil, createdAt: 0, updatedAt: 0
        )
    }

    func newStep(_ kind: StepKind) -> WorkflowStep {
        WorkflowStep(id: UUID().uuidString, label: nil, when: nil, onError: .stop, kind: Self.withFreshIDs(kind))
    }

    /// The steps inside a loop or group get ids of their own, so adding the same template twice never clashes.
    static func withFreshIDs(_ kind: StepKind) -> StepKind {
        func fresh(_ steps: [WorkflowStep]) -> [WorkflowStep] {
            steps.map { step in
                var next = step
                next.id = UUID().uuidString
                next.kind = withFreshIDs(step.kind)
                return next
            }
        }
        switch kind {
        case .repeat(let times, let steps): return .repeat(times: times, steps: fresh(steps))
        case .parallel(let steps): return .parallel(steps: fresh(steps))
        default: return kind
        }
    }

    // MARK: Editing

    @discardableResult
    func save(_ workflow: Workflow) -> Workflow? {
        do {
            let saved = try core.saveWorkflow(workflow: workflow, now: SystemInfo.nowSeconds)
            lastError = nil
            reload()
            return saved
        } catch {
            lastError = error.userMessage
            return nil
        }
    }

    func delete(_ id: String) { perform { try core.deleteWorkflow(id: id) } }
    func setEnabled(_ id: String, _ on: Bool) { perform { try core.setWorkflowEnabled(id: id, enabled: on) } }
    func authorize(_ id: String) { perform { try core.authorizeWorkflow(id: id) } }
    func revokeAuthorization(_ id: String) { perform { try core.revokeWorkflowAuthorization(id: id) } }

    func duplicate(_ id: String) {
        perform { _ = try core.duplicateWorkflow(id: id, newId: UUID().uuidString, now: SystemInfo.nowSeconds) }
    }

    func clearHistory() {
        try? core.clearWorkflowRuns()
        reload()
    }

    func record(_ run: WorkflowRun) {
        try? core.recordWorkflowRun(run: run)
        DispatchQueue.main.async { [self] in reloadRuns() }
    }

    // MARK: Sharing

    func export(_ ids: [String], to url: URL) throws {
        try core.exportWorkflows(ids: ids, now: SystemInfo.nowSeconds).write(to: url, atomically: true, encoding: .utf8)
    }

    @discardableResult
    func importWorkflows(from url: URL) throws -> [Workflow] {
        let data = try Data(contentsOf: url)
        guard let json = String(data: data, encoding: .utf8) else { throw CoreError.Backup(message: "the file is not a Kriya workflow package") }
        let added = try core.importWorkflows(json: json, now: SystemInfo.nowSeconds)
        reload()
        return added
    }

    private func perform(_ work: () throws -> Void) {
        do {
            try work()
            lastError = nil
        } catch {
            lastError = error.userMessage
        }
        reload()
    }
}
