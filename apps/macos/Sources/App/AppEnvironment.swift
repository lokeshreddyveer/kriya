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
    let launcherTools: LauncherToolSources
    let folderRules: FolderRulesService
    let remote: RemoteCommands
    let audio: AudioControl
    let clipboardMerger: ClipboardMerger
    private(set) var launcherHotkeys: LauncherHotkeys?
    let menuBarHider: MenuBarHider
    let systemMonitor = SystemMonitor()
    let notes = NotesController()
    let clipboardRules = ClipboardRuleStore()
    let appAudio = AppAudioEngine()
    lazy var quickConfigs = QuickConfigStore(engine: appAudio)
    lazy var windowList = WindowListController(recency: .shared)
    private var windowTriggers: WindowTriggers?
    private var quickConfigSub: AnyCancellable?
    private var quickConfigCommands = Set<String>()
    private var deviceCommandSubs: [AnyCancellable] = []
    private var deviceCommands = Set<String>()
    private var favoriteAppSub: AnyCancellable?
    private var favoriteAppCommands = Set<String>()
    let soundMixer = SoundMixerModel()
    let soundRules = SoundRuleRunner()
    private var pageCapture: PageCaptureService?
    private var soundModeSub: AnyCancellable?
    private var dialogJumpObserver: NSObjectProtocol?
    private var soundModeCommands: Set<String> = []
    let focusSession = FocusSessionController()
    let worldClock = WorldClockModel()
    let sharedClipboard = SharedClipboardService()
    let dictation = DictationService()
    let dialogFolders: DialogFolderHelper
    private(set) var volumeKeys: VolumeKeys?
    let dragStore: DragToolsStore
    let pasteStack: PasteStack
    let speaker: Speaker
    let screenStore: ScreenToolsStore
    let hotCorners: HotCorners
    let displayTools: DisplayTools
    let fileShelf: FileShelf
    let inventory: AppInventory
    let homebrew: HomebrewManager
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
    let navigateDrag: NavigateDragController
    let buttonChords: ButtonChordController
    let buttonReplacement: PrimaryButtonReplacementController
    let trackpadGestures = TrackpadGestureService(emitter: SystemTrackpadEmitter(), recognizer: GestureRecognizer(mapping: [:]))
    private var dragCancellable: AnyCancellable?
    private var pauseCancellable: AnyCancellable?
    private var dragFeatureCancellable: AnyCancellable?
    private var pointerMenuCancellable: AnyCancellable?
    let pointerEffects: PointerEffects
    let links: LinkRouter
    let bridge: BrowserBridge
    let safariInbox: SafariInboxWatcher
    let clipboardStore: ClipboardStore
    let capture: ScreenCaptureService
    let intelligence: IntelligenceCoordinator
    let timeline = PerformanceTimeline()
    private let captureEditor = CaptureEditorController()
    private(set) var launcherSources: LauncherSources?
    /// Reads requests typed in plain words and hands them to the features that already exist (see IntentLauncher).
    var intentLauncher: IntentLauncher?
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
        let clipStore = ClipboardStore(core: core)
        let clipboard = ClipboardService(store: clipStore)
        ClipboardSyncService.shared.attach(clipStore)
        let approvals = ScriptApprovals(core: core)
        let selection = SelectionService(store: SelectionStore(core: core), clipboard: clipboard, approvals: approvals)
        let keyboard = KeyboardService(store: KeyboardStore(core: core), clipboard: clipboard)
        let automation = AutomationEngine(store: WorkflowStore(core: core))
        let pointerMenuStore = PointerMenuStore(core: core)
        let pointerMenu = PointerMenu(store: pointerMenuStore, library: library, executor: executor)
        let linkStore = LinkRoutingStore(core: core, logFile: paths.support.appendingPathComponent("link-log.json"))
        let links = LinkRouter(store: linkStore)
        let bridge = BrowserBridge(support: paths.support)
        let safariInbox = SafariInboxWatcher(support: paths.support)
        let capture = ScreenCaptureService(settings: CaptureSettingsStore())
        // A link found in text read from a picture goes through the person's link rules when they choose to route it.
        capture.routeLink = { [links] url in links.open(url, sourceAppID: nil) }
        let intelligence = IntelligenceCoordinator(service: AppleIntelligence(model: GatewayTextModel(gateway: .shared)))
        let workspaceStore = WorkspaceStore(core: core)
        let pointerStore = PointerEffectsStore(core: core)
        let launcherTools = LauncherToolSources(extras: LauncherExtras(), prefs: keyboard.palette.prefs)
        let remote = RemoteCommands(support: paths.support)
        let clipboardMerger = ClipboardMerger(events: events, monitor: clipboard.monitor)
        let menuBarHider = MenuBarHider()
        let folderRules = FolderRulesService(store: FolderRulesStore(), history: finder.runner.history)
        let pointerEffects = PointerEffects(store: pointerStore, displays: windowController.displays, executor: executor)
        let dragStore = DragToolsStore(core: core)
        let pasteStack = PasteStack(events: events)
        let audio = AudioControl()
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
        let homebrew = HomebrewManager()
        let keepAwake = KeepAwake()
        let remapStore = RemapStore(core: core)
        let keyboardDevices = KeyboardDevices()
        let remap = RemapService(events: events, store: remapStore, keyboards: keyboardDevices) { [weak library, weak executor] id in
            guard let executor, let saved = library?.actions.first(where: { $0.id == id }) else { return }
            Task { _ = await executor.perform(saved.action) }
        }
        // The drag tools belong to Mouse & Trackpad: they do nothing while it is off for the app in front (off, or an app left alone), and
        // they give way to a gesture or hold rule on the same button.
        let dragTools = DragTools(
            events: events, store: dragStore, windowStore: windows, run: runIdentifier,
            isActive: { [weak profiles, weak mouse] in profiles?.isFeatureActive(.mouse) == true && mouse?.compiled(forDevice: nil) != nil },
            mouseClaims: { [weak mouse, weak activity] button, modifiers in
                mouse?.claims(button: button, modifiers: modifiers, device: activity?.currentDeviceID()) ?? ButtonClaims()
            })
        let navigateDrag = NavigateDragController(events: events, mouseClaims: { [weak mouse, weak activity] button, modifiers in
            mouse?.claims(button: button, modifiers: modifiers, device: activity?.currentDeviceID()) ?? ButtonClaims()
        })
        let buttonChords = ButtonChordController(events: events, run: { [weak library, weak executor] id in
            guard let executor, let saved = library?.actions.first(where: { $0.id == id }) else { return }
            Task { _ = await executor.perform(saved.action) }
        }, mouseClaims: { [weak mouse, weak activity] button, modifiers in
            mouse?.claims(button: button, modifiers: modifiers, device: activity?.currentDeviceID()) ?? ButtonClaims()
        })
        let buttonReplacement = PrimaryButtonReplacementController(events: events, run: { [weak library, weak executor] id in
            guard let executor, let saved = library?.actions.first(where: { $0.id == id }) else { return }
            Task { _ = await executor.perform(saved.action) }
        })
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
        keyboard.store.reservedProvider = { [windows, clipboard, selection, finder, keyboard, pointerStore] in
            var keys: [ReservedKey] = []
            for s in windows.shortcuts { keys.append(ReservedKey(keyCode: s.keyCode, modifiers: s.modifiers, owner: "Windows: \(windows.title(forCommand: s.command))")) }
            let c = clipboard.store.config
            if let k = c.quickKey { keys.append(ReservedKey(keyCode: k, modifiers: c.quickModifiers, owner: "Clipboard: open history")) }
            if let k = c.plainKey { keys.append(ReservedKey(keyCode: k, modifiers: c.plainModifiers, owner: "Clipboard: paste as plain text")) }
            if let k = c.stripKey { keys.append(ReservedKey(keyCode: k, modifiers: c.stripModifiers, owner: "Clipboard: remove formatting")) }
            if let k = selection.store.config.manualKey { keys.append(ReservedKey(keyCode: k, modifiers: selection.store.config.manualModifiers, owner: "Selection bar")) }
            if let k = finder.store.config.launcherKeyCode { keys.append(ReservedKey(keyCode: k, modifiers: finder.store.config.launcherModifiers, owner: "Finder action launcher")) }
            let p = pointerStore.current
            if let k = p.spotlightKey { keys.append(ReservedKey(keyCode: k, modifiers: p.spotlightModifiers, owner: "Pointer: spotlight")) }
            if let k = p.presentationKey { keys.append(ReservedKey(keyCode: k, modifiers: p.presentationModifiers, owner: "Pointer: presentation mode")) }
            if let k = keyboard.store.config.paletteKey { keys.append(ReservedKey(keyCode: k, modifiers: keyboard.store.config.paletteModifiers, owner: "Command launcher")) }
            return keys
        }
        let popoverPrefs = PopoverPrefs()
        SettingsReloader.register(.windowLocks) { WindowLockStore.shared.reload() }
        SettingsReloader.register(.popover) { popoverPrefs.reload() }
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
            // The rest of the stores that can reload, so a restore changes open screens and running services now, not after a relaunch.
            pointerMenuStore.reload()
            linkStore.reload()
            workspaceStore.reload()
            pointerStore.reload()
            dragStore.reload()
            screenStore.reload()
            remapStore.reload()
            popoverPrefs.reload()
            WindowLockStore.shared.reload()
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
        self.dialogFolders = DialogFolderHelper(destinations: finder.destinations)
        self.pointerMenuStore = pointerMenuStore
        self.pointerMenu = pointerMenu
        self.linkStore = linkStore
        self.links = links
        self.bridge = bridge
        self.safariInbox = safariInbox
        self.clipboardStore = clipStore
        self.capture = capture
        self.intelligence = intelligence
        self.workspaceStore = workspaceStore
        self.workspaces = workspaces
        self.pointerStore = pointerStore
        self.launcherTools = launcherTools
        self.folderRules = folderRules
        self.remote = remote
        self.audio = audio
        self.clipboardMerger = clipboardMerger
        self.menuBarHider = menuBarHider
        self.pointerEffects = pointerEffects
        self.dragStore = dragStore
        self.pasteStack = pasteStack
        self.speaker = speaker
        self.screenStore = screenStore
        self.hotCorners = hotCorners
        self.displayTools = displayTools
        self.fileShelf = fileShelf
        self.inventory = inventory
        self.homebrew = homebrew
        self.runIdentifier = runIdentifier
        self.quickCommands = QuickCommands(run: runIdentifier)
        self.popoverPrefs = popoverPrefs
        self.keepAwake = keepAwake
        self.remapStore = remapStore
        self.remap = remap
        self.keyboardDevices = keyboardDevices
        self.dragTools = dragTools
        self.navigateDrag = navigateDrag
        self.buttonChords = buttonChords
        self.buttonReplacement = buttonReplacement
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
        let pages = PageCaptureService(support: paths.support, shelf: fileShelf)
        pageCapture = pages
        bridge.savePage = { [weak pages] file, action in DispatchQueue.main.async { pages?.handle(file: file, action: action) } }
        bridge.openLink = { [weak links] url in DispatchQueue.main.async { links?.open(url, sourceAppID: nil) } }
        safariInbox.openLink = { [weak links] url in DispatchQueue.main.async { links?.open(url, sourceAppID: nil) } }
        safariInbox.savePage = { [weak pages] clip, action in DispatchQueue.main.async { pages?.perform(action, on: clip) } }
        bridge.showSelection = { [weak selection] text in DispatchQueue.main.async { selection?.showText(text) } }
        safariInbox.showSelection = { [weak selection] text in DispatchQueue.main.async { selection?.showText(text) } }
        selection.runner.runWorkflow = { [weak automation] id, text in automation?.fire(id, source: "Selection bar", input: text) }
        selection.runner.sendToShelf = { [weak fileShelf] text in fileShelf?.add(text: text) }
        fileShelf.workflows = { [weak automation] in (automation?.store.workflows ?? []).filter(\.enabled).map { (id: $0.id, name: $0.name) } }
        fileShelf.runWorkflow = { [weak automation] id, text in automation?.fire(id, source: "File shelf", input: text) }
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
            let captures = CaptureSettings.commands.map { (command: $0.command, title: $0.title) }
            return spaces + spots + underPointer + screens + captures
        }
        for entry in CaptureSettings.commands {
            // By name, so the commands that are not a plain capture (history, pins, cards, the camera) do what their name says.
            executor.registerCommand(entry.command) { [weak capture] in capture?.run(command: entry.command) }
        }
        // Each saved area is a command of its own, kept in step with the list.
        let areaCommands = AreaCommandRegistry(executor: executor)
        let syncAreas = { [weak capture] in areaCommands.sync { _ = capture?.run(command: $0) } }
        capture.onSavedAreasChanged = syncAreas
        syncAreas()
        capture.showEditor = { [captureEditor, weak capture] image, done in
            guard let capture else { done(image); return }
            captureEditor.show(image, service: capture, startingStyle: capture.editorStartStyle, completion: done)
        }
        capture.sendToShelf = { [weak fileShelf] url in fileShelf?.add(file: url) }
        // Owned by the service manager like the other background services: stopped in safe mode, started again when it ends.
        // (Screen Recording is asked for when a capture is taken, so a refusal does not stop the shortcuts that explain it.)
        services.register(AuxiliaryService(id: "capture", title: "Screen capture shortcuts", start: { [weak capture] in capture?.start() }, stop: { [weak capture] in capture?.stop() }))
        timeline.start(events: events)
        keyboard.palette.addProvider { [weak capture] in
            CaptureSettings.commands.map { entry in
                PaletteEntry(id: entry.command, title: entry.title, subtitle: "Screen capture", symbol: entry.mode.symbol, category: .command) { capture?.run(command: entry.command) }
            }
        }
        services.register(AuxiliaryService(id: "workspaces", title: "Workspaces", start: { [weak workspaces] in workspaces?.start() }, stop: { [weak workspaces] in workspaces?.stop() }))
        SpaceChangeLayouts.shared.controller = windowController
        SpaceChangeLayouts.shared.update()
        services.register(AuxiliaryService(id: "displayTools", title: "Displays & corners", start: { [weak displayTools] in displayTools?.start() }, stop: { [weak displayTools] in displayTools?.stop() }))
        executor.registerCommand("clipboard.stack") { [weak pasteStack] in DispatchQueue.main.async { pasteStack?.toggle() } }
        executor.registerCommand("color.pick") { DispatchQueue.main.async { ScreenColorPicker.pick() } }
        executor.registerCommand("focus.session") { [weak self] in DispatchQueue.main.async { self?.focusSession.toggle() } }
        executor.registerCommand("clipboard.paste_as_file") { DispatchQueue.main.async { PasteIntoFolderService.run() } }
        executor.registerCommand("clipboard.send_other") { [weak self] in DispatchQueue.main.async { self?.sharedClipboard.send() } }
        executor.registerCommand("clipboard.receive_other") { [weak self] in DispatchQueue.main.async { self?.sharedClipboard.receive() } }
        executor.registerCommand("dictation.toggle") { [weak self] in DispatchQueue.main.async { self?.dictation.toggle() } }
        executor.registerCommand("dialog.folders") { [weak self] in DispatchQueue.main.async { self?.dialogFolders.toggle() } }
        executor.registerCommand("notes.open") { [weak self] in DispatchQueue.main.async { self?.notes.toggle() } }
        for entry in AudioControl.commands {
            executor.registerCommand(entry.command) { [weak audio] in DispatchQueue.main.async { audio?.run(entry.command) } }
        }
        executor.registerCommand("text.speak") { [weak speaker] in DispatchQueue.main.async { speaker?.toggle() } }
        executor.registerCommand("text.stop_speaking") { [weak speaker] in DispatchQueue.main.async { speaker?.stop() } }
        executor.registerCommand("display.next_profile") { [weak displayTools] in DispatchQueue.main.async { displayTools?.applyNextProfile() } }
        executor.registerCommand("display.dim_more") { [weak displayTools] in DispatchQueue.main.async { displayTools?.dim(by: 0.1) } }
        executor.registerCommand("display.dim_less") { [weak displayTools] in DispatchQueue.main.async { displayTools?.dim(by: -0.1) } }
        executor.registerCommand("shelf.toggle") { [weak fileShelf] in DispatchQueue.main.async { fileShelf?.toggle() } }
        // One command to leave every mouse rule alone, or take them up again: the way out when something is wrong with the mouse.
        executor.registerCommand("mouse.rules.pause_toggle") { [weak self] in DispatchQueue.main.async { self?.toggleMouseRulesPause() } }
        // The backup input path for button replacement: pause it, or start the confirmation again, from any key bound to this.
        executor.registerCommand("mouse.replacement.pause") { [weak self] in DispatchQueue.main.async { self?.buttonReplacement.togglePause() } }
        // Trackpad gestures by name, so any shortcut, button rule, chord or hold can run them.
        for entry in TrackpadGestureCommands.all {
            executor.registerCommand(entry.command) { [weak self] in
                let at = CGEvent(source: nil)?.location ?? .zero
                self?.trackpadGestures.run(entry.kind, at: at)
            }
        }
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
        services.register(AuxiliaryService(id: "pointerEffects", title: "Pointer effects", start: { [weak pointerEffects] in pointerEffects?.start() }, stop: { [weak pointerEffects] in pointerEffects?.stop() }))
        services.register(AuxiliaryService(id: "systemMonitor", title: "System monitor", start: { [weak systemMonitor] in systemMonitor?.start() }, stop: { [weak systemMonitor] in systemMonitor?.stop() }))
        // These background services are owned by the service manager: it starts them, and stops them in safe mode or when a permission
        // they need is refused, instead of starting them here once and forgetting them.
        let mergeService = clipboardMerger, folderService = folderRules, hiderService = menuBarHider, mixerService = appAudio, soundRuleService = soundRules
        services.register(AuxiliaryService(id: "clipboardMerge", title: "Copy-twice merge", start: { mergeService.start() }, stop: { mergeService.stop() }))
        services.register(AuxiliaryService(id: "folderRules", title: "Folder rules", start: { folderService.start() }, stop: { folderService.stop() }))
        services.register(AuxiliaryService(id: "menuBarHider", title: "Menu bar hider", start: { hiderService.start() }, stop: { hiderService.stop() }))
        services.register(AuxiliaryService(id: "soundMixer", title: "Sound mixer", start: { mixerService.start() }, stop: { mixerService.stopAll() }, wake: { mixerService.refresh() }))
        services.register(AuxiliaryService(id: "soundRules", title: "Sound rules", start: { soundRuleService.start() }, stop: { soundRuleService.stop() }))
        workspaces.applySoundMode = { [weak soundRules] id in
            guard let runner = soundRules, let mode = runner.modes.first(where: { $0.id == id }) else { return false }
            runner.apply(mode)
            return true
        }
        workspaces.putSoundBack = { [weak soundRules] in soundRules?.putSoundBack() }
        configureAITools()
        services.register(AuxiliaryService(id: "midi", title: "MIDI triggers", start: { MIDITriggerRunner.shared.start() }, stop: { MIDITriggerRunner.shared.stop() }, isActive: { MIDITriggerRunner.shared.isActive }))
        services.register(AuxiliaryService(id: "safariInbox", title: "Safari inbox", start: { [weak safariInbox] in safariInbox?.start() }, stop: { [weak safariInbox] in safariInbox?.stop() }))
        services.register(AuxiliaryService(id: "mcpServer", title: "MCP server", start: { MCPHTTPServer.shared.start() }, stop: { MCPHTTPServer.shared.stop() }, isActive: { MCPHTTPServer.shared.isActive }))
        SettingsReloader.register(.sound) { [appAudio, soundRules] in
            appAudio.reload()
            soundRules.reload()
            DevicePriorityRunner.shared.reload()
            LocationAudioRunner.shared.reload()
        }
        services.register(AuxiliaryService(id: "locationAudio", title: "Sound by place", blockedWhenDenied: [.location], start: { LocationAudioRunner.shared.start() }, stop: { LocationAudioRunner.shared.stop() }, isActive: { LocationAudioRunner.shared.isActive }))
        services.register(AuxiliaryService(id: "soundDevices", title: "Sound device order", start: { DevicePriorityRunner.shared.start() }, stop: { DevicePriorityRunner.shared.stop() }, isActive: { DevicePriorityRunner.shared.isActive }))
        AutoEQRunner.shared.target = appAudio
        services.register(AuxiliaryService(id: "autoEQ", title: "Headphone correction", start: { AutoEQRunner.shared.start() }, stop: { AutoEQRunner.shared.stop() }, isActive: { AutoEQRunner.shared.isActive }))
        services.register(AuxiliaryService(id: "focusSession", title: "Focus sessions", start: { [weak self] in self?.focusSession.start() }, stop: { [weak self] in self?.focusSession.stop() }))
        worldClock.meetings = launcherTools.meetings
        services.register(AuxiliaryService(id: "worldClock", title: "World clock", start: { [weak self] in self?.worldClock.start() }, stop: { [weak self] in self?.worldClock.stop() }))
        services.register(AuxiliaryService(id: "sharedClipboard", title: "Shared clipboard", start: { [weak self] in self?.sharedClipboard.start() }, stop: { [weak self] in self?.sharedClipboard.stop() }))
        dialogFolders.type = { [weak keyboard] text in keyboard?.injector.insert(text, cursorBack: 0) }
        dialogFolders.applyAutoJump()
        dialogJumpObserver = NotificationCenter.default.addObserver(forName: .kriyaDialogAutoJumpChanged, object: nil, queue: .main) { [weak self] _ in self?.dialogFolders.applyAutoJump() }
        dictation.insert = { [weak keyboard] text in DispatchQueue.global(qos: .userInitiated).async { keyboard?.injector.insert(text, cursorBack: 0) } }
        let keys = VolumeKeys(events: events, engine: appAudio)
        volumeKeys = keys
        services.register(AuxiliaryService(id: "volumeKeys", title: "Volume keys", blockedWhenDenied: [.inputMonitoring], start: { keys.start() }, stop: { keys.stop() }))
        Task { @MainActor in SoundIntentBridge.engine = self.appAudio; SoundIntentBridge.mixer = self.soundMixer }
        clipboard.monitor.rules = clipboardRules
        remote.runCommand = { [weak keyboard] id in keyboard?.run(.command(command: id)) }
        remote.runAction = { [weak keyboard] id in keyboard?.run(.action(actionId: id)) }
        remote.runWorkflow = { [weak automation] id in automation?.fire(id, source: "Command line") }
        remote.showLauncher = { [weak keyboard] text in keyboard?.palette.show(prefill: text) }
        pointerMenuCancellable = pointerMenuStore.$config.receive(on: DispatchQueue.main).sink { [weak self] config in
            guard let self else { return }
            self.pointerMenu.setOptionRightClick(config.optionRightClick && self.permissions.isGranted(.inputMonitoring) && !self.crashGuard.isSafeMode, events: self.events)
        }
        services.register(AuxiliaryService(id: "keyboardDevices", title: "Keyboard device watcher", start: { [weak keyboardDevices] in keyboardDevices?.start() }, stop: { [weak keyboardDevices] in keyboardDevices?.stop() }))
        keyboardCancellable = keyboardDevices.$devices.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            guard let self else { return }
            self.remap.apply(allowed: self.permissions.isGranted(.inputMonitoring) && !self.crashGuard.isSafeMode)
        }
        remapCancellable = remapStore.$config.receive(on: DispatchQueue.main).sink { [weak self] _ in
            guard let self else { return }
            self.remap.apply(allowed: self.permissions.isGranted(.inputMonitoring) && !self.crashGuard.isSafeMode)
        }
        dragCancellable = dragStore.$config.receive(on: DispatchQueue.main).sink { [weak self] config in
            guard let self else { return }
            self.updateDragTools(config)
        }
        // Pausing the mouse rules puts everything back at once: held buttons let go, the pointer free, nothing waiting.
        // When macOS keeps switching the mouse hold off, this runs before the hold is switched back on.
        events.cleanUpBeforeResuming = { [weak self] in self?.releaseMouseHolds() }
        pauseCancellable = events.$mouseRulesPaused.removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] paused in
            guard let self else { return }
            if paused {
                self.releaseMouseHolds()
            } else {
                self.updateDragTools(self.dragStore.config)
            }
        }
        // Switching Mouse & Trackpad on or off starts and stops the drag tools with it.
        dragFeatureCancellable = self.config.$settings.map { $0.enabledFeatures.contains(.mouse) }.removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] _ in
            guard let self else { return }
            self.updateDragTools(self.dragStore.config)
        }
        // The pointer menu opens from any shortcut, button or gesture that runs these commands.
        for (command, appOnly) in [("menu.pointer", false), ("menu.app", true)] {
            executor.registerCommand(command) { [weak pointerMenu, weak config] in
                guard config?.isEnabled(.contextMenu) == true else { return }
                DispatchQueue.main.async { pointerMenu?.show(appMenuOnly: appOnly) }
            }
        }
        // Sound modes can be turned on and off from anything that runs commands, and the sound can be put back.
        executor.registerCommand("finder.drawer") { DispatchQueue.main.async { FinderDrawer.shared.toggle() } }
        executor.registerCommand("sound.restore") { [weak soundRules] in DispatchQueue.main.async { soundRules?.putSoundBack() } }
        soundModeSub = soundRules.$modes.receive(on: DispatchQueue.main).sink { [weak self] modes in
            guard let self else { return }
            for command in self.soundModeCommands { self.executor.unregisterCommand(command) }
            self.soundModeCommands = Set(modes.map { "sound.mode.\($0.id)" })
            for mode in modes {
                let id = mode.id
                self.executor.registerCommand("sound.mode.\(id)") { [weak self] in
                    DispatchQueue.main.async { if let mode = self?.soundRules.modes.first(where: { $0.id == id }) { self?.soundRules.toggle(mode) } }
                }
            }
        }
        registerSoundCommands()
        registerWindowListCommands()
        let triggers = WindowTriggers(run: runIdentifier)
        windowTriggers = triggers
        triggers.start()
        KeyboardCommands.extra = { [weak automation, weak soundRules, weak self] in
            [(command: "automation.macros", title: "Show the macro menu (workflows by group, for the front app)"),
             (command: "finder.drawer", title: "Show or hide the Finder drawer (selection and kept files)"),
             (command: "sound.restore", title: "Put the sound back how it was before Kriya changed it")]
                + (soundRules?.modes ?? []).map { (command: "sound.mode.\($0.id)", title: "Sound mode: \($0.name) (turn on or off)") }
                + (self?.quickConfigs.configs ?? []).map { (command: QuickConfigStore.command(for: $0.id), title: "Quick Config: \($0.name)") }
                + (self?.appAudio.favorites ?? []).flatMap { id -> [(command: String, title: String)] in
                    let name = AudioProcessList.name(for: id)
                    return [(command: "sound.app.mute.\(id)", title: "\(name): mute or unmute"), (command: "sound.app.volume_up.\(id)", title: "\(name): volume up"), (command: "sound.app.volume_down.\(id)", title: "\(name): volume down")]
                }
                + (self?.soundMixer.outputs ?? []).map { (command: "sound.set_output.\($0.uid)", title: "Sound output: \(DeviceNames.shared.name(for: $0))") }
                + (self?.soundMixer.inputs ?? []).map { (command: "sound.set_input.\($0.uid)", title: "Sound input: \(DeviceNames.shared.name(for: $0))") }
                + (automation?.store.workflows ?? []).filter(\.enabled).map { (command: workflowCommand(workflow: $0), title: "Workflow: \($0.name)") }
        }
        keyboard.palette.addProvider { [weak self] in
            guard let list = self?.windowList else { return [] }
            return [PaletteEntry(id: "windowlist", title: "Window List", subtitle: "Search every open window, with pictures and favorites", symbol: "macwindow.on.rectangle", category: .command,
                                 keywords: ["windows", "switch", "find window", "thumbnails", "favorite windows"]) { list.show() }]
        }
        keyboard.palette.addProvider { [weak automation] in
            (automation?.store.workflows ?? []).filter(\.enabled).map { workflow in
                PaletteEntry(id: "workflow:\(workflow.id)", title: "Run: \(workflow.name)", subtitle: "Workflow", symbol: "gearshape.2", category: .workflow) { automation?.fire(workflow.id, source: "Command launcher") }
            }
        }
        // Apps, open windows, files, clipboard history, macOS settings, a calculator, timers and emoji.
        let sources = LauncherSources(inventory: inventory, clipboard: clipboard, prefs: keyboard.palette.prefs)
        sources.intelligence = intelligence
        sources.tools = launcherTools
        devices.activeDeviceID = { [weak activity] in activity?.currentDeviceID() }
        devices.rateSampler = { [weak activity] id, seconds, done in
            if let activity { activity.sampleMovement(of: id, seconds: seconds, completion: done) } else { done([]) }
        }
        devices.activeAttribution = { [weak activity] in activity?.attribution(maxAgeNs: DeviceActivityTracker.testWindowNs) ?? .none }
        devices.lastUsedProvider = { [weak activity] id in activity?.lastUsed(id) }
        clipboard.quick.extraMenuActions = { [weak intelligence, weak clipboard] item in
            guard !item.sensitive, item.kind == .text || item.kind == .richText || item.kind == .url,
                  let text = clipboard?.store.blob(item.id)?.plain, !text.isEmpty else { return [] }
            // Paste it already tidied: the history item itself is left as it was.
            var actions = TextFilter.allCases.map { filter in
                QuickMenuAction(title: filter.title, symbol: filter.symbol, submenu: "Paste Changed") { clipboard?.paster.pasteTransformed(filter.apply(to: text)) }
            }
            if let intelligence, intelligence.service.isAvailable, intelligence.service.settings.onClipboardItems {
                actions += [
                    ("Summarize", IntelligenceTask.summarize, "text.append"), ("Explain", .explain, "questionmark.bubble"),
                    ("Fix Grammar", .fixGrammar, "checkmark.circle"), ("Make Professional", .professional, "briefcase"),
                ].map { title, task, symbol in
                    QuickMenuAction(title: title, symbol: symbol, submenu: "Apple Intelligence") { intelligence.perform(task, on: text) }
                }
            }
            return actions
        }
        sources.finder = finder
        sources.audio = audio
        sources.notes = notes
        sources.sharedClipboard = sharedClipboard
        sources.focus = focusSession
        notes.summarize = { [weak intelligence] text in intelligence?.perform(.summarize, on: text) }
        sources.runWorkflow = { [weak automation] id, text in automation?.fire(id, source: "Command launcher", input: text) }
        sources.workflowTitle = { [weak automation] id in automation?.store.workflow(id)?.name }
        sources.register(in: keyboard.palette)
        let launcherHotkeys = LauncherHotkeys(prefs: keyboard.palette.prefs)
        keyboard.palette.hotkeys = launcherHotkeys
        launcherHotkeys.runResult = { [weak palette = keyboard.palette] id in palette?.runResult(withID: id) }
        launcherHotkeys.showSelection = { [weak palette = keyboard.palette] in palette?.showForSelection() }
        self.launcherHotkeys = launcherHotkeys
        launcherTools.hotkeys = launcherHotkeys
        launcherTools.contactsAccess = { [weak sources] in sources?.contacts.isAllowed ?? false }
        launcherTools.requestContactsAccess = { [weak sources] done in sources?.contacts.requestAccess(done) ?? done(false) }
        launcherHotkeys.start()
        // Apple Intelligence on the selection: the bar offers its actions only where it can run and the person allows it.
        selection.runner.runIntelligence = { [weak intelligence] task, text, pointer, replace in
            DispatchQueue.main.async { intelligence?.perform(task, on: text, near: pointer, replace: replace) }
        }
        selection.isOffered = { [weak intelligence] action in
            guard case .intelligence = action.kind else { return true }
            return intelligence?.service.isAvailable == true && intelligence?.service.settings.inSelectionBar == true
        }
        launcherSources = sources
        configureIntents(sources: sources)
        quickCommands.search = { [weak palette = keyboard.palette] text in palette?.search(text) ?? [] }
        quickCommands.choose = { [weak palette = keyboard.palette] entry in palette?.choose(entry) }
    }
}

