import Carbon.HIToolbox
import XCTest
@testable import Kriya

final class DeviceClassificationTests: XCTestCase {
    private func classify(name: String, transport: String, builtIn: Bool = false, serial: String? = nil,
                          usagePage: Int? = 0x01, usage: Int? = 0x02) -> DeviceRegistry.Described {
        DeviceRegistry.classify(
            vendor: 0x046D, product: 0xC52B, name: name, serial: serial, transport: transport,
            location: 0x1400_0000, builtIn: builtIn, usagePage: usagePage, usage: usage
        )
    }

    func testUSBMouseIsWired() {
        let d = classify(name: "USB Optical Mouse", transport: "USB")
        XCTAssertEqual(d.kind, .mouse)
        XCTAssertEqual(d.connection, .wired)
    }

    func testBluetoothMouseIsWireless() {
        XCTAssertEqual(classify(name: "MX Master 3", transport: "Bluetooth Low Energy").connection, .wireless)
        XCTAssertEqual(classify(name: "Magic Mouse", transport: "Bluetooth").connection, .wireless)
    }

    func testReceiverMouseIsWirelessEvenThoughItReportsUSB() {
        XCTAssertEqual(classify(name: "USB Receiver", transport: "USB").connection, .wireless)
        XCTAssertEqual(classify(name: "Logitech Unifying", transport: "USB").connection, .wireless)
    }

    func testBuiltInTrackpad() {
        let d = classify(name: "Apple Internal Trackpad", transport: "SPI", builtIn: true, usagePage: 0x0D, usage: 0x05)
        XCTAssertEqual(d.kind, .trackpad)
        XCTAssertEqual(d.connection, .builtIn)
        XCTAssertTrue(d.id.hasPrefix("builtin:"))
    }

    func testMagicTrackpadOverBluetooth() {
        let d = classify(name: "Magic Trackpad", transport: "Bluetooth", usagePage: 0x01, usage: 0x02)
        XCTAssertEqual(d.kind, .trackpad)
        XCTAssertEqual(d.connection, .wireless)
    }

    func testSerialNumberMakesTheIdStableAcrossPorts() {
        let a = classify(name: "Mouse", transport: "USB", serial: "ABC123")
        let b = DeviceRegistry.classify(
            vendor: 0x046D, product: 0xC52B, name: "Mouse", serial: "ABC123", transport: "USB",
            location: 0x9999, builtIn: false, usagePage: 0x01, usage: 0x02
        )
        XCTAssertEqual(a.id, b.id)
    }
}

final class PermissionManagerTests: XCTestCase {
    private func make(_ probe: FakeProbe) -> PermissionManager {
        PermissionManager(probe: probe, defaults: UserDefaults(suiteName: "kriya-tests-\(UUID().uuidString)")!)
    }

    func testNothingIsRequestedAtLaunch() {
        let probe = FakeProbe()
        _ = make(probe)
        XCTAssertTrue(probe.requested.isEmpty)
    }

    func testAnUnaskedPermissionIsNotShownAsDenied() {
        let manager = make(FakeProbe())
        XCTAssertEqual(manager.status(.accessibility), .notDetermined)
    }

    func testGrantingIsNoticedOnRefresh() {
        let probe = FakeProbe()
        let manager = make(probe)
        XCTAssertFalse(manager.isGranted(.accessibility))
        probe.granted = [.accessibility]
        manager.refresh()
        XCTAssertTrue(manager.isGranted(.accessibility))
    }

    func testAskedThenDeniedOpensSettingsInsteadOfPromptingAgain() {
        let probe = FakeProbe()
        let manager = make(probe)
        manager.request(.accessibility)               // first ask: the system prompt
        XCTAssertEqual(probe.requested, [.accessibility])
        manager.refresh()                             // still denied, and now known to have been asked
        XCTAssertEqual(manager.status(.accessibility), .denied)
        manager.request(.accessibility)               // second ask: no second prompt
        XCTAssertEqual(probe.requested, [.accessibility])
    }

    func testMissingListsOnlyWhatAFeatureNeeds() {
        let probe = FakeProbe()
        probe.granted = [.accessibility]
        let manager = make(probe)
        XCTAssertEqual(manager.missing(for: .mouse), [.inputMonitoring])
        XCTAssertEqual(manager.missing(for: .windowManagement), [])
        XCTAssertEqual(manager.missing(for: .contextMenu), [])
    }
}

final class ActionExecutorTests: XCTestCase {
    private var world: TestWorld!
    private var executor: ActionExecutor!

    override func setUpWithError() throws {
        world = try TestWorld()
        executor = ActionExecutor(permissions: world.permissions)
    }

    override func tearDown() { world.cleanUp() }

    func testShellSuccessAndFailure() async {
        let ok = await executor.perform(.runShell(script: "true"))
        XCTAssertEqual(ok, .success)
        let bad = await executor.perform(.runShell(script: "echo nope; exit 3"))
        if case .failure(let message) = bad {
            XCTAssertTrue(message.contains("nope"))
        } else {
            XCTFail("expected a failure")
        }
    }

    func testInvalidActionsAreRefusedBeforeRunning() async {
        let outcome = await executor.perform(.openUrl(url: "javascript:alert(1)"))
        XCTAssertFalse(outcome.isSuccess)
    }

    func testKeyPressNeedsAccessibility() async {
        let outcome = await executor.perform(.keyPress(keyCode: 0, modifiers: KeyModifiers.command))
        XCTAssertEqual(outcome, .failure("Accessibility permission is needed to press keys."))
    }

    func testBuiltinCommandsRunWhenRegisteredAndFailWhenNot() async {
        var calls = 0
        executor.registerCommand("window.left_half") { calls += 1 }
        let found = await executor.perform(.builtin(command: "window.left_half"))
        XCTAssertEqual(found, .success)
        XCTAssertEqual(calls, 1)
        executor.unregisterCommand("window.left_half")
        let missing = await executor.perform(.builtin(command: "window.left_half"))
        XCTAssertFalse(missing.isSuccess)
    }

    func testSequenceRunsInOrderAndStopsAtTheFirstFailure() async {
        var order: [String] = []
        executor.registerCommand("a") { order.append("a") }
        executor.registerCommand("c") { order.append("c") }
        let sequence = Action.sequence(
            steps: [.builtin(command: "a"), .builtin(command: "missing"), .builtin(command: "c")],
            delayMs: 0
        )
        let outcome = await executor.perform(sequence)
        XCTAssertFalse(outcome.isSuccess)
        XCTAssertEqual(order, ["a"])
    }

    func testModifierBitsRoundTrip() {
        let bits = KeyModifiers.command | KeyModifiers.shift | KeyModifiers.option
        XCTAssertEqual(KeyModifiers.bits(from: KeyModifiers.flags(from: bits)), bits)
    }
}

final class BackupManagerTests: XCTestCase {
    private var world: TestWorld!
    private var backup: BackupManager!

    override func setUpWithError() throws {
        world = try TestWorld()
        backup = BackupManager(core: world.core, folder: world.folder.appendingPathComponent("Backups", isDirectory: true), passphrases: MemoryPassphraseStore())
        try FileManager.default.createDirectory(at: world.folder.appendingPathComponent("Backups"), withIntermediateDirectories: true)
    }

    override func tearDown() { world.cleanUp() }

    func testRestoreBringsBackSettingsAndSavesTheCurrentOnesFirst() throws {
        let library = ActionLibrary(core: world.core)
        try library.save(name: "Open site", action: .openUrl(url: "https://example.com"))
        world.config.setEnabled(.mouse, true)
        let file = world.folder.appendingPathComponent("saved.kriyabackup")
        try backup.export(to: file)

        // Change things after the backup was made.
        world.config.setEnabled(.mouse, false)
        try library.delete(try XCTUnwrap(library.actions.first))
        XCTAssertTrue(library.actions.isEmpty)

        var restored = false
        backup.onRestored = { restored = true }
        let summary = try backup.restore(from: file)
        XCTAssertEqual(summary.actions, 1)
        XCTAssertTrue(restored)
        XCTAssertEqual(backup.automaticBackups.count, 1, "the state before the restore is kept")

        library.reload()
        world.config.reload()
        XCTAssertEqual(library.actions.count, 1)
        XCTAssertTrue(world.config.isEnabled(.mouse))
    }

    func testANonBackupFileChangesNothing() throws {
        let junk = world.folder.appendingPathComponent("junk.kriyabackup")
        try Data("not a backup".utf8).write(to: junk)
        world.config.setEnabled(.mouse, true)
        XCTAssertThrowsError(try backup.restore(from: junk))
        XCTAssertTrue(world.config.isEnabled(.mouse))
        XCTAssertTrue(backup.automaticBackups.isEmpty)
    }
}

final class ProfileDecisionTests: XCTestCase {
    func testDefaultProfileExistsAndAppProfilesOverrideIt() throws {
        let world = try TestWorld()
        defer { world.cleanUp() }
        let store = ProfileStore(core: world.core)
        XCTAssertEqual(store.profiles.count, 1)
        XCTAssertTrue(store.defaultProfile?.isDefault ?? false)

        let game = Profile(id: "g", name: "Game", appId: "com.example.game", isDefault: false, isEnabled: true,
                           featureOverrides: [FeatureOverride(feature: .mouse, enabled: false)], sortOrder: 1)
        try store.save(game)
        XCTAssertEqual(disabledFeatures(profiles: store.profiles, appId: "com.example.game"), [.mouse])
        XCTAssertEqual(disabledFeatures(profiles: store.profiles, appId: "com.other"), [])
    }
}

