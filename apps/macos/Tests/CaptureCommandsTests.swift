import XCTest
@testable import Kriya

/// A stand-in for macOS's hot-key service, so the tests never take a real shortcut.
private final class StandInHotKeys: HotKeyBackend {
    var onPressed: ((UInt32) -> Bool)?
    var live: [UInt32: String] = [:]

    func register(keyCode: UInt16, modifiers: UInt64, id: UInt32) -> Bool {
        let key = "\(keyCode):\(modifiers)"
        if live.values.contains(key) { return false }
        live[id] = key
        return true
    }

    func unregister(id: UInt32) { live[id] = nil }
}

final class CaptureCommandsTests: XCTestCase {
    private let all = CaptureCommandCatalog.added

    // MARK: Every command is complete

    func testTheRequestedCommandsAreAllThere() {
        let wanted = [
            "capture.region.copy", "capture.region.save", "capture.region.upload", "capture.region.annotate", "capture.region.pin",
            "capture.history.open", "capture.restore", "capture.desktopicons.toggle", "capture.cards.toggle", "capture.cards.saveall",
            "capture.cards.closeall", "capture.scroll.start", "capture.scroll.stop", "capture.timer", "capture.rec.restart",
            "capture.camera.fullscreen", "capture.pins.toggle", "capture.pins.closeall", "capture.pins.choose",
        ]
        XCTAssertEqual(Set(all.map(\.id)), Set(wanted))
        XCTAssertEqual(all.count, wanted.count)
    }

    func testEveryCommandHasAUniqueNameThatDoesNotClashWithTheOlderOnes() {
        let ids = all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        for id in ids {
            XCTAssertTrue(id.hasPrefix("capture."), id)
            // "capture.area.<id>" is how a saved area is named; a command must never be taken for one.
            XCTAssertFalse(id.hasPrefix("capture.area."), id)
        }
        let everyName = CaptureSettings.commands.map(\.command)
        XCTAssertEqual(Set(everyName).count, everyName.count, "the older commands and these never share a name")
        for id in ids { XCTAssertTrue(everyName.contains(id), "\(id) can be given a shortcut and run by name") }
    }

    func testEveryCommandHasAnOwnerAndAPlainTitle() {
        for command in all {
            XCTAssertEqual(command.owner, "Screen capture", command.id)
            XCTAssertEqual(command.feature, "capture", command.id)
            XCTAssertGreaterThan(command.title.count, 8, command.id)
            XCTAssertFalse(command.title.contains("capture."), "\(command.id) is titled for people, not by its name")
            XCTAssertTrue(command.title.first?.isUppercase == true, command.title)
        }
        let titles = all.map(\.title)
        XCTAssertEqual(Set(titles).count, titles.count, "two commands never read the same")
    }

    func testEveryNeedHasAWholeSentenceToSayWhenItIsNotMet() {
        for need in CaptureNeed.allCases {
            XCTAssertTrue(need.problem.hasSuffix("."), "\(need)")
            XCTAssertGreaterThan(need.problem.count, 20, "\(need)")
        }
        XCTAssertEqual(Set(CaptureNeed.allCases.map(\.problem)).count, CaptureNeed.allCases.count, "each says something different")
    }

    // MARK: Disabled states

    private var ready: CaptureCommandState {
        var s = CaptureCommandState()
        s.uploadReady = true; s.pinCount = 2; s.cardCount = 2; s.closedCardCount = 1; s.isScrolling = true; s.kriyaRecording = true; s.cameraShown = true
        return s
    }

    func testWhenEverythingIsInPlaceEveryCommandCanRun() {
        // Scrolling cannot be started while one runs, and nothing can start while capturing, so these two are the exceptions.
        var state = ready
        state.isScrolling = false
        for command in all where command.id != CaptureCommandID.scrollStop {
            XCTAssertTrue(command.availability(in: state).isAvailable, command.id)
        }
        XCTAssertTrue(CaptureCommandCatalog.command(CaptureCommandID.scrollStop)!.availability(in: ready).isAvailable)
    }

