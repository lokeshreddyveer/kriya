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

/// Stands in for a feature that is not built yet, so enabling, permissions and lifecycle can all be exercised now.
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

    /// The real feature modules, and placeholders for the ones that arrive in later phases.
    private static func defaultModules() -> [FeatureModule] {
        FeatureId.all.map { feature -> FeatureModule in
            switch feature {
            case .mouse: return MouseFeature()
            case .windowManagement: return WindowFeature()
            case .trafficLights: return TrafficLightFeature()
            case .contextMenu: return FinderFeature()
            case .clipboard: return ClipboardFeature()
            case .selectionBar: return SelectionFeature()
            case .keyboard: return KeyboardFeature()
            case .automation: return AutomationFeature()
            default: return ScaffoldModule(feature)
            }
        }
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
    }
}
