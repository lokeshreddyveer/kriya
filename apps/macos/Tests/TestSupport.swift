import XCTest
@testable import Kriya

/// A permission source the tests control, so they never touch the real macOS privacy settings.
final class FakeProbe: PermissionProbe {
    var granted: Set<Permission> = []
    private(set) var requested: [Permission] = []

    func status(of permission: Permission) -> PermissionStatus {
        if permission == .automation { return .onDemand }
        return granted.contains(permission) ? .granted : .denied
    }

    func request(_ permission: Permission) {
        requested.append(permission)
    }
}

/// A feature that only counts how often it was started and stopped.
final class FakeModule: FeatureModule {
    let feature: FeatureId
    private(set) var starts = 0
    private(set) var stops = 0
    var failure: Error?

    init(_ feature: FeatureId) { self.feature = feature }

    func start(context: ServiceContext) throws {
        if let failure { throw failure }
        starts += 1
    }

    func stop() { stops += 1 }
}

/// Everything a test needs, built on throwaway folders and a throwaway defaults suite.
struct TestWorld {
    let folder: URL
    let core: KriyaCore
    let config: ConfigStore
    let probe = FakeProbe()
    let permissions: PermissionManager
    let crashGuard: CrashGuard

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("kriya-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        core = try KriyaCore.open(supportDir: folder.path, now: 1_000)
        config = ConfigStore(core: core)
        let suite = UserDefaults(suiteName: "kriya-tests-\(UUID().uuidString)")!
        permissions = PermissionManager(probe: probe, defaults: suite)
        crashGuard = CrashGuard(core: core)
    }

    func makeContext(events: EventMonitor = EventMonitor()) -> ServiceContext {
        let devices = DeviceRegistry(core: core)
        let profiles = ProfileStore(core: core)
        let library = ActionLibrary(core: core)
        let windows = WindowStore(core: core)
        let clipboardService = ClipboardService(store: ClipboardStore(core: core))
        return ServiceContext(
            config: config, permissions: permissions, events: events, devices: devices, profiles: profiles,
            library: library, executor: ActionExecutor(permissions: permissions),
            mouse: MouseStore(core: core, library: library, devices: devices, profiles: profiles),
            activity: DeviceActivityTracker(),
            windows: windows, windowController: WindowController(core: core, store: windows, displays: DisplayManager()),
            traffic: TrafficStore(core: core),
            finder: FinderService(store: FinderStore(core: core, menuFile: folder.appendingPathComponent("finder-menu.json"), defaults: UserDefaults(suiteName: "kriya-tests-\(UUID().uuidString)")!)),
            clipboard: clipboardService,
            selection: SelectionService(store: SelectionStore(core: core), clipboard: clipboardService, approvals: ScriptApprovals(core: core)),
            keyboard: KeyboardService(store: KeyboardStore(core: core), clipboard: clipboardService),
            automation: AutomationEngine(store: WorkflowStore(core: core))
        )
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: folder)
    }
}
