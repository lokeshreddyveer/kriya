import XCTest
@testable import Kriya

/// Lifecycle, permissions, availability, evidence and audio behaviour that an audit found not to be backed by anything.
final class AuditFixesTests: XCTestCase {
    private var world: TestWorld!

    override func setUpWithError() throws { world = try TestWorld() }
    override func tearDown() { world.cleanUp() }

    // MARK: Background services obey safe mode and permissions

    private final class Counter { var starts = 0, stops = 0, wakes = 0 }

    func testABackgroundServiceFollowsSafeModePermissionsAndWake() {
        let services = ServiceManager(context: world.makeContext(), crashGuard: world.crashGuard, modules: [])
        let counter = Counter()
        services.register(AuxiliaryService(id: "test.place", title: "Sound by place", blockedWhenDenied: [.location],
                                           start: { counter.starts += 1 }, stop: { counter.stops += 1 }, wake: { counter.wakes += 1 }))
        XCTAssertEqual(services.auxiliaryState("test.place"), .off, "nothing runs before the manager reconciles")
        services.reconcile()
        XCTAssertEqual(counter.starts, 1)
        XCTAssertEqual(services.auxiliaryState("test.place"), .running)
        services.reconcile()
        XCTAssertEqual(counter.starts, 1, "reconciling again does not start it twice")

        world.crashGuard.beginSession(forceSafeMode: true)
        services.reconcile()
        XCTAssertEqual(counter.stops, 1, "safe mode stops it, as it stops a feature")
        XCTAssertEqual(services.auxiliaryState("test.place"), .safeMode)
        world.crashGuard.leaveSafeMode()
        services.reconcile()
        XCTAssertEqual(counter.starts, 2)

        // Refused permission: the fake system says "denied" once Kriya has asked.
        world.permissions.request(.location)
        world.permissions.refresh()
        services.reconcile()
        XCTAssertEqual(counter.stops, 2)
        XCTAssertEqual(services.auxiliaryState("test.place"), .needsPermission([.location]))
        world.probe.granted = [.location]
        world.permissions.refresh()
        services.reconcile()
        XCTAssertEqual(counter.starts, 3)

        services.stopAll()
        XCTAssertEqual(counter.stops, 3)
    }

    func testAServiceNotAskedForYetIsNotBlocked() {
        let services = ServiceManager(context: world.makeContext(), crashGuard: world.crashGuard, modules: [])
        let counter = Counter()
        services.register(AuxiliaryService(id: "test.keys", title: "Volume keys", blockedWhenDenied: [.inputMonitoring], start: { counter.starts += 1 }, stop: {}))
        services.reconcile()
        XCTAssertEqual(counter.starts, 1, "a permission never requested is notDetermined, not denied")
    }

    func testAServiceThatDeclinedToStartIsNotReportedRunning() {
        let services = ServiceManager(context: world.makeContext(), crashGuard: world.crashGuard, modules: [])
        final class Flag { var on = false }
        let flag = Flag(), counter = Counter()
        services.register(AuxiliaryService(id: "test.declines", title: "Declines", start: { counter.starts += 1 },
                                           stop: { counter.stops += 1 }, isActive: { flag.on }))
        services.reconcile()
        XCTAssertEqual(counter.starts, 1)
        XCTAssertEqual(services.auxiliaryState("test.declines"), .off, "start did nothing, so nothing is claimed")
        services.reconcile()
        XCTAssertEqual(counter.starts, 2, "it is tried again on the next check")
        flag.on = true   // the person turned its own switch on
        XCTAssertEqual(services.auxiliaryState("test.declines"), .running, "asked live, not remembered")
        services.reconcile()
        XCTAssertEqual(services.auxiliaryState("test.declines"), .running)
        XCTAssertEqual(counter.starts, 3)
        services.stopAll()
    }

