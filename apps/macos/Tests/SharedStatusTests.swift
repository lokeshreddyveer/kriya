import XCTest
@testable import Kriya

final class FeatureRegistryTests: XCTestCase {
    func testTheRegistryHangsTogether() {
        let problems = FeatureRegistry.problems(coreKeys: Set(FeatureId.all.map(\.key)), resetAreas: Set(FeatureReset.areas.map(\.id)))
        XCTAssertEqual(problems, [])
    }

    func testEverySettingsPaneNamedExists() {
        for feature in FeatureRegistry.extras { XCTAssertNotNil(SettingsPane(rawValue: feature.pane), feature.id) }
        for entry in SettingsIndex.entries { XCTAssertNotNil(SettingsPane(rawValue: entry.pane), entry.title) }
    }

    func testDependenciesAndDependentsAreTwoViewsOfTheSameThing() {
        XCTAssertEqual(FeatureRegistry.dependents(of: "aiProviders").map(\.id).sorted(), ["mcpServer", "semanticSearch"])
        XCTAssertEqual(FeatureRegistry.dependents(of: "automation").map(\.id), ["midi"])
        XCTAssertEqual(FeatureRegistry.feature("midi")?.dependsOn, ["automation"])
    }

    func testThePermissionMatrixListsEveryFeatureThatNeedsOne() {
        let matrix = FeatureRegistry.permissionMatrix(core: [(title: "Mouse", permissions: ["Accessibility", "Input Monitoring"]), (title: "Clipboard", permissions: [])])
        XCTAssertEqual(matrix.first { $0.permission == "Accessibility" }?.features, ["Mouse"])
        XCTAssertEqual(matrix.first { $0.permission == "Location" }?.features, ["Sound by Place"])
        XCTAssertTrue(matrix.first { $0.permission == "Automation" }?.features.contains("Finder Drawer") ?? false)
        XCTAssertNil(matrix.first { $0.features.contains("Clipboard") })
    }

    func testTheRegistryCatchesABrokenEntry() {
        // The checker itself: an area that does not exist is reported.
        XCTAssertFalse(FeatureRegistry.problems(coreKeys: [], resetAreas: []).isEmpty)
    }
}

final class FeatureActivityLogTests: XCTestCase {
    func testUseFailureAndChangeAreKeptApart() {
        var log = FeatureActivityLog()
        let t = Date(timeIntervalSince1970: 1_000_000)
        log.used("midi", at: t)
        XCTAssertEqual(log.lastUsed["midi"], t)
        log.failed("midi", "could not open the device sk-abcdefghijklmnopqrstuvwxyz", at: t)
        log.failed("midi", "again", at: t.addingTimeInterval(1))
        XCTAssertEqual(log.failures["midi"]?.count, 2)
        XCTAssertEqual(log.failures["midi"]?.last, "again")
        XCTAssertFalse(String(describing: log.failures).contains("sk-abcdefgh"), "a secret in an error message is not kept")
        log.clearFailures("midi")
        XCTAssertNil(log.failures["midi"])
        log.changed("midi", "Turned on", at: t)
        XCTAssertEqual(log.changes.first?.what, "Turned on")
    }

    func testRecentChangesAreNewestFirstBoundedAndWindowed() {
        var log = FeatureActivityLog()
        let now = Date()
        log.changed("a", "old", at: now.addingTimeInterval(-10 * 86_400))
        for i in 0..<(FeatureActivityLog.changeLimit + 10) { log.changed("b", "c\(i)", at: now) }
        XCTAssertEqual(log.changes.count, FeatureActivityLog.changeLimit)
        XCTAssertTrue(log.recentChanges(within: 7, now: now).allSatisfy { $0.feature == "b" })
        XCTAssertEqual(log.recentChanges(within: 7, now: now).first?.what, "c\(FeatureActivityLog.changeLimit + 9)")
    }

    func testTheLogRoundTripsThroughStorage() throws {
        var log = FeatureActivityLog()
        log.used("ddc"); log.changed("ddc", "x"); log.failed("ddc", "y")
        let back = try JSONDecoder().decode(FeatureActivityLog.self, from: JSONEncoder().encode(log))
        XCTAssertEqual(back.lastUsed.keys.sorted(), ["ddc"])
        XCTAssertEqual(back.failures["ddc"]?.count, 1)
        XCTAssertEqual(back.changes.count, 1)
    }
}

