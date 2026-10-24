import Combine
import Foundation
import IOKit.hid

/// The keyboards connected right now, so a remapping rule can be limited to one of them. Each is known by what it reports about itself
/// (maker, model, serial number), not only by name, because a name can change when a Bluetooth keyboard reconnects or is renamed.
final class KeyboardDevices: ObservableObject {
    private static let rememberedKey = "keyboard.deviceNames.v1"

    @Published private(set) var devices: [KeyboardDevice] = []
    /// Names kept for keyboards seen before, so a rule for one that is unplugged still says which keyboard it is.
    @Published private(set) var remembered: [String: String] = UserDefaults.standard.dictionary(forKey: KeyboardDevices.rememberedKey) as? [String: String] ?? [:]
    private var manager: IOHIDManager?

    /// The names of the connected keyboards (kept for the parts that only need names).
    var names: [String] { Array(Set(devices.map(\.name))).sorted() }

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
        guard let manager, let found = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return }
        let list = found.compactMap { device -> KeyboardDevice? in
            guard let name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String else { return nil }
            let vendor = (IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? NSNumber)?.intValue ?? 0
            let product = (IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? NSNumber)?.intValue ?? 0
            let serial = IOHIDDeviceGetProperty(device, kIOHIDSerialNumberKey as CFString) as? String
            return KeyboardDevice(id: KeyboardDevice.identity(vendor: vendor, product: product, serial: serial), name: name)
        }
        // One entry per distinct keyboard, in a steady order.
        var seen = Set<String>()
        devices = list.filter { seen.insert($0.id + "|" + $0.name).inserted }.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
        var names = remembered
        for device in devices { names[device.id] = device.name }
        if names != remembered {
            remembered = names
            UserDefaults.standard.set(names, forKey: Self.rememberedKey)
        }
    }
}
