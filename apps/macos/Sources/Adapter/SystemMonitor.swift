import AppKit
import Combine
import IOKit
import IOKit.ps

/// Reads the Mac's own state: processor, memory, disks, network, battery, devices, temperature, running programs.
/// It samples only while the menu-bar readout is on or a window showing it is open, so it costs nothing otherwise.
final class SystemMonitor: ObservableObject {
    static let barKey = "systemMonitor.menuBar"
    static let metricsKey = "systemMonitor.metrics"
    static let alertsKey = "systemMonitor.lowBatteryAlerts"

    @Published private(set) var snapshot = MonitorSnapshot()
    @Published var showInMenuBar: Bool { didSet { defaults.set(showInMenuBar, forKey: Self.barKey); update() } }
    @Published var metrics: [MonitorMetric] { didSet { defaults.set(MonitorMetric.join(metrics), forKey: Self.metricsKey) } }
    /// Detail rows (programs) are read only while a window shows them.
    @Published private(set) var viewers = 0

    @Published var lowBatteryAlerts: Bool { didSet { defaults.set(lowBatteryAlerts, forKey: Self.alertsKey); watchBatteries() } }
    static let alertConfigKey = "systemMonitor.resourceAlerts.v1"
    @Published var alertConfig: ResourceAlertConfig { didSet { if let data = try? JSONEncoder().encode(alertConfig) { defaults.set(data, forKey: Self.alertConfigKey) } } }
    private var alertState = ResourceAlertState()
    let info = MacInfo.read()
    private var batteryTimer: Timer?
    private var warned = Set<String>()
    private let toast = Toast()
    private let defaults: UserDefaults
    private var timer: Timer?
    private var lastTicks: CPUTicks?
    private var lastCores: [CPUTicks] = []
    private var lastNet: (counters: NetCounters, at: Date)?
    private var ticksSincePrograms = 0
    private let worker = DispatchQueue(label: "kriya.systemmonitor", qos: .utility)

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        showInMenuBar = defaults.bool(forKey: Self.barKey)
        lowBatteryAlerts = defaults.object(forKey: Self.alertsKey) as? Bool ?? true
        alertConfig = defaults.data(forKey: Self.alertConfigKey).flatMap { try? JSONDecoder().decode(ResourceAlertConfig.self, from: $0) } ?? ResourceAlertConfig()
        let saved = MonitorMetric.parse(defaults.string(forKey: Self.metricsKey) ?? "")
        metrics = saved.isEmpty ? [.cpu, .memory] : saved
    }

    func start() { update(); watchBatteries() }

    /// Every few minutes, says so when a mouse, keyboard or trackpad is nearly flat. Reads only the battery levels macOS lists.
    private func watchBatteries() {
        batteryTimer?.invalidate(); batteryTimer = nil
        guard lowBatteryAlerts else { return }
        let t = Timer(timeInterval: 300, repeats: true) { [weak self] _ in self?.checkBatteries() }
        RunLoop.main.add(t, forMode: .common)
        batteryTimer = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.checkBatteries() }
    }

    private func checkBatteries() {
        let result = LowBattery.check(DeviceBattery.readSystem(), warned: warned)
        warned = result.warned
        for name in result.warn { toast.show("\(name) is running low. Charge it soon.", isError: true) }
    }

    func viewerAppeared() { viewers += 1; update(); sample() }
    func viewerGone() { viewers = max(viewers - 1, 0); update() }

    private func update() {
        let wanted = showInMenuBar || viewers > 0
        if wanted, timer == nil {
            let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.sample() }
            RunLoop.main.add(t, forMode: .common)
            timer = t
            sample()
        } else if !wanted {
            timer?.invalidate(); timer = nil
            lastTicks = nil; lastNet = nil; lastCores = []
        }
    }

    private func sample() {
        let withPrograms = viewers > 0 && (ticksSincePrograms % 2 == 0)
        ticksSincePrograms += 1
        let heavy = viewers > 0
        var next = snapshot
        // The cheap readings are taken here; programs and disks come from a background queue.
        let ticks = Self.cpuTicks()
        if let old = lastTicks, let ticks { next.cpu = CPUTicks.usage(from: old, to: ticks) }
        lastTicks = ticks
        let cores = Self.coreTicks()
        if cores.count == lastCores.count { next.cores = zip(lastCores, cores).map { CPUTicks.usage(from: $0, to: $1) } }
        lastCores = cores
        next.memory = Self.memory()
        let now = Date()
        let counters = Self.netCounters()
        if let last = lastNet {
            let rate = NetCounters.rate(from: last.counters, to: counters, seconds: now.timeIntervalSince(last.at))
            next.down = rate.down; next.up = rate.up
        }
        lastNet = (counters, now)
        next.totalDown = counters.received; next.totalUp = counters.sent
        next.battery = Self.battery()
        next.thermal = ProcessInfo.processInfo.thermalState
        next.uptime = ProcessInfo.processInfo.systemUptime
        if heavy { next.devices = DeviceBattery.readSystem() }
        snapshot = next
        worker.async { [weak self] in
            let disks = Self.disks()
            let programs = withPrograms ? Self.programs() : nil
            DispatchQueue.main.async {
                guard let self else { return }
                var s = self.snapshot
                s.disks = disks
                if let programs {
                    s.topByCPU = Array(programs.sorted { $0.cpu > $1.cpu }.prefix(6))
                    s.topByMemory = Array(programs.sorted { $0.memory > $1.memory }.prefix(6))
                }
                self.snapshot = s
                for message in ResourceAlerts.evaluate(s, config: self.alertConfig, state: &self.alertState, now: Date()) { self.toast.show(message, isError: true) }
            }
        }
    }

    // MARK: Readings

    private static func cpuTicks() -> CPUTicks? {
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        var info = host_cpu_load_info()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return nil }
        return CPUTicks(user: UInt64(info.cpu_ticks.0), system: UInt64(info.cpu_ticks.1), idle: UInt64(info.cpu_ticks.2), nice: UInt64(info.cpu_ticks.3))
    }

    private static func coreTicks() -> [CPUTicks] {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS, let info else { return [] }
        defer { vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)), vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.size)) }
        return (0..<Int(cpuCount)).map { i in
            let base = i * Int(CPU_STATE_MAX)
            return CPUTicks(user: UInt64(info[base + Int(CPU_STATE_USER)]), system: UInt64(info[base + Int(CPU_STATE_SYSTEM)]),
                            idle: UInt64(info[base + Int(CPU_STATE_IDLE)]), nice: UInt64(info[base + Int(CPU_STATE_NICE)]))
        }
    }

    private static func memory() -> MemoryInfo {
        var m = MemoryInfo()
        m.total = Double(ProcessInfo.processInfo.physicalMemory)
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        var stats = vm_statistics64()
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        if result == KERN_SUCCESS {
            let page = Double(vm_kernel_page_size)
            m.wired = Double(stats.wire_count) * page
            m.compressed = Double(stats.compressor_page_count) * page
            m.app = Double(stats.internal_page_count - stats.purgeable_count) * page
            m.cached = Double(stats.external_page_count + stats.purgeable_count) * page
            m.used = m.app + m.wired + m.compressed
        }
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 { m.swapUsed = Double(swap.xsu_used) }
        return m
    }

    private static func disks() -> [DiskInfo] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeIsInternalKey, .volumeIsLocalKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.volumeIsLocal == true, let total = v.volumeTotalCapacity, total > 0 else { return nil }
            let free = v.volumeAvailableCapacityForImportantUsage ?? 0
            return DiskInfo(name: url.path == "/" ? (v.volumeName ?? "Macintosh HD") : (v.volumeName ?? url.lastPathComponent), path: url.path,
                            total: Int64(total), free: free, isInternal: v.volumeIsInternal ?? false)
        }.sorted { ($0.path == "/" ? 0 : 1, $0.name) < ($1.path == "/" ? 0 : 1, $1.name) }
    }

    private static func netCounters() -> NetCounters {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return NetCounters(received: 0, sent: 0) }
        defer { freeifaddrs(list) }
        var received: UInt64 = 0, sent: UInt64 = 0
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let i = p.pointee
            guard let addr = i.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK), i.ifa_flags & UInt32(IFF_LOOPBACK) == 0, let data = i.ifa_data else { continue }
            let name = String(cString: i.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("pdp_ip") else { continue }
            let d = data.assumingMemoryBound(to: if_data.self).pointee
            received += UInt64(d.ifi_ibytes); sent += UInt64(d.ifi_obytes)
        }
        return NetCounters(received: received, sent: sent)
    }

    private static func battery() -> BatteryInfo? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any], (d["Type"] as? String) == "InternalBattery",
                  let current = d["Current Capacity"] as? Int else { continue }
            let max = (d["Max Capacity"] as? Int) ?? 100
            var left = d[kIOPSTimeToEmptyKey] as? Int
            if (left ?? -1) < 0 { left = nil }
            var info = BatteryInfo(percent: max > 0 ? min(current * 100 / max, 100) : current, charging: (d["Is Charging"] as? Bool) ?? false,
                                   onAC: (d["Power Source State"] as? String) == "AC Power", minutesLeft: left, cycles: nil, healthPercent: nil)
            let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
            if service != 0 {
                defer { IOObjectRelease(service) }
                func number(_ key: String) -> Int? { (IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.intValue }
                info.cycles = number("CycleCount")
                if let design = number("DesignCapacity"), let raw = number("AppleRawMaxCapacity") ?? number("MaxCapacity"), design > 0, raw > 100 {
                    info.healthPercent = min(raw * 100 / design, 100)
                }
            }
            return info
        }
        return nil
    }

    private static func programs() -> [ProcessUse] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-Aceo", "pid=,pcpu=,rss=,comm="]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return ProcessUse.parse(String(decoding: data, as: UTF8.self))
    }
}

/// Facts about this Mac that do not change while it runs.
struct MacInfo {
    let model: String
    let chip: String
    let system: String
    let memory: String
    let cores: String

    static func read() -> MacInfo {
        func text(_ name: String) -> String? {
            var size = 0
            guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
            var buffer = [CChar](repeating: 0, count: size)
            guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
            return String(cString: buffer)
        }
        let p = ProcessInfo.processInfo
        let v = p.operatingSystemVersion
        return MacInfo(model: text("hw.model") ?? "Mac", chip: text("machdep.cpu.brand_string") ?? "Unknown",
                       system: "macOS \(v.majorVersion).\(v.minorVersion)\(v.patchVersion > 0 ? ".\(v.patchVersion)" : "")",
                       memory: ByteFormat.size(Double(p.physicalMemory)), cores: "\(p.processorCount) cores")
    }
}
