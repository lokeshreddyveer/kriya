import Foundation
import IOKit.hid

/// Works out which mouse or trackpad an event came from. The system's event does not say, so a second IOHIDManager,
/// on its own thread, notes which device moved, scrolled or clicked last. An event arriving just after counts as that
/// device's. This is a best guess, right whenever one device is used at a time and a little blurred when two are used
/// in the same few hundredths of a second.
final class DeviceActivityTracker {
    private let lock = NSLock()
    private var lastTimes: [String: UInt64] = [:]   // guarded by lock: when each device last moved, scrolled or clicked
    private var lastUsedDates: [String: Date] = [:]   // guarded by lock

    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private var interfaceIDs: [UnsafeMutableRawPointer: String] = [:]   // used only on the tracker's thread

    /// A rate measurement in progress: the device and the times its movement reports arrived, in nanoseconds. Guarded by lock.
    private var sampling: (id: String, times: [UInt64])?

    /// Activity older than this is forgotten, so an event with no recent device falls back to the general settings.
    static let maxAgeNs: UInt64 = 300_000_000
    /// How far back the live line on the Devices tab looks, so a device moved a moment ago is still named.
    static let testWindowNs: UInt64 = 1_500_000_000

    func start() {
        guard thread == nil else { return }
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            guard let self else { ready.signal(); return }
            self.runLoop = CFRunLoopGetCurrent()
            let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
            IOHIDManagerSetDeviceMatchingMultiple(manager, [
                [kIOHIDDeviceUsagePageKey: 0x01, kIOHIDDeviceUsageKey: 0x02],
                [kIOHIDDeviceUsagePageKey: 0x01, kIOHIDDeviceUsageKey: 0x01],
                [kIOHIDDeviceUsagePageKey: 0x0D, kIOHIDDeviceUsageKey: 0x05],
            ] as CFArray)
            // Only the elements that mean "moved, scrolled or clicked": X, Y, wheel, and the buttons.
            IOHIDManagerSetInputValueMatchingMultiple(manager, [
                [kIOHIDElementUsagePageKey: 0x01, kIOHIDElementUsageMinKey: 0x30, kIOHIDElementUsageMaxKey: 0x38],
                [kIOHIDElementUsagePageKey: 0x09],
            ] as CFArray)
            let context = Unmanaged.passUnretained(self).toOpaque()
            IOHIDManagerRegisterDeviceMatchingCallback(manager, trackerDeviceAdded, context)
            IOHIDManagerRegisterDeviceRemovalCallback(manager, trackerDeviceRemoved, context)
            IOHIDManagerRegisterInputValueCallback(manager, trackerInputValue, context)
            IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
            _ = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            ready.signal()
            CFRunLoopRun()
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            self.interfaceIDs.removeAll()
        }
        thread.name = "app.kriya.deviceactivity"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        self.thread = thread
        Log.info("Devices", "Tracking which device is in use")
    }

    func stop() {
        if let runLoop { CFRunLoopStop(runLoop) }
        runLoop = nil
        thread = nil
        lock.lock()
        lastTimes.removeAll()
        lock.unlock()
    }

    /// Which device an event just now came from. If two devices were active in the same few hundredths of a second there is no telling
    /// which, so the answer is "not sure" and the general settings are used rather than one device's by guesswork. Safe from any thread.
    func attribution(maxAgeNs: UInt64 = DeviceActivityTracker.maxAgeNs) -> DeviceAttribution.Result {
        lock.lock()
        defer { lock.unlock() }
        let now = DispatchTime.now().uptimeNanoseconds
        return DeviceAttribution.resolve(ages: lastTimes.mapValues { now &- $0 }, maxAge: maxAgeNs)
    }

    /// The device that was active in the last few hundredths of a second and was the only one, if any. Safe from any thread.
    func currentDeviceID() -> String? {
        if case .device(let id) = attribution() { return id }
        return nil
    }

    /// When a device last moved, scrolled or clicked (since Kriya started). Safe to call from any thread.
    func lastUsed(_ id: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return lastUsedDates[id]
    }

    /// Lets tests say which device is active without any hardware.
    func simulateActivity(deviceID: String?) {
        lock.lock()
        lastTimes.removeAll()
        if let deviceID { lastTimes[deviceID] = DispatchTime.now().uptimeNanoseconds; lastUsedDates[deviceID] = Date() }
        lock.unlock()
    }

    /// Lets tests say that several devices are active at once.
    func simulateActivity(deviceIDs: [String]) {
        lock.lock()
        lastTimes.removeAll()
        let now = DispatchTime.now().uptimeNanoseconds
        for id in deviceIDs { lastTimes[id] = now; lastUsedDates[id] = Date() }
        lock.unlock()
    }

    /// Records when the movement reports of one device arrive, for `seconds`, then hands them over (on the main queue). Only one at a time;
    /// a second request while one is running is answered with nothing. Nothing is stored after it.
    func sampleMovement(of deviceID: String, seconds: Double, completion: @escaping ([UInt64]) -> Void) {
        lock.lock()
        guard sampling == nil else { lock.unlock(); DispatchQueue.main.async { completion([]) }; return }
        sampling = (deviceID, [])
        lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let times = self.sampling?.times ?? []
            self.sampling = nil
            self.lock.unlock()
            DispatchQueue.main.async { completion(times) }
        }
    }

    // MARK: Callbacks (tracker thread)

    fileprivate func added(_ device: IOHIDDevice) {
        let pointer = Unmanaged.passUnretained(device).toOpaque()
        if let described = DeviceRegistry.describe(device) { interfaceIDs[pointer] = described.id }
    }

    fileprivate func removed(_ device: IOHIDDevice) {
        if let id = interfaceIDs[Unmanaged.passUnretained(device).toOpaque()] {
            lock.lock()
            lastTimes[id] = nil
            lock.unlock()
        }
        interfaceIDs[Unmanaged.passUnretained(device).toOpaque()] = nil
    }

    fileprivate func input(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let device = IOHIDElementGetDevice(element)
        guard let id = interfaceIDs[Unmanaged.passUnretained(device).toOpaque()] else { return }
        // A report of "no movement" is not activity.
        guard IOHIDValueGetIntegerValue(value) != 0 else { return }
        lock.lock(); let measuring = sampling?.id == id; lock.unlock()
        if measuring, IOHIDElementGetUsagePage(element) == 0x01, [0x30, 0x31].contains(IOHIDElementGetUsage(element)) {
            let stamp = DeviceCapabilityReader.nanoseconds(fromMach: IOHIDValueGetTimeStamp(value))
            lock.lock()
            sampling?.times.append(stamp)
            lock.unlock()
        }
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        lastTimes[id] = now
        lastUsedDates[id] = Date()
        lock.unlock()
    }
}

private func trackerDeviceAdded(_ context: UnsafeMutableRawPointer?, _ result: IOReturn, _ sender: UnsafeMutableRawPointer?, _ device: IOHIDDevice) {
    guard let context else { return }
    Unmanaged<DeviceActivityTracker>.fromOpaque(context).takeUnretainedValue().added(device)
}

private func trackerDeviceRemoved(_ context: UnsafeMutableRawPointer?, _ result: IOReturn, _ sender: UnsafeMutableRawPointer?, _ device: IOHIDDevice) {
    guard let context else { return }
    Unmanaged<DeviceActivityTracker>.fromOpaque(context).takeUnretainedValue().removed(device)
}

private func trackerInputValue(_ context: UnsafeMutableRawPointer?, _ result: IOReturn, _ sender: UnsafeMutableRawPointer?, _ value: IOHIDValue) {
    guard let context else { return }
    Unmanaged<DeviceActivityTracker>.fromOpaque(context).takeUnretainedValue().input(value)
}
