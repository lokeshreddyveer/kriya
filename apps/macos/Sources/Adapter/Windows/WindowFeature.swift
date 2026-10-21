import AppKit
import Combine

/// Window management: shortcuts, drag-to-edge snapping, modifier drag and resize, the switcher, saved layouts, placement
/// rules and display changes. Shortcuts use the system's hot-key service, so the feature needs only Accessibility;
/// modifier dragging needs Input Monitoring as well and turns itself on once that is allowed.
final class WindowFeature: FeatureModule {
    let feature = FeatureId.windowManagement

    private var context: ServiceContext?
    private var hotkeys: HotkeyCenter?
    private var dragSnapper: DragSnapper?
    private var modifierDrag: ModifierDrag?
    private var switcher: WindowSwitcher?
    private var radial: RadialMenu?
    private var grid: GridMenu?
    private let recency = WindowRecency()
    private var registeredCommands: Set<String> = []
    private var cancellables = Set<AnyCancellable>()
    private var launchObserver: NSObjectProtocol?
    private var activateObserver: NSObjectProtocol?

    func start(context: ServiceContext) throws {
        self.context = context
        guard AXIsProcessTrusted() else {
            throw NSError(domain: "Kriya", code: 2, userInfo: [NSLocalizedDescriptionKey: "Accessibility permission is needed."])
        }
        let controller = context.windowController
        let store = context.windows

        recency.start()
        let switcher = WindowSwitcher(store: store, recency: recency)
        self.switcher = switcher
        radial = RadialMenu(controller: controller, store: store)
        grid = GridMenu(controller: controller, store: store)

        hotkeys = HotkeyCenter { [weak self] command in self?.fire(command) }
        dragSnapper = DragSnapper(store: store, controller: controller)

        controller.displays.onChange = { [weak controller] before, after in controller?.displaysChanged(from: before, to: after) }
        controller.displays.start()
        controller.startSnapshots()

        launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                controller.applyRuleAfterLaunch(of: app)
            }
        }

        activateObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                controller.applyRuleOnActivate(of: app)
            }
        }

        // Keep shortcuts, commands and optional parts in step with the settings and with permissions.
        Publishers.CombineLatest4(
            store.$shortcuts, store.$config, store.$sizes.map { $0.map(\.id) }.removeDuplicates(),
            Publishers.CombineLatest(store.$layouts.map { $0.map(\.id) }.removeDuplicates(), context.permissions.$statuses.removeDuplicates())
        )
        .debounce(for: .milliseconds(80), scheduler: DispatchQueue.main)
        .sink { [weak self] _, _, _, _ in self?.reconfigure() }
        .store(in: &cancellables)
        reconfigure()
        Log.info("Windows", "Window management started")
    }

    func stop() {
        cancellables.removeAll()
        unregisterCommands()
        hotkeys?.unregisterAll()
        hotkeys = nil
        dragSnapper?.stop()
        dragSnapper = nil
        modifierDrag?.stop()
        modifierDrag = nil
        switcher?.close()
        switcher = nil
        radial?.close()
        radial = nil
        grid?.close()
        grid = nil
        context?.windowController.stash.stop()
        recency.stop()
        if let launchObserver { NSWorkspace.shared.notificationCenter.removeObserver(launchObserver) }
        launchObserver = nil
        if let activateObserver { NSWorkspace.shared.notificationCenter.removeObserver(activateObserver) }
        activateObserver = nil
        context?.windowController.stopSnapshots()
        context?.windowController.displays.onChange = nil
        context?.windowController.displays.stop()
        context?.windows.flushPendingSaves()
        context = nil
    }

    func systemDidWake() {
        context?.windowController.displays.refresh()
        reconfigure()
    }

    // MARK: Keeping things in step

    private func reconfigure() {
        guard let context else { return }
        let store = context.windows
        let config = store.config

        registerCommands()
        let failed = hotkeys?.update(store.shortcuts) ?? []
        context.windowController.diagnostics.hotkeyFailures = failed.map { store.title(forCommand: $0) }

        if config.snapOnDrag { dragSnapper?.start() } else { dragSnapper?.stop() }

        let wantsModifierDrag = config.moveModifier != 0 || config.resizeModifier != 0
        if wantsModifierDrag, context.permissions.isGranted(.inputMonitoring) {
            if modifierDrag == nil { modifierDrag = ModifierDrag(events: context.events, store: store) }
            modifierDrag?.start()
        } else {
            modifierDrag?.stop()
        }
    }

    /// Makes every window command usable by name, so a mouse button or a script can run it too.
    private func registerCommands() {
        guard let context else { return }
        unregisterCommands()
        let store = context.windows
        var commands = windowLayouts().map(\.command)
        commands += windowExtraCommands().map(\.command)
        commands += store.sizes.map { store.sizeCommand($0) }
        commands += store.layouts.map { store.layoutCommand($0) }
        for command in commands {
            context.executor.registerCommand(command) { [weak self] in self?.fire(command) }
        }
        registeredCommands = Set(commands)
    }

    private func unregisterCommands() {
        guard let context else { return }
        for command in registeredCommands { context.executor.unregisterCommand(command) }
        registeredCommands.removeAll()
    }

    // MARK: Running a command

    private func fire(_ command: String) {
        guard let context, context.profiles.isFeatureActive(.windowManagement) else { return }
        if command == "window.switcher" {
            switcher?.toggle()
            return
        }
        if command == "window.radial" {
            radial?.toggle()
            return
        }
        if command == "window.grid" {
            grid?.toggle()
            return
        }
        if command == "window.previous" || command == "window.send_behind" {
            switchToPrevious()
            return
        }
        context.windowController.run(command: command)
    }

    /// Brings the window used just before this one to the front, which also leaves this one behind it.
    private func switchToPrevious() {
        guard let context, AXIsProcessTrusted() else { return }
        let focusedKey = AXWindow.focused()?.key
        let others = WindowController.openWindows(excluding: context.windows.currentConfig).filter { $0.window.key != focusedKey }
        let latest = others.max { recency.lastUsed(window: $0.window.key, pid: $0.window.pid) < recency.lastUsed(window: $1.window.key, pid: $1.window.pid) }
        latest?.window.raise()
    }
}