final class MouseFeatureTests: XCTestCase {
    func testWholeLinesNeverRoundASmallMovementToNothing() {
        XCTAssertEqual(MouseFeature.wholeLines(0), 0)
        XCTAssertEqual(MouseFeature.wholeLines(0.3), 1)
        XCTAssertEqual(MouseFeature.wholeLines(-0.3), -1)
        XCTAssertEqual(MouseFeature.wholeLines(2.4), 2)
        XCTAssertEqual(MouseFeature.wholeLines(-2.6), -3)
    }

    func testPresetsResolveByDeviceAndApp() throws {
        let world = try TestWorld()
        defer { world.cleanUp() }
        let devices = DeviceRegistry(core: world.core)
        let profiles = ProfileStore(core: world.core)
        let library = ActionLibrary(core: world.core)
        let store = MouseStore(core: world.core, library: library, devices: devices, profiles: profiles)

        store.setAssignment(device: "mouse-1", app: nil, preset: "builtin.fast")
        store.setAssignment(device: nil, app: "com.example.app", preset: "builtin.precise")
        XCTAssertEqual(
            resolveMousePreset(assignments: store.assignments, defaultPresetId: "default", deviceId: "mouse-1", appId: "other"),
            "builtin.fast"
        )
        XCTAssertEqual(
            resolveMousePreset(assignments: store.assignments, defaultPresetId: "default", deviceId: "mouse-2", appId: "com.example.app"),
            "builtin.precise"
        )
        store.setAssignment(device: "mouse-1", app: nil, preset: nil)
        XCTAssertNil(store.assignment(device: "mouse-1", app: nil))
    }

    func testEditsToTheDefaultPresetPersistAndBuiltinsRefuseEdits() throws {
        let world = try TestWorld()
        defer { world.cleanUp() }
        let store = MouseStore(
            core: world.core, library: ActionLibrary(core: world.core),
            devices: DeviceRegistry(core: world.core), profiles: ProfileStore(core: world.core)
        )
        store.update(presetID: "default") { $0.vertical.reverse = true }
        store.flushPendingSaves()
        store.reload()
        XCTAssertTrue(store.defaultPreset?.settings.vertical.reverse ?? false)

        store.update(presetID: "builtin.fast") { $0.vertical.reverse = true }
        XCTAssertFalse(store.preset("builtin.fast")?.settings.vertical.reverse ?? true)
    }

    func testExclusionLeavesTheMouseAlone() throws {
        let world = try TestWorld()
        defer { world.cleanUp() }
        let profiles = ProfileStore(core: world.core)
        let store = MouseStore(
            core: world.core, library: ActionLibrary(core: world.core),
            devices: DeviceRegistry(core: world.core), profiles: profiles
        )
        store.start()
        XCTAssertNotNil(store.compiled(forDevice: nil))
    }

    func testButtonKeysCompileOnlyForSavedActions() {
        let settings = MouseSettings(
            vertical: defaultMouseSettings().vertical, horizontal: defaultMouseSettings().horizontal,
            pointer: defaultMouseSettings().pointer,
            buttons: [
                ButtonRule(button: 3, modifiers: 0, actionId: "known", trigger: .click),
                ButtonRule(button: 4, modifiers: 0, actionId: "gone", trigger: .click),
            ],
            gestures: defaultMouseSettings().gestures,
            horizontalScrollModifier: defaultMouseSettings().horizontalScrollModifier,
            rawScrollModifier: defaultMouseSettings().rawScrollModifier,
            holdMs: 350
        )
        let compiled = CompiledMouse(settings: settings, actions: ["known": .noop], neutral: defaultMouseSettings().vertical)
        XCTAssertNotNil(compiled.buttonActions[ButtonKey(button: 3, modifiers: 0)])
        XCTAssertNil(compiled.buttonActions[ButtonKey(button: 4, modifiers: 0)])
        XCTAssertTrue(compiled.verticalIsNeutral)
    }
}

final class WindowManagementTests: XCTestCase {
    private let area = Rect(x: 0, y: 25, width: 1200, height: 775)
    private let current = Rect(x: 100, y: 100, width: 400, height: 300)

    func testLayoutsComeFromTheCore() {
        let left = windowLayoutFrame(layout: .leftHalf, area: area, current: current, gap: 0)
        XCTAssertEqual(left.width, 600)
        XCTAssertEqual(windowLayoutFrame(layout: .maximize, area: area, current: current, gap: 0), area)
        XCTAssertEqual(windowLayouts().count, 21)
        XCTAssertEqual(windowLayoutFromCommand(command: "window.left_half"), .leftHalf)
    }

    func testTinyLayoutPicturesAreDrawnFromAFullSizeScreen() {
        // The menu-bar window draws each layout as a small screen from these numbers, so they have to be the layout's
        // real share of the screen, not stretched by minimum window sizes.
        let screen = Rect(x: 0, y: 0, width: 1600, height: 1000)
        let window = Rect(x: 400, y: 250, width: 800, height: 500)
        let left = windowLayoutFrame(layout: .leftHalf, area: screen, current: window, gap: 0)
        XCTAssertEqual(left.width, 800)
        XCTAssertEqual(left.height, 1000)
        let corner = windowLayoutFrame(layout: .topRight, area: screen, current: window, gap: 0)
        XCTAssertEqual([corner.x, corner.y, corner.width, corner.height], [800, 0, 800, 500])
        let third = windowLayoutFrame(layout: .firstThird, area: screen, current: window, gap: 0)
        XCTAssertEqual(third.width, 533, accuracy: 1)
    }

    func testCommandsMatchTheNamesTheMouseFeatureUses() {
        // Every layout the core knows must be offered as a command that a shortcut, button or gesture can run.
        let offered = Set(WindowCommands.all.map(\.command))
        for layout in windowLayouts() {
            XCTAssertTrue(offered.contains(layout.command), "\(layout.command) is not offered as a command")
            XCTAssertNotNil(windowLayoutFromCommand(command: layout.command), "\(layout.command) is not a layout command")
        }
        XCTAssertTrue(windowExtraCommands().contains { $0.command == "window.restore" })
        XCTAssertTrue(windowExtraCommands().contains { $0.command == "window.next_display" })
    }

    func testCarbonModifiersMapEveryKey() {
        let bits = KeyModifiers.control | KeyModifiers.option | KeyModifiers.command | KeyModifiers.shift
        XCTAssertEqual(
            HotkeyCenter.carbonModifiers(bits),
            UInt32(controlKey | optionKey | cmdKey | shiftKey)
        )
        XCTAssertEqual(HotkeyCenter.carbonModifiers(0), 0)
    }

    func testWindowSettingsAndShortcutsPersistAndRejectConflicts() throws {
        let world = try TestWorld()
        defer { world.cleanUp() }
        let store = WindowStore(core: world.core)
        XCTAssertEqual(store.shortcuts, defaultWindowShortcuts())

        store.updateConfig { $0.gap = 12 }
        store.flushPendingSaves()
        store.reload()
        XCTAssertEqual(store.config.gap, 12)

        let taken = try XCTUnwrap(store.shortcut(for: "window.left_half"))
        store.setShortcut("window.center", keyCode: taken.keyCode, modifiers: taken.modifiers)
        XCTAssertNotNil(store.lastError, "two commands cannot share a shortcut")
        XCTAssertNotEqual(store.shortcut(for: "window.center")?.keyCode, taken.keyCode)
    }

    func testSavedLayoutsRoundTripThroughTheStore() throws {
        let world = try TestWorld()
        defer { world.cleanUp() }
        let store = WindowStore(core: world.core)
        let entry = LayoutEntry(appId: "com.example", title: "Doc", displayId: "d", frame: Rect(x: 0, y: 0, width: 0.5, height: 1))
        store.saveLayout(SavedLayout(id: "L1", name: "Writing", displayKey: "d", isAuto: false, createdAt: 1, entries: [entry], unplaced: .leave, launchMissing: false, isGroup: false))
        XCTAssertEqual(store.layouts.map(\.name), ["Writing"])
        XCTAssertEqual(store.title(forCommand: store.layoutCommand(store.layouts[0])), "Layout: Writing")
        store.deleteLayout("L1")
        XCTAssertTrue(store.layouts.isEmpty)
    }

    func testTheSwitcherRanksByRecencyThenMatch() {
        let items = [
            SwitcherItem(id: "a", appName: "Safari", title: "News", lastUsed: 1),
            SwitcherItem(id: "b", appName: "Xcode", title: "Kriya", lastUsed: 9),
        ]
        XCTAssertEqual(windowRankSwitcher(items: items, query: ""), ["b", "a"])
        XCTAssertEqual(windowRankSwitcher(items: items, query: "saf"), ["a"])
    }

    func testDisplayConversionFlipsTheVerticalAxis() {
        // A window at the top-left of the main display is at the top of the screen in AppKit's bottom-left coordinates.
        guard let main = NSScreen.screens.first else { return }
        let converted = DisplayManager.appKitFrame(Rect(x: 0, y: 0, width: 100, height: 50))
        XCTAssertEqual(converted.maxY, main.frame.height, accuracy: 0.5)
        XCTAssertEqual(converted.height, 50, accuracy: 0.5)
    }

