import Combine
import Foundation
import IOKit.hid

/// The keyboards connected right now, by name, so a remapping rule can be limited to one of them.
final class KeyboardDevices: ObservableObject {
    @Published private(set) var names: [String] = []
    private var manager: IOHIDManager?

    func start() {
        guard manager == nil else { return }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let match: [String: Any] = [kIOHIDDeviceUsagePageKey as String: 0x01, kIOHIDDeviceUsageKey as String: 0x06]
        IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)
        let changed: IOHIDDeviceCallback = { context, _, _, _ in
            guard let context else { return }
            let me = Unmanaged<KeyboardDevices>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { me.refresh() }
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, changed, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, changed, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager
        refresh()
    }

    func stop() {
        if let manager {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        manager = nil
    }

    private func refresh() {
        guard let manager, let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return }
        let found = devices.compactMap { IOHIDDeviceGetProperty($0, kIOHIDProductKey as CFString) as? String }
        names = Array(Set(found)).sorted()
    }
}
