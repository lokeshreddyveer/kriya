import Combine
import SwiftUI

/// Builds every service once, in dependency order, and hands them to the interface. The interface gets each service as its
/// own environment object so a view updates when the one thing it shows changes.
final class AppEnvironment {
    let paths: AppPaths
    let core: KriyaCore
    let config: ConfigStore
    let crashGuard: CrashGuard
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
    let pointerMenuStore: PointerMenuStore
    let pointerMenu: PointerMenu
    let linkStore: LinkRoutingStore
    let workspaceStore: WorkspaceStore
    let workspaces: WorkspaceController
    let pointerStore: PointerEffectsStore
    let dragStore: DragToolsStore
    let pasteStack: PasteStack
    let speaker: Speaker
    let screenStore: ScreenToolsStore
    let hotCorners: HotCorners
    let displayTools: DisplayTools
    let fileShelf: FileShelf
    let inventory: AppInventory
    let runIdentifier: (String) -> Void
    let quickCommands: QuickCommands
    let popoverPrefs: PopoverPrefs
    private var screenCancellable: AnyCancellable?
    let keepAwake: KeepAwake
    let remapStore: RemapStore
    let remap: RemapService
    let keyboardDevices: KeyboardDevices
    private var remapCancellable: AnyCancellable?
    private var keyboardCancellable: AnyCancellable?
    let dragTools: DragTools
    private var dragCancellable: AnyCancellable?
    private var pointerMenuCancellable: AnyCancellable?
    let pointerEffects: PointerEffects
    let links: LinkRouter
    let clipboard: ClipboardService
    let approvals: ScriptApprovals
    let selection: SelectionService
    let keyboard: KeyboardService
    let automation: AutomationEngine
    let services: ServiceManager
    let backup: BackupManager
    let updates: UpdateManager
    let navigator = SettingsNavigator()