    func testHistoryUndoIsPerWindow() {
        let history = FrameHistory()
        let a = Rect(x: 0, y: 0, width: 400, height: 300)
        history.record(key: "w1", frame: a)
        XCTAssertNil(history.undo(key: "w2", current: Rect(x: 5, y: 5, width: 10, height: 10)))
        XCTAssertEqual(history.undo(key: "w1", current: Rect(x: 600, y: 0, width: 600, height: 775)), a)
    }
}

final class TrafficLightTests: XCTestCase {
    func testNothingIsInterceptedByDefault() throws {
        let world = try TestWorld()
        defer { world.cleanUp() }
        let store = TrafficStore(core: world.core)
        XCTAssertTrue(store.isIdle)
        XCTAssertEqual(store.resolve(appID: "a", button: .close, modifiers: 0), .native)
    }

    func testRulesResolveByButtonKeysAndApp() throws {
        let world = try TestWorld()
        defer { world.cleanUp() }
        let store = TrafficStore(core: world.core)
        store.update { $0.bindings = [TrafficBinding(button: .close, modifiers: KeyModifiers.option, action: .quitApp)] }
        XCTAssertFalse(store.isIdle)
        XCTAssertEqual(store.resolve(appID: "a", button: .close, modifiers: KeyModifiers.option), .quitApp)
        XCTAssertEqual(store.resolve(appID: "a", button: .close, modifiers: 0), .native)

        store.saveProfile(TrafficProfile(
            id: "p", appId: "editor", enabled: true,
            bindings: [TrafficBinding(button: .close, modifiers: KeyModifiers.option, action: .native)]
        ))
        XCTAssertEqual(store.resolve(appID: "editor", button: .close, modifiers: KeyModifiers.option), .native)
        XCTAssertEqual(store.resolve(appID: "other", button: .close, modifiers: KeyModifiers.option), .quitApp)
    }

    func testExcludedAndSystemAppsAreNeverIntercepted() throws {
        let world = try TestWorld()
        defer { world.cleanUp() }
        let store = TrafficStore(core: world.core)
        store.update { $0.bindings = [TrafficBinding(button: .zoom, modifiers: 0, action: .maximize)]; $0.excludedAppIds = ["com.game"] }
        XCTAssertEqual(store.resolve(appID: "com.game", button: .zoom, modifiers: 0), .native)
        XCTAssertEqual(store.resolve(appID: "com.apple.dock", button: .zoom, modifiers: 0), .native)
        XCTAssertEqual(store.resolve(appID: "com.other", button: .zoom, modifiers: 0), .maximize)
    }

    func testRestoringNativeClearsTheRules() throws {
        let world = try TestWorld()
        defer { world.cleanUp() }
        let store = TrafficStore(core: world.core)
        store.update { $0.bindings = suggestedTrafficBindings() }
        store.flushPendingSaves()
        store.restoreNative(everything: false)
        XCTAssertTrue(store.config.bindings.isEmpty)
        XCTAssertTrue(store.isIdle)
    }

    func testTheTitleBarCheckRejectsClicksFarFromAnyWindowCorner() {
        // A point far outside every window is never a button, so the Accessibility lookup is skipped.
        XCTAssertFalse(TrafficLightFeature.isInTitleBarCorner(CGPoint(x: -50_000, y: -50_000)))
    }

    func testEveryActionHasATitleAndSymbol() {
        let actions: [TrafficAction] = [.native, .doNothing, .closeWindow, .quitApp, .hideApp, .hideOtherApps, .minimizeWindow,
                                         .minimizeAllWindows, .maximize, .toggleFullScreen, .center, .snap(layout: .leftHalf), .run(actionId: "x")]
        for action in actions {
            XCTAssertFalse(action.title.isEmpty)
            XCTAssertFalse(action.symbol.isEmpty)
        }
    }
}

final class FinderActionTests: XCTestCase {
    private func menu() -> FinderMenuFile {
        FinderMenuFile(
            token: "t", title: "Kriya", flat: false,
            items: [
                .init(id: "path", title: "Copy Path", applies: "anything", extensions: [], submenu: nil),
                .init(id: "extract", title: "Extract", applies: "archives", extensions: [], submenu: nil),
                .init(id: "rename", title: "Rename", applies: "single_item", extensions: [], submenu: nil),
                .init(id: "batch", title: "Batch", applies: "multiple_items", extensions: [], submenu: nil),
                .init(id: "newfile", title: "New File", applies: "folder_background", extensions: [], submenu: nil),
                .init(id: "png", title: "Only PNG", applies: "files", extensions: ["png"], submenu: nil),
                .init(id: "convert", title: "Convert", applies: "files", extensions: [], submenu: .conversions),
                .init(id: "with", title: "Open With", applies: "files", extensions: [], submenu: .favoriteApps),
            ],
            templates: [], folderTemplates: [], favoriteApps: [],
            conversions: ["png": [.init(id: "jpeg", title: "JPEG")], "jpg": [.init(id: "png", title: "PNG"), .init(id: "pdf", title: "PDF")]]
        )
    }

    private func ids(_ file: FinderMenuFile, _ selection: FinderMenuFile.Selection) -> [String] {
        file.visibleItems(for: selection).map(\.id)
    }

    func testSelectionsGetTheRightActions() {
        let file = menu()
        let one = FinderMenuFile.Selection(count: 1, folders: 0, extensions: ["png"], isBackground: false)
        XCTAssertEqual(ids(file, one), ["path", "rename", "png", "convert"])
        let many = FinderMenuFile.Selection(count: 2, folders: 0, extensions: ["png", "png"], isBackground: false)
        XCTAssertEqual(ids(file, many), ["path", "batch", "png", "convert"])
        let archive = FinderMenuFile.Selection(count: 1, folders: 0, extensions: ["zip"], isBackground: false)
        XCTAssertTrue(ids(file, archive).contains("extract"))
        let folder = FinderMenuFile.Selection(count: 1, folders: 1, extensions: [""], isBackground: false)
        XCTAssertEqual(ids(file, folder), ["path", "rename"])
        let background = FinderMenuFile.Selection(count: 1, folders: 1, extensions: [], isBackground: true)
        XCTAssertEqual(ids(file, background), ["path", "newfile"])
    }

    func testConversionsAreTheFormatsEverySelectedFileCanBecome() {
        let file = menu()
        let both = FinderMenuFile.Selection(count: 2, folders: 0, extensions: ["png", "jpg"], isBackground: false)
        XCTAssertTrue(file.conversionTargets(for: both).isEmpty)
        let jpgs = FinderMenuFile.Selection(count: 2, folders: 0, extensions: ["jpg", "jpg"], isBackground: false)
        XCTAssertEqual(file.conversionTargets(for: jpgs).map(\.id), ["png", "pdf"])
        XCTAssertFalse(ids(file, both).contains("convert"), "an item with nothing to offer is left out")
    }

    func testRequestsRoundTripAndRejectGarbage() throws {
        let request = FinderRequest(item: "copy-path", child: "x", token: "secret", paths: ["/a b/c é.txt", "/x"], target: nil)
        let url = try XCTUnwrap(request.url)
        XCTAssertEqual(FinderRequest(url: url), request)
        XCTAssertNil(FinderRequest(url: URL(string: "https://example.com/run?item=a&token=b")!))
        XCTAssertNil(FinderRequest(url: URL(string: "kriya://finder/run?item=a")!), "no token")
        XCTAssertNil(FinderRequest(url: URL(string: "kriya://finder/other?item=a&token=b")!))
        XCTAssertNil(FinderRequest(url: URL(string: "kriya://finder/run?item=a&token=b&paths=%%%")!))
    }

    func testConversionsMatchTheFileType() {
        XCTAssertTrue(Converter.targets(forExtension: "png").contains { $0.id == "jpeg" })
        XCTAssertFalse(Converter.targets(forExtension: "png").contains { $0.id == "png" })
        XCTAssertFalse(Converter.targets(forExtension: "jpg").contains { $0.id == "jpeg" }, "jpg is already jpeg")
        XCTAssertTrue(Converter.targets(forExtension: "docx").contains { $0.id == "txt" })
        XCTAssertTrue(Converter.targets(forExtension: "xyz").isEmpty)
    }

    func testProtectedFoldersAreRefused() {
        XCTAssertTrue(ProtectedPaths.isProtected("/"))
        XCTAssertTrue(ProtectedPaths.isProtected(NSHomeDirectory()))
        XCTAssertTrue(ProtectedPaths.isProtected("/System/Library"))
        XCTAssertFalse(ProtectedPaths.isProtected(NSHomeDirectory() + "/Documents/report.txt"))
    }

    func testTheStorePublishesItsMenuAndOnlyWhileActive() throws {
        let world = try TestWorld()
        defer { world.cleanUp() }
        let file = world.folder.appendingPathComponent("finder-menu.json")
        let store = FinderStore(core: world.core, menuFile: file, defaults: UserDefaults(suiteName: "kriya-tests-\(UUID().uuidString)")!)
        XCTAssertTrue(try JSONDecoder().decode(FinderMenuFile.self, from: Data(contentsOf: file)).items.isEmpty, "off: Finder's menu is empty")
        store.setActive(true)
        let active = try JSONDecoder().decode(FinderMenuFile.self, from: Data(contentsOf: file))
        XCTAssertEqual(active.items.count, store.items.filter(\.enabled).count)
        XCTAssertEqual(active.token, store.token)
        store.setEnabled("compress", false)
        XCTAssertFalse(try JSONDecoder().decode(FinderMenuFile.self, from: Data(contentsOf: file)).items.contains { $0.id == "compress" })
        let permissions = try XCTUnwrap(try? FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.intValue, 0o600)
    }

