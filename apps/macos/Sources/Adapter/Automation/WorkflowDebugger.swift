import Foundation

/// Lets a person watch a workflow run one step at a time: it waits before a step that has a breakpoint (or before every step when
/// stepping), shows the variables and the text as they are at that moment, and carries on when told to.
final class WorkflowDebugger: ObservableObject {
    @Published var breakpoints: Set<String> = []
    /// Waits before every step, not only those with a breakpoint.
    @Published var stepping: Bool
    @Published private(set) var isWaiting = false
    @Published private(set) var stepTitle = ""
    @Published private(set) var variables: [(name: String, value: String)] = []
    @Published private(set) var text = ""
    @Published private(set) var visited: [String] = []

    private var continuation: CheckedContinuation<Bool, Never>?
    private let lock = NSLock()
    private var stopped = false

    init(stepping: Bool = true, breakpoints: Set<String> = []) {
        self.stepping = stepping
        self.breakpoints = breakpoints
    }

    /// Called by the engine before a step. Returns false if the person stopped the run.
    func beforeStep(id: String, title: String, variables: [String: String], text: String) async -> Bool {
        let shouldWait = await MainActor.run { stepping || breakpoints.contains(id) }
        lock.lock()
        let wasStopped = stopped
        lock.unlock()
        if wasStopped { return false }
        guard shouldWait else {
            await MainActor.run { visited.append(title) }
            return true
        }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            DispatchQueue.main.async {
                self.stepTitle = title
                self.variables = variables.sorted { $0.key < $1.key }.map { (name: $0.key, value: $0.value) }
                self.text = text
                self.visited.append(title)
                self.isWaiting = true
                self.lock.lock()
                self.continuation = continuation
                self.lock.unlock()
            }
        }
    }

    /// Runs the waiting step, then waits again before the next one.
    func step() { release(proceed: true, stepping: true) }

    /// Runs on until the next breakpoint.
    func resume() { release(proceed: true, stepping: false) }

    /// Ends the run.
    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
        release(proceed: false, stepping: stepping)
    }

    private func release(proceed: Bool, stepping next: Bool) {
        DispatchQueue.main.async {
            self.stepping = next
            self.isWaiting = false
            self.lock.lock()
            let waiting = self.continuation
            self.continuation = nil
            self.lock.unlock()
            waiting?.resume(returning: proceed)
        }
    }
}
