import AppKit
import Combine

/// Runs a focus session: starts it, counts down, and puts everything back at the end or on the next launch after a crash.
final class FocusSessionController: ObservableObject {
    private static let configKey = "focusSession.config.v1"
    private static let stateKey = "focusSession.state.v1"

    @Published var config: FocusSessionConfig { didSet { save() } }
    @Published private(set) var state: FocusSessionState?
    @Published private(set) var remainingText = ""

    private let defaults: UserDefaults
    private let toast = Toast()
    private var timer: Timer?
    private let queue = DispatchQueue(label: "app.kriya.focus", qos: .userInitiated)

    var isActive: Bool { state != nil }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        config = (defaults.data(forKey: Self.configKey).flatMap { try? JSONDecoder().decode(FocusSessionConfig.self, from: $0) }) ?? FocusSessionConfig()
        state = defaults.data(forKey: Self.stateKey).flatMap { try? JSONDecoder().decode(FocusSessionState.self, from: $0) }
    }

    /// A session left over from before Kriya last quit is carried on, or finished if its time has passed.
    func start() {
        guard let state else { return }
        if state.endsAt <= Date() { finish(announce: false) } else { tick(); schedule() }
    }

    func toggle() { isActive ? finish(announce: true) : begin(minutes: nil) }

    func begin(minutes: Int?) {
        guard !isActive else { return }
        var c = config
        if let minutes { c.minutes = minutes }
        let plan = FocusPlan.start(c, dockHidden: Self.dockHidden(), desktopIconsShown: Self.desktopIconsShown(), now: Date())
        state = plan.state
        if let data = try? JSONEncoder().encode(plan.state) { defaults.set(data, forKey: Self.stateKey) }
        run(plan.steps)
        toast.show("Focus for \(c.clamped.minutes) minutes")
        tick(); schedule()
    }

    func finish(announce: Bool) {
        guard let current = state else { return }
        timer?.invalidate(); timer = nil
        state = nil
        remainingText = ""
        defaults.removeObject(forKey: Self.stateKey)
        run(FocusPlan.end(current))
        if announce { toast.show("Focus ended. Everything is back as it was.") }
    }

    private func schedule() {
        timer?.invalidate()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        guard let state else { return }
        if state.endsAt <= Date() { finish(announce: true) } else { remainingText = FocusPlan.remaining(until: state.endsAt, now: Date()) }
    }

    private func save() { if let data = try? JSONEncoder().encode(config) { defaults.set(data, forKey: Self.configKey) } }

    // MARK: Doing it

    private func run(_ steps: [FocusStep]) {
        queue.async {
            var restartDock = false, restartFinder = false
            for step in steps {
                switch step {
                case .setDockHidden(let hidden):
                    Self.defaultsWrite("com.apple.dock", "autohide", hidden); restartDock = true
                case .setDesktopIcons(let shown):
                    Self.defaultsWrite("com.apple.finder", "CreateDesktop", shown); restartFinder = true
                case .quit(let id):
                    DispatchQueue.main.async { NSRunningApplication.runningApplications(withBundleIdentifier: id).forEach { $0.terminate() } }
                case .shortcut(let name):
                    Self.run("/usr/bin/shortcuts", ["run", name])
                }
            }
            if restartDock { Self.run("/usr/bin/killall", ["Dock"]) }
            if restartFinder { Self.run("/usr/bin/killall", ["Finder"]) }
        }
    }

    private static func defaultsWrite(_ domain: String, _ key: String, _ value: Bool) {
        run("/usr/bin/defaults", ["write", domain, key, "-bool", value ? "true" : "false"])
    }

    static func dockHidden() -> Bool { output("/usr/bin/defaults", ["read", "com.apple.dock", "autohide"]).trimmingCharacters(in: .whitespacesAndNewlines) == "1" }

    /// Desktop icons are shown unless the setting says otherwise.
    static func desktopIconsShown() -> Bool { output("/usr/bin/defaults", ["read", "com.apple.finder", "CreateDesktop"]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "0" }

    @discardableResult
    private static func run(_ path: String, _ args: [String]) -> Int32 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return -1 }
        task.waitUntilExit()
        return task.terminationStatus
    }

    private static func output(_ path: String, _ args: [String]) -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
