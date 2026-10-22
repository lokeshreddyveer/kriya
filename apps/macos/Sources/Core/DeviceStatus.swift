import Foundation
import IOKit.ps

/// A battery reading for something plugged in or paired.
struct BatteryReading: Equatable {
    let name: String
    let percent: Int
    let charging: Bool
}

/// What Kriya can say about a device's battery. Only what macOS reports; never a guess.
enum BatteryState: Equatable {
    case level(percent: Int, charging: Bool)
    /// The device does not report a battery to macOS (wired mice, receivers, built-in trackpads, most third-party ones).
    case unavailable
}

enum DeviceBattery {
    /// The power sources macOS lists that are not the Mac's own battery: Bluetooth mice, trackpads and keyboards.
    static func parse(_ descriptions: [[String: Any]]) -> [BatteryReading] {
        descriptions.compactMap { description in
            guard let name = description["Name"] as? String, !name.isEmpty else { return nil }
            if (description["Type"] as? String) == "InternalBattery" || (description["Transport Type"] as? String) == "Internal" { return nil }
            if (description["Is Present"] as? Bool) == false { return nil }
            guard let current = description["Current Capacity"] as? Int else { return nil }
            let maximum = (description["Max Capacity"] as? Int) ?? 100
            guard maximum > 0 else { return nil }
            let percent = min(max(current * 100 / maximum, 0), 100)
            return BatteryReading(name: name, percent: percent, charging: (description["Is Charging"] as? Bool) ?? false)
        }
    }

    /// The reading that belongs to a device, or `.unavailable` if none does or it is not clear which does. A name that
    /// matches only loosely counts only when exactly one reading matches.
    /// A name this short ("Mouse") says too little to match a longer one ("Magic Mouse") and be sure it is the same device.
    private static let looseMinimum = 8

    static func state(forDeviceNamed names: [String], readings: [BatteryReading]) -> BatteryState {
        func normal(_ text: String) -> String { text.lowercased().filter { $0.isLetter || $0.isNumber } }
        let wanted = names.map(normal).filter { $0.count >= 3 }
        guard !wanted.isEmpty else { return .unavailable }
        let exact = readings.filter { wanted.contains(normal($0.name)) }
        if exact.count == 1 { return level(exact[0]) }
        if exact.count > 1 { return .unavailable }
        let loose = readings.filter { reading in
            let name = normal(reading.name)
            return wanted.contains { $0.count >= looseMinimum && name.count >= looseMinimum && ($0.contains(name) || name.contains($0)) }
        }
        return loose.count == 1 ? level(loose[0]) : .unavailable
    }

    private static func level(_ reading: BatteryReading) -> BatteryState { .level(percent: reading.percent, charging: reading.charging) }

    /// Asks macOS for the power sources.
    static func readSystem() -> [BatteryReading] {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return [] }
        let descriptions = list.compactMap { IOPSGetPowerSourceDescription(blob, $0)?.takeUnretainedValue() as? [String: Any] }
        return parse(descriptions)
    }
}

/// When each device connected, and whether it came back after going away while Kriya was running. Its settings come back
/// by themselves (they are kept by device, not by connection), so this only says so.
struct ConnectionHistory: Equatable {
    private(set) var connectedAt: [String: Date] = [:]
    private(set) var reconnectedAt: [String: Date] = [:]
    private var away: Set<String> = []

    mutating func connected(_ id: String, at date: Date) {
        connectedAt[id] = date
        if away.remove(id) != nil { reconnectedAt[id] = date }
    }

    mutating func disconnected(_ id: String) {
        away.insert(id)
        connectedAt[id] = nil
    }

    /// Forgetting a device, or one that is not there any more.
    mutating func forget(_ id: String) {
        connectedAt[id] = nil
        reconnectedAt[id] = nil
        away.remove(id)
    }
}

/// What the Devices pane shows about one device beyond its name.
struct DeviceStatus: Equatable {
    var battery: BatteryState = .unavailable
    var connectedAt: Date?
    var reconnectedAt: Date?
    var lastUsed: Date?
}

enum DeviceStatusText {
    static func battery(_ state: BatteryState, connection: ConnectionKind) -> String {
        switch state {
        case .level(let percent, let charging): return "Battery \(percent)%" + (charging ? ", charging" : "")
        case .unavailable: return connection == .builtIn ? "Built in" : "Battery: not reported by this device"
        }
    }

    static func reconnected(_ date: Date?, now: Date = Date()) -> String? {
        guard let date else { return nil }
        return "Reconnected \(relative(date, now: now)). Its settings came back by themselves."
    }

    static func lastUsed(_ date: Date?, now: Date = Date()) -> String? {
        guard let date else { return nil }
        return "Last used \(relative(date, now: now))"
    }

    static func relative(_ date: Date, now: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 10 { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