    func testEachNeedDisablesTheCommandsThatHaveIt() {
        for command in all {
            for need in command.needs {
                var state = ready
                state.isScrolling = false
                switch need {
                case .screenPermission: state.hasScreenPermission = false
                case .notBusy: state.isCapturing = true
                case .kriyaSelector: state.kriyaSelector = false
                case .uploadReady: state.uploadReady = false
                case .scrollRunning: state.isScrolling = false
                case .kriyaRecorderRunning: state.kriyaRecording = false
                case .cameraShown: state.cameraShown = false
                case .pinsOpen: state.pinCount = 0
                case .cardsShown: state.cardCount = 0
                case .closedCard: state.closedCardCount = 0
                }
                XCTAssertEqual(command.availability(in: state), .disabled(need.problem), "\(command.id) without \(need)")
            }
        }
    }

    func testTheFirstThingMissingIsTheOneSaid() {
        var state = ready
        state.hasScreenPermission = false
        state.uploadReady = false
        let upload = CaptureCommandCatalog.command(CaptureCommandID.regionUpload)!
        XCTAssertEqual(upload.availability(in: state).error, CaptureNeed.screenPermission.problem)
        state.hasScreenPermission = true
        XCTAssertEqual(upload.availability(in: state).error, CaptureNeed.uploadReady.problem)
    }

    func testCommandsThatNeedNothingAreAlwaysAvailable() {
        let bare = CaptureCommandState(hasScreenPermission: false, isCapturing: true, kriyaSelector: false)
        for id in [CaptureCommandID.historyOpen, CaptureCommandID.desktopIcons, CaptureCommandID.pinsChoose] {
            XCTAssertTrue(CaptureCommandCatalog.availability(of: id, in: bare)?.isAvailable == true, id)
        }
        XCTAssertNil(CaptureCommandCatalog.availability(of: "capture.region", in: bare), "an older command is not one of these")
    }

    func testOnlySetupIsSaidInSettingsNotMomentaryState() {
        var state = CaptureCommandState()
        state.uploadReady = false
        XCTAssertEqual(CaptureCommandCatalog.setupProblem(of: CaptureCommandID.regionUpload, in: state), CaptureNeed.uploadReady.problem)
        XCTAssertNil(CaptureCommandCatalog.setupProblem(of: CaptureCommandID.pinsToggle, in: state), "no pins on the screen is not a setup problem")
        XCTAssertNil(CaptureCommandCatalog.setupProblem(of: CaptureCommandID.scrollStop, in: state))
        state.kriyaSelector = false
        XCTAssertEqual(CaptureCommandCatalog.setupProblem(of: CaptureCommandID.regionCopy, in: state), CaptureNeed.kriyaSelector.problem)
    }

    // MARK: What the area commands do

    func testEachAreaCommandChoosesItsOwnDelivery() {
        let expected: [String: ForcedDelivery] = [
            CaptureCommandID.regionCopy: .copy, CaptureCommandID.regionSave: .save, CaptureCommandID.regionUpload: .upload,
            CaptureCommandID.regionAnnotate: .annotate, CaptureCommandID.regionPin: .pin,
        ]
        for command in all { XCTAssertEqual(command.forced, expected[command.id], command.id) }
    }

    func testAnUploadCommandNeedsAnUploadBucketAndTheOthersDoNot() {
        for command in all {
            XCTAssertEqual(command.needs.contains(.uploadReady), command.id == CaptureCommandID.regionUpload, command.id)
        }
    }

    func testARequestCarriesWhatTheCommandForced() {
        let request = CaptureRequest.make(mode: .region, action: .normal, settings: CaptureSettings(), policy: CaptureDeliveryPolicy(), forced: .upload)
        XCTAssertEqual(request.forced, .upload)
        XCTAssertNil(CaptureRequest.make(mode: .region, action: .normal, settings: CaptureSettings(), policy: CaptureDeliveryPolicy()).forced)
    }

    func testSavingSeveralCardsIsDescribedPlainly() {
        XCTAssertEqual(CardBatch.summary(saved: 2, alreadySaved: 0, failed: 0), "Saved 2 captures.")
        XCTAssertEqual(CardBatch.summary(saved: 1, alreadySaved: 3, failed: 0), "Saved 1 capture, 3 already saved.")
        XCTAssertEqual(CardBatch.summary(saved: 0, alreadySaved: 2, failed: 0), "2 captures already saved.")
        XCTAssertEqual(CardBatch.summary(saved: 1, alreadySaved: 0, failed: 1), "Saved 1 capture, 1 capture could not be saved.")
        XCTAssertEqual(CardBatch.summary(saved: 0, alreadySaved: 0, failed: 0), "There was nothing to save.")
    }

    // MARK: Conflicts and the shortcut registry

