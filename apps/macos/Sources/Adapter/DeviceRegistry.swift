import Combine
import Foundation
import IOKit.hid

/// A pointing device as the interface shows it: what the core remembers, plus whether it is plugged in right now.
struct InputDevice: Identifiable, Equatable {
    var record: DeviceRecord
    var isConnected: Bool

    var id: String { record.id }
    var displayName: String { record.nickname ?? record.name }
    var connection: ConnectionKind { record.connectionOverride ?? record.detectedConnection }
}

/// Finds mice and trackpads through IOHIDManager (wired, Bluetooth and receiver-based alike) and keeps the shared
/// registry in the core up to date, so a device keeps its name and choices between runs and is recognised again when
/// it reconnects.
final class DeviceRegistry: ObservableObject {
    @Published private(set) var devices: [InputDevice] = []

    private let core: KriyaCore
    private var manager: IOHIDManager?
    private var records: [String: DeviceRecord] = [:]
    private var liveCounts: [String: Int] = [:]                      // interfaces currently present, per device
    private var liveInterfaces: [UnsafeMutableRawPointer: String] = [:]

    init(core: KriyaCore) {
        self.core = core
        loadRecords()
    }

    // MARK: Lifecycle

    func start() {
        guard manager == nil else { return }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [[String: Any]] = [
            [kIOHIDDeviceUsagePageKey: 0x01, kIOHIDDeviceUsageKey: 0x02],   // generic desktop: mouse
            [kIOHIDDeviceUsagePageKey: 0x01, kIOHIDDeviceUsageKey: 0x01],   // generic desktop: pointer
            [kIOHIDDeviceUsagePageKey: 0x0D, kIOHIDDeviceUsageKey: 0x05],   // digitizer: touch pad
        ]
        IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, hidDeviceAdded, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, hidDeviceRemoved, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if result != kIOReturnSuccess {
            Log.warning("Devices", "IOHIDManager did not open cleanly (code \(result)); devices may be missing")
        }
        self.manager = manager
        Log.info("Devices", "Watching for mice and trackpads")
    }

    func stop() {
        guard let manager else { return }
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = nil
        liveInterfaces.removeAll()
        liveCounts.removeAll()
        publish()
    }

    /// Re-reads the saved choices after a restore, keeping what is plugged in.
    func reload() {
        loadRecords()
    }

    // MARK: Editing

    func setNickname(_ nickname: String?, for id: String) {
        do {
            try core.setDeviceNickname(id: id, nickname: nickname)
            loadRecords()
        } catch {
            Log.error("Devices", "Could not rename device: \(error.userMessage)")
        }
    }

    func setConnectionOverride(_ value: ConnectionKind?, for id: String) {
        do {
            try core.setDeviceConnectionOverride(id: id, value: value)
            loadRecords()
        } catch {
            Log.error("Devices", "Could not change device connection: \(error.userMessage)")
        }
    }

    /// Removes a device that is not plugged in from the list.
    func forget(_ id: String) {
        guard (liveCounts[id] ?? 0) == 0 else { return }
        try? core.forgetDevice(id: id)
        loadRecords()
    }

    // MARK: Registry state

    private func loadRecords() {
        do {
            records = Dictionary(uniqueKeysWithValues: try core.devices().map { ($0.id, $0) })
        } catch {
            Log.error("Devices", "Could not load devices: \(error.userMessage)")
        }
        publish()
    }

    private func publish() {
        devices = records.values
            .map { InputDevice(record: $0, isConnected: (liveCounts[$0.id] ?? 0) > 0) }
            .sorted { a, b in
                if a.isConnected != b.isConnected { return a.isConnected }
                return a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
            }
    }

    // MARK: IOHIDManager callbacks (main run loop)

    fileprivate func handleAdded(_ device: IOHIDDevice) {
        let pointer = Unmanaged.passUnretained(device).toOpaque()
        guard liveInterfaces[pointer] == nil, let described = Self.describe(device) else { return }
        liveInterfaces[pointer] = described.id
        liveCounts[described.id, default: 0] += 1

        let now = SystemInfo.nowSeconds
        let known = records[described.id]
        let record = DeviceRecord(
            id: described.id,
            name: described.name,
            vendorId: UInt32(described.vendor),
            productId: UInt32(described.product),
            serial: described.serial,
            transport: described.transport,
            kind: described.kind,
            detectedConnection: described.connection,
            connectionOverride: known?.connectionOverride,
            nickname: known?.nickname,
            firstSeen: known?.firstSeen ?? now,
            lastSeen: now
        )
        records[described.id] = record
        do {
            try core.upsertDevice(device: record)
        } catch {
            Log.error("Devices", "Could not save device: \(error.userMessage)")
        }
        if liveCounts[described.id] == 1 {
            Log.info("Devices", "Connected: \(described.name) (\(described.connection.title), \(described.transport))")
        }
        publish()
    }

