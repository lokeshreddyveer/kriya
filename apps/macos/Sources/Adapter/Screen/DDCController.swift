import AppKit
import IOKit

/// Brightness and input of external monitors over DDC/CI, on Apple silicon Macs. The calls it needs are in IOKit but not in
/// Apple's headers, so they are looked up by name at run time; if they are missing, or a monitor does not answer, the controls
/// are simply not shown. Nothing here is assumed to work for every monitor.
final class DDCController: ObservableObject {
    static let shared = DDCController()
    private static let presetsKey = "monitorPresets.v1"

    struct Monitor: Identifiable, Equatable {
        let id: String
        var name: String
        var brightness: DDC.Reading?
        var input: DDC.Reading?
        /// The input before the last switch, so it can be switched back.
        var previousInput: Int?
        var brightnessPercent: Int? { brightness.map { DDC.percent(fromRaw: $0.current, maximum: $0.maximum) } }
    }

    @Published private(set) var monitors: [Monitor] = []
    @Published private(set) var status: String?
    @Published private(set) var busy = false
    @Published var presets: [MonitorPreset] {
        didSet { if let data = try? JSONEncoder().encode(presets) { UserDefaults.standard.set(data, forKey: Self.presetsKey) } }
    }
    /// What the monitors were set to before the last preset, so it can be undone.
    @Published private(set) var undoSettings: [MonitorSetting]?

    private struct API {
        typealias Create = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
        typealias IO = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn
        let create: Create, read: IO, write: IO