    func testRenamesAreChecksAndRunFromTheCore() {
        let plan = finderPlanBatchRename(
            names: ["a.txt", "b.txt"], rule: BatchRenameRule(steps: [.prefix(text: "x-")]), others: []
        )
        XCTAssertEqual(plan.map(\.to), ["x-a.txt", "x-b.txt"])
        XCTAssertTrue(finderRenamePlanReady(plan: plan))
        XCTAssertEqual(finderShellEscape(path: "/it's here"), "'/it'\\''s here'")
        XCTAssertEqual(finderUniqueName(candidate: "a.txt", existing: ["a.txt"]), "a 2.txt")
    }

    func testBatchRenameDraftsRoundTrip() {
        let steps: [RenameStep] = [
            .findReplace(find: "a", replace: "b", caseSensitive: true), .prefix(text: "p"), .suffix(text: "s"),
            .number(start: 3, step: 2, digits: 4, position: .start, separator: "_"), .changeCase(mode: .title),
            .trim, .removeCharacters(characters: "xyz"), .replaceExtension(extension: "md"),
        ]
        XCTAssertEqual(steps.map { StepDraft($0).asStep }, steps)
    }

    func testChecksumsQuarantineAndAliasesWork() throws {
        let world = try TestWorld()
        defer { world.cleanUp() }
        let file = world.folder.appendingPathComponent("abc.txt")
        try Data("abc".utf8).write(to: file)
        XCTAssertEqual(try FolderTools.checksum(of: file), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "the well-known SHA-256 of “abc”")
        XCTAssertThrowsError(try FolderTools.checksum(of: world.folder.appendingPathComponent("missing")))

        // The download warning goes, and only that.
        XCTAssertEqual(setxattr(file.path, "com.apple.quarantine", "0081;00000000;Test;", 19, 0, 0), 0)
        XCTAssertEqual(setxattr(file.path, "user.keep", "yes", 3, 0, 0), 0)
        _ = try FolderTools.removeQuarantine([file])
        XCTAssertEqual(getxattr(file.path, "com.apple.quarantine", nil, 0, 0, 0), -1, "the warning is gone")
        XCTAssertGreaterThan(getxattr(file.path, "user.keep", nil, 0, 0, 0), 0, "other marks stay")

        // An alias is made beside the file and points back at it; a second one gets another name.
        let first = try FolderTools.makeAliases([file])
        let second = try FolderTools.makeAliases([file])
        let names = try FileManager.default.contentsOfDirectory(atPath: world.folder.path).sorted()
        XCTAssertTrue(names.contains("abc.txt alias") && names.contains("abc.txt alias 2"), "\(names)")
        XCTAssertEqual(first.reveal.count, 1)
        XCTAssertEqual(second.reveal.count, 1)
        var stale = false
        let data = try URL.bookmarkData(withContentsOf: first.reveal[0])
        XCTAssertEqual(try URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale).standardizedFileURL.path, file.standardizedFileURL.path)
    }

    func testSelectedItemsAreRefusedInSystemFoldersEvenThroughLinks() throws {
        let world = try TestWorld()
        defer { world.cleanUp() }
        XCTAssertTrue(FinderService.isAllowedItem(world.folder.appendingPathComponent("a.txt").path))
        XCTAssertFalse(FinderService.isAllowedItem("/System/Library/CoreServices"))
        XCTAssertFalse(FinderService.isAllowedItem("/usr/bin/true"))
        XCTAssertFalse(FinderService.isAllowedItem("/"))
        let link = world.folder.appendingPathComponent("to-system")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/System/Library")
        XCTAssertFalse(FinderService.isAllowedItem(link.path), "a link into a system folder is treated as that folder")
    }

    func testRequestFoldersAreCheckedLikeSelectedItems() throws {
        let world = try TestWorld()
        defer { world.cleanUp() }
        XCTAssertEqual(FinderService.safeTarget(world.folder.path), world.folder.standardizedFileURL.path)
        XCTAssertNil(FinderService.safeTarget("relative/folder"), "only absolute paths")
        XCTAssertNil(FinderService.safeTarget("/"), "never the root")
        XCTAssertNil(FinderService.safeTarget("/System/Library"), "never the system's own folders")
        XCTAssertNil(FinderService.safeTarget("/usr/bin"))
        XCTAssertNil(FinderService.safeTarget(world.folder.appendingPathComponent("missing").path), "it must exist")
        let file = world.folder.appendingPathComponent("a.txt")
        FileManager.default.createFile(atPath: file.path, contents: Data())
        XCTAssertNil(FinderService.safeTarget(file.path), "it must be a folder")
        XCTAssertEqual(FinderService.safeTarget(world.folder.path + "/../" + world.folder.lastPathComponent), world.folder.standardizedFileURL.path, "dots are resolved")
    }

    func testTheRunnerCreatesNamesThatDoNotClashAndNeverOverwrites() throws {
        let world = try TestWorld()
        defer { world.cleanUp() }
        let store = FinderStore(core: world.core, menuFile: world.folder.appendingPathComponent("m.json"), defaults: UserDefaults(suiteName: "kriya-tests-\(UUID().uuidString)")!)
        let runner = FileActionRunner(store: store)
        let item = try XCTUnwrap(store.item("new-file"))
        runner.run(item, paths: [], target: world.folder.path, child: nil)
        runner.run(item, paths: [], target: world.folder.path, child: nil)
        let done = expectation(description: "created")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { done.fulfill() }
        wait(for: [done], timeout: 3)
        let names = try FileManager.default.contentsOfDirectory(atPath: world.folder.path)
        XCTAssertTrue(names.contains("untitled.txt"))
        XCTAssertTrue(names.contains("untitled 2.txt"))
    }
}

final class ClipboardTests: XCTestCase {
    private func newClip(_ text: String, app: String? = "com.apple.TextEdit") -> NewClip {
        NewClip(text: text, rich: nil, richFormat: nil, image: nil, imageFormat: nil, imageWidth: nil, imageHeight: nil, files: [], sourceApp: app, concealed: false)
    }

    func testCopiesAreRecordedSearchedPinnedAndDeduplicated() throws {
        let world = try TestWorld()
        defer { world.cleanUp() }
        let store = ClipboardStore(core: world.core)
        XCTAssertEqual(store.record(newClip("hello world"))?.status, .stored)
        XCTAssertEqual(store.record(newClip("hello world"))?.status, .duplicate)
        XCTAssertEqual(store.search("hello").count, 1)
        let id = try XCTUnwrap(store.search("hello").first?.id)
        store.setPinned(id, true)
        XCTAssertTrue(try XCTUnwrap(store.item(id)).pinned)
        store.setTags(id, ["Work", "work"])
        XCTAssertEqual(store.item(id)?.tags, ["work"])
    }

    func testSecretsExcludedAppsAndPauseAreNotRecorded() throws {
        let world = try TestWorld()
        defer { world.cleanUp() }
        let store = ClipboardStore(core: world.core)
        XCTAssertEqual(store.record(newClip("4111 1111 1111 1111"))?.skipped, .looksSensitive)
        XCTAssertEqual(store.record(newClip("hunter2 secret", app: "com.1password.1password"))?.skipped, .excludedApp)
        store.updateConfig { $0.paused = true }
        XCTAssertEqual(store.record(newClip("anything"))?.skipped, .paused)
        XCTAssertTrue(store.search("").isEmpty)
        XCTAssertEqual(clipEarlySkip(config: store.config, sourceApp: nil, concealed: false), .paused)
        XCTAssertTrue(clipConcealedTypes().contains("org.nspasteboard.ConcealedType"))
    }

    func testSnippetsSurviveClearingAndRoundTripThroughAFile() throws {
        let world = try TestWorld()
        defer { world.cleanUp() }
        let store = ClipboardStore(core: world.core)
        store.addSnippet(title: "Sig", text: "Best,\nMe")
        _ = store.record(newClip("temporary"))
        XCTAssertEqual(store.clear(keepPinned: true, keepSnippets: true), 1)
        XCTAssertEqual(store.search("").count, 1)

        let file = world.folder.appendingPathComponent("snippets.json")
        try store.exportSnippets(store.search("").map(\.id), to: file)
        let other = try TestWorld()
        defer { other.cleanUp() }
        let target = ClipboardStore(core: other.core)
        let summary = try target.importSnippets(from: file)
        XCTAssertEqual(summary.added, 1)
        XCTAssertEqual(target.search("best").first?.title, "Sig")
    }

