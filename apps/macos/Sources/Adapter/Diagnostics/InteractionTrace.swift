import Combine
import Foundation

/// A short record of what Kriya just did in answer to a shortcut or a command, for working out why something happened.
/// It is off until asked for, switches itself off after five minutes, and keeps only what Kriya did (which shortcut, which
/// command), never what was typed or selected.
final class InteractionTrace: ObservableObject {
    static let shared = InteractionTrace()

    struct Entry: Identifiable, Equatable {
        let id = UUID()
        let time: Date
        let source: String
        let text: String
    }

    static let capacity = 300
    static let duration: TimeInterval = 300

    @Published private(set) var entries: [Entry] = []
    @Published private(set) var isOn = false
    @Published private(set) var offAt: Date?

    private let lock = NSLock()
    private var running = false           // guarded by lock
    private var until = Date.distantPast  // guarded by lock
    private let now: () -> Date

    init(now: @escaping () -> Date = Date.init) { self.now = now }

    func start() {
        lock.lock()
        running = true
        until = now().addingTimeInterval(Self.duration)
        let end = until
        lock.unlock()
        DispatchQueue.main.async { self.isOn = true; self.offAt = end }
    }

    func stop() {
        lock.lock()
        running = false
        lock.unlock()
        DispatchQueue.main.async { self.isOn = false; self.offAt = nil }
    }

    func clear() { DispatchQueue.main.async { self.entries.removeAll() } }

    /// Whether anything is being recorded right now. Cheap, and safe from any thread, so a caller can skip the work of
    /// describing an event when nobody is looking.
    var isRecording: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running && now() <= until
    }

    /// Records something Kriya did. Does nothing while the trace is off, so it costs next to nothing.
    func note(_ source: String, _ text: String) {
        lock.lock()
        let active = running
        let expired = now() > until
        if active, expired { running = false }
        lock.unlock()
        guard active else { return }
        if expired {
            DispatchQueue.main.async { self.isOn = false; self.offAt = nil }
            return
        }
        let entry = Entry(time: now(), source: source, text: text)
        DispatchQueue.main.async {
            self.entries.append(entry)
            if self.entries.count > Self.capacity { self.entries.removeFirst(self.entries.count - Self.capacity) }
        }
    }

    /// The trace as text, for a support report.
    func text() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return entries.map { "\(formatter.string(from: $0.time))  \($0.source): \($0.text)" }.joined(separator: "\n")
    }
}

/// How the event tap has been doing over the last few minutes: one sample every few seconds.
final class PerformanceTimeline: ObservableObject {
    struct Sample: Identifiable, Equatable {
        let id = UUID()
        let time: Date
        /// Events handled since the previous sample.
        let events: Int
        let p95Microseconds: Int
        let slowHandlers: Int
        let recoveries: Int
    }

    static let capacity = 120
    static let interval: TimeInterval = 5

    @Published private(set) var samples: [Sample] = []

    private weak var events: EventMonitor?
    private var timer: Timer?
    private var previous = EventMonitor.Stats()

    func start(events: EventMonitor) {
        guard timer == nil else { return }
        self.events = events
        previous = events.currentStats()
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in self?.sample() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func sample() {
        guard let events else { return }
        let now = events.currentStats()
        append(Self.sample(from: previous, to: now, at: Date()))
        previous = now
    }

    func append(_ sample: Sample) {
        samples.append(sample)
        if samples.count > Self.capacity { samples.removeFirst(samples.count - Self.capacity) }
    }

    /// The change between two readings of the event tap's numbers.
    static func sample(from before: EventMonitor.Stats, to after: EventMonitor.Stats, at time: Date) -> Sample {
        Sample(
            time: time, events: max(0, after.eventsHandled - before.eventsHandled), p95Microseconds: after.p95Microseconds,
            slowHandlers: max(0, after.slowHandlers - before.slowHandlers), recoveries: max(0, after.tapRecoveries - before.tapRecoveries)
        )
    }
}