        static func load() -> API? {
            guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW),
                  let c = dlsym(handle, "IOAVServiceCreateWithService"), let r = dlsym(handle, "IOAVServiceReadI2C"), let w = dlsym(handle, "IOAVServiceWriteI2C") else { return nil }
            return API(create: unsafeBitCast(c, to: Create.self), read: unsafeBitCast(r, to: IO.self), write: unsafeBitCast(w, to: IO.self))
        }
    }

    private let queue = DispatchQueue(label: "app.kriya.ddc", qos: .userInitiated)
    private var services: [String: CFTypeRef] = [:]
    private var api: API?
    private var observer: NSObjectProtocol?

    private init() {
        presets = UserDefaults.standard.data(forKey: Self.presetsKey).flatMap { try? JSONDecoder().decode([MonitorPreset].self, from: $0) } ?? []
    }

    private static var isAppleSilicon: Bool {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) } == "arm64"
    }

    /// Looks for monitors and asks each what it can do. Run when the pane opens and when the displays change.
    func refresh() {
        guard Self.isAppleSilicon else { status = "Monitor controls need a Mac with Apple silicon."; monitors = []; return }
        guard !busy else { return }
        busy = true
        status = nil
        queue.async { [self] in
            if api == nil { api = API.load() }
            guard let api else { finish(monitors: [], status: "This version of macOS does not offer the calls Kriya needs to reach monitors."); return }
            var found: [Monitor] = []
            var refs: [String: CFTypeRef] = [:]
            for (index, entry) in Self.externalServices().enumerated() {
                defer { IOObjectRelease(entry.service) }
                guard let ref = api.create(kCFAllocatorDefault, entry.service)?.takeRetainedValue() else { continue }
                let id = "\(entry.name)#\(index)"
                refs[id] = ref
                var monitor = Monitor(id: id, name: entry.name)
                monitor.brightness = read(DDC.brightness, ref, api)
                monitor.input = read(DDC.inputSource, ref, api)
                found.append(monitor)
            }
            services = refs
            let answered = found.filter { $0.brightness != nil || $0.input != nil }
            finish(monitors: answered, status: found.isEmpty ? "No external monitor was found." : (answered.isEmpty ? "The monitors found did not answer. Many monitors, and some docks and adapters, do not support DDC." : nil))
        }
    }

    func startWatching() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            // A monitor that has just woken needs a moment before it answers.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self?.refresh() }
        }
    }

    private func finish(monitors list: [Monitor], status text: String?) {
        DispatchQueue.main.async {
            let keep = Dictionary(uniqueKeysWithValues: self.monitors.map { ($0.id, $0.previousInput) })
            self.monitors = list.map { var m = $0; m.previousInput = keep[m.id] ?? nil; return m }
            self.status = text
            self.busy = false
        }
    }

    // MARK: Changes

    func setBrightness(_ id: String, percent: Int) {
        guard let monitor = monitors.first(where: { $0.id == id }), let reading = monitor.brightness else { return }
        let raw = DDC.raw(fromPercent: percent, maximum: reading.maximum)
        send(DDC.brightness, raw, to: id) { ok in
            guard ok else { return }
            self.update(id) { $0.brightness = DDC.Reading(current: Int(raw), maximum: reading.maximum) }
        }
    }

    func setInput(_ id: String, code: Int) {
        guard let monitor = monitors.first(where: { $0.id == id }), (1...0xFF).contains(code) else { return }
        let before = monitor.input?.current
        send(DDC.inputSource, UInt16(code), to: id) { ok in
            guard ok else { return }
            self.update(id) { $0.previousInput = before; $0.input = DDC.Reading(current: code, maximum: $0.input?.maximum ?? 0) }
        }
    }

    func switchBack(_ id: String) {
        if let previous = monitors.first(where: { $0.id == id })?.previousInput { setInput(id, code: previous) }
    }

    private func update(_ id: String, _ change: (inout Monitor) -> Void) {
        if let index = monitors.firstIndex(where: { $0.id == id }) { change(&monitors[index]) }
    }

    private func send(_ vcp: UInt8, _ value: UInt16, to id: String, done: @escaping (Bool) -> Void) {
        queue.async { [self] in
            guard let api, let ref = services[id] else { DispatchQueue.main.async { done(false) }; return }
            let ok = write(DDC.setPacket(vcp, value: value), ref, api)
            DispatchQueue.main.async {
                if !ok { Toast().show("The monitor did not accept that.", isError: true) }
                done(ok)
            }
        }
    }

    // MARK: Presets

    func savePreset(named name: String) {
        let clean = name.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty, presets.count < MonitorPresets.limit, !monitors.isEmpty else { return }
        let settings = monitors.map { MonitorSetting(monitor: $0.name, brightnessPercent: $0.brightnessPercent, inputCode: $0.input?.current) }
        presets.append(MonitorPreset(name: clean, settings: settings))
    }

    func apply(_ preset: MonitorPreset) {
        var before: [MonitorSetting] = []
        var delay = 0.0
        for setting in preset.settings {
            guard let monitor = monitors.first(where: { $0.name == setting.monitor }) else { continue }
            before.append(MonitorSetting(monitor: monitor.name, brightnessPercent: monitor.brightnessPercent, inputCode: monitor.input?.current))
            if let b = setting.brightnessPercent, monitor.brightness != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self.setBrightness(monitor.id, percent: b) }
                delay += 0.2
            }
            if let i = setting.inputCode, monitor.input != nil, i != monitor.input?.current {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self.setInput(monitor.id, code: i) }
                delay += 0.2
            }
        }
        undoSettings = before.isEmpty ? nil : before
        AuditLog.shared.record(.setting, "Monitor preset “\(preset.name)” applied")
    }

    func undoLastPreset() {
        guard let previous = undoSettings else { return }
        apply(MonitorPreset(name: "Previous settings", settings: previous))
        undoSettings = nil
    }

    // MARK: Talking to a monitor

    private func write(_ bytes: [UInt8], _ ref: CFTypeRef, _ api: API) -> Bool {
        for attempt in 0..<3 {
            var data = bytes
            let result = data.withUnsafeMutableBytes { api.write(ref, 0x37, 0x51, $0.baseAddress!, UInt32($0.count)) }
            if result == kIOReturnSuccess { return true }
            usleep(UInt32(20_000 * (attempt + 1)))
        }
        return false
    }

    private func read(_ vcp: UInt8, _ ref: CFTypeRef, _ api: API) -> DDC.Reading? {
        for attempt in 0..<3 {
            guard write(DDC.getRequest(vcp), ref, api) else { return nil }
            usleep(50_000)
            var reply = [UInt8](repeating: 0, count: 12)
            let result = reply.withUnsafeMutableBytes { api.read(ref, 0x37, 0x51, $0.baseAddress!, 11) }
            if result == kIOReturnSuccess, let reading = DDC.parseReply(Array(reply.prefix(11)), vcp: vcp) { return reading }
            usleep(UInt32(30_000 * (attempt + 1)))
        }
        return nil
    }

    /// The external display connections the system lists, with the monitor's name where it can be found.
    private static func externalServices() -> [(service: io_service_t, name: String)] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var out: [(io_service_t, String)] = []
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            let location = IORegistryEntryCreateCFProperty(entry, "Location" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
            if location == "External" {
                out.append((entry, name(of: entry) ?? "Monitor \(out.count + 1)"))
            } else {
                IOObjectRelease(entry)
            }
            entry = IOIteratorNext(iterator)
        }
        return out
    }

    private static func name(of entry: io_service_t) -> String? {
        let options = IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
        guard let attributes = IORegistryEntrySearchCFProperty(entry, kIOServicePlane, "DisplayAttributes" as CFString, kCFAllocatorDefault, options) as? [String: Any],
              let product = attributes["ProductAttributes"] as? [String: Any], let name = product["ProductName"] as? String, !name.isEmpty else { return nil }
        return name
    }
}
