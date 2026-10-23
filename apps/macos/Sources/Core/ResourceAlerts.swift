import Foundation

/// When the Mac is struggling, say so once, in words, and not again for a while.
struct ResourceAlertConfig: Codable, Equatable {
    var enabled = false
    var cpuPercent = 90
    /// How long the processor has to stay above that before it is worth saying.
    var cpuSeconds = 60
    var memoryPercent = 90
    var diskFreeGB = 10
    var batteryHealthBelow = 80

    var clamped: ResourceAlertConfig {
        var c = self
        c.cpuPercent = min(max(cpuPercent, 50), 100)
        c.cpuSeconds = min(max(cpuSeconds, 10), 600)
        c.memoryPercent = min(max(memoryPercent, 50), 100)
        c.diskFreeGB = min(max(diskFreeGB, 1), 500)
        c.batteryHealthBelow = min(max(batteryHealthBelow, 50), 95)
        return c
    }
}

struct ResourceAlertState: Equatable {
    var cpuHighSince: Date?
    /// When each kind was last said, so it is not repeated at once.
    var said: [String: Date] = [:]
}

enum ResourceAlerts {
    static let cooldown: TimeInterval = 30 * 60

    /// The messages to show now. Changes `state` so the same thing is not said every two seconds.
    static func evaluate(_ snapshot: MonitorSnapshot, config rawConfig: ResourceAlertConfig, state: inout ResourceAlertState, now: Date) -> [String] {
        let config = rawConfig.clamped
        guard config.enabled else { state = ResourceAlertState(); return [] }
        var messages: [String] = []

        func say(_ key: String, _ condition: Bool, _ message: @autoclosure () -> String) {
            guard condition else { state.said[key] = nil; return }
            if let last = state.said[key], now.timeIntervalSince(last) < cooldown { return }
            state.said[key] = now
            messages.append(message())
        }

        if snapshot.cpu * 100 >= Double(config.cpuPercent) {
            if state.cpuHighSince == nil { state.cpuHighSince = now }
        } else {
            state.cpuHighSince = nil
        }
        let busyFor = state.cpuHighSince.map { now.timeIntervalSince($0) } ?? 0
        let busy = busyFor >= Double(config.cpuSeconds)
        say("cpu", busy, "The processor has been above \(config.cpuPercent)% for \(Int(busyFor)) seconds." + (snapshot.topByCPU.first.map { " \($0.name) is using the most." } ?? ""))

        say("memory", snapshot.memory.total > 0 && snapshot.memory.share * 100 >= Double(config.memoryPercent),
            "Memory is \(MonitorSnapshot.percent(snapshot.memory.share)) full." + (snapshot.memory.swapUsed > 0 ? " The Mac is using \(ByteFormat.size(snapshot.memory.swapUsed)) of disk as extra memory." : ""))

        if let disk = snapshot.disks.first {
            say("disk", disk.total > 0 && disk.free < Int64(config.diskFreeGB) * 1_073_741_824, "Only \(ByteFormat.size(Double(disk.free))) is free on the startup disk.")
        }
        say("thermal", snapshot.thermal == .serious || snapshot.thermal == .critical, "The Mac is hot and slowing itself down.")
        if let health = snapshot.battery?.healthPercent {
            say("battery", health < config.batteryHealthBelow, "The battery holds \(health)% of what it did when new.")
        }
        return messages
    }
}