    func testEveryNonCoreFeatureNamesARealRuntimeOwner() {
        for feature in FeatureRegistry.extras {
            let owner = FeatureRegistry.runtimeOwners[feature.id]
            XCTAssertNotNil(owner, "\(feature.id) has a screen and tests but nothing that runs it")
            XCTAssertTrue(owner?.isReal == true, "\(feature.id)'s owner is not registered")
        }
        for id in FeatureRegistry.runtimeOwners.keys { XCTAssertNotNil(FeatureRegistry.feature(id), "\(id) is not a listed feature") }
        for case .service(let id) in FeatureRegistry.runtimeOwners.values { XCTAssertTrue(ServiceManager.knownAuxiliaryIDs.contains(id), id) }
    }

    // MARK: Secret files

    func testASecretFileIsPrivateFromTheFirstByteAndRepairedWhenLoosened() throws {
        let file = world.folder.appendingPathComponent("secrets/key")
        XCTAssertTrue(PrivateFile.write(Data("abc".utf8), to: file))
        XCTAssertEqual(PrivateFile.isPrivate(file), true)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "abc")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        XCTAssertEqual(PrivateFile.isPrivate(file), false)
        XCTAssertTrue(PrivateFile.ensurePrivate(file), "something loosened it, and using it puts it right")
        XCTAssertEqual(PrivateFile.isPrivate(file), true)
        // Writing over a loose file does not keep the loose mode.
        try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: file.path)
        XCTAssertTrue(PrivateFile.write(Data("new".utf8), to: file))
        XCTAssertEqual(PrivateFile.isPrivate(file), true)
        XCTAssertFalse(PrivateFile.ensurePrivate(world.folder.appendingPathComponent("secrets/missing")), "a file that is not there is not private")
        XCTAssertEqual(PrivateFile.randomHex()?.count, 64)
        XCTAssertNotEqual(PrivateFile.randomHex(), PrivateFile.randomHex())
    }

    func testTheBrowserKeyIs64CharactersAndStaysPrivate() {
        let support = world.folder.appendingPathComponent("bridge")
        let token = BridgeToken.loadOrCreate(in: support)
        XCTAssertEqual(token.count, 64)
        XCTAssertEqual(BridgeToken.read(in: support), token, "the host can read what the app made")
        XCTAssertEqual(PrivateFile.isPrivate(BridgeToken.fileURL(in: support)), true)
        XCTAssertEqual(BridgeToken.loadOrCreate(in: support), token, "made once and kept")
    }

    // MARK: Settings search and links cannot point at nothing

    /// Every .swift file under the Settings screens, read once.
    private static let settingsSource: String = {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/UI/Settings")
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        return files.compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
    }()

    func testEverySettingsSearchEntryPointsAtARealPaneAndTab() {
        XCTAssertFalse(Self.settingsSource.isEmpty, "the Settings sources were not found, so nothing below would be checked")
        var seen = Set<String>()
        for entry in SettingsIndex.entries {
            XCTAssertNotNil(SettingsPane(rawValue: entry.pane), "“\(entry.title)” points at pane “\(entry.pane)”, which does not exist")
            XCTAssertTrue(seen.insert(entry.id).inserted, "“\(entry.title)” is listed twice for the same place")
            if let tab = entry.tab {
                XCTAssertTrue(Self.settingsSource.contains("\"\(tab)\""), "“\(entry.title)” opens tab “\(tab)” in \(entry.pane), but no screen has a tab with that name")
            }
        }
    }

    func testEveryTabHintTheAppSendsNamesARealTab() {
        // Deep links from the launcher and the feature list pass a tab by name; a rename must fail here, not silently land on the first tab.
        for feature in FeatureRegistry.extras {
            guard let tab = feature.tab else { continue }
            XCTAssertTrue(Self.settingsSource.contains("\"\(tab)\""), "\(feature.id) opens tab “\(tab)”, which no screen has")
        }
    }

    // MARK: Availability and evidence are not assumed

    func testAvailabilityMeansARealModuleIsRegistered() {
        for feature in FeatureId.all { XCTAssertTrue(feature.isAvailable, feature.title) }
        XCTAssertEqual(Set(ServiceManager.moduleFactories.keys), Set(FeatureId.all), "every feature has a real module and none is a placeholder")
        for (feature, make) in ServiceManager.moduleFactories { XCTAssertEqual(make().feature, feature) }
    }

    func testEvidenceSourceCoverageIsWorkedOut() {
        XCTAssertTrue(FeatureRegistry.isImplemented("midi"))
        XCTAssertTrue(FeatureRegistry.isImplemented("mouse"))
        XCTAssertFalse(FeatureRegistry.isImplemented("a-feature-nobody-built"))
        let ledger = EvidenceLedger()
        XCTAssertFalse(ledger.row(feature: "a-feature-nobody-built", testClasses: [], build: "1").inSource)
        XCTAssertTrue(ledger.row(feature: "capture", testClasses: [], build: "1").inSource)
        for feature in FeatureRegistry.extras { XCTAssertTrue(FeatureRegistry.isImplemented(feature.id), "\(feature.id) is listed but has no screen or tests") }
    }

    // MARK: Every permission is modelled

    func testEveryPermissionNamedByAFeatureIsInTheStateMachine() {
        XCTAssertEqual(Permission.allCases.count, 11)
        XCTAssertEqual(Permission.named("contacts"), .contacts, "the launcher reads Contacts, so the matrix can show and repair it")
        XCTAssertTrue(FeatureRegistry.feature("launcher")?.permissions.contains("Contacts") == true)
        for feature in FeatureRegistry.extras {
            for name in feature.permissions where !name.contains("Safari") {
                XCTAssertNotNil(Permission.named(name), "\(feature.id) names “\(name)”, which has no state or repair action")
            }
        }
        for permission in Permission.allCases {
            XCTAssertFalse(permission.reason.isEmpty, permission.rawValue)
            XCTAssertFalse(permission.symbol.isEmpty, permission.rawValue)
            XCTAssertNotNil(permission.settingsURL.scheme, permission.rawValue)
        }
        XCTAssertEqual(Permission.named("bluetooth"), .bluetooth)
        XCTAssertEqual(Permission.named("Screen Recording"), .screenRecording)
        XCTAssertNil(Permission.named("Teleportation"))
    }

    func testTheNewPermissionsCanBeAskedForAndRevoked() {
        world.permissions.request(.camera)
        XCTAssertTrue(world.probe.granted.isEmpty)
        world.probe.granted = [.camera]
        world.permissions.refresh()
        XCTAssertTrue(world.permissions.isGranted(.camera))
        world.probe.granted = []
        world.permissions.refresh()
        XCTAssertEqual(world.permissions.status(.camera), .denied, "taken away after being asked for")
    }

    // MARK: Settings navigation

    func testATabHintSurvivesSlowPanesAndIsDroppedWhenThePaneIsLeft() {
        let nav = SettingsNavigator()
        nav.go(.apps, tab: "Updates")
        XCTAssertEqual(nav.tabHint, "Updates")
        RunLoop.current.run(until: Date().addingTimeInterval(0.9))
        XCTAssertEqual(nav.tabHint, "Updates", "no longer expires after 0.6 seconds, before a slow pane is built")
        nav.pane = .capture
        XCTAssertNil(nav.tabHint, "leaving the pane drops it, so it cannot land on a later visit")
        nav.go(.apps)
        XCTAssertNil(nav.tabHint)
        nav.go(.finder, tab: "Menus")
        nav.go(.finder, tab: "Setup")
        XCTAssertEqual(nav.tabHint, "Setup")
    }

    // MARK: Audio

    private func run(_ p: AudioProcessor, _ input: [Float], channels: Int = 2) -> [Float] {
        var out = [Float](repeating: 0, count: input.count)
        input.withUnsafeBufferPointer { i in out.withUnsafeMutableBufferPointer { o in
            p.process(input: i.baseAddress!, output: o.baseAddress!, frames: input.count / channels, channels: channels)
        } }
        return out
    }

    func testSoundAtFullVolumeWithNoEffectsPassesThroughUntouched() {
        let loud = (0..<4800).map { 0.97 * sinf(2 * .pi * 440 * Float($0 / 2) / 48_000) }
        let out = run(AudioProcessor(), loud)
        XCTAssertEqual(out, loud, "bit for bit: no clipping bends the peaks of loud music")
    }

    func testOnlyBoostedSoundIsSoftClipped() {
        let p = AudioProcessor()
        p.targetGain = 1
        let loud = [Float](repeating: 0.95, count: 960)
        XCTAssertEqual(run(p, loud).last!, 0.95, accuracy: 1e-6, "a signal that is not boosted keeps its peaks")
        let boosted = AudioProcessor()
        boosted.targetGain = 2
        let y = run(boosted, loud)
        XCTAssertLessThanOrEqual(y.map { abs($0) }.max()!, 1.0)
        XCTAssertGreaterThan(y.last!, 0.9, "boosted sound is bent smoothly, not cut flat")
    }

    func testTheEqualiserStaysOnAcrossManyBuffersAndSettingChanges() {
        let p = AudioProcessor()
        var gains = [Float](repeating: 0, count: 10); gains[5] = 12
        p.setEQ(gains: gains, sampleRate: 48_000)
        let tone = (0..<9600).map { 0.1 * sinf(2 * .pi * 1000 * Float($0 / 2) / 48_000) }
        var rms: [Float] = []
        for round in 0..<6 {
            if round == 3 { p.setEQ(gains: gains, sampleRate: 48_000) }   // a change while it is playing
            let out = run(p, tone)
            rms.append((out[2000...].map { $0 * $0 }.reduce(0, +) / Float(out.count - 2000)).squareRoot())
        }
        for value in rms.dropFirst() { XCTAssertEqual(value, rms.last!, accuracy: rms.last! * 0.08, "no buffer loses its equaliser") }
        XCTAssertGreaterThan(rms.last!, 0.1 * 0.7071 * 2.5, "the 12 dB boost at 1 kHz is still applied")
    }

    func testSettingsReachTheAudioThreadTogetherAndReadBackExactly() {
        let p = AudioProcessor()
        p.targetGain = 0.5; p.muted = true; p.preampGain = 1; p.balance = 0; p.tempGain = 0.5
        XCTAssertEqual(p.targetGain, 0.5); XCTAssertTrue(p.muted); XCTAssertEqual(p.tempGain, 0.5)
        let tone = [Float](repeating: 0.4, count: 4800)
        _ = run(p, tone)                               // ramps to silence
        XCTAssertEqual(run(p, tone).last!, 0, accuracy: 1e-6, "muted means silent, whatever the gain")
        p.muted = false
        _ = run(p, tone)                               // ramps up
        XCTAssertEqual(run(p, tone).last!, 0.4 * 0.5 * 0.5, accuracy: 1e-5, "gain and the timed turn-down apply together")
        XCTAssertEqual(p.peak, 0.1, accuracy: 1e-5)
    }

    func testSettingsChangedFromAnotherThreadNeverTearOrCrash() {
        let p = AudioProcessor()
        let done = expectation(description: "writer finished")
        DispatchQueue.global().async {
            for i in 0..<2000 { p.targetGain = Float(i % 3) * 0.5; p.muted = i % 7 == 0; p.balance = Float(i % 5) / 4 - 0.5 }
            done.fulfill()
        }
        let tone = [Float](repeating: 0.3, count: 960)
        for _ in 0..<400 {
            let out = run(p, tone)
            XCTAssertTrue(out.allSatisfy { $0.isFinite && abs($0) <= 1 })
        }
        wait(for: [done], timeout: 10)
    }

    func testSilenceAfterEQDoesNotLeaveTinyNumbersBehind() {
        let p = AudioProcessor()
        var gains = [Float](repeating: 0, count: 10); gains[2] = 6
        p.setEQ(gains: gains, sampleRate: 48_000)
        _ = run(p, (0..<4800).map { 0.2 * sinf(Float($0 / 2) * 0.05) })
        for _ in 0..<40 { _ = run(p, [Float](repeating: 0, count: 4800)) }
        let tail = run(p, [Float](repeating: 0, count: 960))
        XCTAssertTrue(tail.allSatisfy { $0 == 0 || abs($0) > 1e-15 }, "filter memory is flushed instead of decaying into denormals")
    }
}
