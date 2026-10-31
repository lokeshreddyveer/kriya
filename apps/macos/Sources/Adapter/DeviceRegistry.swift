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
    /// What the Devices pane shows beyond the name: battery, last use and reconnection, by device id.
    @Published private(set) var statuses: [String: DeviceStatus] = [:]
    /// What each device says it can do, read from the system. Kept after a device is unplugged, so the Devices tab can still describe it.
    @Published private(set) var capabilities: [String: DeviceCapabilities] = [:]
    /// The state of a polling-rate measurement, by device id. Only when asked for.
    @Published private(set) var rateStates: [String: PollingRateState] = [:]
    /// Records when one device's movement reports arrive, for a number of seconds. Set by the app from the activity tracker.
    var rateSampler: ((String, Double, @escaping ([UInt64]) -> Void) -> Void)?
    private var hardwareInfo: [String: HIDDeviceInfo] = [:]

    /// Where battery readings come from. A test replaces it, so no hardware is needed.
    var batteryReader: () -> [BatteryReading] = DeviceBattery.readSystem
    /// When a device was last used, and which device is in use now. Set by the app from the activity tracker.
    var lastUsedProvider: (String) -> Date? = { _ in nil }
    var activeDeviceID: () -> String? = { nil }
    /// Who Kriya thinks is in use, with a longer memory than an event gets, for the live line on the Devices tab.
    var activeAttribution: () -> DeviceAttribution.Result = { .none }

    private var history = ConnectionHistory()
    private var readings: [BatteryReading] = []
    private var statusTimer: Timer?
    private let nameLock = NSLock()
    private var names: [String: String] = [:]          // guarded by nameLock, for the event tap's thread

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
        refreshStatus()
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.refreshStatus() }
        RunLoop.main.add(timer, forMode: .common)
        statusTimer = timer
    }

    func stop() {
        guard let manager else { return }
        statusTimer?.invalidate()
        statusTimer = nil
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
        history.forget(id)
        loadRecords()
    }

    // MARK: Status (battery, last use, reconnection)

    /// Reads batteries again, off the main thread, then updates what the pane shows. Cheap enough to run every minute.
    func refreshStatus() {
        let reader = batteryReader
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let fresh = reader()
            DispatchQueue.main.async {
                guard let self else { return }
                self.readings = fresh
                self.publishStatuses()
            }
        }
    }

    private func publishStatuses() {
        var next: [String: DeviceStatus] = [:]
        for device in devices {
            var status = DeviceStatus()
            if device.isConnected {
                let wanted = [device.record.name, device.record.nickname].compactMap { $0 }
                status.battery = DeviceBattery.state(forDeviceNamed: wanted, readings: readings)
            }
            status.connectedAt = history.connectedAt[device.id]
            status.reconnectedAt = history.reconnectedAt[device.id]
            status.lastUsed = lastUsedProvider(device.id)
            next[device.id] = status
        }
        if next != statuses { statuses = next }
    }

    /// The name of a device, from any thread (the event tap's, for the trace).
    func displayName(forID id: String) -> String? {
        nameLock.lock()
        defer { nameLock.unlock() }
        return names[id]
    }

    /// The device in use right now, by name, if there is one.
    func activeDeviceName() -> String? {
        activeDeviceID().flatMap(displayName(forID:))
    }

    /// The same, but saying so when two devices were just used together and it cannot tell which one this is.
    func activeDeviceLabel() -> String? {
        switch activeAttribution() {
        case .device(let id): return displayName(forID: id)
        case .ambiguous: return "not sure which device"
        case .none: return activeDeviceName()
        }
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

    fileprivate func setRateState(_ state: PollingRateState, for id: String) { rateStates[id] = state }

    private func publish() {
        devices = records.values
            .map { InputDevice(record: $0, isConnected: (liveCounts[$0.id] ?? 0) > 0) }
            .sorted { a, b in
                if a.isConnected != b.isConnected { return a.isConnected }
                return a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
            }
        nameLock.lock()
        names = Dictionary(devices.map { ($0.id, $0.displayName) }, uniquingKeysWith: { first, _ in first })
        nameLock.unlock()
        publishStatuses()
    }

    // MARK: IOHIDManager callbacks (main run loop)

    fileprivate func handleAdded(_ device: IOHIDDevice) {
        let pointer = Unmanaged.passUnretained(device).toOpaque()
        guard liveInterfaces[pointer] == nil, let described = Self.describe(device) else { return }
        liveInterfaces[pointer] = described.id
        liveCounts[described.id, default: 0] += 1
        // What the device says about itself is read here, once for each interface it has, and described together.
        let read = DeviceCapabilityReader.info(of: device)
        if hardwareInfo[described.id] != nil { hardwareInfo[described.id]?.merge(read) } else { hardwareInfo[described.id] = read }
        capabilities[described.id] = hardwareInfo[described.id].map(DeviceCapabilityAnalyzer.analyze)

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
            history.connected(described.id, at: Date())
            DeviceTimelineStore.shared.record(described.name, connected: true)
            Log.info("Devices", "Connected: \(described.name) (\(described.connection.title), \(described.transport))")
            refreshStatus()
        }
        publish()
    }

    fileprivate func handleRemoved(_ device: IOHIDDevice) {
        let pointer = Unmanaged.passUnretained(device).toOpaque()
        guard let id = liveInterfaces.removeValue(forKey: pointer) else { return }
        let remaining = (liveCounts[id] ?? 1) - 1
        liveCounts[id] = remaining > 0 ? remaining : nil
        if remaining <= 0 { hardwareInfo[id] = nil }
        if remaining <= 0 {
            let now = SystemInfo.nowSeconds
            try? core.touchDevice(id: id, lastSeen: now)
            records[id]?.lastSeen = now
            history.disconnected(id)
            DeviceTimelineStore.shared.record(records[id]?.name ?? id, connected: false)
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


/// The device timeline, kept in preferences.
final class DeviceTimelineStore: ObservableObject {
    static let shared = DeviceTimelineStore()
    private let key = "deviceTimeline.v1"
    @Published private(set) var timeline: DeviceTimeline

    private init() {
        timeline = UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(DeviceTimeline.self, from: $0) } ?? DeviceTimeline()
    }

    func record(_ device: String, connected: Bool) {
        DispatchQueue.main.async { [self] in
            timeline.record(device, connected: connected, at: Date())
            if let data = try? JSONEncoder().encode(timeline) { UserDefaults.standard.set(data, forKey: key) }
        }
    }

    func clear() { timeline = DeviceTimeline(); UserDefaults.standard.removeObject(forKey: key) }
}

/// Where a polling-rate measurement is.
enum PollingRateState: Equatable {
    case measuring
    case measured(hz: Int)
    /// Not enough movement in the time to tell.
    case notEnoughMovement
}

extension DeviceRegistry {
    /// Measures how often a device reports. The person is asked to move the mouse steadily for a few seconds. Nothing is kept but the
    /// number, and the device is not opened for exclusive use.
    func measurePollingRate(for id: String, seconds: Double = 4) {
        guard let rateSampler, rateStates[id] != .measuring else { return }
        setRateState(.measuring, for: id)
        rateSampler(id, seconds) { [weak self] times in
            var estimator = PollingRateEstimator()
            times.forEach { estimator.record(nanoseconds: $0) }
            self?.setRateState(estimator.estimate().map { .measured(hz: $0) } ?? .notEnoughMovement, for: id)
        }
    }
}