    func testTheMonitorReadsTextRichTextAndFilesFromAPasteboard() {
        let board = NSPasteboard(name: NSPasteboard.Name("kriya-test-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.clearContents()
        board.setString("plain words", forType: .string)
        board.setData(Data("{\\rtf1 plain words}".utf8), forType: .rtf)
        let rich = ClipboardMonitor.read(board, source: "app", config: defaultClipConfig())
        XCTAssertEqual(rich?.text, "plain words")
        XCTAssertEqual(rich?.richFormat, "rtf")
        var noRich = defaultClipConfig(); noRich.captureRichText = false
        XCTAssertNil(ClipboardMonitor.read(board, source: nil, config: noRich)?.rich)

        board.clearContents()
        board.writeObjects([URL(fileURLWithPath: "/tmp/example.txt") as NSURL])
        XCTAssertEqual(ClipboardMonitor.read(board, source: nil, config: defaultClipConfig())?.files, ["/tmp/example.txt"])
        board.clearContents()
        XCTAssertNil(ClipboardMonitor.read(board, source: nil, config: defaultClipConfig()))
    }
}

final class SelectionBarTests: XCTestCase {
    func testTextToolsRunThroughTheCore() throws {
        XCTAssertEqual(try textApply(op: .titleCase, text: "hello big world"), "Hello Big World")
        XCTAssertEqual(try textApplyAll(ops: [.trim, .removeDuplicateLines, .sortLines(descending: false, caseSensitive: false, numeric: false)], text: " b\na\nb "), "a\nb")
        XCTAssertThrowsError(try textApply(op: .jsonFormat, text: "{nope"))
        XCTAssertNotNil(textJsonValidate(text: "{\"a\":"))
        XCTAssertNil(textJsonValidate(text: "{\"a\":1}"))
        XCTAssertEqual(try textUrlTemplate(template: "https://x.test/?q={text}", text: "a b"), "https://x.test/?q=a%20b")
        XCTAssertNotNil(textUrlTemplateProblem(template: "javascript:{text}"))
        XCTAssertEqual(textFindUrls(text: "go to example.com now"), ["https://example.com"])
    }

    func testActionsFollowTheSelectionAndTheApp() throws {
        let world = try TestWorld()
        defer { world.cleanUp() }
        let store = SelectionStore(core: world.core)
        let (actions, config) = store.current
        let editable = selectionActionsFor(actions: actions, config: config, appId: "com.apple.TextEdit", editable: true, text: "some words")
        XCTAssertTrue(editable.contains("cut") && editable.contains("uppercase"))
        let readOnly = selectionActionsFor(actions: actions, config: config, appId: "com.apple.Safari", editable: false, text: "some words")
        XCTAssertFalse(readOnly.contains("cut"))
        XCTAssertTrue(selectionActionsFor(actions: actions, config: config, appId: "com.1password.1password", editable: true, text: "x").isEmpty)
        XCTAssertEqual(selectionBehavior(config: config, appId: nil).allowCopyFallback, true, "the copy fallback is on by default so the bar also works in apps that do not expose their selection")
    }

    func testScriptsMustBeApprovedAndApprovalBelongsToTheExactText() throws {
        let world = try TestWorld()
        defer { world.cleanUp() }
        let approvals = ScriptApprovals(core: world.core)
        XCTAssertFalse(approvals.isApproved(language: "shell", source: "echo hi"))
        try world.core.approveScript(fingerprint: scriptFingerprint(language: "shell", source: "echo hi"), label: "Greeter", now: 1)
        approvals.reload()
        XCTAssertTrue(approvals.isApproved(language: "shell", source: "echo hi"))
        XCTAssertFalse(approvals.isApproved(language: "shell", source: "echo hi; rm -rf ~"))
        XCTAssertEqual(approvals.approved.count, 1)
        approvals.revoke(approvals.approved[0].fingerprint)
        XCTAssertTrue(approvals.approved.isEmpty)
    }

    func testCustomActionsRoundTripThroughAPackage() throws {
        let world = try TestWorld()
        defer { world.cleanUp() }
        let store = SelectionStore(core: world.core)
        store.upsert(SelectionAction(id: "mine", title: "Shout", symbol: "star", kind: .transform(ops: [.uppercase], copyOnly: true), enabled: true, applies: .anything, appIds: []))
        let file = world.folder.appendingPathComponent("actions.json")
        try store.exportActions(["mine"], name: "Mine", to: file)
        store.delete("mine")
        let added = try store.importActions(from: file)
        XCTAssertEqual(added.map(\.title), ["Shout"])
        XCTAssertNotNil(store.action("mine"))
    }

    func testTheBarsLookAndBehaviorAreSettings() throws {
        let world = try TestWorld()
        defer { world.cleanUp() }
        let store = SelectionStore(core: world.core)
        store.updateConfig { $0.theme = .dark; $0.activationDelayMs = 400; $0.maxVisible = 5 }
        store.flushPendingSaves()
        store.reload()
        XCTAssertEqual(store.config.theme, .dark)
        XCTAssertEqual(store.config.activationDelayMs, 400)
        XCTAssertEqual(store.config.maxVisible, 5)
    }
}

final class KeyboardAndExpansionTests: XCTestCase {
    private func context(_ now: Int64) -> TemplateContext {
        TemplateContext(now: now, utcOffsetSeconds: 0, clipboard: "CLIP", selection: nil, appName: nil, uuid: nil, prompts: [])
    }

    func testSnippetsRenderPlaceholders() {
        let out = renderSnippet(body: "On {date:yyyy-MM-dd}: {clipboard}{cursor}!", context: context(0))
        XCTAssertEqual(out.text, "On 1970-01-01: CLIP!")
        XCTAssertEqual(out.cursorBack, 1)
        XCTAssertEqual(renderSnippet(body: "{prompt:Name}", context: context(0)).promptsNeeded, ["Name"])
        XCTAssertEqual(snippetFormatTime(timestamp: 86_400, utcOffsetSeconds: 0, format: "EEE d MMM"), "Fri 2 Jan")
    }

    func testTypedAbbreviationsAreFound() throws {
        let matcher = ExpansionMatcher()
        let now: Int64 = 1
        matcher.setSnippets(snippets: [ExpansionSnippet(id: "a", title: "BRB", abbreviation: "brb", body: "be right back", category: nil, favorite: false, enabled: true, appIds: [], caseSensitive: false, expandOn: .delimiter, useCount: 0, createdAt: now, updatedAt: now)])
        XCTAssertNil(matcher.feed(character: "b", appId: nil))
        XCTAssertNil(matcher.feed(character: "r", appId: nil))
        XCTAssertNil(matcher.feed(character: "b", appId: nil))
        let hit = try XCTUnwrap(matcher.feed(character: " ", appId: nil))
        XCTAssertEqual(hit.snippetId, "a")
        XCTAssertEqual(hit.deleteCount, 4)
        XCTAssertEqual(hit.trailing, " ")
    }

    func testSnippetsAreStoredSearchedAndRefusedWhenTheAbbreviationClashes() throws {
        let world = try TestWorld()
        defer { world.cleanUp() }
        let store = KeyboardStore(core: world.core)
        var first = store.newSnippet()
        first.title = "Sign-off"; first.abbreviation = ";sig"; first.body = "Kind regards,\n{cursor}"
        XCTAssertTrue(store.saveSnippet(first))
        var clash = store.newSnippet()
        clash.title = "Other"; clash.abbreviation = ";SIG"; clash.body = "x"
        XCTAssertFalse(store.saveSnippet(clash))
        XCTAssertNotNil(store.lastError)
        XCTAssertEqual(store.search("regards").count, 1)
        store.toggleFavorite(first.id)
        XCTAssertEqual(store.search("", favoritesOnly: true).count, 1)
        XCTAssertEqual(store.categories, [])
    }

    func testShortcutsAreCheckedAgainstTheSystemAndEachOtherAndScopedToApps() throws {
        let world = try TestWorld()
        defer { world.cleanUp() }
        let store = KeyboardStore(core: world.core)
        let quit = KeyShortcut(id: "q", name: "Quit", keyCode: 12, modifiers: KeyModifiers.command, scope: .global, target: .command(command: "palette.open"), enabled: true)
        XCTAssertTrue(store.checkShortcut(quit).contains { $0.blocking })
        store.saveShortcut(quit)
        XCTAssertNotNil(store.lastError)

        let mail = KeyShortcut(id: "m", name: "In Mail", keyCode: 40, modifiers: KeyModifiers.option, scope: .onlyApps(appIds: ["com.apple.mail"]), target: .command(command: "window.maximize"), enabled: true)
        store.saveShortcut(mail)
        XCTAssertNil(store.lastError)
        XCTAssertNotNil(store.shortcut(keyCode: 40, modifiers: KeyModifiers.option, app: "com.apple.mail"))
        XCTAssertNil(store.shortcut(keyCode: 40, modifiers: KeyModifiers.option, app: "com.apple.Safari"))
        XCTAssertNil(store.shortcut(keyCode: 41, modifiers: KeyModifiers.option, app: "com.apple.mail"))
        let global = KeyShortcut(id: "g", name: "Anywhere", keyCode: 40, modifiers: KeyModifiers.option, scope: .global, target: .command(command: "window.center"), enabled: true)
        XCTAssertTrue(store.checkShortcut(global).contains { $0.kind == .duplicate })
        store.reservedProvider = { [ReservedKey(keyCode: 5, modifiers: KeyModifiers.option, owner: "Windows: Left half")] }
        let taken = KeyShortcut(id: "t", name: "Taken", keyCode: 5, modifiers: KeyModifiers.option, scope: .global, target: .command(command: "window.center"), enabled: true)
        store.saveShortcut(taken)
        XCTAssertTrue(store.lastError?.contains("Windows") ?? false)
    }

    func testTheCommandLauncherRanksByWhatYouType() {
        let items = [
            SwitcherItem(id: "a", appName: "Windows", title: "Window: Left half", lastUsed: 0),
            SwitcherItem(id: "b", appName: "Clipboard", title: "Open clipboard history", lastUsed: 0),
        ]
        XCTAssertEqual(windowRankSwitcher(items: items, query: "clip"), ["b"])
        XCTAssertEqual(windowRankSwitcher(items: items, query: "left"), ["a"])
    }

    func testSettingsPanesAreReachableFromTheKeyboardInOrder() {
        XCTAssertEqual(SettingsPane.allCases.first, .features)
        XCTAssertTrue(SettingsPane.allCases.count >= 9, "⌘1 to ⌘9 each open a pane")
        XCTAssertEqual(Set(SettingsPane.allCases.map(\.rawValue)).count, SettingsPane.allCases.count)
    }

    func testSidebarGroupsFollowTheOrderOfThePanes() {
        let groups = SettingsPane.allCases.map(\.group)
        let order = SettingsPaneGroup.allCases
        XCTAssertEqual(groups, groups.sorted { order.firstIndex(of: $0)! < order.firstIndex(of: $1)! }, "each group's panes sit together")
        for feature in FeatureId.all { XCTAssertEqual(feature.pane.feature, feature) }
    }

    func testSidebarSearchFindsPanesByTitleAndKeyword() {
        XCTAssertTrue(SettingsPane.mouse.matches("scroll"))
        XCTAssertTrue(SettingsPane.selection.matches("popclip"))
        XCTAssertTrue(SettingsPane.finder.matches("right click"))
        XCTAssertFalse(SettingsPane.about.matches("scroll"))
        XCTAssertTrue(SettingsPane.about.matches("  "), "an empty search shows everything")
    }
}

final class AutomationTests: XCTestCase {
    private func make() throws -> (TestWorld, AutomationEngine) {
        let world = try TestWorld()
        let engine = AutomationEngine(store: WorkflowStore(core: world.core))
        engine.context = world.makeContext()
        return (world, engine)
    }

    private func workflow(_ engine: AutomationEngine, _ name: String, _ steps: [StepKind], timeout: UInt32 = 30, enabled: Bool = true) throws -> Workflow {
        var w = engine.store.newWorkflow()
        w.name = name
        w.enabled = enabled
        w.timeoutSeconds = timeout
        w.steps = steps.map { engine.store.newStep($0) }
        return try XCTUnwrap(engine.store.save(w))
    }

    private func run(_ engine: AutomationEngine, _ w: Workflow, input: String = "", test: Bool = true, dry: Bool = false, approved: Bool = false) async -> WorkflowRun {
        await engine.execute(w, source: "Test", input: input, depth: 0, test: test, dryRun: dry, approvedForTest: approved, progress: nil)
    }

    func testStepsRunInOrderAndTransformTheText() async throws {
        let (world, engine) = try make()
        defer { world.cleanUp() }
        let w = try workflow(engine, "Tidy", [.textTransform(ops: [.trim, .uppercase]), .delay(ms: 1), .notify(message: "done")])
        let result = await run(engine, w, input: "  hello ")
        XCTAssertEqual(result.status, .succeeded)
        XCTAssertEqual(result.steps.map(\.status), [.ok, .ok, .ok])
        XCTAssertEqual(result.revision, 1)
    }

    func testADryRunPlansEverythingAndDoesNothing() async throws {
        let (world, engine) = try make()
        defer { world.cleanUp() }
        let w = try workflow(engine, "Plan", [.script(language: .shell, source: "touch /tmp/kriya-should-not-exist-\(UUID().uuidString)"), .system(op: .sleep, value: 0)])
        let result = await run(engine, w, dry: true)
        XCTAssertEqual(result.steps.map(\.status), [.planned, .planned])
        XCTAssertEqual(result.status, .succeeded)
        XCTAssertTrue(result.steps[0].message?.hasPrefix("Would") ?? false)
    }

    func testARiskyWorkflowIsBlockedUntilAuthorized() async throws {
        let (world, engine) = try make()
        defer { world.cleanUp() }
        let w = try workflow(engine, "Risky", [.script(language: .shell, source: "echo hi")])
        XCTAssertTrue(workflowNeedsAuthorization(workflow: w))
        let blocked = await run(engine, w, test: false)
        XCTAssertEqual(blocked.status, .blocked)
        XCTAssertTrue(blocked.steps.isEmpty, "nothing ran")

        engine.store.authorize(w.id)
        let allowed = await run(engine, try XCTUnwrap(engine.store.workflow(w.id)), test: false)
        XCTAssertEqual(allowed.status, .succeeded)

        var edited = try XCTUnwrap(engine.store.workflow(w.id))
        edited.steps[0].kind = .script(language: .shell, source: "echo changed")
        let saved = try XCTUnwrap(engine.store.save(edited))
        XCTAssertTrue(workflowNeedsAuthorization(workflow: saved), "editing a script takes the authorization away")
    }

    func testStepConditionsSkipSteps() async throws {
        let (world, engine) = try make()
        defer { world.cleanUp() }
        var w = engine.store.newWorkflow()
        w.name = "Conditional"; w.enabled = true
        var guarded = engine.store.newStep(.notify(message: "only in a made-up app"))
        guarded.when = ConditionGroup(mode: .all, items: [ConditionItem(kind: .frontApp(appIds: ["com.example.nonexistent"]), negate: false)])
        w.steps = [guarded, engine.store.newStep(.notify(message: "always"))]
        let saved = try XCTUnwrap(engine.store.save(w))
        let result = await run(engine, saved)
        XCTAssertEqual(result.steps.map(\.status), [.skipped, .ok])
    }

    func testAFailingStepStopsOrCarriesOnAsConfigured() async throws {
        let (world, engine) = try make()
        defer { world.cleanUp() }
        var w = engine.store.newWorkflow()
        w.name = "Fails"; w.enabled = true
        var failing = engine.store.newStep(.textTransform(ops: [.jsonFormat]))
        failing.onError = .stop
        w.steps = [failing, engine.store.newStep(.notify(message: "after"))]
        let stopped = await run(engine, try XCTUnwrap(engine.store.save(w)), input: "not json")
        XCTAssertEqual(stopped.status, .failed)
        XCTAssertEqual(stopped.steps.count, 1)
        XCTAssertTrue(stopped.error?.contains("Step 1") ?? false)

        w.steps[0].onError = .continue
        let carried = await run(engine, try XCTUnwrap(engine.store.save(w)), input: "not json")
        XCTAssertEqual(carried.steps.map(\.status), [.failed, .ok])
    }

    func testTheTimeLimitEndsALongWorkflow() async throws {
        let (world, engine) = try make()
        defer { world.cleanUp() }
        let w = try workflow(engine, "Slow", [.delay(ms: 5000), .notify(message: "never")], timeout: 1)
        let result = await run(engine, w)
        XCTAssertEqual(result.status, .timedOut)
        XCTAssertFalse(result.steps.contains { $0.title.contains("never") })
    }

    func testARunCanBeStopped() async throws {
        let (world, engine) = try make()
        defer { world.cleanUp() }
        let w = try workflow(engine, "Stoppable", [.delay(ms: 30_000), .notify(message: "never")], timeout: 60)
        async let result = run(engine, w)
        try await Task.sleep(nanoseconds: 300_000_000)
        engine.cancelAll()
        let finished = await result
        XCTAssertEqual(finished.status, .cancelled)
    }

    func testChainedWorkflowsRunAndLoopsAreRefusedWhenSaved() async throws {
        let (world, engine) = try make()
        defer { world.cleanUp() }
        let child = try workflow(engine, "Child", [.notify(message: "child ran")])
        let parent = try workflow(engine, "Parent", [.runWorkflow(workflowId: child.id)])
        let chained = await run(engine, parent)
        XCTAssertEqual(chained.status, .succeeded)
        var loop = try XCTUnwrap(engine.store.workflow(child.id))
        loop.steps = [engine.store.newStep(.runWorkflow(workflowId: parent.id))]
        XCTAssertNil(engine.store.save(loop))
        XCTAssertTrue(engine.store.lastError?.contains("loop") ?? false)
    }

    func testARunawayWorkflowIsRefused() async throws {
        let (world, engine) = try make()
        defer { world.cleanUp() }
        let w = try workflow(engine, "Fast", [.notify(message: "x")])
        var statuses: [RunStatus] = []
        for _ in 0..<12 { statuses.append(await run(engine, w, test: false).status) }
        XCTAssertTrue(statuses.prefix(8).allSatisfy { $0 == .succeeded })
        XCTAssertTrue(statuses.suffix(2).allSatisfy { $0 == .blocked }, "more than 8 starts in 10 seconds are refused")
    }

    func testHistoryRecordsRunsWithoutTheirText() async throws {
        let (world, engine) = try make()
        defer { world.cleanUp() }
        let w = try workflow(engine, "Logged", [.textTransform(ops: [.uppercase])])
        _ = await run(engine, w, input: "secret words")
        try await Task.sleep(nanoseconds: 200_000_000)
        engine.store.reloadRuns()
        let runs = engine.store.runs
        XCTAssertEqual(runs.first?.workflowName, "Logged")
        let encoded = String(describing: runs)
        XCTAssertFalse(encoded.contains("secret words") || encoded.contains("SECRET WORDS"))
    }

    func testPackagesRoundTripAndNothingImportedRunsOrIsAuthorized() throws {
        let (world, engine) = try make()
        defer { world.cleanUp() }
        let w = try workflow(engine, "Shared", [.script(language: .shell, source: "echo hi")])
        engine.store.authorize(w.id)
        let file = world.folder.appendingPathComponent("workflows.json")
        try engine.store.export([w.id], to: file)
        let (otherWorld, other) = try make()
        defer { otherWorld.cleanUp() }
        let added = try other.store.importWorkflows(from: file)
        XCTAssertEqual(added.count, 1)
        XCTAssertFalse(added[0].enabled)
        XCTAssertTrue(workflowNeedsAuthorization(workflow: added[0]))
    }

    func testTheCatalogDrivesTheBuilder() {
        XCTAssertGreaterThanOrEqual(workflowStepCatalog().count, 25)
        XCTAssertTrue(workflowStepCatalog().contains { $0.risk == .needsAuthorization })
        XCTAssertGreaterThanOrEqual(workflowTriggerCatalog().count, 13)
        XCTAssertEqual(workflowMaxChainDepth(), 5)
    }
}


final class EventDispatchTests: XCTestCase {
    private func event(_ type: CGEventType) -> CGEvent {
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: .zero, mouseButton: .left)!
    }

    func testFeaturesSeeAnEventInOrderAndPassingChangesNothing() {
        var seen: [String] = []
        let result = EventMonitor.dispatch(
            handlers: [{ _, _ in seen.append("a"); return .passThrough }, { _, _ in seen.append("b"); return .passThrough }],
            type: .leftMouseDown, event: event(.leftMouseDown)
        )
        XCTAssertEqual(seen, ["a", "b"])
        XCTAssertFalse(result.dropped)
        XCTAssertNil(result.replacement)
    }

    func testOnceAFeatureTakesAPressTheLaterOnesDoNotActOnIt() {
        var seen: [String] = []
        let result = EventMonitor.dispatch(
            handlers: [{ _, _ in seen.append("a"); return .drop }, { _, _ in seen.append("b"); return .passThrough }],
            type: .leftMouseDown, event: event(.leftMouseDown)
        )
        XCTAssertEqual(seen, ["a"])
        XCTAssertTrue(result.dropped)
    }

    func testTheEndOfAnInteractionStillReachesEveryFeature() {
        for type in [CGEventType.leftMouseUp, .rightMouseUp, .otherMouseUp, .keyUp, .flagsChanged] {
            var seen: [String] = []
            let result = EventMonitor.dispatch(
                handlers: [{ _, _ in seen.append("a"); return .drop }, { _, _ in seen.append("b"); return .passThrough }, { _, _ in seen.append("c"); return .drop }],
                type: type, event: event(.leftMouseUp)
            )
            XCTAssertEqual(seen, ["a", "b", "c"], "\(type) must reach every feature so none is left waiting")
            XCTAssertTrue(result.dropped)
        }
    }

    func testDraggingAndKeyPressesStopAtTheFirstFeatureThatTakesThem() {
        for type in [CGEventType.leftMouseDragged, .keyDown, .scrollWheel, .mouseMoved] {
            var seen: [String] = []
            _ = EventMonitor.dispatch(
                handlers: [{ _, _ in seen.append("a"); return .drop }, { _, _ in seen.append("b"); return .passThrough }],
                type: type, event: event(.leftMouseDown)
            )
            XCTAssertEqual(seen, ["a"], "\(type)")
        }
    }

    func testAFeatureCanReplaceTheEventForTheNextOne() {
        let swapped = event(.rightMouseDown)
        var received: CGEvent?
        let result = EventMonitor.dispatch(
            handlers: [{ _, _ in .replace(swapped) }, { _, e in received = e; return .passThrough }],
            type: .leftMouseDown, event: event(.leftMouseDown)
        )
        XCTAssertTrue(received === swapped || received?.type == .rightMouseDown)
        XCTAssertNotNil(result.replacement)
        XCTAssertFalse(result.dropped)
    }
}


final class CapsLockMappingTests: XCTestCase {
    private let ours: [String: Any] = ["HIDKeyboardModifierMappingSrc": 30064771129, "HIDKeyboardModifierMappingDst": 30064771181]
    private let theirs: [String: Any] = ["HIDKeyboardModifierMappingSrc": 30064771300, "HIDKeyboardModifierMappingDst": 30064771301]

