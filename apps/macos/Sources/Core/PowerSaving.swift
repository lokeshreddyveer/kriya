import Foundation
import IOKit.ps

/// Kriya's own power saving: when it is on, Kriya's background checks run less often and its optional extras pause. It never touches
/// the system's Low Power Mode, which macOS does not let an app change.
enum PowerSaving {
    enum Mode: String, CaseIterable, Identifiable {
        case off, lowPowerOnly, onBattery, always
        var id: String { rawValue }
        var title: String {
            switch self {
            case .off: return "Never"
            case .lowPowerOnly: return "When Low Power Mode is on"
            case .onBattery: return "When Low Power Mode is on, or on battery"
            case .always: return "Always"
            }
        }
    }

    static func isActive(mode: Mode, lowPowerMode: Bool, onBattery: Bool) -> Bool {
        switch mode {
        case .off: return false
        case .lowPowerOnly: return lowPowerMode
        case .onBattery: return lowPowerMode || onBattery
        case .always: return true
        }
    }

    /// How long to wait between checks: several times longer while saving, never more than ten minutes.
    static func interval(_ base: TimeInterval, saving: Bool, factor: Double = 4) -> TimeInterval {
        saving ? min(base * factor, 600) : base
    }

    /// What changes, in words, for the settings screen.
    static let whatItDoes: [String] = [
        "The system monitor and sound-device checks look less often.",
        "The search index updates less often.",
        "The launcher's browser-tab and network lookups wait to be asked.",
        "Animations in Kriya's own windows are shortened.",
    ]
}

/// The live state: the person's choice, the Mac's Low Power Mode and whether it is on battery. Read from any thread.
final class PowerSavingState: ObservableObject {
    static let shared = PowerSavingState()
    static let modeKey = "powerSaving.mode"

    @Published private(set) var isActive = false
    private let lock = NSLock()
    private var cached = false

    var mode: PowerSaving.Mode {
        get { PowerSaving.Mode(rawValue: UserDefaults.standard.string(forKey: Self.modeKey) ?? "") ?? .off }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Self.modeKey); refresh() }
    }

    var activeNow: Bool { lock.lock(); defer { lock.unlock() }; return cached }

    var lowPowerMode: Bool { ProcessInfo.processInfo.isLowPowerModeEnabled }

    private init() {
        NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in self?.refresh() }
        refresh()
    }

    func refresh() {
        let battery = DeviceBattery.onBatteryPower()
        let next = PowerSaving.isActive(mode: mode, lowPowerMode: lowPowerMode, onBattery: battery)
        lock.lock(); cached = next; lock.unlock()
        DispatchQueue.main.async { self.isActive = next }
    }

    func interval(_ base: TimeInterval) -> TimeInterval { PowerSaving.interval(base, saving: activeNow) }
}


extension DeviceBattery {
    /// True when the Mac is running on its battery rather than a power adapter. False on a Mac with no battery.
    static func onBatteryPower() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(), let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? else { return false }
        return type == kIOPSBatteryPowerValue
    }
}
