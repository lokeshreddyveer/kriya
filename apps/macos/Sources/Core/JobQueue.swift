import Foundation

/// The list of file jobs waiting, running and finished, with a pause that holds back jobs that have not started.
struct JobQueueState: Equatable {
    enum Status: Equatable { case waiting, running, done, failed }

    struct Job: Equatable, Identifiable {
        let id: String
        let title: String
        var status: Status
    }

    private(set) var jobs: [Job] = []
    private(set) var paused = false
    static let keepFinished = 20

    mutating func add(id: String, title: String) { jobs.append(Job(id: id, title: title, status: .waiting)); trim() }

    mutating func start(_ id: String) { set(id, .running) }
    mutating func finish(_ id: String, failed: Bool) { set(id, failed ? .failed : .done); trim() }
    mutating func setPaused(_ value: Bool) { paused = value }

    /// A waiting job cancelled before it starts. A running job cannot be stopped part-way, so it is left alone.
    @discardableResult
    mutating func cancelWaiting(_ id: String) -> Bool {
        guard let i = jobs.firstIndex(where: { $0.id == id && $0.status == .waiting }) else { return false }
        jobs.remove(at: i)
        return true
    }

    /// The next job to run: the first waiting one, unless paused.
    var next: Job? { paused ? nil : jobs.first { $0.status == .waiting } }
    var waitingCount: Int { jobs.filter { $0.status == .waiting }.count }
    var runningCount: Int { jobs.filter { $0.status == .running }.count }
    var isBusy: Bool { waitingCount + runningCount > 0 }

    var summary: String {
        if !isBusy { return "No file operations waiting." }
        var parts: [String] = []
        if runningCount > 0 { parts.append("\(runningCount) running") }
        if waitingCount > 0 { parts.append("\(waitingCount) waiting") }
        return parts.joined(separator: ", ") + (paused ? " (paused: waiting ones will not start)" : "")
    }

    private mutating func set(_ id: String, _ status: Status) {
        if let i = jobs.firstIndex(where: { $0.id == id }) { jobs[i].status = status }
    }

    private mutating func trim() {
        let finished = jobs.filter { $0.status == .done || $0.status == .failed }
        if finished.count > Self.keepFinished {
            let drop = Set(finished.prefix(finished.count - Self.keepFinished).map(\.id))
            jobs.removeAll { drop.contains($0.id) }
        }
    }
}