    private func keys(_ list: [[String: Any]]) -> [Int64] {
        list.compactMap { ($0["HIDKeyboardModifierMappingSrc"] as? NSNumber)?.int64Value }
    }

    func testTurningTheSwapOnKeepsOtherMappingsAndAddsOurs() {
        let result = RemapService.merged([theirs], capsOn: true)
        XCTAssertEqual(keys(result), [30064771300, 30064771129])
    }

    func testTurningItOffRemovesOnlyOurEntry() {
        let result = RemapService.merged([theirs, ours], capsOn: false)
        XCTAssertEqual(keys(result), [30064771300])
        XCTAssertEqual(keys(RemapService.merged([], capsOn: false)), [], "nothing there, nothing to remove")
    }

    func testTurningItOnTwiceNeverDoublesOurEntry() {
        let once = RemapService.merged([theirs], capsOn: true)
        let twice = RemapService.merged(once, capsOn: true)
        XCTAssertEqual(keys(twice), [30064771300, 30064771129])
    }

    func testHidutilOutputIsReadForTheFirstServiceThatHasMappings() {
        let output = """
        RegistryID  Key                   Value
        100000802   UserKeyMapping   (
                {
                HIDKeyboardModifierMappingDst = 30064771181;
                HIDKeyboardModifierMappingSrc = 30064771129;
            }
        )
        1000007d7   UserKeyMapping   (
                {
                HIDKeyboardModifierMappingDst = 30064771181;
                HIDKeyboardModifierMappingSrc = 30064771129;
            }
        )
        """
        var received = ""
        let parsed = RemapService.parseMappings(output) { plist in
            received = plist
            return "[{\"HIDKeyboardModifierMappingSrc\":30064771129,\"HIDKeyboardModifierMappingDst\":30064771181}]"
        }
        XCTAssertEqual(parsed.map(keys), [30064771129])
        XCTAssertTrue(received.hasPrefix("(") && received.hasSuffix(")"), "one service's list is handed on, brackets included")
        XCTAssertFalse(received.contains("1000007d7"), "only the first service")
    }