extension View {
    func injecting(_ env: AppEnvironment) -> some View {
        self
            .environmentObject(env.config)
            .environmentObject(env.crashGuard)
            .environmentObject(env.buttonReplacement)
            .environmentObject(CoexistenceMonitor.shared)
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
            .environmentObject(env.bridge)
            .environmentObject(env.safariInbox)
            .environmentObject(env.capture)
            .environmentObject(env.intelligence.service)
            .environmentObject(env.timeline)
            .environmentObject(env.keyboard.palette.prefs)
            .environmentObject(env.launcherTools.extras)
            .environmentObject(env.launcherTools)
            .environmentObject(env.folderRules)
            .environmentObject(env.folderRules.store)
            .environmentObject(env.menuBarHider)
            .environmentObject(env.systemMonitor)
            .environmentObject(env.notes)
            .environmentObject(env.appAudio)
            .environmentObject(env.soundMixer)
            .environmentObject(env.quickConfigs)
            .environmentObject(env.windowList.model)
            .environmentObject(env.soundRules)
            .environmentObject(env.focusSession)
            .environmentObject(env.worldClock)
            .environmentObject(env.sharedClipboard)
            .environmentObject(env.dictation)
            .environmentObject(env.speaker)
            .environmentObject(env.clipboardRules)
            .environmentObject(env.workspaceStore)
            .environmentObject(env.pointerStore)
            .environmentObject(env.dragStore)
            .environmentObject(env.screenStore)
            .environmentObject(env.displayTools)
            .environmentObject(env.fileShelf)
            .environmentObject(env.inventory)
            .environmentObject(env.homebrew)
            .environmentObject(env.keepAwake)
            .environmentObject(env.remapStore)
            .environmentObject(env.keyboardDevices)
            .environmentObject(env.quickCommands)
            .environmentObject(env.popoverPrefs)
            .environmentObject(ShortcutRegistry.shared)
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


extension AppEnvironment {
    /// Commands for the window list, favorite windows and throwing a window to an edge.
    fileprivate func registerWindowListCommands() {
        let list = windowList
        let controller = windowController
        executor.registerCommand("window.list") { DispatchQueue.main.async { list.toggle() } }
        executor.registerCommand("window.favorite_toggle") { DispatchQueue.main.async { list.model.toggleFrontFavorite() } }
        for n in 1...9 { executor.registerCommand("window.favorite_\(n)") { DispatchQueue.main.async { list.model.goToFavorite(number: n) } } }
        executor.registerCommand("window.reflow") { DispatchQueue.main.async { controller.run(command: "window.reflow") } }
        for name in ["left", "right", "up", "down", "top_left", "top_right", "bottom_left", "bottom_right"] {
            executor.registerCommand("window.throw_\(name)") { DispatchQueue.main.async { controller.run(command: "window.throw_\(name)") } }
        }
    }

    /// Shortcut-ready commands for the sound mixer: the app in front, timed mutes, saved setups and the devices.
    /// Starts the drag tools' event handler when a tool needs it (auto-scroll included), Input Monitoring is allowed, safe mode is off
    /// and Mouse & Trackpad is on; stops it otherwise.
    fileprivate func updateDragTools(_ drag: DragToolsConfig) {
        if DragToolsActivation.shouldRun(drag, inputMonitoring: permissions.isGranted(.inputMonitoring), safeMode: crashGuard.isSafeMode, mouseOn: config.isEnabled(.mouse)) {
            dragTools.start()
        } else {
            dragTools.stop()
        }
        updateNavigateDrag()
    }

    /// Kriya’s own held state is cleared and its own synthetic gestures cancelled. Nothing is posted that could press or release a
    /// button: a click held back is forgotten, not replayed, and no release is sent for a press that belongs to another app or device.
    /// The one exception is a press Kriya itself made by replacing a button, which is released once its physical button is let go.
    /// Safe to call at any time, and more than once.
    func releaseMouseHolds() {
        navigateDrag.stop()
        buttonChords.stop(replayPending: false)
        buttonReplacement.stop(.switchedOff)
        dragTools.reset()
        dragTools.stop()
        trackpadGestures.cancel()
    }

    /// Pauses every mouse rule, or resumes them.
    func toggleMouseRulesPause() { events.setMouseRulesPaused(!events.mouseRulesPaused) }

    /// Click-and-drag navigation listens only while it is switched on, Input Monitoring is allowed, safe mode is off and Mouse & Trackpad is on.
    fileprivate func updateNavigateDrag() {
        let allowed = permissions.isGranted(.inputMonitoring) && !crashGuard.isSafeMode && config.isEnabled(.mouse)
        navigateDrag.refresh(allowed: allowed)
        buttonChords.refresh(allowed: allowed)
        buttonReplacement.refresh(allowed: allowed, denial: crashGuard.isSafeMode ? .safeMode : .permissionLost)
    }

    fileprivate func registerSoundCommands() {
        let engine = appAudio
        func onFront(_ change: @escaping (AppAudioEngine, String) -> Void) -> () -> Void {
            { DispatchQueue.main.async { if let key = engine.frontAppKey() { change(engine, key) } } }
        }
        let fade = { UserDefaults.standard.object(forKey: "soundTimedFadeSeconds") as? Double ?? 2 }
        executor.registerCommand("sound.mixer.toggle") { NotificationCenter.default.post(name: SoundStatusItem.toggleNotification, object: nil) }
        executor.registerCommand("sound.front.mute", handler: onFront { e, k in e.update(k) { $0.muted.toggle() } })
        // The step is the one chosen in Sound settings (5% unless changed), the same one the mixer's arrow keys use.
        let step = { UserDefaults.standard.object(forKey: "soundVolumeStep") as? Double ?? VolumeStep.standard }
        executor.registerCommand("sound.front.volume_up", handler: onFront { e, k in e.update(k) { $0.volume = VolumeStep.next($0.volume, up: true, step: step(), range: 0...AppAudioSettings.maxVolume) } })
        executor.registerCommand("sound.front.volume_down", handler: onFront { e, k in e.update(k) { $0.volume = VolumeStep.next($0.volume, up: false, step: step(), range: 0...AppAudioSettings.maxVolume) } })
        executor.registerCommand("sound.front.favorite", handler: onFront { e, k in e.setFavorite(k, !e.isFavorite(k)) })
        executor.registerCommand("sound.front.boost", handler: onFront { e, k in e.setBoost(k, !e.isBoosted(k)) })
        executor.registerCommand("sound.front.menubar_icon", handler: onFront { e, k in e.setMenuBarIcon(k, !e.menuBarApps.contains(k)) })
        executor.registerCommand("sound.devices.priority_toggle") { DispatchQueue.main.async { DevicePriorityRunner.shared.enabled.toggle() } }
        executor.registerCommand("sound.front.bypass_effects", handler: onFront { e, k in e.update(k) { $0.effectsBypassed.toggle() } })
        executor.registerCommand("sound.front.reset_effects", handler: onFront { e, k in e.update(k) { $0.eq = EQPreset.flat.gains; $0.preamp = 0; $0.balance = 0; $0.effectsBypassed = false } })
        executor.registerCommand("sound.front.reset", handler: onFront { e, k in e.reset(k) })
        for seconds in [30, 60, 120] {
            executor.registerCommand("sound.front.mute_\(seconds)", handler: onFront { e, k in e.startTimed(k, level: 0, duration: TimeInterval(seconds), fadeOut: fade(), fadeIn: fade()) })
        }
        executor.registerCommand("sound.timer.cancel") { DispatchQueue.main.async { engine.cancelAllTimed() } }
        executor.registerCommand("sound.effects.toggle_all") { DispatchQueue.main.async { engine.update(AppAudioEngine.systemKey) { $0.effectsBypassed.toggle() } } }

        quickConfigSub = quickConfigs.$configs.receive(on: DispatchQueue.main).sink { [weak self] configs in
            guard let self else { return }
            for command in self.quickConfigCommands { self.executor.unregisterCommand(command) }
            self.quickConfigCommands = Set(configs.map { QuickConfigStore.command(for: $0.id) })
            for config in configs {
                let id = config.id
                self.executor.registerCommand(QuickConfigStore.command(for: id)) { [weak self] in DispatchQueue.main.async { self?.quickConfigs.apply(id) } }
            }
        }
        // Each favorite app gets its own mute and volume commands, so a shortcut can be set for one app.
        favoriteAppSub = engine.$favorites.receive(on: DispatchQueue.main).sink { [weak self] favorites in
            guard let self else { return }
            for command in self.favoriteAppCommands { self.executor.unregisterCommand(command) }
            self.favoriteAppCommands = []
            for id in favorites {
                for (suffix, change) in [("mute", { (s: inout AppAudioSettings) in s.muted.toggle() }),
                                         ("volume_up", { (s: inout AppAudioSettings) in s.volume = VolumeStep.next(s.volume, up: true, step: UserDefaults.standard.object(forKey: "soundVolumeStep") as? Double ?? VolumeStep.standard, range: 0...AppAudioSettings.maxVolume) }),
                                         ("volume_down", { (s: inout AppAudioSettings) in s.volume = VolumeStep.next(s.volume, up: false, step: UserDefaults.standard.object(forKey: "soundVolumeStep") as? Double ?? VolumeStep.standard, range: 0...AppAudioSettings.maxVolume) })] as [(String, (inout AppAudioSettings) -> Void)] {
                    let command = "sound.app.\(suffix).\(id)"
                    self.favoriteAppCommands.insert(command)
                    self.executor.registerCommand(command) { DispatchQueue.main.async { engine.update(id, change) } }
                }
            }
        }
        soundMixer.refresh()
        let register: ([AudioDevice], Bool) -> Void = { [weak self] devices, isInput in
            guard let self else { return }
            let prefix = isInput ? "sound.set_input." : "sound.set_output."
            for device in devices {
                let command = prefix + device.uid
                self.deviceCommands.insert(command)
                self.executor.registerCommand(command) { [weak self] in
                    DispatchQueue.main.async { if let d = AudioControl.shared.device(uid: device.uid) { AudioControl.shared.setDefault(d); self?.soundMixer.refresh() } }
                }
            }
        }
        deviceCommandSubs = [
            soundMixer.$outputs.receive(on: DispatchQueue.main).sink { register($0, false) },
            soundMixer.$inputs.receive(on: DispatchQueue.main).sink { register($0, true) },
        ]
    }

    /// Connects the tools an AI may ask for to the parts of Kriya that do the work. A tool whose part is not connected here says it
    /// is not available.
    fileprivate func configureAITools() {
        let clipStore = clipboardStore
        let engine = AIToolEngine.shared
        let host = LiveToolHost()
        engine.host = host
        engine.extraTools = { MCPClientManager.shared.tools }
        engine.extraHost = { tool, arguments in try await MCPClientManager.shared.callTool(exposedName: tool.name, arguments: arguments) }
        host.searchClipboard = { [weak clipStore] query, limit in
            DispatchQueue.main.sync {
                (clipStore?.search(query, limit: UInt32(limit)) ?? []).filter { !$0.sensitive && ($0.kind == .text || $0.kind == .url) }
                    .map { String($0.preview.prefix(120)) }
            }
        }
        host.isExcludedApp = { [weak clipStore] id in DispatchQueue.main.sync { clipStore?.config.excludedAppIds.contains(id) ?? false } }
        host.describeWorkflow = { [weak automation] id in
            DispatchQueue.main.sync {
                guard let workflow = automation?.store.workflow(id) else { return nil }
                let steps = workflow.steps.enumerated().map { "\($0.offset + 1). \(workflowStepSummary(step: $0.element))" }.joined(separator: "\n")
                return "\(workflow.name) — \(workflow.trigger.title)\(workflow.enabled ? "" : " (switched off)")\n\(steps)"
            }
        }
        host.diagnostics = { [weak permissions] in
            DispatchQueue.main.sync {
                let list = Permission.allCases.map { "\($0.title): \(permissions?.status($0) ?? .notDetermined)" }.joined(separator: "\n")
                return "Kriya \(SystemInfo.appVersion), macOS \(SystemInfo.osVersion), \(SystemInfo.architecture)\n\(list)"
            }
        }
        host.toggleSoundMode = { [weak self] name in
            DispatchQueue.main.sync {
                guard let runner = self?.soundRules, let mode = runner.modes.first(where: { $0.name.lowercased() == name.lowercased() }) else { return nil }
                let wasOn = runner.activeModeID == mode.id
                runner.toggle(mode)
                return wasOn ? "Turned \(mode.name) off." : "Turned \(mode.name) on."
            }
        }
        host.openLauncher = { [weak keyboard] query in keyboard?.palette.show(prefill: query) }
        configureAIIndex()
        configureAIToolActions()
        host.runWorkflow = { [weak automation] id in automation?.fire(id, source: "AI tool") }
    }
}


extension AppEnvironment {
    /// Tells the AI index where each source's text comes from. Each is called on the main thread when the index is updated.
    fileprivate func configureAIIndex() {
        let indexer = AIIndexer.shared
        indexer.providers[.notes] = {
            let path = UserDefaults.standard.string(forKey: NotesModel.folderKey)
            let store = NoteStore(folder: path.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? NoteStore.defaultFolder)
            return store.list().prefix(500).map { note in
                IndexDocument(id: "note:" + note.url.path, source: .notes, title: note.title, text: store.read(note.url), target: note.url.path, updated: note.modified)
            }
        }
        indexer.providers[.workflows] = { [weak self] in
            (self?.automation.store.workflows ?? []).map { workflow in
                let steps = workflow.steps.map { workflowStepSummary(step: $0) }.joined(separator: "\n")
                return IndexDocument(id: "workflow:" + workflow.id, source: .workflows, title: workflow.name, text: [workflow.notes ?? "", workflow.trigger.title, steps].joined(separator: "\n"), target: workflow.id,
                                     updated: Date(timeIntervalSince1970: TimeInterval(workflow.updatedAt)))
            }
        }
        indexer.providers[.actions] = {
            KeyboardCommands.all.map { IndexDocument(id: "command:" + $0.command, source: .actions, title: $0.title, text: $0.command.replacingOccurrences(of: ".", with: " "), target: $0.command, updated: Date(timeIntervalSince1970: 0)) }
        }
        indexer.providers[.clipboard] = { [weak self] in
            guard let store = self?.clipboardStore else { return [] }
            let filter = ClipFilter(kinds: [], pinnedOnly: false, favoritesOnly: false, collectionId: nil, tag: nil)
            return store.search("", filter: filter, limit: 400).filter { ($0.favorite || $0.pinned) && !$0.sensitive && ($0.kind == .text || $0.kind == .url) }.map { clip in
                IndexDocument(id: "clip:" + clip.id, source: .clipboard, title: clip.title ?? "", text: String(clip.preview.prefix(300)), target: clip.id, updated: Date(timeIntervalSince1970: TimeInterval(clip.lastUsedAt)), favorite: clip.favorite)
            }
        }
        indexer.providers[.savedPages] = { [weak self] in
            guard let folder = self?.pageCapture?.folder else { return [] }
            let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            return urls.filter { $0.pathExtension == "md" }.prefix(300).compactMap { url in
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
                return IndexDocument(id: "page:" + url.path, source: .savedPages, title: url.deletingPathExtension().lastPathComponent, text: text, target: url.path, updated: date)
            }
        }
        indexer.providers[.bookmarks] = { [weak self] in
            (self?.launcherSources?.bookmarks.all ?? []).prefix(2000).map { IndexDocument(id: "bookmark:" + $0.url, source: .bookmarks, title: $0.title, text: $0.url, target: $0.url, updated: Date(timeIntervalSince1970: 0)) }
        }
        indexer.providers[.activity] = { ActivitySummarySanitizer.documents(from: AuditLog.shared.entries) }
        indexer.start()
    }
}


extension AppEnvironment {
    /// The four tools that act on the Mac, connected to the parts of Kriya that already do these things. Each still asks the person
    /// first (the engine does that) and each is limited to what a person could do by hand in that part of Kriya.
    fileprivate func configureAIToolActions() {
        guard let host = AIToolEngine.shared.host as? LiveToolHost else { return }
        NotesAI.workflowStore = automation.store
        AudioAI.runner = soundRules
        AudioAI.appAudio = appAudio
        func failure(_ text: String) -> Error { NSError(domain: "Kriya", code: 20, userInfo: [NSLocalizedDescriptionKey: text]) }

        host.listWorkflows = { [weak self] in
            DispatchQueue.main.sync { (self?.automation.store.workflows ?? []).prefix(60).map { "\($0.id) — \($0.name)\($0.enabled ? "" : " (switched off)")" } }
        }
        host.listScripts = { [weak self] in
            DispatchQueue.main.sync { (self?.launcherTools.extras.scripts ?? []).prefix(60).map { "\($0.id) — \($0.name)" } }
        }
        host.listCommands = { query in
            DispatchQueue.main.sync {
                KeyboardCommands.all.filter { query.isEmpty || $0.title.lowercased().contains(query.lowercased()) || $0.command.contains(query.lowercased()) }.prefix(40).map { "\($0.command) — \($0.title)" }
            }
        }

        host.runScript = { [weak self] id in
            let script: ScriptCommand? = DispatchQueue.main.sync { self?.launcherTools.extras.scripts.first { $0.id == id } }
            guard let script else { throw failure("There is no launcher script with that id.") }
            // The same first-run check as running it from the launcher: the script's text, shown to the person, approved by its content.
            let approved: Bool = DispatchQueue.main.sync {
                LauncherApprovals.shared.ensureApproved(kind: "script", label: script.name, content: script.source, detail: "An AI asked to run this launcher script. It runs with your access to this Mac. Read it first.")
            }
            guard approved else { throw failure("The script was not approved.") }
            AuditLog.shared.record(.script, "Launcher script “\(script.name)” run for an AI")
            let environment = ["PATH": "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin", "KRIYA_ARGUMENT": ""]
            let output = try ToolRunner.run("/bin/zsh", ["-c", script.source, "kriya-script", ""], environment: environment, timeout: 60)
            return output.isEmpty ? "\(script.name) finished and printed nothing." : String(output.suffix(4000))
        }

        host.installCask = { [weak self] cask in
            try await MainActor.run {
                guard let brew = self?.homebrew else { throw failure("Homebrew is not available.") }
                guard HomebrewParsing.isValidToken(cask) else { throw failure("That is not a valid cask name.") }
                guard brew.brewPath != nil else { throw failure("Homebrew is not installed on this Mac.") }
                guard !LocalOnly.isOn else { throw failure(LocalOnly.blockedMessage) }
                guard !brew.isRunning else { throw failure("Another install is running. Wait for it to finish.") }
                brew.install([cask])
                return "Started installing \(cask). Progress, a Stop button and the log are in Kriya's Apps settings."
            }
        }

        host.changeShortcut = { [weak self] command, text in
            try await MainActor.run {
                guard let store = self?.keyboard.store else { throw failure("Shortcuts are not available.") }
                guard let known = KeyboardCommands.all.first(where: { $0.command == command }) else { throw failure("There is no command with that name. Use kriya.list_commands to see them.") }
                guard let parsed = ShortcutText.parse(text) else { throw failure("That is not a shortcut Kriya accepts. Write it like cmd+shift+k, and include command, control or option.") }
                var candidate = store.shortcuts.first { if case .command(let c) = $0.target { return c == command }; return false }
                    ?? KeyShortcut(id: UUID().uuidString, name: known.title, keyCode: parsed.keyCode, modifiers: parsed.modifiers, scope: .global, target: .command(command: command), enabled: true)
                let before = candidate.keyCode == parsed.keyCode && candidate.modifiers == parsed.modifiers
                candidate.keyCode = parsed.keyCode
                candidate.modifiers = parsed.modifiers
                if before { return "\(known.title) already uses \(KeyNames.describe(keyCode: parsed.keyCode, modifiers: parsed.modifiers))." }
                let conflicts = store.checkShortcut(candidate)
                guard conflicts.isEmpty else { throw failure("\(KeyNames.describe(keyCode: parsed.keyCode, modifiers: parsed.modifiers)) clashes with \(conflicts.count) other shortcut\(conflicts.count == 1 ? "" : "s") or one macOS keeps, so it was not set.") }
                store.saveShortcut(candidate)
                AuditLog.shared.record(.setting, "Shortcut for “\(known.title)” set by an AI")
                FeatureActivity.shared.changed("keyboard", "Shortcut for \(known.title) changed")
                return "\(known.title) now uses \(KeyNames.describe(keyCode: parsed.keyCode, modifiers: parsed.modifiers)). You can change it back in Keyboard settings."
            }
        }

        host.exportClipboard = { [weak self] limit in
            try await MainActor.run {
                guard let store = self?.clipboardStore else { throw failure("The clipboard history is not available.") }
                let filter = ClipFilter(kinds: [], pinnedOnly: false, favoritesOnly: false, collectionId: nil, tag: nil)
                let items: [(title: String, text: String, at: Date)] = store.search("", filter: filter, limit: UInt32(max(1, min(limit, 50)))).compactMap { clip in
                    guard !clip.sensitive, clip.kind == .text || clip.kind == .url, let text = store.blob(clip.id)?.plain else { return nil }
                    return (clip.title ?? "", text, Date(timeIntervalSince1970: TimeInterval(clip.createdAt)))
                }
                guard !items.isEmpty else { throw failure("There is nothing to export: no recent text items, or they all looked like secrets.") }
                let panel = NSSavePanel()
                panel.allowedContentTypes = [.plainText]
                panel.nameFieldStringValue = "Kriya clipboard export.md"
                panel.message = "An AI asked to export \(items.count) recent clipboard item\(items.count == 1 ? "" : "s"). Items that look like secrets are left out."
                NSApp.activate(ignoringOtherApps: true)
                guard panel.runModal() == .OK, let url = panel.url else { throw failure("The person chose not to save the export.") }
                try ClipboardExport.markdown(items).write(to: url, atomically: true, encoding: .utf8)
                AuditLog.shared.record(.files, "Clipboard export saved for an AI (\(items.count) items)")
                return "Saved \(items.count) item\(items.count == 1 ? "" : "s") to \(url.lastPathComponent)."
            }
        }
    }
}
