import Foundation

/// How long named pieces of work took, in total. These are Kriya's own measurements of its own work with a clock, so they are
/// approximate: they do not include time the system spent on Kriya's behalf, and they say nothing about other programs.
struct TimingTable: Equatable {
    struct Stat: Equatable {
        var count = 0
        var totalMicroseconds = 0
        var worstMicroseconds = 0
        var averageMicroseconds: Int { count == 0 ? 0 : totalMicroseconds / count }
    }

    static let maxNames = 80
    private(set) var stats: [String: Stat] = [:]

    mutating func record(_ name: String, microseconds: Int) {
        guard microseconds >= 0, stats[name] != nil || stats.count < Self.maxNames else { return }
        var stat = stats[name] ?? Stat()
        stat.count += 1
        stat.totalMicroseconds += microseconds
        stat.worstMicroseconds = max(stat.worstMicroseconds, microseconds)
        stats[name] = stat
    }

    /// Busiest first.
    var ranked: [(name: String, stat: Stat)] {
        stats.map { ($0.key, $0.value) }.sorted { $0.1.totalMicroseconds != $1.1.totalMicroseconds ? $0.1.totalMicroseconds > $1.1.totalMicroseconds : $0.0 < $1.0 }
    }

    mutating func clear() { stats = [:] }
}

/// The timings Kriya keeps while the person has them switched on. Off, `measure` only runs the work.
final class FeatureTimings: ObservableObject {
    static let shared = FeatureTimings()
    private static let key = "featureTimings.enabled"

    @Published var enabled: Bool { didSet { UserDefaults.standard.set(enabled, forKey: Self.key); if !enabled { reset() } } }
    @Published private(set) var table = TimingTable()
    private var pending = TimingTable()
    private let lock = NSLock()
    private var publishScheduled = false

    private init() { enabled = UserDefaults.standard.bool(forKey: Self.key) }

    @discardableResult
    func measure<T>(_ name: String, _ work: () -> T) -> T {
        guard enabled else { return work() }
        let start = DispatchTime.now().uptimeNanoseconds
        let result = work()
        let micros = Int((DispatchTime.now().uptimeNanoseconds - start) / 1000)
        lock.lock()
        pending.record(name, microseconds: micros)
        let schedule = !publishScheduled
        publishScheduled = true
        lock.unlock()
        if schedule { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.publish() } }
        return result
    }

    private func publish() {
        lock.lock()
        let copy = pending
        publishScheduled = false
        lock.unlock()
        table = copy
    }

    func reset() {
        lock.lock(); pending.clear(); lock.unlock()
        table = TimingTable()
    }
}

enum ProcessMemory {
    /// The memory Kriya's process holds in RAM now, in bytes.
    static func residentBytes() -> UInt64? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? info.resident_size : nil
    }
}