    func testNothingSetIsAnEmptyListAndUnreadableOutputIsRefused() {
        let none = "RegistryID  Key                   Value\n100000802   UserKeyMapping   (null)\n"
        XCTAssertEqual(RemapService.parseMappings(none) { _ in "[]" }?.count, 0)
        let broken = "100000802   UserKeyMapping   (\n  {\n"
        XCTAssertNil(RemapService.parseMappings(broken) { _ in "[]" }, "a list that never closes is not read")
        XCTAssertNil(RemapService.parseMappings("x   UserKeyMapping   (\n)") { _ in nil }, "when the converter fails, nothing is changed")
    }
}

final class StaleFileTests: XCTestCase {
    func testOnlyBigFilesNobodyTouchedForALongTimeAreListedBiggestFirst() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let day: TimeInterval = 86_400
        func file(_ name: String, mb: Int64, modifiedDaysAgo: Double?, openedDaysAgo: Double? = nil) -> FoundFile {
            FoundFile(path: "/x/\(name)", size: mb * 1_048_576, modified: modifiedDaysAgo.map { now.addingTimeInterval(-$0 * day) }, accessed: openedDaysAgo.map { now.addingTimeInterval(-$0 * day) })
        }
        let files = [
            file("old-small", mb: 1, modifiedDaysAgo: 900),
            file("old-big", mb: 500, modifiedDaysAgo: 800),
            file("old-medium", mb: 50, modifiedDaysAgo: 400),
            file("recent", mb: 900, modifiedDaysAgo: 3),
            file("old-but-opened-lately", mb: 300, modifiedDaysAgo: 900, openedDaysAgo: 10),
            file("no-dates", mb: 700, modifiedDaysAgo: nil),
        ]
        XCTAssertEqual(DuplicateFinder.stale(files, olderThanDays: 365, now: now).map(\.name), ["old-big", "old-medium"])
        XCTAssertEqual(DuplicateFinder.stale(files, olderThanDays: 700, now: now).map(\.name), ["old-big"])
        XCTAssertEqual(DuplicateFinder.stale(files, olderThanDays: 365, now: now, count: 1).map(\.name), ["old-big"])
    }
}