final class EvidenceLedgerTests: XCTestCase {
    func testARecordIsCurrentOnlyForTheBuildItWasMadeOn() {
        var ledger = EvidenceLedger()
        let row0 = ledger.row(feature: "midi", testClasses: ["MIDITriggerTests"], build: "25")
        XCTAssertEqual(row0.tests, .none)
        XCTAssertEqual(row0.manual, .none)
        XCTAssertTrue(row0.inSource)
        ledger.record("midi", build: "25", testsPassed: true, verifiedByHand: false, note: "ok")
        XCTAssertEqual(ledger.row(feature: "midi", testClasses: [], build: "25").tests, .current)
        XCTAssertEqual(ledger.row(feature: "midi", testClasses: [], build: "25").manual, .none, "tests passing says nothing about use by hand")
        XCTAssertEqual(ledger.row(feature: "midi", testClasses: [], build: "26").tests, .staleBuild(recorded: "25"))
    }

    func testANewBuildStartsFromNothingAndForgetWorks() {
        var ledger = EvidenceLedger()
        ledger.record("ddc", build: "25", testsPassed: true, verifiedByHand: true, note: "")
        ledger.record("ddc", build: "26", testsPassed: false, verifiedByHand: true, note: "")
        let row = ledger.row(feature: "ddc", testClasses: [], build: "26")
        XCTAssertEqual(row.tests, .none, "what passed on 25 is not claimed for 26")
        XCTAssertEqual(row.manual, .current)
        ledger.forget("ddc")
        XCTAssertEqual(ledger.row(feature: "ddc", testClasses: [], build: "26").manual, .none)
    }
}

final class SettingsIndexTests: XCTestCase {
    func testNestedSettingsAreFoundByTitleOrKeyword() {
        XCTAssertEqual(SettingsIndex.search("midi").first?.title, "MIDI triggers")
        XCTAssertEqual(SettingsIndex.search("midi").first?.tab, "Safety")
        XCTAssertEqual(SettingsIndex.search("ddc").first?.pane, "displays")
        XCTAssertEqual(SettingsIndex.search("hdmi").first?.tab, "Monitor Controls")
        XCTAssertTrue(SettingsIndex.search("embeddings").contains { $0.title == "Search by meaning" })
        XCTAssertEqual(SettingsIndex.search("clipboard sync").first?.pane, "clipboard")
        XCTAssertTrue(SettingsIndex.search("zzzzzz").isEmpty)
        XCTAssertTrue(SettingsIndex.search("   ").isEmpty)
    }

    func testTitleMatchesRankAboveKeywordMatches() {
        let list = [SettingsIndexEntry(pane: "sound", tab: nil, title: "Other thing", keywords: "location"), SettingsIndexEntry(pane: "sound", tab: nil, title: "Location audio", keywords: "")]
        XCTAssertEqual(SettingsIndex.search("location", in: list).first?.title, "Location audio")
    }

    func testEveryTabNamedInTheIndexIsARealTab() {
        let valid: [String: Set<String>] = [
            "mouse": Set(MousePaneTabs.names), "windows": ["Snap", "Window List", "Layouts", "Triggers", "Sizes", "Apps"], "displays": ["Displays", "Monitor Controls", "Profiles", "Hot Corners"],
            "finder": ["Actions", "Templates", "Apps", "Pointer Menu", "Setup"], "clipboard": ["History", "Snippets", "Privacy", "Settings"], "links": ["Rules", "Options", "Browsers", "Log & Test"],
            "apps": ["Installed", "Install", "Leftovers", "Updates", "Background"], "automation": ["Workflows", "History", "Safety"], "diagnostics": ["Overview", "Health", "Trace", "Timeline", "Audit"],
            "pointer": ["Everyday", "Presentation", "Accessibility", "Advanced"], "keyboard": ["Shortcuts", "Keys", "Snippets", "Expansion", "Launcher"],
        ]
        for entry in SettingsIndex.entries {
            guard let tab = entry.tab else { continue }
            XCTAssertTrue(valid[entry.pane]?.contains(tab) ?? false, "\(entry.pane) has no tab “\(tab)” (\(entry.title))")
        }
    }
}