    func testEveryCommandCanBeRegisteredThroughTheRegistryUnderItsOwner() {
        let registry = ShortcutRegistry(backend: StandInHotKeys())
        let bindings = all.enumerated().map { ShortcutBinding(command: $1.id, keyCode: UInt16(10 + $0), modifiers: KeyModifiers.control | KeyModifiers.option) }
        let refused = registry.register(owner: CaptureCommandCatalog.owner, bindings: bindings, title: { id in CaptureSettings.commands.first { $0.command == id }?.title ?? id }, onFire: { _ in })
        XCTAssertTrue(refused.isEmpty)
        XCTAssertEqual(registry.entries.count, all.count)
        for command in all {
            let entry = registry.entries.first { $0.command == command.id }
            XCTAssertEqual(entry?.owner, command.owner, command.id)
            XCTAssertEqual(entry?.title, command.title, command.id)
            XCTAssertEqual(entry?.status, .active, command.id)
        }
        XCTAssertTrue(registry.conflicts.isEmpty)
    }

    func testTwoCommandsOnTheSameKeysAreAClashAndTheSecondIsRefused() {
        let registry = ShortcutRegistry(backend: StandInHotKeys())
        let keys = KeyModifiers.control | KeyModifiers.option
        let bindings = [
            ShortcutBinding(command: CaptureCommandID.regionCopy, keyCode: 8, modifiers: keys),
            ShortcutBinding(command: CaptureCommandID.pinsToggle, keyCode: 8, modifiers: keys),
        ]
        let refused = registry.register(owner: CaptureCommandCatalog.owner, bindings: bindings, title: { $0 }, onFire: { _ in })
        XCTAssertEqual(refused, [CaptureCommandID.pinsToggle])
        XCTAssertEqual(registry.conflicts.count, 1, "the clash is listed, counting the refused one")
    }

    func testAnotherFeaturesShortcutIsAClashBeforeItIsSaved() {
        let registry = ShortcutRegistry(backend: StandInHotKeys())
        let keys = KeyModifiers.control | KeyModifiers.shift
        registry.register(owner: "Window layouts", bindings: [ShortcutBinding(command: "layout.left", keyCode: 123, modifiers: keys)], title: { _ in "Snap left" }, onFire: { _ in })
        registry.register(owner: CaptureCommandCatalog.owner, bindings: [ShortcutBinding(command: CaptureCommandID.pinsToggle, keyCode: 5, modifiers: keys)], title: { _ in "Pins" }, onFire: { _ in })
        let clash = CaptureCommandCatalog.clashes(command: CaptureCommandID.regionPin, keyCode: 123, modifiers: keys, among: registry.entries)
        XCTAssertEqual(clash.map(\.owner), ["Window layouts"])
        XCTAssertTrue(CaptureCommandCatalog.clashes(command: CaptureCommandID.pinsToggle, keyCode: 5, modifiers: keys, among: registry.entries).isEmpty, "a command's own keys are not a clash with itself")
        XCTAssertTrue(CaptureCommandCatalog.clashes(command: CaptureCommandID.regionPin, keyCode: 99, modifiers: keys, among: registry.entries).isEmpty)
    }

    func testDuplicateKeysInSavedShortcutsAreFound() {
        let shortcuts = [
            CaptureShortcut(command: CaptureCommandID.pinsToggle, keyCode: 5, modifiers: 3),
            CaptureShortcut(command: CaptureCommandID.pinsCloseAll, keyCode: 5, modifiers: 3),
            CaptureShortcut(command: CaptureCommandID.historyOpen, keyCode: 6, modifiers: 3),
        ]
        XCTAssertEqual(CaptureCommandCatalog.duplicateKeys(in: shortcuts), [[CaptureCommandID.pinsCloseAll, CaptureCommandID.pinsToggle]])
        XCTAssertTrue(CaptureCommandCatalog.duplicateKeys(in: [shortcuts[0], shortcuts[2]]).isEmpty)
    }

    func testTheCaptureStoreKeepsShortcutsForTheNewCommandsAndRefusesSharedKeys() throws {
        let suite = "kriya.test.commands.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CaptureSettingsStore(defaults: defaults)
        store.setShortcut(CaptureCommandID.pinsToggle, keyCode: 5, modifiers: KeyModifiers.control)
        XCTAssertEqual(store.shortcut(for: CaptureCommandID.pinsToggle)?.keyCode, 5)
        store.setShortcut(CaptureCommandID.pinsCloseAll, keyCode: 5, modifiers: KeyModifiers.control)
        XCTAssertNil(store.shortcut(for: CaptureCommandID.pinsToggle), "the keys moved to the command that asked last")
        XCTAssertNotNil(CaptureSettingsStore(defaults: defaults).shortcut(for: CaptureCommandID.pinsCloseAll), "and the choice is kept")
    }

