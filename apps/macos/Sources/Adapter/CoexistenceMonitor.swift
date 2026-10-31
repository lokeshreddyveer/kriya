import AppKit
import Combine

/// Notices other mouse tools being installed or open, and what their events show. It lets Kriya's scrolling step aside for them. It
/// reads the list of apps and the sender of scroll events, nothing else: not another app's settings, permissions or what you do.
final class CoexistenceMonitor: ObservableObject {
    static let shared = CoexistenceMonitor()

    @Published private(set) var statuses: [CompetingToolStatus] = []
    @Published private(set) var plan = CoexistencePlan.Result(ownership: .nothingConfigured, yieldsScrolling: false, observedOverlaps: [], notes: [])

    /// The open tools, for anything that only needs the list.
    var running: [CompetingTool] { statuses.filter(\.running).map(\.tool) }

    private let lock = NSLock()
    private var yielding = false              // guarded by lock, for the event tap's thread
    private var kriyaChangesScrolling = false
    /// Scroll events seen from other processes: when the latest came, by process. Metadata only; guarded by lock.
    private var scrollSenders: [pid_t: Date] = [:]
    private var cancellables = Set<AnyCancellable>()
    private let defaults: UserDefaults

    /// How long a sighting counts as evidence.
    static let evidenceWindow: TimeInterval = 600

    /// Whether Kriya should leave the wheel alone right now. Safe to call from any thread.
    var yieldsScrolling: Bool { lock.lock(); defer { lock.unlock() }; return yielding }

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            center.publisher(for: name).debounce(for: .milliseconds(300), scheduler: DispatchQueue.main).sink { [weak self] _ in self?.refresh() }.store(in: &cancellables)
        }
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main).sink { [weak self] _ in self?.refresh() }.store(in: &cancellables)
        refresh()
    }

    /// Told by the mouse feature whether, with the settings in force, Kriya would change the wheel.
    func setKriyaChangesScrolling(_ value: Bool) {
        lock.lock(); let changed = kriyaChangesScrolling != value; kriyaChangesScrolling = value; lock.unlock()
        if changed { DispatchQueue.main.async { self.refresh() } }
    }

    /// A scroll event that another process posted (a real wheel has no process). Only the process number and the time are kept.
    func noteScroll(fromProcess pid: pid_t) {
        guard pid > 0, pid != ProcessInfo.processInfo.processIdentifier else { return }
        let now = Date()
        lock.lock()
        let isNew = scrollSenders[pid] == nil
        // Updated at most once a second, so a busy scroll is not a busy lock.
        if isNew || now.timeIntervalSince(scrollSenders[pid] ?? .distantPast) > 1 { scrollSenders[pid] = now }
        lock.unlock()
        if isNew { DispatchQueue.main.async { self.refresh() } }
    }

    func refresh() {
        let apps = NSWorkspace.shared.runningApplications
        let found = CompetingTools.detect(running: apps.map { (bundleID: $0.bundleIdentifier, name: $0.localizedName) })
        let installed = Set(CompetingTools.known.filter { tool in
            tool.bundleIDs.contains { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
        }.map(\.name))

        // Which of the open tools has been seen sending scroll events lately.
        let cutoff = Date().addingTimeInterval(-Self.evidenceWindow)
        lock.lock()
        scrollSenders = scrollSenders.filter { $0.value > cutoff }
        let senders = Set(scrollSenders.keys)
        let changes = kriyaChangesScrolling
        lock.unlock()
        var evidence: [String: Set<MouseArea>] = [:]
        for tool in found {
            let pids = apps.filter { app in
                (app.bundleIdentifier.map(tool.bundleIDs.contains) ?? false) || (app.localizedName.map(tool.processNames.contains) ?? false)
            }.map(\.processIdentifier)
            if pids.contains(where: senders.contains) { evidence[tool.name, default: []].insert(.scrolling) }
        }

        let kriyaAreas: Set<MouseArea> = changes ? [.scrolling] : []
        let list = CoexistencePlan.statuses(installed: installed, running: found, kriyaAreas: kriyaAreas, evidence: evidence)
        let result = CoexistencePlan.evaluate(statuses: list, settings: CoexistenceStore(defaults: defaults).settings, kriyaChangesScrolling: changes)
        lock.lock(); yielding = result.yieldsScrolling; lock.unlock()
        if list != statuses { statuses = list }
        if result != plan { plan = result }
    }
}
