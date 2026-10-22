import AppKit
import Combine
import IOKit.pwr_mgt
import IOKit.ps

/// Keeps the Mac from sleeping on its own: for a set time, until turned off, or while chosen apps are running. The
/// system releases the hold by itself if Kriya quits, so a Mac can never be left unable to sleep.
final class KeepAwake: ObservableObject {
    @Published private(set) var isOn = false
    /// When a timed session ends. Nil for a session with no end, or when the hold comes from a running app.
    @Published private(set) var endsAt: Date?
    @Published private(set) var heldBy: String = ""
    @Published var keepDisplayOn: Bool {
        didSet { UserDefaults.standard.set(keepDisplayOn, forKey: Self.displayKey); apply() }
    }
    @Published var watchedAppIDs: [String] {
        didSet { UserDefaults.standard.set(watchedAppIDs, forKey: Self.appsKey); apply() }
    }

    /// Stop keeping the Mac awake when it runs on battery and the charge falls to this percentage. 0 turns it off.
    @Published var stopBelowBattery: Int {
        didSet { UserDefaults.standard.set(stopBelowBattery, forKey: Self.batteryKey) }
    }

    private static let batteryKey = "keepAwakeBattery"
    private static let displayKey = "keepAwakeDisplay"
    private static let appsKey = "keepAwakeApps"

    private var manual = false
    private var assertions: [IOPMAssertionID] = []
    private var timer: Timer?
    private var batteryTimer: Timer?
    private var observers: [NSObjectProtocol] = []

    init() {
        keepDisplayOn = UserDefaults.standard.bool(forKey: Self.displayKey)
        watchedAppIDs = UserDefaults.standard.stringArray(forKey: Self.appsKey) ?? []
        stopBelowBattery = UserDefaults.standard.integer(forKey: Self.batteryKey)
        batteryTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.checkBattery() }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.apply() })
        }
        apply()
    }

    /// On battery and at or below the chosen charge: let the Mac sleep again.
    private func checkBattery() {
        guard isOn, stopBelowBattery > 0, let (level, onBattery) = Self.battery(), onBattery, level <= stopBelowBattery else { return }
        Log.info("Power", "Battery at \(level)%: no longer keeping the Mac awake")
        manual = false
        endsAt = nil
        timer?.invalidate()
        timer = nil
        // Apps that are being watched are let go too, so the Mac can sleep.
        watchedAppIDs = []
        apply()
    }

    /// The charge in percent, and whether the Mac is running on battery.
    private static func battery() -> (Int, Bool)? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  let capacity = description[kIOPSCurrentCapacityKey] as? Int,
                  let state = description[kIOPSPowerSourceStateKey] as? String else { continue }
            return (capacity, state == kIOPSBatteryPowerValue)
        }
        return nil
    }

    deinit {
        batteryTimer?.invalidate()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        release()
    }

    // MARK: Turning it on and off

    /// Starts a session. `minutes` of nil keeps the Mac awake until it is turned off.
    func start(minutes: Int?) {
        manual = true
        endsAt = minutes.map { Date().addingTimeInterval(TimeInterval($0 * 60)) }
        timer?.invalidate()
        timer = nil
        if let endsAt {
            let timer = Timer(fire: endsAt, interval: 0, repeats: false) { [weak self] _ in self?.stop() }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
        apply()
        Log.info("Power", minutes.map { "Keeping the Mac awake for \($0) minutes" } ?? "Keeping the Mac awake")
    }

    /// Keeps the Mac awake until the next time the clock shows this hour and minute (today, or tomorrow if it has passed).
    func start(untilHour hour: Int, minute: Int) {
        guard let target = Calendar.current.nextDate(after: Date(), matching: DateComponents(hour: hour, minute: minute, second: 0), matchingPolicy: .nextTime) else { return }
        start(minutes: max(1, Int(target.timeIntervalSinceNow / 60)))
    }

    func stop() {
        manual = false
        endsAt = nil
        timer?.invalidate()
        timer = nil
        apply()
    }

    func toggle() {
        if manual { stop() } else { start(minutes: nil) }
    }

    // MARK: Holding

    private var runningWatchedApp: String? {
        guard !watchedAppIDs.isEmpty else { return nil }
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        return watchedAppIDs.first { running.contains($0) }
    }

    private func apply() {
        release()
        let app = runningWatchedApp
        guard manual || app != nil else {
            isOn = false
            heldBy = ""
            return
        }
        hold(kIOPMAssertionTypePreventUserIdleSystemSleep as String, reason: "Kriya is keeping the Mac awake")
        if keepDisplayOn { hold(kIOPMAssertionTypePreventUserIdleDisplaySleep as String, reason: "Kriya is keeping the display on") }
        isOn = true
        heldBy = manual ? "You turned it on" : "\(AppChoice.name(for: app ?? "")) is running"
    }

    private func hold(_ type: String, reason: String) {
        var id = IOPMAssertionID(0)
        if IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &id) == kIOReturnSuccess {
            assertions.append(id)
        }
    }

    private func release() {
        for id in assertions { IOPMAssertionRelease(id) }
        assertions.removeAll()
    }
}