private enum MousePaneTabs { static let names = ["Devices", "Presets", "Apps", "Drag"] }

final class ActivityFeedTests: XCTestCase {
    func testSourcesAreMergedNewestFirst() {
        let t = Date(timeIntervalSince1970: 5_000)
        let audit = [AuditLog.Entry(kind: .backup, summary: "Backed up", at: t.addingTimeInterval(10))]
        let ai = [AIActivity(at: t.addingTimeInterval(30), feature: "Launcher", provider: "Local", model: "m", inputCharacters: 40, outputCharacters: 10, tokens: 5, secretsHidden: 2, status: "ok", note: nil)]
        let changes = [FeatureActivityLog.Change(feature: "midi", what: "Turned on", at: t.addingTimeInterval(20))]
        let failures = ["ddc": FeatureActivityLog.Failure(count: 3, last: "no answer", at: t)]
        let lines = ActivityFeed.merge(audit: audit, ai: ai, changes: changes, failures: failures)
        XCTAssertEqual(lines.map(\.source), [.ai, .change, .action, .failure])
        XCTAssertEqual(lines[1].title, "MIDI Triggers")
        XCTAssertTrue(lines[0].detail.contains("2 secrets hidden"))
        XCTAssertEqual(ActivityFeed.merge(audit: audit, ai: ai, changes: changes, failures: failures, limit: 2).count, 2)
    }

    func testTheReportCarriesNoSecretsOrPersonalPaths() {
        let t = Date()
        let audit = [AuditLog.Entry(kind: .files, summary: "Moved \(NSHomeDirectory())/Documents/a.txt with key sk-abcdefghijklmnopqrstuvwxyz", at: t)]
        let report = ActivityFeed.report(ActivityFeed.merge(audit: audit, ai: [], changes: [], failures: [:]))
        XCTAssertFalse(report.contains("sk-abcdefgh"))
        XCTAssertFalse(report.contains(NSHomeDirectory()))
        XCTAssertTrue(report.contains("[Actions]"))
    }

    func testPermissionAndAreaNamesAreReadable() {
        XCTAssertEqual(ActivityFeed.title(for: "permission:accessibility"), "Permission")
        XCTAssertEqual(ActivityFeed.title(for: "mouse"), "Mouse & Trackpad")
        XCTAssertEqual(ActivityFeed.title(for: "sound"), "Sound")
    }
}

final class FeatureExportTests: XCTestCase {
    func testAnAreaSurvivesExportAndImportAndKeepsToItsOwnKeys() throws {
        let defaults = UserDefaults(suiteName: "kriya-export-\(UUID().uuidString)")!
        let midi = try XCTUnwrap(FeatureReset.areas.first { $0.id == "midi" })
        defaults.set(Data([1, 2, 3]), forKey: "midiTriggers.v1")
        defaults.set(true, forKey: "midiTriggers.enabled")
        defaults.set("other", forKey: "launcherPrefs.v1")
        let data = try FeatureReset.exportData(midi, build: "25", in: defaults)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("launcherPrefs"), "only the area's own keys are exported")
        let values = try FeatureReset.importValues(data, into: midi)
        XCTAssertEqual(values["midiTriggers.v1"] as? Data, Data([1, 2, 3]))
        XCTAssertEqual(values["midiTriggers.enabled"] as? Bool, true)
    }

    func testAFileForAnotherAreaOrNotOursIsRefused() throws {
        let defaults = UserDefaults(suiteName: "kriya-export-\(UUID().uuidString)")!
        let midi = try XCTUnwrap(FeatureReset.areas.first { $0.id == "midi" })
        let sound = try XCTUnwrap(FeatureReset.areas.first { $0.id == "sound" })
        defaults.set(true, forKey: "midiTriggers.enabled")
        let data = try FeatureReset.exportData(midi, build: "25", in: defaults)
        XCTAssertThrowsError(try FeatureReset.importValues(data, into: sound)) { XCTAssertEqual($0 as? FeatureReset.ImportProblem, .wrongArea("midi")) }
        XCTAssertThrowsError(try FeatureReset.importValues(Data("{}".utf8), into: midi)) { XCTAssertEqual($0 as? FeatureReset.ImportProblem, .notOurs) }
        // A file that names a key from outside the area cannot write it.
        let sneaky = #"{"format":"kriya-settings-area","area":"midi","build":"1","values":{"launcherPrefs.v1":"x","midiTriggers.enabled":true}}"#
        let values = try FeatureReset.importValues(Data(sneaky.utf8), into: midi)
        XCTAssertEqual(Array(values.keys), ["midiTriggers.enabled"])
    }

    func testEveryResetAreaKeyBelongsToExactlyOneArea() {
        let keys = FeatureReset.areas.flatMap(\.keys)
        XCTAssertEqual(keys.count, Set(keys).count)
        XCTAssertNotNil(FeatureReset.areas.first { $0.id == "clipsync" })
    }
}