    init(paths: AppPaths, core: KriyaCore) {
        // Built as local values first so each service can use the ones before it.
        let config = ConfigStore(core: core)
        Log.shared.configure(fileURL: paths.logFile, level: config.settings.logLevel)
        let crashGuard = CrashGuard(core: core)
        let permissions = PermissionManager()
        let events = EventMonitor()
        let devices = DeviceRegistry(core: core)
        let profiles = ProfileStore(core: core)
        let library = ActionLibrary(core: core)
        let executor = ActionExecutor(permissions: permissions)
        let mouse = MouseStore(core: core, library: library, devices: devices, profiles: profiles)
        let activity = DeviceActivityTracker()
        let windows = WindowStore(core: core)
        let windowController = WindowController(core: core, store: windows, displays: DisplayManager())
        let traffic = TrafficStore(core: core)
        let finder = FinderService(store: FinderStore(core: core, menuFile: paths.support.appendingPathComponent("finder-menu.json")))
        let clipboard = ClipboardService(store: ClipboardStore(core: core))
        let approvals = ScriptApprovals(core: core)
        let selection = SelectionService(store: SelectionStore(core: core), clipboard: clipboard, approvals: approvals)
        let keyboard = KeyboardService(store: KeyboardStore(core: core), clipboard: clipboard)
        let automation = AutomationEngine(store: WorkflowStore(core: core))
        let pointerMenuStore = PointerMenuStore(core: core)
        let pointerMenu = PointerMenu(store: pointerMenuStore, library: library, executor: executor)
        let linkStore = LinkRoutingStore(core: core, logFile: paths.support.appendingPathComponent("link-log.json"))
        let links = LinkRouter(store: linkStore)
        let workspaceStore = WorkspaceStore(core: core)
        let pointerStore = PointerEffectsStore(core: core)
        let pointerEffects = PointerEffects(store: pointerStore, displays: windowController.displays, executor: executor)
        let dragStore = DragToolsStore(core: core)
        let pasteStack = PasteStack(events: events)
        let speaker = Speaker()
        let screenStore = ScreenToolsStore(core: core)
        // Runs a saved action by its id, or a built-in command by its name.
        let runIdentifier: (String) -> Void = { [weak library, weak executor] id in
            guard let executor else { return }
            if let saved = library?.actions.first(where: { $0.id == id }) {
                Task { _ = await executor.perform(saved.action) }
            } else {
                Task { _ = await executor.perform(.builtin(command: id)) }
            }
        }
        let hotCorners = HotCorners(store: screenStore, run: runIdentifier)
        let displayTools = DisplayTools(store: screenStore)
        let fileShelf = FileShelf(store: screenStore)
        let inventory = AppInventory()
        let keepAwake = KeepAwake()
        let remapStore = RemapStore(core: core)
        let keyboardDevices = KeyboardDevices()
        let remap = RemapService(events: events, store: remapStore, keyboards: keyboardDevices) { [weak library, weak executor] id in
            guard let executor, let saved = library?.actions.first(where: { $0.id == id }) else { return }
            Task { _ = await executor.perform(saved.action) }
        }
        let dragTools = DragTools(events: events, store: dragStore, windowStore: windows, run: runIdentifier)
        let workspaces = WorkspaceController(
            store: workspaceStore, windowController: windowController, windows: windows, executor: executor,
            isEnabled: { [weak config] in config?.isEnabled(.windowManagement) == true }
        )
        let context = ServiceContext(
            config: config, permissions: permissions, events: events, devices: devices,
            profiles: profiles, library: library, executor: executor, mouse: mouse, activity: activity,
            windows: windows, windowController: windowController, traffic: traffic, finder: finder, clipboard: clipboard, selection: selection, keyboard: keyboard, automation: automation
        )
        let services = ServiceManager(context: context, crashGuard: crashGuard)
        let backup = BackupManager(core: core, folder: paths.backups)
        let updates = UpdateManager(config: config)
        // Shortcuts may not take keys that other parts of Kriya already use.
        keyboard.store.reservedProvider = { [windows, clipboard, selection, finder, keyboard] in
            var keys: [ReservedKey] = []
            for s in windows.shortcuts { keys.append(ReservedKey(keyCode: s.keyCode, modifiers: s.modifiers, owner: "Windows: \(windows.title(forCommand: s.command))")) }
            let c = clipboard.store.config
            if let k = c.quickKey { keys.append(ReservedKey(keyCode: k, modifiers: c.quickModifiers, owner: "Clipboard: open history")) }
            if let k = c.plainKey { keys.append(ReservedKey(keyCode: k, modifiers: c.plainModifiers, owner: "Clipboard: paste as plain text")) }
            if let k = c.stripKey { keys.append(ReservedKey(keyCode: k, modifiers: c.stripModifiers, owner: "Clipboard: remove formatting")) }
            if let k = selection.store.config.manualKey { keys.append(ReservedKey(keyCode: k, modifiers: selection.store.config.manualModifiers, owner: "Selection bar")) }
            if let k = finder.store.config.launcherKeyCode { keys.append(ReservedKey(keyCode: k, modifiers: finder.store.config.launcherModifiers, owner: "Finder action launcher")) }
            if let k = keyboard.store.config.paletteKey { keys.append(ReservedKey(keyCode: k, modifiers: keyboard.store.config.paletteModifiers, owner: "Command launcher")) }
            return keys
        }
        backup.onRestored = {
            config.reload()
            profiles.reload()
            library.reload()
            devices.reload()
            mouse.reload()
            windows.reload()
            traffic.reload()
            finder.store.reload()
            clipboard.store.reload()
            selection.store.reload()
            approvals.reload()
            keyboard.store.reload()
            automation.store.reload()
        }

        self.paths = paths
        self.core = core
        self.config = config
        self.crashGuard = crashGuard
        self.permissions = permissions
        self.events = events
        self.devices = devices
        self.profiles = profiles
        self.library = library
        self.executor = executor
        self.mouse = mouse
        self.activity = activity
        self.windows = windows
        self.windowController = windowController
        self.traffic = traffic
        self.finder = finder
        self.pointerMenuStore = pointerMenuStore
        self.pointerMenu = pointerMenu
        self.linkStore = linkStore
        self.links = links
        self.workspaceStore = workspaceStore
        self.workspaces = workspaces
        self.pointerStore = pointerStore
        self.pointerEffects = pointerEffects
        self.dragStore = dragStore
        self.pasteStack = pasteStack
        self.speaker = speaker
        self.screenStore = screenStore
        self.hotCorners = hotCorners
        self.displayTools = displayTools
        self.fileShelf = fileShelf
        self.inventory = inventory
        self.runIdentifier = runIdentifier
        self.quickCommands = QuickCommands(run: runIdentifier)
        self.popoverPrefs = PopoverPrefs()
        self.keepAwake = keepAwake
        self.remapStore = remapStore
        self.remap = remap
        self.keyboardDevices = keyboardDevices
        self.dragTools = dragTools
        self.clipboard = clipboard
        self.approvals = approvals
        self.selection = selection
        self.keyboard = keyboard
        self.automation = automation
        self.services = services
        self.backup = backup
        self.updates = updates

        // Workflows can be reached from everywhere that runs commands, text, or files.
        automation.setFeature = { feature, enabled in services.setFeature(feature, enabled: enabled) }
        selection.runner.runWorkflow = { [weak automation] id, text in automation?.fire(id, source: "Selection bar", input: text) }
        finder.runner.runWorkflow = { [weak automation] id, text in automation?.fire(id, source: "Finder menu", input: text) }
        pointerMenu.runWorkflow = { [weak automation] id in automation?.fire(id, source: "Pointer menu") }
        WindowCommands.dynamic = { [weak workspaceStore, weak pointerStore] in
            let spaces = (workspaceStore?.config.workspaces ?? []).map { (command: workspaceCommand(id: $0.id), title: "Workspace: \($0.name)") }
            let spots = (pointerStore?.config.positions ?? []).map { (command: pointerPositionCommand(id: $0.id), title: "Pointer: \($0.name)") }
            let places: [(String, String)] = [
                ("left_half", "Left half"), ("right_half", "Right half"), ("top_half", "Top half"), ("bottom_half", "Bottom half"),
                ("maximize", "Maximize"), ("center", "Center"), ("top_left", "Top left"), ("top_right", "Top right"),
                ("bottom_left", "Bottom left"), ("bottom_right", "Bottom right"),
            ]
            let underPointer = places.map { (command: "window.pointer.\($0.0)", title: "Window under the pointer: \($0.1)") }
            let screens = [("window.screen_left", "Move to the display on the left"), ("window.screen_right", "Move to the display on the right"),
                           ("window.screen_up", "Move to the display above"), ("window.screen_down", "Move to the display below")]
                .map { (command: $0.0, title: $0.1) }
            return spaces + spots + underPointer + screens
        }
        workspaces.start()
        displayTools.start()
        executor.registerCommand("clipboard.stack") { [weak pasteStack] in DispatchQueue.main.async { pasteStack?.toggle() } }
        executor.registerCommand("text.speak") { [weak speaker] in DispatchQueue.main.async { speaker?.toggle() } }
        executor.registerCommand("text.stop_speaking") { [weak speaker] in DispatchQueue.main.async { speaker?.stop() } }
        executor.registerCommand("display.next_profile") { [weak displayTools] in DispatchQueue.main.async { displayTools?.applyNextProfile() } }
        executor.registerCommand("display.dim_more") { [weak displayTools] in DispatchQueue.main.async { displayTools?.dim(by: 0.1) } }
        executor.registerCommand("display.dim_less") { [weak displayTools] in DispatchQueue.main.async { displayTools?.dim(by: -0.1) } }
        executor.registerCommand("shelf.toggle") { [weak fileShelf] in DispatchQueue.main.async { fileShelf?.toggle() } }
        screenCancellable = screenStore.$config.receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.hotCorners.apply()
            self?.fileShelf.apply()
        }
        executor.registerCommand("power.keep_awake") { [weak keepAwake] in DispatchQueue.main.async { keepAwake?.toggle() } }
        executor.registerCommand("power.keep_awake_off") { [weak keepAwake] in DispatchQueue.main.async { keepAwake?.stop() } }
        for minutes in [15, 30, 60, 120, 240] {
            executor.registerCommand("power.keep_awake.\(minutes)") { [weak keepAwake] in DispatchQueue.main.async { keepAwake?.start(minutes: minutes) } }
        }
        executor.registerCommand("link.route_clipboard") { [weak links] in
            DispatchQueue.main.async { links?.chooseBrowserForClipboardLink() }
        }
        pointerEffects.start()
        pointerMenuCancellable = pointerMenuStore.$config.receive(on: DispatchQueue.main).sink { [weak self] config in
            guard let self else { return }
            self.pointerMenu.setOptionRightClick(config.optionRightClick && self.permissions.isGranted(.inputMonitoring), events: self.events)
        }
        keyboardDevices.start()
        keyboardCancellable = keyboardDevices.$names.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            guard let self else { return }
            self.remap.apply(allowed: self.permissions.isGranted(.inputMonitoring))
        }
        remapCancellable = remapStore.$config.receive(on: DispatchQueue.main).sink { [weak self] _ in
            guard let self else { return }
            self.remap.apply(allowed: self.permissions.isGranted(.inputMonitoring))
        }
        dragCancellable = dragStore.$config.receive(on: DispatchQueue.main).sink { [weak self] config in
            guard let self else { return }
            if (config.scrollEnabled || config.followModifier != 0 || !config.doubleClicks.isEmpty || !config.buttonScrolls.isEmpty), self.permissions.isGranted(.inputMonitoring) {
                self.dragTools.start()
            } else {
                self.dragTools.stop()
            }
        }
        // The pointer menu opens from any shortcut, button or gesture that runs these commands.
        for (command, appOnly) in [("menu.pointer", false), ("menu.app", true)] {
            executor.registerCommand(command) { [weak pointerMenu, weak config] in
                guard config?.isEnabled(.contextMenu) == true else { return }
                DispatchQueue.main.async { pointerMenu?.show(appMenuOnly: appOnly) }
            }
        }
        KeyboardCommands.extra = { [weak automation] in
            (automation?.store.workflows ?? []).filter(\.enabled).map { (command: workflowCommand(workflow: $0), title: "Workflow: \($0.name)") }
        }
        keyboard.palette.addProvider { [weak automation] in
            (automation?.store.workflows ?? []).filter(\.enabled).map { workflow in
                PaletteEntry(id: "workflow:\(workflow.id)", title: "Run: \(workflow.name)", subtitle: "Workflow", symbol: "gearshape.2") { automation?.fire(workflow.id, source: "Command launcher") }
            }
        }
    }
}

