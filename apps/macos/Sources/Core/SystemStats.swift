import Foundation

/// Counters of processor time since start-up, read twice to find how busy the processor was between the reads.
struct CPUTicks: Equatable {
    var user: UInt64, system: UInt64, idle: UInt64, nice: UInt64
    var total: UInt64 { user + system + idle + nice }

    /// Busy time as a share of all time between two reads, 0...1.
    static func usage(from old: CPUTicks, to new: CPUTicks) -> Double {
        guard new.total > old.total else { return 0 }
        let all = Double(new.total - old.total)
        let idle = Double(new.idle >= old.idle ? new.idle - old.idle : 0)
        return min(max(1 - idle / all, 0), 1)
    }
}

struct NetCounters: Equatable {
    var received: UInt64, sent: UInt64

    /// Bytes per second between two reads. A counter that went backwards (an interface came back up) counts as zero.
    static func rate(from old: NetCounters, to new: NetCounters, seconds: Double) -> (down: Double, up: Double) {
        guard seconds > 0 else { return (0, 0) }
        let down = new.received >= old.received ? Double(new.received - old.received) / seconds : 0
        let up = new.sent >= old.sent ? Double(new.sent - old.sent) / seconds : 0
        return (down, up)
    }
}

enum ByteFormat {
    /// "1.4 GB", "820 KB": binary steps, one decimal from megabytes up.
    static func size(_ bytes: Double) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = max(bytes, 0), index = 0
        while value >= 1024, index < units.count - 1 { value /= 1024; index += 1 }
        return index < 2 ? "\(Int(value.rounded())) \(units[index])" : String(format: "%.1f %@", value, units[index])
    }

    static func rate(_ bytesPerSecond: Double) -> String { size(bytesPerSecond) + "/s" }

    /// "3 d 4 h", "2 h 05 m", "12 m".
    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(max(seconds, 0)), days = total / 86_400, hours = total % 86_400 / 3600, minutes = total % 3600 / 60
        if days > 0 { return "\(days) d \(hours) h" }
        if hours > 0 { return "\(hours) h \(String(format: "%02d", minutes)) m" }
        return "\(minutes) m"
    }
}

/// The readings that can be shown beside the menu-bar icon.
enum MonitorMetric: String, CaseIterable, Identifiable {
    case cpu, memory, disk, network, battery
    var id: String { rawValue }
    var title: String {
        switch self {
        case .cpu: return "Processor"
        case .memory: return "Memory"
        case .disk: return "Disk space"
        case .network: return "Network speed"
        case .battery: return "Battery"
        }
    }
    static func parse(_ text: String) -> [MonitorMetric] { text.split(separator: ",").compactMap { MonitorMetric(rawValue: String($0)) } }
    static func join(_ list: [MonitorMetric]) -> String { list.map(\.rawValue).joined(separator: ",") }
}

struct DiskInfo: Identifiable, Equatable {
    var id: String { path }
    let name: String
    let path: String
    let total: Int64
    let free: Int64
    let isInternal: Bool
    var used: Int64 { max(total - free, 0) }
    var usedShare: Double { total > 0 ? Double(used) / Double(total) : 0 }
}

struct ProcessUse: Identifiable, Equatable {
    let id: Int32
    let name: String
    let cpu: Double
    let memory: Double

    /// Reads the lines of `ps -Aceo pid=,pcpu=,rss=,comm=`. Lines that do not parse are skipped.
    static func parse(_ output: String) -> [ProcessUse] {
        output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count == 4, let pid = Int32(parts[0]), let cpu = Double(parts[1]), let rss = Double(parts[2]) else { return nil }
            return ProcessUse(id: pid, name: String(parts[3]).trimmingCharacters(in: .whitespaces), cpu: cpu, memory: rss * 1024)
        }
    }
}

struct MemoryInfo: Equatable {
    var total: Double = 0, used: Double = 0, app: Double = 0, wired: Double = 0, compressed: Double = 0, cached: Double = 0
    var swapUsed: Double = 0
    var share: Double { total > 0 ? used / total : 0 }
}

struct BatteryInfo: Equatable {
    var percent: Int
    var charging: Bool
    var onAC: Bool
    var minutesLeft: Int?
    var cycles: Int?
    var healthPercent: Int?
}

struct MonitorSnapshot: Equatable {
    var cpu: Double = 0
    var cores: [Double] = []
    var memory = MemoryInfo()
    var disks: [DiskInfo] = []
    var down: Double = 0
    var up: Double = 0
    var totalDown: UInt64 = 0
    var totalUp: UInt64 = 0
    var battery: BatteryInfo?
    var devices: [BatteryReading] = []
    var thermal: ProcessInfo.ThermalState = .nominal
    var uptime: TimeInterval = 0
    var topByCPU: [ProcessUse] = []
    var topByMemory: [ProcessUse] = []

    static func percent(_ share: Double) -> String { "\(Int((share * 100).rounded()))%" }

    /// The short text beside the icon for the chosen readings.
    func menuBarText(_ metrics: [MonitorMetric]) -> String {
        metrics.map { metric in
            switch metric {
            case .cpu: return "CPU \(Self.percent(cpu))"
            case .memory: return "RAM \(Self.percent(memory.share))"
            case .disk: return disks.first.map { "\(ByteFormat.size(Double($0.free))) free" } ?? "Disk"
            case .network: return "↓\(ByteFormat.rate(down)) ↑\(ByteFormat.rate(up))"
            case .battery: return battery.map { "\($0.percent)%\($0.charging ? "⚡︎" : "")" } ?? "AC"
            }
        }.joined(separator: "  ")
    }

    static func thermalText(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "Cool"
        case .fair: return "Warm"
        case .serious: return "Hot, the Mac is slowing down"
        case .critical: return "Very hot, the Mac is slowing down a lot"
        @unknown default: return "Unknown"
        }
    }
}