    // MARK: Pins and cards report what they hold

    func testPinsStartEmptyAndHidingNothingDoesNothing() {
        let pins = PinnedShots()
        XCTAssertEqual(pins.count, 0)
        pins.toggleVisibility()
        XCTAssertFalse(pins.isHidden, "nothing to put away")
        pins.closeAll()
        XCTAssertEqual(pins.count, 0)
    }

    func testPinsCanBeHiddenAndBroughtBack() {
        let pins = PinnedShots()
        let image = NSImage(size: NSSize(width: 40, height: 30))
        pins.pin(image)
        pins.pin(image)
        XCTAssertEqual(pins.count, 2)
        pins.toggleVisibility()
        XCTAssertTrue(pins.isHidden)
        XCTAssertEqual(pins.count, 2, "put away, not closed")
        pins.pin(image)
        XCTAssertFalse(pins.isHidden, "a new pin brings the others back")
        XCTAssertEqual(pins.count, 3)
        pins.closeAll()
        XCTAssertEqual(pins.count, 0)
        XCTAssertFalse(pins.isHidden)
    }
}

final class CaptureCommandRunTests: XCTestCase {
    private var service: ScreenCaptureService!
    private var calls = 0

    override func setUpWithError() throws {
        let settings = CaptureSettingsStore(defaults: UserDefaults(suiteName: "kriya-commands-\(UUID().uuidString)")!)
        service = ScreenCaptureService(settings: settings)
        service.pasteboard = NSPasteboard(name: NSPasteboard.Name("kriya-commands-\(UUID().uuidString)"))
        service.capturer = { [unowned self] _ in calls += 1 }
        calls = 0
    }

    func testAnUnknownCommandNameIsNotRun() {
        // Only a name that is not a command is run here: running a real one would hide the desktop icons, open a file panel, and so on.
        XCTAssertFalse(service.run(command: "capture.nothing.like.this"))
    }

    func testACommandWithoutPermissionStartsNothingAndSaysWhy() {
        service.hasPermission = { false }
        let command = CaptureCommandCatalog.command(CaptureCommandID.regionCopy)!
        XCTAssertEqual(command.availability(in: service.commandState()).error, CaptureNeed.screenPermission.problem)
        service.perform(command)
        XCTAssertFalse(service.isCapturing)
        XCTAssertEqual(calls, 0)
        XCTAssertNil(service.request?.forced)
    }

    func testAnAreaCommandNeedsKriyasSelector() {
        service.hasPermission = { true }
        service.nativeSelectorEnabled = false
        let command = CaptureCommandCatalog.command(CaptureCommandID.regionPin)!
        XCTAssertEqual(command.availability(in: service.commandState()).error, CaptureNeed.kriyaSelector.problem)
        service.perform(command)
        XCTAssertFalse(service.isCapturing)
        XCTAssertEqual(calls, 0)
    }

    func testStoppingAScrollThatIsNotRunningSaysSo() {
        let stop = CaptureCommandCatalog.command(CaptureCommandID.scrollStop)!
        XCTAssertEqual(stop.availability(in: service.commandState()).error, "No scrolling capture is running.")
        service.perform(stop)
        XCTAssertFalse(service.isCapturing)
    }

    func testAForcedDeliveryIsUsedOnceAndNotLeftBehindWhenACaptureIsCancelled() {
        service.hasPermission = { true }
        service.nativeSelectorEnabled = false
        // The stand-in screenshot tool waits, so the capture stays open while the checks run.
        let gate = DispatchSemaphore(value: 0)
        service.capturer = { _ in gate.wait() }
        defer { gate.signal(); gate.signal() }
        service.capture(.region, action: .normal, forced: .copy)
        XCTAssertEqual(service.request?.forced, .copy)
        XCTAssertEqual(service.consumeForcedDelivery(), .copy)
        XCTAssertNil(service.consumeForcedDelivery(), "taken once")
        service.finishCapture()
        service.capture(.region, action: .normal, forced: .save)
        XCTAssertEqual(service.request?.forced, .save)
        service.finishCapture()
        XCTAssertNil(service.request?.forced, "a cancelled capture leaves nothing for the next one")
    }
}
