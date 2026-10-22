import Foundation
import IOKit.hid

/// Works out which mouse or trackpad an event came from. The system's event does not say, so a second IOHIDManager,
/// on its own thread, notes which device moved, scrolled or clicked last. An event arriving just after counts as that
/// device's. This is a best guess, right whenever one device is used at a time and a little blurred when two are used
/// in the same few hundredths of a second.
final class DeviceActivityTracker {
    private let lock = NSLock()
    private var lastID: String?          // guarded by lock
    private var lastTimeNs: UInt64 = 0   // guarded by lock
    private var lastUsedDates: [String: Date] = [:]   // guarded by lock

    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private var interfaceIDs: [UnsafeMutableRawPointer: String] = [:]   // used only on the tracker's thread

    /// Activity older than this is forgotten, so an event with no recent device falls back to the general settings.
    private static let maxAgeNs: UInt64 = 300_000_000

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
        lastID = nil
        lock.unlock()
    }

    /// The device that was active in the last few hundredths of a second, if any. Safe to call from any thread.
    func currentDeviceID() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let lastID else { return nil }
        return DispatchTime.now().uptimeNanoseconds &- lastTimeNs <= Self.maxAgeNs ? lastID : nil
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
        lastID = deviceID
        lastTimeNs = DispatchTime.now().uptimeNanoseconds
        if let deviceID { lastUsedDates[deviceID] = Date() }
        lock.unlock()
    }

    // MARK: Callbacks (tracker thread)

    fileprivate func added(_ device: IOHIDDevice) {
        let pointer = Unmanaged.passUnretained(device).toOpaque()
        if let described = DeviceRegistry.describe(device) { interfaceIDs[pointer] = described.id }
    }

    fileprivate func removed(_ device: IOHIDDevice) {
        interfaceIDs[Unmanaged.passUnretained(device).toOpaque()] = nil
    }

    fileprivate func input(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let device = IOHIDElementGetDevice(element)
        guard let id = interfaceIDs[Unmanaged.passUnretained(device).toOpaque()] else { return }
        // A report of "no movement" is not activity.
        guard IOHIDValueGetIntegerValue(value) != 0 else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        lastID = id
        lastTimeNs = now
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