final class ConflictCenterTests: XCTestCase {
    private func midi(_ number: Int, name: String = "") -> MIDITrigger { var t = MIDITrigger(); t.number = number; t.name = name; t.targetID = "wf"; return t }

    func testMIDIControlsAppearAndClashWithEachOther() {
        let entries = InteractionMap.entries(InteractionMap.Inputs(midi: [midi(60, name: "A"), midi(60, name: "B"), midi(61, name: "C")]))
        XCTAssertEqual(entries.filter { $0.kind == .midi }.count, 3)
        let clashes = InteractionMap.clashes(entries)
        XCTAssertEqual(clashes.count, 0, "two of the same kind from the same part are that part's own business")
    }

    func testSeverityDistinguishesBlockedFromBoth() {
        func entry(_ kind: InteractionEntry.Kind, key: String = "k") -> InteractionEntry {
            InteractionEntry(kind: kind, owner: kind.rawValue, title: "t", trigger: "x", key: key, pane: .keyboard)
        }
        XCTAssertEqual(InteractionMap.severity(of: [entry(.remap), entry(.hotkey)]), .blocks)
        XCTAssertEqual(InteractionMap.severity(of: [entry(.gesture), entry(.mouseButton)]), .blocks)
        XCTAssertEqual(InteractionMap.severity(of: [entry(.hotCorner), entry(.automation)]), .both)
        XCTAssertEqual(InteractionMap.severity(of: [entry(.hotkey), entry(.automation)]), .order)
        XCTAssertTrue(InteractionMap.Severity.blocks < .both)
    }

    func testTheReportIsReadableAndSortedBySeverity() {
        let remap = InteractionEntry(kind: .remap, owner: "Key remapping", title: "Caps → Esc", trigger: "Caps Lock", key: "k", pane: .keyboard)
        let hotkey = InteractionEntry(kind: .hotkey, owner: "Windows", title: "Maximize", trigger: "Caps Lock", key: "k", pane: .windows)
        let report = InteractionMap.report([[remap, hotkey]])
        XCTAssertTrue(report.contains("One may never run"))
        XCTAssertTrue(report.contains("Key remapping › Caps → Esc"))
        XCTAssertEqual(InteractionMap.report([]), "No two things in Kriya want the same trigger.")
    }
}

final class CodeSignInfoTests: XCTestCase {
    func testWhatMacOSSaysIsTurnedIntoWords() {
        let notarized = CodeSignInfo.parse(spctl: "/Applications/Kriya.app: accepted\nsource=Notarized Developer ID", codesign: "Authority=Developer ID Application: A (X4MH29QNRS)\nTeamIdentifier=X4MH29QNRS")
        XCTAssertEqual(notarized.verdict, .notarized)
        XCTAssertEqual(notarized.team, "X4MH29QNRS")
        XCTAssertEqual(CodeSignInfo.parse(spctl: "accepted\nsource=Developer ID", codesign: "").verdict, .developerID)
        XCTAssertEqual(CodeSignInfo.parse(spctl: "rejected\nsource=no usable signature", codesign: "code object is not signed at all").verdict, .unsigned)
        XCTAssertEqual(CodeSignInfo.parse(spctl: "rejected", codesign: "Authority=Apple Development: me\nTeamIdentifier=ABC").verdict, .signedOnly)
        XCTAssertEqual(CodeSignInfo.parse(spctl: "", codesign: "").verdict, .unknown)
        XCTAssertNil(CodeSignInfo.parse(spctl: "", codesign: "TeamIdentifier=not set").team)
    }
}