    fileprivate func handleRemoved(_ device: IOHIDDevice) {
        let pointer = Unmanaged.passUnretained(device).toOpaque()
        guard let id = liveInterfaces.removeValue(forKey: pointer) else { return }
        let remaining = (liveCounts[id] ?? 1) - 1
        liveCounts[id] = remaining > 0 ? remaining : nil
        if remaining <= 0 {
            let now = SystemInfo.nowSeconds
            try? core.touchDevice(id: id, lastSeen: now)
            records[id]?.lastSeen = now
            Log.info("Devices", "Disconnected: \(records[id]?.name ?? id)")
        }
        publish()
    }

    // MARK: Identifying a device

    struct Described: Equatable {
        var id: String
        var name: String
        var vendor: Int
        var product: Int
        var serial: String?
        var transport: String
        var kind: DeviceKind
        var connection: ConnectionKind
    }

    static func describe(_ device: IOHIDDevice) -> Described? {
        func property(_ key: String) -> Any? { IOHIDDeviceGetProperty(device, key as CFString) }
        let vendor = property(kIOHIDVendorIDKey) as? Int ?? 0
        let product = property(kIOHIDProductIDKey) as? Int ?? 0
        let name = property(kIOHIDProductKey) as? String ?? "Pointing Device"
        let serial = (property(kIOHIDSerialNumberKey) as? String).flatMap { $0.isEmpty ? nil : $0 }
        let transport = property(kIOHIDTransportKey) as? String ?? "Unknown"
        let location = property(kIOHIDLocationIDKey) as? Int
        let builtIn = (property("Built-In") as? Int) == 1
        let usagePage = property(kIOHIDPrimaryUsagePageKey) as? Int
        let usage = property(kIOHIDPrimaryUsageKey) as? Int
        return classify(
            vendor: vendor, product: product, name: name, serial: serial, transport: transport,
            location: location, builtIn: builtIn, usagePage: usagePage, usage: usage
        )
    }

    /// Works out what kind of device this is and how it is connected. Pure, so it can be tested with sample values.
    static func classify(
        vendor: Int, product: Int, name: String, serial: String?, transport: String,
        location: Int?, builtIn: Bool, usagePage: Int?, usage: Int?
    ) -> Described {
        let lowerName = name.lowercased()
        let upperTransport = transport.uppercased()

        let kind: DeviceKind = lowerName.contains("trackpad") || (usagePage == 0x0D && usage == 0x05) ? .trackpad : .mouse

        let connection: ConnectionKind
        if builtIn || ["SPI", "FIFO", "I2C"].contains(upperTransport) {
            connection = .builtIn
        } else if upperTransport.contains("BLUETOOTH") {
            connection = .wireless
        } else if ["receiver", "unifying", "bolt", "wireless", "2.4g"].contains(where: lowerName.contains) {
            // A mouse behind a USB receiver reports itself as USB. The name is the best hint; the person can correct it.
            connection = .wireless
        } else {
            connection = .wired
        }

        let id: String
        if let serial {
            id = "\(vendor):\(product):\(serial)"
        } else if builtIn {
            id = "builtin:\(vendor):\(product)"
        } else {
            id = "\(vendor):\(product):\(upperTransport.lowercased()):loc\(location ?? 0)"
        }
        return Described(
            id: id, name: name, vendor: vendor, product: product, serial: serial,
            transport: transport, kind: kind, connection: connection
        )
    }
}

private func hidDeviceAdded(_ context: UnsafeMutableRawPointer?, _ result: IOReturn, _ sender: UnsafeMutableRawPointer?, _ device: IOHIDDevice) {
    guard let context else { return }
    Unmanaged<DeviceRegistry>.fromOpaque(context).takeUnretainedValue().handleAdded(device)
}

private func hidDeviceRemoved(_ context: UnsafeMutableRawPointer?, _ result: IOReturn, _ sender: UnsafeMutableRawPointer?, _ device: IOHIDDevice) {
    guard let context else { return }
    Unmanaged<DeviceRegistry>.fromOpaque(context).takeUnretainedValue().handleRemoved(device)
}