final class CaptureNamingAndDuplicateRuleTests: XCTestCase {
    func testNamesCarryTheAppAndNeverClash() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let plain = CaptureNaming.fileName(pattern: nil, date: date, app: "Safari", mode: "capture", ext: "png")
        XCTAssertTrue(plain.hasPrefix("Kriya Capture ") && plain.hasSuffix(".png"))
        let named = CaptureNaming.fileName(pattern: "{app} {date} {time}", date: date, app: "Safari", mode: "capture", ext: "png")
        XCTAssertTrue(named.hasPrefix("Safari 2023-"))
        XCTAssertEqual(CaptureNaming.fileName(pattern: "{app} {time}", date: date, app: "A/B:C", mode: "m", ext: "png").prefix(4), "ABC ")
        let taken = CaptureNaming.fileName(pattern: "{app} {time}", date: date, app: "X", mode: "m", ext: "png") { $0.hasSuffix(" 2.png") ? false : true }
        XCTAssertTrue(taken.hasSuffix(" 2.png"), "a name in use gets a number")
        XCTAssertEqual(CaptureNaming.fileName(pattern: "shot {n}", date: date, app: nil, mode: "m", ext: "png") { $0 == "shot 1.png" }, "shot 2.png")
    }

    func testBadPatternsAreExplainedAndFallBack() {
        XCTAssertNotNil(CaptureNaming.problem(""))
        XCTAssertNotNil(CaptureNaming.problem("fixed name"))
        XCTAssertNotNil(CaptureNaming.problem("a/b {time}"))
        XCTAssertNil(CaptureNaming.problem("{app} {time}"))
        let name = CaptureNaming.fileName(pattern: "fixed", date: Date(), app: nil, mode: "m", ext: "png")
        XCTAssertTrue(name.hasPrefix("Kriya Capture "), "a bad pattern uses the default")
    }

    func testOnlyLaterCopiesAreMarkedAsDuplicates() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        func file(_ name: String, size: Int64, age: TimeInterval) -> FolderFile { FolderFile(name: name, size: size, modified: base.addingTimeInterval(age)) }
        let files = [file("report.pdf", size: 100, age: 0), file("report (1).pdf", size: 100, age: 50), file("report copy.pdf", size: 100, age: 90),
                     file("different.pdf", size: 100, age: 10), file("alone.txt", size: 7, age: 5), file("empty1", size: 0, age: 1), file("empty2", size: 0, age: 2)]
        let sums = ["report.pdf": "A", "report (1).pdf": "A", "report copy.pdf": "A", "different.pdf": "B"]
        let copies = FolderRuleEngine.duplicateNames(files) { sums[$0.name] }
        XCTAssertEqual(copies, ["report (1).pdf", "report copy.pdf"], "the oldest is the original; same size with other contents is not a copy; empty files are ignored")
    }

    func testARuleWithTheCopyConditionOnlyMatchesMarkedFiles() {
        let now = Date()
        let rule = FolderRule(name: "Trash copies", enabled: true, folder: "/tmp/x", conditions: [.isDuplicate], action: .trash)
        var copy = FolderFile(name: "a (1).pdf", size: 5, modified: now.addingTimeInterval(-600))
        copy.isDuplicate = true
        let original = FolderFile(name: "a.pdf", size: 5, modified: now.addingTimeInterval(-600))
        XCTAssertTrue(FolderRuleEngine.matches(rule, copy, now: now))
        XCTAssertFalse(FolderRuleEngine.matches(rule, original, now: now))
        XCTAssertTrue(FolderCondition.isDuplicate.summary.contains("copy"))
    }
}

final class FinderMetadataTests: XCTestCase {
    func testTagsAreParsedAndMergedWithoutRepeats() {
        XCTAssertEqual(FinderMetadata.parseTags(" Work, receipts ,work\n, ,Tax"), ["Work", "receipts", "Tax"])
        XCTAssertEqual(FinderMetadata.merged(existing: ["Work"], adding: ["work", "Tax"]), ["Work", "Tax"])
        XCTAssertTrue(FinderMetadata.parseTags(String(repeating: "x", count: 80)).isEmpty, "a very long name is not a tag")
    }

    func testACommentCanBeWrittenReadAndRemoved() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("kriya-comment-\(UUID().uuidString).txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(FinderMetadata.comment(of: file), "")
        _ = try FinderMetadata.setComment("For the tax return", on: [file])
        XCTAssertEqual(FinderMetadata.comment(of: file), "For the tax return")
        _ = try FinderMetadata.setComment("", on: [file])
        XCTAssertEqual(FinderMetadata.comment(of: file), "")
    }

    func testTagsCanBeAddedToAFile() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("kriya-tags-\(UUID().uuidString).txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        _ = try FinderMetadata.addTags(["Work"], to: [file])
        _ = try FinderMetadata.addTags(["Tax", "work"], to: [file])
        XCTAssertEqual(FinderMetadata.tags(of: file), ["Work", "Tax"])
    }
}

final class AuditAndLocalOnlyTests: XCTestCase {
    func testTheAuditLogKeepsTheNewestFirstAndOnlyTheLatest() {
        let defaults = UserDefaults(suiteName: "kriya-audit-\(UUID().uuidString)")!
        let log = AuditLog(defaults: defaults)
        for index in 0..<(AuditLog.capacity + 5) { log.record(.network, "request \(index)") }
        let published = expectation(description: "published")
        DispatchQueue.main.async { published.fulfill() }
        wait(for: [published], timeout: 2)
        XCTAssertEqual(log.entries.count, AuditLog.capacity)
        XCTAssertEqual(log.entries.first?.summary, "request \(AuditLog.capacity + 4)")
        XCTAssertEqual(AuditLog(defaults: defaults).entries.count, AuditLog.capacity, "it survives a restart")
    }

    func testLongOrMultiLineSummariesAreCutDownAndFilterWorks() {
        let log = AuditLog(defaults: UserDefaults(suiteName: "kriya-audit-\(UUID().uuidString)")!)
        log.record(.script, String(repeating: "x", count: 500) + "\nsecond line")
        log.record(.files, "Folder rule “Tidy”: 3 changes")
        XCTAssertLessThanOrEqual(log.entries.first { $0.kind == .script }?.summary.count ?? 999, 160)
        XCTAssertFalse(log.entries.contains { $0.summary.contains("\n") })
        XCTAssertTrue(log.text(kinds: [.files]).contains("Tidy"))
        XCTAssertFalse(log.text(kinds: [.files]).contains("xxxx"))
        log.clear()
        XCTAssertTrue(log.entries.isEmpty)
    }

    func testLocalOnlyBlocksAnAPICommandBeforeItBuildsAnyRequest() {
        let before = LocalOnly.isOn
        defer { LocalOnly.isOn = before }
        LocalOnly.isOn = true
        var command = APICommand(name: "Find", keyword: "find", url: "https://api.example.com/{query}")
        command.id = "t"
        XCTAssertTrue(LocalOnly.isOn)
        XCTAssertTrue(LocalOnly.blockedMessage.contains("no network requests"))
        XCTAssertFalse(LocalOnly.stopped.isEmpty)
    }
}

final class BackupComparisonTests: XCTestCase {
    private func summary(profiles: UInt32, actions: UInt32 = 0, rules: UInt32 = 0) -> BackupSummary {
        BackupSummary(createdAt: 0, appVersion: "0.5.0", profiles: profiles, actions: actions, rules: rules, devices: 0, mousePresets: 0, windowLayouts: 0)
    }

    func testTheRestorePreviewSaysWhatWouldBeAddedAndRemoved() {
        let text = BackupComparison.preview(now: summary(profiles: 5, rules: 2), backup: summary(profiles: 3, actions: 4, rules: 2), madeAt: "yesterday")
        XCTAssertTrue(text.contains("Profiles: 5 → 3 (2 removed)"))
        XCTAssertTrue(text.contains("Saved actions: 0 → 4 (4 added)"))
        XCTAssertTrue(text.contains("Rules: 2 (same count)"))
        XCTAssertTrue(text.contains("Restoring would remove: 2 profiles."))
        XCTAssertTrue(text.contains("saved first"))
    }

    func testNothingIsCalledOutWhenNothingWouldBeRemoved() {
        let text = BackupComparison.preview(now: summary(profiles: 1), backup: summary(profiles: 4), madeAt: "today")
        XCTAssertFalse(text.contains("Restoring would remove"))
    }
}

final class EncryptedSnippetExportTests: XCTestCase {
    func testASealedExportOpensOnlyWithItsPassphrase() throws {
        let sealed = try BackupCrypto.seal("{\"snippets\":[]}", passphrase: "correct horse")
        XCTAssertTrue(BackupCrypto.isEncrypted(sealed))
        XCTAssertEqual(try BackupCrypto.open(sealed, passphrase: "correct horse"), "{\"snippets\":[]}")
        XCTAssertThrowsError(try BackupCrypto.open(sealed, passphrase: "wrong phrase")) { XCTAssertEqual($0 as? BackupCryptoError, .wrongPassphrase) }
        XCTAssertThrowsError(try BackupCrypto.seal("x", passphrase: "short")) { XCTAssertEqual($0 as? BackupCryptoError, .tooShort) }
    }

    func testTheStoreSeesWhichFilesNeedAPassphrase() throws {
        let plain = FileManager.default.temporaryDirectory.appendingPathComponent("kriya-\(UUID().uuidString).json")
        let sealed = FileManager.default.temporaryDirectory.appendingPathComponent("kriya-\(UUID().uuidString).json")
        try Data("{}".utf8).write(to: plain)
        try BackupCrypto.seal("{}", passphrase: "correct horse").write(to: sealed)
        defer { try? FileManager.default.removeItem(at: plain); try? FileManager.default.removeItem(at: sealed) }
        XCTAssertFalse(ClipboardStore.needsPassphrase(plain))
        XCTAssertTrue(ClipboardStore.needsPassphrase(sealed))
    }
}
