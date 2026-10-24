import AppKit
import Combine

/// Everything a feature may use when it starts.
struct ServiceContext {
    let config: ConfigStore
    let permissions: PermissionManager
    let events: EventMonitor
    let devices: DeviceRegistry
    let profiles: ProfileStore
    let library: ActionLibrary
    let executor: ActionExecutor
    let mouse: MouseStore
    let activity: DeviceActivityTracker
    let windows: WindowStore
    let windowController: WindowController
    let traffic: TrafficStore
    let finder: FinderService
    let clipboard: ClipboardService
    let selection: SelectionService
    let keyboard: KeyboardService
    let automation: AutomationEngine
}

/// One switchable feature. Later phases supply the real modules; each subscribes to events and registers commands in
/// `start` and removes them in `stop`.
protocol FeatureModule: AnyObject {
    var feature: FeatureId { get }
    func start(context: ServiceContext) throws
    func stop()
    func systemDidWake()
}

extension FeatureModule {
    func systemDidWake() {}
}

/// A background service that is not one of the eight switchable features (the sound mixer, folder rules, MIDI, the MCP server, volume
/// keys…) but must still obey the same rules: not running in safe mode, stopped when a permission it needs is refused, and told when
/// the Mac wakes. It used to be started once at launch and never looked at again.
struct AuxiliaryService {
    let id: String
    let title: String
    /// Permissions whose refusal stops the service. (One not asked for yet does not: the service asks when it first needs it.)
    var blockedWhenDenied: [Permission] = []
    let start: () -> Void
    let stop: () -> Void
    var wake: () -> Void = {}
    /// Whether the service is really doing its job after `start`. Some services decline to start (their own switch is off, or a port is
    /// taken); without this the manager would report them as running. Nil means "started means running".
    var isActive: (() -> Bool)? = nil
}

/// Stands in for a feature that is not built yet, so enabling, permissions and lifecycle can all be exercised now. No shipped feature
/// uses it any more; `FeatureId.isAvailable` is false for anything that would.
final class ScaffoldModule: FeatureModule {
    let feature: FeatureId

    init(_ feature: FeatureId) {
        self.feature = feature
    }

    func start(context: ServiceContext) throws {
        Log.info("Features", "\(feature.title) started (placeholder until \(feature.arrivesIn))")
    }

    func stop() {
        Log.info("Features", "\(feature.title) stopped")
    }
}

enum FeatureState: Equatable {
    case off
    case safeMode
    case needsPermission([Permission])
    case running
    case failed(String)
}

/// Starts and stops features so they match what the person has turned on, what the system permits and whether the app
/// is in safe mode. It re-checks whenever any of those change, and when the Mac wakes from sleep.
final class ServiceManager: ObservableObject {
    @Published private(set) var states: [FeatureId: FeatureState] = [:]
    /// The same, for the background services outside the eight features, by id.
    @Published private(set) var auxiliaryStates: [String: FeatureState] = [:]
    private var auxiliary: [AuxiliaryService] = []
    private var auxiliaryRunning: Set<String> = []

    private let context: ServiceContext
    private let crashGuard: CrashGuard
    private var modules: [FeatureId: FeatureModule] = [:]
    private var running: Set<FeatureId> = []
    private var cancellables = Set<AnyCancellable>()
    private var wakeObserver: NSObjectProtocol?

    init(context: ServiceContext, crashGuard: CrashGuard, modules: [FeatureModule]? = nil) {
        self.context = context
        self.crashGuard = crashGuard
        for module in modules ?? Self.defaultModules() {
            self.modules[module.feature] = module
        }
        for feature in FeatureId.all { states[feature] = .off }
    }

    deinit {
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    }

    /// The real module for each feature that has one. This one list is what `FeatureId.isAvailable` reads, so a feature can never be
    /// shown as available without a module behind it.
    static let moduleFactories: [FeatureId: () -> FeatureModule] = [
        .mouse: { MouseFeature() }, .windowManagement: { WindowFeature() }, .trafficLights: { TrafficLightFeature() },
        .contextMenu: { FinderFeature() }, .clipboard: { ClipboardFeature() }, .selectionBar: { SelectionFeature() },
        .keyboard: { KeyboardFeature() }, .automation: { AutomationFeature() },
    ]

    /// The real feature modules, and a placeholder for any feature that has none.
    private static func defaultModules() -> [FeatureModule] {
        FeatureId.all.map { moduleFactories[$0]?() ?? ScaffoldModule($0) }
    }

    // MARK: Background services outside the eight features

    /// Hands a background service to the manager. It is started on the next `reconcile`, and from then on follows safe mode,
    /// permissions and wake-from-sleep like a feature does.
    /// Every id a background service is registered under. A service registered under any other id is a mistake, and a feature that
    /// names an id missing from here is not counted as implemented (see `FeatureRegistry.runtimeOwners`).
    static let knownAuxiliaryIDs: Set<String> = [
        "clipboardMerge", "folderRules", "menuBarHider", "soundMixer", "soundRules", "midi", "mcpServer", "locationAudio", "volumeKeys",
        "capture", "workspaces", "displayTools", "pointerEffects", "systemMonitor", "safariInbox", "focusSession", "worldClock",
        "sharedClipboard", "keyboardDevices",
    ]