extension View {
    func injecting(_ env: AppEnvironment) -> some View {
        self
            .environmentObject(env.config)
            .environmentObject(env.crashGuard)
            .environmentObject(env.permissions)
            .environmentObject(env.events)
            .environmentObject(env.devices)
            .environmentObject(env.profiles)
            .environmentObject(env.library)
            .environmentObject(env.mouse)
            .environmentObject(env.windows)
            .environmentObject(env.traffic)
            .environmentObject(env.finder)
            .environmentObject(env.finder.store)
            .environmentObject(env.pointerMenuStore)
            .environmentObject(env.linkStore)
            .environmentObject(env.workspaceStore)
            .environmentObject(env.pointerStore)
            .environmentObject(env.dragStore)
            .environmentObject(env.screenStore)
            .environmentObject(env.displayTools)
            .environmentObject(env.fileShelf)
            .environmentObject(env.inventory)
            .environmentObject(env.keepAwake)
            .environmentObject(env.remapStore)
            .environmentObject(env.keyboardDevices)
            .environmentObject(env.quickCommands)
            .environmentObject(env.popoverPrefs)
            .environmentObject(env.pasteStack)
            .environmentObject(env.clipboard)
            .environmentObject(env.clipboard.store)
            .environmentObject(env.approvals)
            .environmentObject(env.selection)
            .environmentObject(env.selection.store)
            .environmentObject(env.keyboard)
            .environmentObject(env.keyboard.store)
            .environmentObject(env.automation)
            .environmentObject(env.automation.store)
            .environmentObject(env.windowController)
            .environmentObject(env.windowController.displays)
            .environmentObject(env.services)
            .environmentObject(env.backup)
            .environmentObject(env.updates)
            .environmentObject(env.navigator)
            .environment(\.executor, env.executor)
            .environment(\.paths, env.paths)
            .tint(Theme.accent)
            .scrollIndicators(.hidden)
    }
}

private struct ExecutorKey: EnvironmentKey { static let defaultValue: ActionExecutor? = nil }
private struct PathsKey: EnvironmentKey { static let defaultValue = AppPaths.live }

extension EnvironmentValues {
    var executor: ActionExecutor? {
        get { self[ExecutorKey.self] }
        set { self[ExecutorKey.self] = newValue }
    }

    var paths: AppPaths {
        get { self[PathsKey.self] }
        set { self[PathsKey.self] = newValue }
    }
}