    func register(_ service: AuxiliaryService) {
        assert(Self.knownAuxiliaryIDs.contains(service.id) || service.id.hasPrefix("test."), "\(service.id) is not in knownAuxiliaryIDs")
        auxiliary.removeAll { $0.id == service.id }
        auxiliary.append(service)
        auxiliaryStates[service.id] = .off
    }

    /// What a background service is doing now. A service that can say whether it is really active is asked, so a switch turned on in
    /// its own screen (which starts it directly) shows as running without waiting for the next check.
    func auxiliaryState(_ id: String) -> FeatureState {
        let stored = auxiliaryStates[id] ?? .off
        guard stored == .off || stored == .running, let active = auxiliary.first(where: { $0.id == id })?.isActive else { return stored }
        return active() ? .running : .off
    }

    private func reconcileAuxiliary() {
        for service in auxiliary {
            if crashGuard.isSafeMode {
                stopAuxiliary(service)
                auxiliaryStates[service.id] = .safeMode
                continue
            }
            let denied = service.blockedWhenDenied.filter { context.permissions.status($0) == .denied }
            if !denied.isEmpty {
                stopAuxiliary(service)
                auxiliaryStates[service.id] = .needsPermission(denied)
                continue
            }
            if !auxiliaryRunning.contains(service.id) {
                service.start()
                guard service.isActive?() ?? true else {
                    // It declined to start (its own switch is off). Nothing is running, so nothing is claimed, and the next check tries again.
                    auxiliaryStates[service.id] = .off
                    continue
                }
                auxiliaryRunning.insert(service.id)
                Log.info("Features", "\(service.title) started")
            }
            auxiliaryStates[service.id] = (service.isActive?() ?? true) ? .running : .off
        }
    }

    private func stopAuxiliary(_ service: AuxiliaryService) {
        guard auxiliaryRunning.remove(service.id) != nil else { return }
        service.stop()
        Log.info("Features", "\(service.title) stopped")
    }

    func state(_ feature: FeatureId) -> FeatureState { states[feature] ?? .off }

    // MARK: Lifecycle

    func start() {
        Publishers.CombineLatest3(
            context.config.$settings.map(\.enabledFeatures).removeDuplicates(),
            context.permissions.$statuses.removeDuplicates(),
            crashGuard.$isSafeMode.removeDuplicates()
        )
        .debounce(for: .milliseconds(80), scheduler: DispatchQueue.main)
        .sink { [weak self] _, _, _ in self?.reconcile() }
        .store(in: &cancellables)

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.systemDidWake() }

        reconcile()
    }

    func stopAll() {
        cancellables.removeAll()
        for feature in running { stop(feature) }
        running.removeAll()
        for service in auxiliary { stopAuxiliary(service) }
    }

    /// Turns a feature on or off. Turning one on asks for the first permission it is missing, and only then.
    func setFeature(_ feature: FeatureId, enabled: Bool) {
        context.config.setEnabled(feature, enabled)
        guard enabled, let first = context.permissions.missing(for: feature).first else { return }
        context.permissions.request(first)
    }

    func retry(_ feature: FeatureId) {
        stop(feature)
        reconcile()
    }

    // MARK: Matching reality to settings

    func reconcile() {
        for feature in FeatureId.all {
            let wanted = context.config.isEnabled(feature)
            if crashGuard.isSafeMode {
                stop(feature)
                states[feature] = wanted ? .safeMode : .off
                continue
            }
            guard wanted else {
                stop(feature)
                states[feature] = .off
                continue
            }
            let missing = context.permissions.missing(for: feature)
            guard missing.isEmpty else {
                stop(feature)
                states[feature] = .needsPermission(missing)
                continue
            }
            if running.contains(feature) {
                states[feature] = .running
            } else {
                start(feature)
            }
        }
        reconcileAuxiliary()
    }

    private func start(_ feature: FeatureId) {
        guard let module = modules[feature] else {
            states[feature] = .failed("This feature is not available in this build.")
            return
        }
        crashGuard.markStarting(feature)
        do {
            try module.start(context: context)
            running.insert(feature)
            states[feature] = .running
        } catch {
            states[feature] = .failed(error.localizedDescription)
            Log.error("Features", "\(feature.title) failed to start: \(error.localizedDescription)")
        }
        crashGuard.markStarted()
    }

    private func stop(_ feature: FeatureId) {
        guard running.remove(feature) != nil else { return }
        modules[feature]?.stop()
    }

    private func systemDidWake() {
        Log.info("Features", "Mac woke from sleep")
        context.permissions.refresh()
        context.events.verifyHealth()
        for feature in running { modules[feature]?.systemDidWake() }
        for service in auxiliary where auxiliaryRunning.contains(service.id) { service.wake() }
    }
}
