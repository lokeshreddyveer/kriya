import XCTest
@testable import Kriya

final class ConflictFixTests: XCTestCase {
    private func entry(_ kind: InteractionEntry.Kind, _ owner: String, _ title: String) -> InteractionEntry {
        InteractionEntry(kind: kind, owner: owner, title: title, trigger: "⌘K", key: "k:40:8", pane: .keyboard)
    }

    func testRemapsAndAutomationCanBeSwitchedOffHereAndTheRestAreChangedInTheirPane() {
        let group = [entry(.hotkey, "Windows", "Left half"), entry(.remap, "Key remapping", "Caps"), entry(.automation, "Automation", "Tidy")]
        let options = ConflictFix.options(for: group)
        XCTAssertEqual(options.filter { $0.action == .turnOff }.map(\.entry.title), ["Caps", "Tidy"])
        XCTAssertEqual(options.filter { $0.action == .change }.count, 3)
        XCTAssertFalse(ConflictFix.canTurnOff(group[0]))
    }

    func testTheSuggestedKeeperIsTheShortcutOrTheButtonRule() {
        let hotkey = entry(.hotkey, "Windows", "Left half"), remap = entry(.remap, "Key remapping", "Caps")
        XCTAssertEqual(ConflictFix.suggestedKeeper(in: [remap, hotkey]), hotkey)
        let button = entry(.mouseButton, "Mouse (Default)", "Back"), gesture = entry(.gesture, "Mouse (Default)", "Swipes")
        XCTAssertEqual(ConflictFix.suggestedKeeper(in: [gesture, button]), button)
        XCTAssertNil(ConflictFix.suggestedKeeper(in: [entry(.midi, "MIDI", "a"), entry(.midi, "MIDI", "b")]))
    }

    func testTurningOffSparesTheKeeperAndWhatCannotBeSwitchedOffHere() {
        let hotkey = entry(.hotkey, "Windows", "Left half"), remap = entry(.remap, "Key remapping", "Caps"), flow = entry(.automation, "Automation", "Tidy")
        XCTAssertEqual(ConflictFix.turnOffAllExcept(flow, in: [hotkey, remap, flow]).map(\.title), ["Caps"])
    }

    func testFreeShortcutsSkipWhatIsInUse() {
        let q = KeyNames.keyCode(forName: "Q")!
        let base = KeyModifiers.control | KeyModifiers.option | KeyModifiers.command
        let free = ConflictFix.freeShortcuts(usedKeys: [InteractionMap.keyboard(q, base)], limit: 3)
        XCTAssertEqual(free.count, 3)
        XCTAssertFalse(free.contains { $0.keyCode == q && $0.modifiers == base })
        XCTAssertTrue(free.allSatisfy { $0.modifiers & base == base })
    }
}

final class PasteIntoFolderTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_760_000_000)

    func testTextBecomesTxtOrMarkdownAndPicturesPng() {
        XCTAssertTrue(PasteIntoFolder.name(for: .text("hello"), at: date, exists: { _ in false })!.hasSuffix(".txt"))
        XCTAssertTrue(PasteIntoFolder.name(for: .text("# Title\nbody"), at: date, exists: { _ in false })!.hasSuffix(".md"))
        XCTAssertTrue(PasteIntoFolder.name(for: .imagePNG(Data([1])), at: date, exists: { _ in false })!.hasSuffix(".png"))
        XCTAssertNil(PasteIntoFolder.name(for: .nothing, at: date, exists: { _ in false }))
        XCTAssertNil(PasteIntoFolder.name(for: .files([]), at: date, exists: { _ in false }))
    }

    func testNothingIsOverwritten() {
        let first = PasteIntoFolder.name(for: .text("a"), at: date, exists: { _ in false })!
        let second = PasteIntoFolder.name(for: .text("a"), at: date, exists: { $0 == first })!
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(second.hasSuffix(" 2.txt"))
        XCTAssertEqual(PasteIntoFolder.uniqueName("a.pdf", exists: { $0 == "a.pdf" || $0 == "a 2.pdf" }), "a 3.pdf")
        XCTAssertEqual(PasteIntoFolder.uniqueName("notes", exists: { $0 == "notes" }), "notes 2")
        XCTAssertEqual(PasteIntoFolder.uniqueName("fresh.txt", exists: { _ in false }), "fresh.txt")
    }

    func testOnlyOrdinaryFoldersInHomeAreWrittenTo() {
        XCTAssertTrue(PasteIntoFolder.isAllowedFolder("/Users/me/Documents", home: "/Users/me"))
        XCTAssertTrue(PasteIntoFolder.isAllowedFolder("/Users/me", home: "/Users/me"))
        XCTAssertFalse(PasteIntoFolder.isAllowedFolder("/System/Library", home: "/Users/me"))
        XCTAssertFalse(PasteIntoFolder.isAllowedFolder("/Users/me/.ssh", home: "/Users/me"))
        XCTAssertFalse(PasteIntoFolder.isAllowedFolder("/Users/me/Library/Preferences", home: "/Users/me"))
        XCTAssertFalse(PasteIntoFolder.isAllowedFolder("/Users/mefoo", home: "/Users/me"))
        XCTAssertFalse(PasteIntoFolder.isAllowedFolder("/Users/me/../other", home: "/Users/me"))
    }
}

final class WorldClockAdditionTests: XCTestCase {
    private func place(_ label: String, _ zone: String) -> ClockPlace { ClockPlace(label: label, zoneID: zone) }
    private func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    func testOverlapIsOnlyWhereEveryoneIsAtWork() {
        // London and New York: 14:00-18:00 in London is 09:00-13:00 in New York (winter, 5 hours apart).
        let places = [place("LON", "Europe/London"), place("NYC", "America/New_York")]
        let slots = MeetingOverlap.merged(MeetingOverlap.slots(places: places, hours: BusinessHours(start: 9, end: 18), from: date("2026-01-12T00:00:00Z")))
        XCTAssertFalse(slots.isEmpty)
        let first = slots[0]
        XCTAssertEqual(first.start, date("2026-01-12T14:00:00Z"))
        XCTAssertEqual(first.end, date("2026-01-12T18:00:00Z"), "14:00 to 18:00 in London")
    }

    func testNoOverlapWhenTheDaysDoNotMeet() {
        let places = [place("LON", "Europe/London"), place("SYD", "Australia/Sydney")]
        let slots = MeetingOverlap.slots(places: places, hours: BusinessHours(start: 9, end: 17), from: date("2026-01-12T00:00:00Z"))
        XCTAssertTrue(slots.isEmpty, "Sydney is 11 hours ahead of London in January")
        XCTAssertTrue(MeetingOverlap.slots(places: [place("A", "Europe/London")], hours: BusinessHours(), from: Date()).isEmpty, "one place needs no overlap")
        XCTAssertTrue(MeetingOverlap.slots(places: [place("A", "Nowhere/Bad"), place("B", "Europe/London")], hours: BusinessHours(), from: Date()).isEmpty)
        XCTAssertTrue(MeetingOverlap.slots(places: [place("A", "Europe/London"), place("B", "Asia/Kolkata")], hours: BusinessHours(start: 10, end: 10), from: Date()).isEmpty)
    }

    func testHalfHourZonesAreHandled() {
        let places = [place("LON", "Europe/London"), place("DEL", "Asia/Kolkata")]
        let slots = MeetingOverlap.merged(MeetingOverlap.slots(places: places, hours: BusinessHours(start: 9, end: 18), from: date("2026-01-12T00:00:00Z")))
        XCTAssertFalse(slots.isEmpty)
        // London 09:00 is Kolkata 14:30, the first hour that is inside both working days.
        XCTAssertEqual(slots[0].start, date("2026-01-12T09:00:00Z"))
    }

    func testSpringForwardIsWarnedAboutInTheRightPlace() {
        let places = [place("NYC", "America/New_York"), place("DEL", "Asia/Kolkata")]
        let changes = DaylightWarnings.upcoming(places: places, from: date("2026-03-01T00:00:00Z"), days: 14)
        XCTAssertEqual(changes.map(\.place), ["NYC"])
        XCTAssertEqual(changes[0].shift, 60)
        XCTAssertTrue(DaylightWarnings.sentence(changes[0]).contains("forward 1 hour"))
        XCTAssertTrue(DaylightWarnings.upcoming(places: places, from: date("2026-06-01T00:00:00Z"), days: 14).isEmpty)
    }

    func testTimesAreReadAndConvertedWithTheDayNamed() {
        XCTAssertEqual(TimeConversion.minutes(from: "3pm"), 900)
        XCTAssertEqual(TimeConversion.minutes(from: "9:05 AM"), 545)
        XCTAssertEqual(TimeConversion.minutes(from: "12am"), 0)
        XCTAssertEqual(TimeConversion.minutes(from: "12pm"), 720)
        XCTAssertEqual(TimeConversion.minutes(from: "15:30"), 930)
        for bad in ["25:00", "13pm", "0pm", "noon", "", "9:75", "1:2:3"] { XCTAssertNil(TimeConversion.minutes(from: bad), bad) }
        let nyc = place("NYC", "America/New_York"), del = place("DEL", "Asia/Kolkata")
        let lines = TimeConversion.lines(time: "9pm", from: nyc, to: [nyc, del], on: date("2026-01-12T12:00:00Z"), twentyFourHour: false)
        XCTAssertEqual(lines, ["NYC 9:00 PM", "DEL 7:30 AM (tomorrow)"])
        XCTAssertTrue(TimeConversion.lines(time: "nonsense", from: nyc, to: [nyc], on: Date(), twentyFourHour: false).isEmpty)
    }
}

final class FolderRuleAdditionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_760_000_000)
    private func file(_ name: String) -> FolderFile { FolderFile(name: name, modified: now.addingTimeInterval(-3600)) }

    func testPatternsMatchTheWholeNameIgnoringCapitals() {
        XCTAssertTrue(NamePattern.matches(#"IMG_[0-9]+\.jpe?g"#, "img_2041.JPG"))
        XCTAssertFalse(NamePattern.matches(#"IMG_[0-9]+\.jpe?g"#, "my IMG_2041.jpg"), "the whole name must fit")
        XCTAssertFalse(NamePattern.matches("", "a"))
        XCTAssertFalse(NamePattern.matches("(", "a"))
    }

    func testBadPatternsAreExplainedAndNeverRun() {
        XCTAssertNotNil(NamePattern.problem(""))
        XCTAssertNotNil(NamePattern.problem("("))
        XCTAssertNotNil(NamePattern.problem(".*"), "matches everything")
        XCTAssertNotNil(NamePattern.problem("(a+)+$"), "runaway shape")
        XCTAssertNotNil(NamePattern.problem(String(repeating: "a", count: 200)))
        XCTAssertNil(NamePattern.problem(#"Screenshot .*\.png"#))
        XCTAssertFalse(NamePattern.matches("(a+)+$", String(repeating: "a", count: 40) + "!"), "refused, so it returns at once")
        XCTAssertEqual(NamePattern.test("a.*", samples: ["abc", "bcd"]).map(\.matches), [true, false])
    }

    func testARuleUsingAPatternMatchesAndIsCheckedBeforeSaving() {
        var rule = FolderRule(name: "Screens", folder: "/Users/me/Desktop", conditions: [.nameMatches(#"Screenshot.*"#)], action: .trash)
        XCTAssertTrue(FolderRuleEngine.matches(rule, file("Screenshot 1.png"), now: now))
        XCTAssertFalse(FolderRuleEngine.matches(rule, file("Photo.png"), now: now))
        rule.conditions = [.nameMatches("(")]
        XCTAssertEqual(FolderRuleEngine.problem(for: rule, folderExists: { _ in true }), "That is not a valid pattern.")
        let decoded = try? JSONDecoder().decode(FolderRule.self, from: JSONEncoder().encode(FolderRule(name: "x", folder: "/a", conditions: [.nameMatches("a")], action: .trash)))
        XCTAssertEqual(decoded?.conditions, [.nameMatches("a")])
    }

    func testTwoRulesThatBothMoveTheSameFileAreFlaggedButTagsAreNot() {
        let a = FolderRule(name: "PDFs", enabled: true, folder: "/Users/me/Downloads", conditions: [.extensionIs(["pdf"])], action: .moveTo("/Users/me/Documents"))
        let b = FolderRule(name: "Invoices", enabled: true, folder: "/Users/me/Downloads", conditions: [.nameContains("invoice")], action: .trash)
        let tag = FolderRule(name: "Tag", enabled: true, folder: "/Users/me/Downloads", conditions: [.extensionIs(["pdf"])], action: .tag("x"))
        let off = FolderRule(name: "Off", enabled: false, folder: "/Users/me/Downloads", conditions: [.extensionIs(["pdf"])], action: .trash)
        let other = FolderRule(name: "Elsewhere", enabled: true, folder: "/Users/me/Desktop", conditions: [.extensionIs(["pdf"])], action: .trash)
        let found = RuleOverlap.find([a, b, tag, off, other], files: [file("invoice.pdf"), file("notes.txt")], now: now)
        XCTAssertEqual(found, [RuleOverlap.Overlap(fileName: "invoice.pdf", rules: ["PDFs", "Invoices"])])
        XCTAssertTrue(RuleOverlap.sentence(found[0]).contains("The first in the list"))
        XCTAssertTrue(RuleOverlap.find([a], files: [file("invoice.pdf")], now: now).isEmpty)
    }
}

final class FocusAdditionTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_760_000_000)

    private func session(minutes: Int = 50) -> FocusSessionState {
        FocusPlan.start(FocusSessionConfig(minutes: minutes), dockHidden: false, desktopIconsShown: true, now: start).state
    }

    func testPausingStopsTheClockAndResumingMovesTheEndOut() {
        let s = session()
        let paused = FocusPlan.paused(s, at: start.addingTimeInterval(600))
        XCTAssertTrue(paused.isPaused)
        XCTAssertEqual(FocusPlan.paused(paused, at: start.addingTimeInterval(700)), paused, "pausing twice changes nothing")
        let back = FocusPlan.resumed(paused, at: start.addingTimeInterval(900))
        XCTAssertFalse(back.isPaused)
        XCTAssertEqual(back.endsAt, s.endsAt.addingTimeInterval(300))
        XCTAssertEqual(back.pausedTotal, 300)
        XCTAssertEqual(FocusPlan.resumed(s, at: start), s, "resuming a running session changes nothing")
    }

    func testFocusedMinutesLeaveOutPauses() {
        var s = session()
        s = FocusPlan.resumed(FocusPlan.paused(s, at: start.addingTimeInterval(600)), at: start.addingTimeInterval(1200))
        XCTAssertEqual(FocusPlan.focusedMinutes(s, now: start.addingTimeInterval(1800)), 20)
        let paused = FocusPlan.paused(s, at: start.addingTimeInterval(1800))
        XCTAssertEqual(FocusPlan.focusedMinutes(paused, now: start.addingTimeInterval(5000)), 20, "still paused")
    }

    func testABreakIsDueOncePerInterval() {
        var s = session(minutes: 120)
        XCTAssertFalse(FocusPlan.breakDue(s, now: start.addingTimeInterval(24 * 60), every: 25))
        XCTAssertTrue(FocusPlan.breakDue(s, now: start.addingTimeInterval(26 * 60), every: 25))
        s.breaksGiven = 1
        XCTAssertFalse(FocusPlan.breakDue(s, now: start.addingTimeInterval(30 * 60), every: 25))
        XCTAssertTrue(FocusPlan.breakDue(s, now: start.addingTimeInterval(51 * 60), every: 25))
        XCTAssertFalse(FocusPlan.breakDue(s, now: start.addingTimeInterval(51 * 60), every: nil))
        XCTAssertFalse(FocusPlan.breakDue(FocusPlan.paused(s, at: start), now: start.addingTimeInterval(9000), every: 25))
        XCTAssertEqual(FocusSessionConfig(breakEveryMinutes: 1).clamped.breakEveryMinutes, 5)
        XCTAssertNil(FocusSessionConfig(breakEveryMinutes: 0).clamped.breakEveryMinutes)
    }

    func testHistoryKeepsTheLastHundredAndTotalsTheWeek() {
        var history = FocusHistory()
        for i in 0..<120 { history.add(FocusHistory.Entry(startedAt: start.addingTimeInterval(Double(i)), plannedMinutes: 25, focusedMinutes: 25, completed: true)) }
        XCTAssertEqual(history.entries.count, 100)
        XCTAssertEqual(history.entries.first?.startedAt, start.addingTimeInterval(119))
        let old = FocusHistory.Entry(startedAt: start.addingTimeInterval(-10 * 86_400), plannedMinutes: 25, focusedMinutes: 25, completed: true)
        history.add(old)
        XCTAssertEqual(history.week(now: start.addingTimeInterval(200)).sessions, 99, "100 kept, one is old")
    }

    func testAnEarlyEndIsRecordedAsEarlyAndOldSavedSessionsStillLoad() throws {
        let s = session(minutes: 50)
        let entry = FocusHistory.entry(for: s, endedAt: start.addingTimeInterval(10 * 60))
        XCTAssertEqual(entry?.focusedMinutes, 10)
        XCTAssertEqual(entry?.completed, false)
        XCTAssertEqual(FocusHistory.entry(for: s, endedAt: s.endsAt)?.completed, true)
        let legacy = #"{"endsAt":0,"dockWasHidden":false,"desktopIconsWereShown":true,"changedDock":false,"changedDesktop":false,"endShortcut":""}"#
        let decoded = try JSONDecoder().decode(FocusSessionState.self, from: Data(legacy.utf8))
        XCTAssertNil(decoded.startedAt)
        XCTAssertNil(FocusHistory.entry(for: decoded, endedAt: start))
    }
}

final class ActionInsightTests: XCTestCase {
    func testRiskFollowsWhatTheActionCanDo() {
        XCTAssertEqual(ActionInsight.risk(of: .noop), .none)
        XCTAssertEqual(ActionInsight.risk(of: .openUrl(url: "https://a.com")), .low)
        XCTAssertEqual(ActionInsight.risk(of: .runShell(script: "rm -rf x")), .high)
        XCTAssertEqual(ActionInsight.risk(of: .builtin(command: "window.left_half")), .low)
        XCTAssertEqual(ActionInsight.risk(of: .builtin(command: "capture.record")), .medium)
        XCTAssertEqual(ActionInsight.risk(of: .sequence(steps: [.noop, .runShortcut(name: "x"), .runShell(script: "ls")], delayMs: 0)), .high, "a sequence is as risky as its worst step")
        XCTAssertEqual(ActionInsight.risk(of: .sequence(steps: [], delayMs: 0)), .none)
    }

    func testSameActionUnderTwoNamesIsFoundAndSearchNeedsEveryWord() {
        let a = NamedAction(id: "1", name: "Mail", action: .openApplication(target: "com.apple.mail"))
        let b = NamedAction(id: "2", name: "Open Mail", action: .openApplication(target: "com.apple.mail"))
        let c = NamedAction(id: "3", name: "Safari", action: .openApplication(target: "com.apple.Safari"))
        XCTAssertEqual(ActionInsight.duplicates([a, b, c]).map { $0.map(\.id) }, [["1", "2"]])
        XCTAssertEqual(ActionInsight.search([a, b, c], text: "open mail", describe: { _ in "" }).map(\.id), ["2"])
        XCTAssertEqual(ActionInsight.search([a, b, c], text: "", describe: { _ in "" }).count, 3)
        XCTAssertEqual(ActionInsight.search([a, b, c], text: "safari", describe: { _ in "Open com.apple.Safari" }).map(\.id), ["3"])
    }
}

final class DiskRiskTests: XCTestCase {
    private let home = "/Users/me"
    private func level(_ path: String) -> DiskRisk.Level { DiskRisk.classify(path, home: home).level }

    func testThingsProgramsRebuildAreSafeAndPersonalThingsAreKept() {
        XCTAssertEqual(level("/Users/me/Library/Caches/com.app"), .safe)
        XCTAssertEqual(level("/Users/me/Library/Developer/Xcode/DerivedData/App-abc"), .safe)
        XCTAssertEqual(level("/Users/me/Documents/project/node_modules"), .safe, "rebuildable even inside Documents")
        XCTAssertEqual(level("/Users/me/Documents/taxes.pdf"), .keep)
        XCTAssertEqual(level("/Users/me/Pictures/Photos Library.photoslibrary"), .keep)
        XCTAssertEqual(level("/Users/me/Library/Mobile Documents/com~apple~CloudDocs/a"), .keep)
        XCTAssertEqual(level("/System/Library/Frameworks"), .keep)
        XCTAssertEqual(level("/Users/me/code/app/.git"), .keep)
        XCTAssertEqual(level("/Users/me/Downloads/old.dmg"), .review)
        XCTAssertEqual(level("/Applications/Foo.app"), .review)
        XCTAssertEqual(level("/Volumes/Backup/stuff"), .review)
        XCTAssertEqual(level("/Users/me/Library/Application Support/Foo"), .keep)
    }

    func testCloudPlaceholdersAreRecognisedAndSuggestionsAreOnlyTheSafeOnesBiggestFirst() {
        XCTAssertTrue(DiskRisk.isCloudPlaceholder(".report.pdf.icloud"))
        XCTAssertFalse(DiskRisk.isCloudPlaceholder("report.pdf"))
        let items: [(path: String, size: Int64)] = [("/Users/me/Library/Caches/a", 10), ("/Users/me/Documents/x", 999), ("/Users/me/Library/Caches/b", 50), ("/Users/me/Library/Logs/c", 5)]
        let result = DiskRisk.cleanupSuggestions(items, limit: 2, home: home)
        XCTAssertEqual(result.items.map(\.path), ["/Users/me/Library/Caches/b", "/Users/me/Library/Caches/a"])
        XCTAssertEqual(result.total, 60)
    }
}

final class PowerAssertionTests: XCTestCase {
    private let sample = """
    Assertion status system-wide:
       BackgroundTask                 0
       PreventUserIdleSystemSleep     1
    Listed by owning process:
       pid 412(caffeinate): [0x0000000100012345] 00:12:05 PreventUserIdleSystemSleep named: "caffeinate command-line tool"
       \tTimeout will fire in 3595 secs Action=TimeoutActionRelease
       pid 733(zoom.us): [0x00000001000ABCDE] 01:02:03 PreventUserIdleDisplaySleep named: "Zoom Meeting"
       pid 733(zoom.us): [0x00000001000ABCDF] 01:02:03 PreventUserIdleDisplaySleep named: "Zoom Meeting"
       pid 90(powerd): [0x0000000100000001] 05:00:00 BackgroundTask named: "com.apple.powerd.bg"
    """

    func testHoldersAreReadAndRepeatsAndBackgroundWorkAreLeftOut() {
        let all = PowerAssertions.parse(sample)
        XCTAssertEqual(all.count, 4)
        XCTAssertEqual(all[0].process, "caffeinate")
        XCTAssertEqual(all[0].heldFor, "00:12:05")
        XCTAssertEqual(all[0].effect, "Keeps the Mac awake")
        XCTAssertEqual(PowerAssertions.awakeHolders(all).map(\.process), ["caffeinate", "zoom.us"])
        XCTAssertEqual(PowerAssertions.summary(all), "caffeinate and zoom.us are keeping this Mac awake.")
    }

    func testSummariesForNoneOneAndMany() {
        XCTAssertEqual(PowerAssertions.summary([]), "Nothing is keeping this Mac awake.")
        XCTAssertEqual(PowerAssertions.parse("garbage\n\nnot a line"), [])
        let many = (1...4).map { PowerAssertions.Assertion(pid: $0, process: "p\($0)", kind: "PreventSystemSleep", name: "n", heldFor: "0:0:1") }
        XCTAssertEqual(PowerAssertions.summary(many), "p1, p2 and 2 more are keeping this Mac awake.")
        XCTAssertEqual(PowerAssertions.summary([many[0]]), "p1 is keeping this Mac awake.")
    }
}

final class ResourceAlertTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_760_000_000)
    private var config: ResourceAlertConfig { ResourceAlertConfig(enabled: true, cpuPercent: 90, cpuSeconds: 60, memoryPercent: 90, diskFreeGB: 10, batteryHealthBelow: 80) }

    private func snapshot(cpu: Double = 0.1, memoryShare: Double = 0.4, freeGB: Int64 = 100) -> MonitorSnapshot {
        var s = MonitorSnapshot()
        s.cpu = cpu
        s.memory = MemoryInfo(total: 100, used: 100 * memoryShare)
        s.disks = [DiskInfo(name: "Macintosh HD", path: "/", total: 500 * 1_073_741_824, free: freeGB * 1_073_741_824, isInternal: true)]
        return s
    }

    func testBusyProcessorOnlySpeaksAfterItStaysBusyThenNotAgainForHalfAnHour() {
        var state = ResourceAlertState()
        XCTAssertTrue(ResourceAlerts.evaluate(snapshot(cpu: 0.95), config: config, state: &state, now: start).isEmpty, "just started being busy")
        XCTAssertTrue(ResourceAlerts.evaluate(snapshot(cpu: 0.95), config: config, state: &state, now: start.addingTimeInterval(30)).isEmpty)
        let said = ResourceAlerts.evaluate(snapshot(cpu: 0.95), config: config, state: &state, now: start.addingTimeInterval(61))
        XCTAssertEqual(said.count, 1)
        XCTAssertTrue(said[0].contains("above 90%"))
        XCTAssertTrue(ResourceAlerts.evaluate(snapshot(cpu: 0.95), config: config, state: &state, now: start.addingTimeInterval(120)).isEmpty, "not again at once")
        XCTAssertEqual(ResourceAlerts.evaluate(snapshot(cpu: 0.95), config: config, state: &state, now: start.addingTimeInterval(61 + 31 * 60)).count, 1, "after the cooldown")
    }

    func testABriefSpikeResetsTheWatch() {
        var state = ResourceAlertState()
        _ = ResourceAlerts.evaluate(snapshot(cpu: 0.95), config: config, state: &state, now: start)
        _ = ResourceAlerts.evaluate(snapshot(cpu: 0.2), config: config, state: &state, now: start.addingTimeInterval(30))
        XCTAssertNil(state.cpuHighSince)
        XCTAssertTrue(ResourceAlerts.evaluate(snapshot(cpu: 0.95), config: config, state: &state, now: start.addingTimeInterval(70)).isEmpty, "the clock started again")
    }

    func testMemoryAndDiskSpeakAtOnceAndSpeakAgainOnceTheyRecover() {
        var state = ResourceAlertState()
        let low = ResourceAlerts.evaluate(snapshot(memoryShare: 0.95, freeGB: 5), config: config, state: &state, now: start)
        XCTAssertEqual(low.count, 2)
        XCTAssertTrue(low.contains { $0.contains("Memory is 95% full") })
        XCTAssertTrue(low.contains { $0.contains("free on the startup disk") })
        XCTAssertTrue(ResourceAlerts.evaluate(snapshot(memoryShare: 0.95, freeGB: 5), config: config, state: &state, now: start.addingTimeInterval(10)).isEmpty)
        _ = ResourceAlerts.evaluate(snapshot(), config: config, state: &state, now: start.addingTimeInterval(20))
        XCTAssertEqual(ResourceAlerts.evaluate(snapshot(memoryShare: 0.95), config: config, state: &state, now: start.addingTimeInterval(30)).count, 1, "recovered, so it can speak again")
    }

    func testHotMacAndTiredBatterySpeakAndTheSwitchTurnsItAllOff() {
        var state = ResourceAlertState()
        var s = snapshot()
        s.thermal = .serious
        s.battery = BatteryInfo(percent: 50, charging: false, onAC: false, minutesLeft: nil, cycles: 900, healthPercent: 72)
        XCTAssertEqual(ResourceAlerts.evaluate(s, config: config, state: &state, now: start).count, 2)
        var off = config
        off.enabled = false
        XCTAssertTrue(ResourceAlerts.evaluate(s, config: off, state: &state, now: start.addingTimeInterval(5)).isEmpty)
        XCTAssertEqual(state, ResourceAlertState(), "turning it off forgets what was said")
        XCTAssertEqual(ResourceAlertConfig(enabled: true, cpuPercent: 5, cpuSeconds: 1, memoryPercent: 500, diskFreeGB: 0, batteryHealthBelow: 0).clamped.cpuPercent, 50)
    }
}

final class InputToolsTests: XCTestCase {
    private func settings(_ rules: [ButtonRule], gestureButton: UInt32? = nil) -> MouseSettings {
        var s = defaultMouseSettings()
        s.buttons = rules
        if let gestureButton { s.gestures.enabled = true; s.gestures.activationButton = gestureButton }
        return s
    }

    func testTheSimulatorSaysWhatARuleWouldDoAndWhatSharesItsButton() {
        let click = ButtonRule(button: 3, modifiers: 0, actionId: "back", trigger: .click)
        let hold = ButtonRule(button: 3, modifiers: 0, actionId: "mc", trigger: .hold)
        let s = settings([click, hold])
        XCTAssertEqual(RuleSimulator.simulate(s, button: 3, modifiers: 0, held: false, actionName: { $0 }).outcome, .runs(actionID: "back"))
        XCTAssertEqual(RuleSimulator.simulate(s, button: 3, modifiers: 0, held: true, actionName: { $0 }).outcome, .runs(actionID: "mc"))
        XCTAssertTrue(RuleSimulator.simulate(s, button: 3, modifiers: 0, held: false, actionName: { $0 }).notes.contains { $0.contains("hold rule") })
        let none = RuleSimulator.simulate(s, button: 4, modifiers: 0, held: false, actionName: { $0 })
        XCTAssertEqual(none.outcome, .nothing)
    }

    func testModifiersGesturesAndDuplicatesAreExplained() {
        let withKey = ButtonRule(button: 3, modifiers: KeyModifiers.command, actionId: "a", trigger: .click)
        let result = RuleSimulator.simulate(settings([withKey]), button: 3, modifiers: 0, held: false, actionName: { $0 })
        XCTAssertEqual(result.outcome, .nothing)
        XCTAssertTrue(result.notes.contains { $0.contains("different modifier keys") })
        let gesture = RuleSimulator.simulate(settings([], gestureButton: 4), button: 4, modifiers: 0, held: false, actionName: { $0 })
        XCTAssertTrue(gesture.notes.contains { $0.contains("swipe gesture") })
        let twice = settings([ButtonRule(button: 3, modifiers: 0, actionId: "a", trigger: .click), ButtonRule(button: 3, modifiers: 0, actionId: "b", trigger: .click)])
        XCTAssertEqual(RuleSimulator.simulate(twice, button: 3, modifiers: 0, held: false, actionName: { $0 }).outcome, .ambiguous(actionIDs: ["a", "b"]))
    }

    func testPointerProfilesTurnEffectsOnAndAccessibilityIsLargest() {
        var a = PointerEffectsStore.blank, b = a
        PointerProfile.presentation.apply(to: &a)
        PointerProfile.accessibility.apply(to: &b)
        XCTAssertTrue(a.enabled && a.haloEnabled && a.clickEnabled && a.showWhenSharing)
        XCTAssertGreaterThan(b.haloSize, a.haloSize)
        var r = a
        PointerProfile.recording.apply(to: &r)
        XCTAssertFalse(r.haloEnabled)
        XCTAssertEqual(PointerProfile.allCases.count, 4)
    }

    func testDeviceHealthFallsWithEachDropInADayAndNeedsHistory() {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        var t = DeviceTimeline()
        XCTAssertNil(t.health(of: "Mouse", now: now))
        t.record("Mouse", connected: true, at: now.addingTimeInterval(-90_000))
        XCTAssertEqual(t.health(of: "Mouse", now: now), 100)
        for i in 0..<4 { t.record("Mouse", connected: false, at: now.addingTimeInterval(Double(-i * 600))) }
        XCTAssertEqual(t.health(of: "Mouse", now: now), 40)
        XCTAssertEqual(DeviceTimeline.describe(health: 40), "Keeps disconnecting")
        XCTAssertEqual(DeviceTimeline.describe(health: 100), "Steady")
        for _ in 0..<400 { t.record("Pad", connected: true, at: now) }
        XCTAssertEqual(t.events.count, DeviceTimeline.limit)
        XCTAssertTrue(t.events(for: "Mouse").count < 5)
    }
}

final class WindowToolsTests: XCTestCase {
    func testLocksCoverAWholeAppOrOnlyWindowsWithATitle() {
        let all = WindowLock(appID: "com.a", titleContains: "")
        let some = WindowLock(appID: "com.b", titleContains: "Budget")
        XCTAssertTrue(WindowLocks.isLocked([all, some], appID: "com.a", title: "Anything"))
        XCTAssertTrue(WindowLocks.isLocked([all, some], appID: "com.b", title: "my budget 2026"))
        XCTAssertFalse(WindowLocks.isLocked([all, some], appID: "com.b", title: "Notes"))
        XCTAssertFalse(WindowLocks.isLocked([all, some], appID: "com.c", title: "Budget"))
        XCTAssertFalse(WindowLocks.isLocked([], appID: "com.a", title: ""))
    }

    func testPreviewSaysWhatEachEntryWouldDo() {
        let entries = [("com.a", "Doc", "d1"), ("com.b", "", "d1"), ("com.c", "", "d1"), ("com.d", "", "d9"), ("com.e", "", "d1")]
        let open = [("com.a", "Doc"), ("com.d", "x"), ("com.e", "Secret"), ("com.c", "other")]
        let matches: [Int?] = [0, 3, 4, nil]
        let rows = LayoutPreview.rows(entries: entries, launchMissing: true, open: open, matches: matches, runningApps: ["com.a", "com.c", "com.d", "com.e"],
                                      displayIDs: ["d1"], isLocked: { $0 == "com.e" })
        XCTAssertEqual(rows.map(\.result), [.moves(windowTitle: "Doc"), .appMissing(willOpen: true), .noMatchingWindow, .displayAbsent, .lockedWindow])
        XCTAssertTrue(rows[0].willMove)
        XCTAssertFalse(rows[4].willMove)
        XCTAssertTrue(LayoutPreview.describe(rows[1], appName: "B").contains("will be opened"))
        XCTAssertTrue(LayoutPreview.describe(rows[3], appName: "D").contains("main display"))
    }
}

final class WorkspaceToolsTests: XCTestCase {
    func testThePlanSeparatesWhatOpensWhatIsOpenAndWhatIsMissing() {
        let plan = WorkspaceLaunchPlan.make(appIDs: ["a", "b", "c", "a"], running: ["b"], installed: { $0 != "c" })
        XCTAssertEqual(plan, WorkspaceLaunchPlan(toOpen: ["a"], alreadyRunning: ["b"], notInstalled: ["c"]))
        XCTAssertEqual(plan.sentence(name: { $0.uppercased() }), "will open A; leaves B as it is; cannot find c")
        XCTAssertEqual(WorkspaceLaunchPlan().sentence(name: { $0 }), "has no apps")
    }

    func testUndoOnlyTouchesWhatTheLaunchDidAndSkipsWhatHasGone() {
        let entry = WorkspaceLaunchLog.Entry(at: Date(), workspaceID: "w", workspaceName: "Work", opened: ["new1", "new2"], alreadyRunning: ["old"], notInstalled: [], hidden: ["h1", "h2"], urlsOpened: 0)
        let plan = WorkspaceRollback.plan(for: entry, running: ["new1", "old", "h2"])
        XCTAssertEqual(plan, WorkspaceRollback.Plan(quit: ["new1"], unhide: ["h2"]))
        XCTAssertFalse(plan.quit.contains("old"))
    }

    func testTheLogKeepsFiftyAndFindsTheLastUndoableOne() {
        var log = WorkspaceLaunchLog()
        func entry(_ opened: [String]) -> WorkspaceLaunchLog.Entry { .init(at: Date(), workspaceID: "w", workspaceName: "W", opened: opened, alreadyRunning: [], notInstalled: [], hidden: [], urlsOpened: 0) }
        log.add(entry(["a"]))
        let nothingOpened = entry([])
        log.add(nothingOpened)
        XCTAssertEqual(log.lastUndoable?.opened, ["a"], "a launch that did nothing is not worth undoing")
        let id = log.lastUndoable!.id
        log.markUndone(id)
        XCTAssertNil(log.lastUndoable)
        for _ in 0..<60 { log.add(entry(["x"])) }
        XCTAssertEqual(log.entries.count, WorkspaceLaunchLog.limit)
    }
}

final class TrafficInsightTests: XCTestCase {
    func testEachChangedRuleSaysWhatMacOSWouldHaveDone() {
        let notes = TrafficInsight.notes(for: [
            TrafficBinding(button: .close, modifiers: 0, action: .quitApp),
            TrafficBinding(button: .zoom, modifiers: KeyModifiers.option, action: .maximize),
            TrafficBinding(button: .minimize, modifiers: 0, action: .native),
            TrafficBinding(button: .zoom, modifiers: 0, action: .doNothing),
        ])
        XCTAssertEqual(notes.count, 3)
        XCTAssertTrue(notes[0].text.contains("plain click on the red button now quit app"))
        XCTAssertTrue(notes[0].text.contains("macOS closes the window"))
        XCTAssertTrue(notes[1].text.contains("zooms the window"))
        XCTAssertTrue(notes[2].text.contains("does nothing"))
        XCTAssertTrue(notes[2].text.contains("enters full screen"))
    }

    func testRepeatedRulesAndTheTitleBarAreReported() {
        let twice = [TrafficBinding(button: .close, modifiers: 0, action: .hideApp), TrafficBinding(button: .close, modifiers: 0, action: .quitApp)]
        XCTAssertEqual(TrafficInsight.duplicates(twice).count, 1)
        XCTAssertTrue(TrafficInsight.duplicates([twice[0]]).isEmpty)
        XCTAssertNil(TrafficInsight.titleBarNote(.native))
        XCTAssertNotNil(TrafficInsight.titleBarNote(.maximize))
    }
}

final class DisplayInsightTests: XCTestCase {
    func testHDRWordsFollowWhatTheScreenReports() {
        XCTAssertEqual(DisplayInsight.hdr(potential: 1.0, current: 1.0), "No HDR support")
        XCTAssertEqual(DisplayInsight.hdr(potential: 4.0, current: 1.0), "HDR capable; showing standard content now")
        XCTAssertEqual(DisplayInsight.hdr(potential: 4.0, current: 2.5), "HDR content is showing now")
    }

    func testDDCReportSaysWhatAnsweredAndWhatDidNot() {
        let text = DisplayInsight.ddcReport(name: "Dell", brightness: DDC.Reading(current: 50, maximum: 100), input: nil)
        XCTAssertTrue(text.contains("brightness works (now 50%)"))
        XCTAssertTrue(text.contains("input switching did not answer"))
    }

    func testWakeRestoreSkipsGoneMonitorsAndZeroAndClamps() {
        let result = DisplayInsight.brightnessToRestore(saved: ["a": 60, "b": 0, "c": 40, "d": 300], connected: ["a", "b", "d"])
        XCTAssertEqual(result, ["a": 60, "d": 100])
    }

    func testChangesNameWhatAppearedAndWhatLeft() {
        let result = DisplayInsight.changes(before: ["1": "Built-in", "2": "Dell"], after: ["1": "Built-in", "3": "LG"])
        XCTAssertEqual(result.map { "\($0.name) \($0.connected)" }, ["Dell false", "LG true"])
        XCTAssertTrue(DisplayInsight.changes(before: ["1": "A"], after: ["1": "A"]).isEmpty)
    }
}

final class UsageLogTests: XCTestCase {
    func testTheLogKeepsNamesCountsUsesAndForgetsOldOnes() {
        var log = UsageLog()
        let t = Date(timeIntervalSince1970: 1_760_000_000)
        log.record("Copy", detail: "Safari", at: t)
        log.record("Search", at: t.addingTimeInterval(1))
        log.record("Copy", at: t.addingTimeInterval(2))
        log.record("", at: t)
        XCTAssertEqual(log.entries.count, 3)
        XCTAssertEqual(log.top(1).map(\.title), ["Copy"])
        XCTAssertEqual(log.top(5).map(\.uses), [2, 1])
        XCTAssertEqual(log.lastUsed("Copy"), t.addingTimeInterval(2))
        XCTAssertNil(log.lastUsed("Nope"))
        for i in 0..<150 { log.record("x\(i)", at: t) }
        XCTAssertEqual(log.entries.count, UsageLog.limit)
        XCTAssertEqual(UsageLog().top(3).count, 0)
    }

    func testLongNamesAreCut() {
        var log = UsageLog()
        log.record(String(repeating: "a", count: 200), detail: String(repeating: "b", count: 200), at: Date())
        XCTAssertEqual(log.entries[0].title.count, 80)
        XCTAssertEqual(log.entries[0].detail.count, 80)
    }
}

final class JobQueueTests: XCTestCase {
    func testJobsRunInOrderAndPauseHoldsBackTheNextOne() {
        var q = JobQueueState()
        q.add(id: "1", title: "Compress 3 items"); q.add(id: "2", title: "Convert 1 item")
        XCTAssertEqual(q.next?.id, "1")
        q.start("1")
        XCTAssertEqual(q.next?.id, "2")
        q.setPaused(true)
        XCTAssertNil(q.next)
        XCTAssertEqual(q.summary, "1 running, 1 waiting (paused: waiting ones will not start)")
        q.setPaused(false)
        q.finish("1", failed: false)
        XCTAssertEqual(q.runningCount, 0)
        XCTAssertEqual(q.waitingCount, 1)
    }

    func testOnlyAWaitingJobCanBeCancelledAndFinishedOnesAreTrimmed() {
        var q = JobQueueState()
        q.add(id: "a", title: "A"); q.add(id: "b", title: "B")
        q.start("a")
        XCTAssertFalse(q.cancelWaiting("a"), "a running job cannot be stopped")
        XCTAssertTrue(q.cancelWaiting("b"))
        XCTAssertFalse(q.cancelWaiting("zzz"))
        q.finish("a", failed: true)
        XCTAssertEqual(q.jobs.first?.status, .failed)
        XCTAssertEqual(q.summary, "No file operations waiting.")
        for i in 0..<40 { q.add(id: "j\(i)", title: "J"); q.finish("j\(i)", failed: false) }
        XCTAssertLessThanOrEqual(q.jobs.count, JobQueueState.keepFinished)
    }
}

final class CaptureProfileTests: XCTestCase {
    func testAProfileChangesWhereAndHowButKeepsShortcutsAndWords() {
        var base = CaptureSettings()
        base.redactWords = ["Priya"]
        base.shortcuts = [CaptureShortcut(command: "capture.region", keyCode: 1, modifiers: 1)]
        let applied = CaptureProfile.starters[2].applied(to: base)
        XCTAssertEqual(applied.delaySeconds, 3)
        XCTAssertEqual(applied.includeCursor, true)
        XCTAssertEqual(applied.redactWords, ["Priya"])
        XCTAssertEqual(applied.shortcuts.count, 1)
        XCTAssertTrue(applied.saveToFolder)
    }

    func testAProfileThatKeepsNothingStillCopies() {
        var p = CaptureProfile.starters[0]
        p.copyImage = false; p.saveToFolder = false
        XCTAssertTrue(p.applied(to: CaptureSettings()).copyImage)
    }

    func testRoundTripAndTheCursorFlag() {
        var s = CaptureSettings()
        s.delaySeconds = 5; s.openEditor = true
        let p = CaptureProfile.from(s, named: "Mine")
        var other = CaptureSettings(); other.copyImage = false
        XCTAssertEqual(p.applied(to: other).delaySeconds, 5)
        let out = URL(fileURLWithPath: "/tmp/x.png")
        XCTAssertEqual(ScreenCaptureArguments.make(mode: .screen, delay: 0, sound: false, output: out, cursor: true), ["-x", "-C", "-t", "png", "/tmp/x.png"])
        XCTAssertEqual(ScreenCaptureArguments.make(mode: .screen, delay: 0, sound: false, output: out), ["-x", "-t", "png", "/tmp/x.png"])
    }

    func testOlderSavedSettingsStillLoad() throws {
        let legacy = #"{"copyImage":true,"saveToFolder":true,"folderPath":"","openEditor":false,"redactAutomatically":false,"delaySeconds":0,"playSound":false,"redactWords":[],"shortcuts":[]}"#
        XCTAssertNil(try JSONDecoder().decode(CaptureSettings.self, from: Data(legacy.utf8)).includeCursor)
    }
}

final class ShelfCareTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_760_000_000)
    private func file(_ path: String, added: Date) -> ShelfRecord { ShelfRecord(kind: .file, value: path, added: added) }

    func testItemsAboutToExpireAreListedSoonestFirst() {
        var lib = ShelfLibrary()
        lib.expiryDays = 1
        lib.shelves[0].items = [file("/a", added: now.addingTimeInterval(-23 * 3600)), file("/b", added: now.addingTimeInterval(-10 * 3600)), file("/c", added: now.addingTimeInterval(-26 * 3600))]
        let soon = lib.expiring(within: 24, now: now)
        XCTAssertEqual(soon.map(\.record.value), ["/a", "/b"])
        XCTAssertEqual(soon.map(\.hoursLeft), [1, 14])
        lib.expiryDays = nil
        XCTAssertTrue(lib.expiring(within: 24, now: now).isEmpty)
    }

    func testMissingFilesAndDuplicatesAcrossShelvesAreFound() {
        var lib = ShelfLibrary()
        lib.shelves[0].items = [file("/here", added: now), file("/gone", added: now), ShelfRecord(kind: .text, value: "note", added: now)]
        var second = ShelfSet(name: "Second")
        second.items = [file("/here", added: now)]
        lib.shelves.append(second)
        XCTAssertEqual(lib.missingFiles(exists: { $0 == "/here" }).map(\.value), ["/gone"])
        let dupes = lib.duplicatesAcrossShelves()
        XCTAssertEqual(dupes.count, 1)
        XCTAssertEqual(Set(dupes[0].compactMap(\.shelf)), ["Shelf", "Second"])
        let ids = lib.missingFiles(exists: { _ in false }).map(\.id)
        lib.remove(ids, now: now)
        XCTAssertEqual(lib.history.count, 2)
    }

    func testGroupsKeepRelatedItemsTogetherAndLooseOnesLast() {
        var lib = ShelfLibrary()
        let a = file("/a", added: now), b = file("/b", added: now), c = file("/c", added: now)
        lib.shelves[0].items = [a, b, c]
        lib.setGroup("Taxes", for: a.id)
        lib.setGroup("  Taxes ", for: b.id)
        lib.setGroup("", for: c.id)
        let groups = lib.groups()
        XCTAssertEqual(groups.map { $0.name }, ["Taxes", nil])
        XCTAssertEqual(groups[0].items.count, 2)
        lib.setGroup(nil, for: a.id)
        XCTAssertEqual(lib.groups().first?.items.count, 1)
    }

    func testOldShelvesWithoutGroupsStillLoad() throws {
        let json = #"{"shelves":[{"id":"main","name":"Shelf","items":[{"id":"1","kind":"file","value":"/a","added":0}]}],"currentID":"main","history":[]}"#
        let lib = try JSONDecoder().decode(ShelfLibrary.self, from: Data(json.utf8))
        XCTAssertNil(lib.shelves[0].items[0].group)
    }
}

final class AppTrustTests: XCTestCase {
    func testNotarizedStoreAndRejectedAppsAreTold() {
        let sign = "Authority=Developer ID Application: Acme Ltd (ABCDE12345)\nTeamIdentifier=ABCDE12345\n"
        let notarized = AppTrust.parse(codesign: sign, spctl: "/A.app: accepted\nsource=Notarized Developer ID\n")
        XCTAssertEqual(notarized.level, .notarized)
        XCTAssertEqual(notarized.signer, "Developer ID Application: Acme Ltd (ABCDE12345)")
        XCTAssertEqual(notarized.teamID, "ABCDE12345")
        XCTAssertEqual(AppTrust.parse(codesign: "Authority=Apple Mac OS Application Signing\n", spctl: "accepted\nsource=Mac App Store").level, .appStore)
        XCTAssertEqual(AppTrust.parse(codesign: sign, spctl: "/A.app: rejected\nsource=no usable signature").level, .rejected)
        XCTAssertTrue(AppTrust.parse(codesign: sign, spctl: "rejected").isConcerning)
        XCTAssertFalse(notarized.isConcerning)
    }

    func testUnsignedAdhocAndUnknownAreTold() {
        XCTAssertEqual(AppTrust.parse(codesign: "/A.app: code object is not signed at all", spctl: "rejected").level, .unsigned)
        XCTAssertEqual(AppTrust.parse(codesign: "Signature=adhoc\nTeamIdentifier=not set\n", spctl: "").level, .adhoc)
        XCTAssertEqual(AppTrust.parse(codesign: "", spctl: "").level, .unknown)
        XCTAssertEqual(AppTrust.parse(codesign: "Signature=adhoc\nTeamIdentifier=not set", spctl: "").teamID, nil)
    }

    func testHomebrewDiagnosisNamesTheLikelyProblem() {
        let missing = HomebrewDiagnosis.lines(appleSilicon: false, foundAt: nil, optHomebrewExists: true, usrLocalExists: true, pathVariable: "/usr/bin")
        XCTAssertTrue(missing.contains { $0.contains("/opt/homebrew exists") })
        let wrongPlace = HomebrewDiagnosis.lines(appleSilicon: true, foundAt: "/usr/local/bin/brew", optHomebrewExists: false, usrLocalExists: true, pathVariable: "/usr/local/bin:/usr/bin")
        XCTAssertTrue(wrongPlace.contains { $0.contains("normally lives at /opt/homebrew/bin/brew") })
        let offPath = HomebrewDiagnosis.lines(appleSilicon: true, foundAt: "/opt/homebrew/bin/brew", optHomebrewExists: true, usrLocalExists: false, pathVariable: "/usr/bin")
        XCTAssertTrue(offPath.contains { $0.contains("not on the PATH") })
        XCTAssertEqual(HomebrewDiagnosis.lines(appleSilicon: true, foundAt: "/opt/homebrew/bin/brew", optHomebrewExists: true, usrLocalExists: false, pathVariable: "/opt/homebrew/bin").count, 1)
    }
}

final class LauncherExplainTests: XCTestCase {
    private func item(_ id: String, _ title: String, _ category: LauncherCategory = .app) -> LauncherCandidate {
        LauncherCandidate(id: id, title: title, subtitle: "", keywords: [], category: category, queryScore: nil, rememberable: true)
    }

    func testTheBreakdownAddsUpToTheScoreRankingUses() {
        var prefs = LauncherPrefsData()
        prefs.pinned = ["safari"]
        let now = Date()
        prefs.usage["safari"] = LauncherUsage(count: 3, last: now)
        let candidate = item("safari", "Safari")
        let explanation = LauncherEngine.explain(candidate, query: "saf", prefs: prefs, now: now)
        XCTAssertNotNil(explanation.total)
        XCTAssertTrue(explanation.lines.contains { $0.hasPrefix("Pinned") })
        XCTAssertTrue(explanation.lines.contains { $0.contains("often or lately") })
        let ranked = LauncherEngine.rank([candidate, item("other", "Sapphire")], query: "saf", prefs: prefs, now: now)
        XCTAssertEqual(ranked.first, "safari")
    }

    func testNonMatchesAndSwitchedOffGroupsSayWhy() {
        var prefs = LauncherPrefsData()
        XCTAssertNil(LauncherEngine.explain(item("a", "Notes"), query: "zzz", prefs: prefs).total)
        XCTAssertTrue(LauncherEngine.explain(item("a", "Notes"), query: "zzz", prefs: prefs).lines[0].contains("does not match"))
        prefs.hidden = ["a"]
        XCTAssertEqual(LauncherEngine.explain(item("a", "Notes"), query: "notes", prefs: prefs).lines, ["You hid this result."])
        XCTAssertTrue(LauncherEngine.explain(item("a", "Notes"), query: "", prefs: LauncherPrefsData()).lines[0].contains("Nothing typed"))
    }

    func testAnAliasWinsAndSaysSo() {
        var prefs = LauncherPrefsData()
        prefs.aliases["n"] = "a"
        let e = LauncherEngine.explain(item("a", "Notes"), query: "n", prefs: prefs)
        XCTAssertTrue(e.lines[0].contains("short name"))
        XCTAssertGreaterThanOrEqual(e.total ?? 0, 5000)
    }
}

final class NoteVersionTests: XCTestCase {
    private func makeStore() -> (NoteStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kriya-notes-\(UUID().uuidString)", isDirectory: true)
        return (NoteStore(folder: dir), dir)
    }

    func testEditsKeepEarlierVersionsAtMostEveryFiveMinutesAndTheyStayOutOfTheList() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let t = Date(timeIntervalSince1970: 1_760_000_000)
        let url = try XCTUnwrap(store.create("first draft", date: t))
        store.save("second draft", to: url, now: t.addingTimeInterval(10))
        XCTAssertEqual(store.versions(of: url).count, 1)
        store.save("third draft", to: url, now: t.addingTimeInterval(60))
        XCTAssertEqual(store.versions(of: url).count, 1, "too soon after the last one")
        store.save("fourth draft", to: url, now: t.addingTimeInterval(400))
        XCTAssertEqual(store.versions(of: url).count, 2)
        XCTAssertEqual(store.list().count, 1, "versions are not notes")
        XCTAssertEqual(store.read(store.versions(of: url)[1].url), "first draft")
    }

    func testGoingBackKeepsWhatWasReplacedSoItCanBeUndone() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let t = Date(timeIntervalSince1970: 1_760_000_000)
        let url = try XCTUnwrap(store.create("old words", date: t))
        store.save("new words", to: url, now: t.addingTimeInterval(10))
        let old = try XCTUnwrap(store.versions(of: url).last)
        XCTAssertTrue(store.restore(old, to: url, now: t.addingTimeInterval(20)))
        XCTAssertEqual(store.read(url), "old words")
        XCTAssertTrue(store.versions(of: url).contains { store.read($0.url) == "new words" })
    }

    func testOnlyTwentyAreKeptAndEmptyOrUnchangedTextKeepsNothing() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let t = Date(timeIntervalSince1970: 1_760_000_000)
        let url = try XCTUnwrap(store.create("v0", date: t))
        store.save("v0", to: url, now: t.addingTimeInterval(1))
        XCTAssertTrue(store.versions(of: url).isEmpty, "nothing changed")
        for i in 1...30 { store.save("v\(i)", to: url, now: t.addingTimeInterval(Double(i) * 400)) }
        XCTAssertEqual(store.versions(of: url).count, NoteStore.versionLimit)
        let blank = try XCTUnwrap(store.create("   ", date: t.addingTimeInterval(5)))
        store.save("now words", to: blank, now: t.addingTimeInterval(6))
        XCTAssertTrue(store.versions(of: blank).isEmpty)
    }
}

final class LicenseAndBackupSizeTests: XCTestCase {
    func testEveryListedCrateIsReadFromCargoTomlText() {
        let cargo = """
        [package]
        name = "x"

        [dependencies]
        uniffi = { version = "0.32" }
        serde = "1"
        # sha2 = "0"
        regex = "1"

        [dev-dependencies]
        tempfile = "3"
        """
        XCTAssertEqual(Licenses.dependencyNames(inCargo: cargo), ["uniffi", "serde", "regex"])
    }

    func testTheLicenseListNamesEveryDependencyTheCoreHas() {
        XCTAssertEqual(Licenses.rustCrates, ["rusqlite", "uniffi", "serde", "serde_json", "regex", "url", "thiserror", "sha2", "aes-gcm", "hmac"])
        XCTAssertTrue(Licenses.all.contains { $0.name == "Sparkle" })
        XCTAssertEqual(Set(Licenses.all.map(\.name)).count, Licenses.all.count)
    }

    func testBackupSizesAreAddedUpInWords() {
        let a = BackupFileInfo(url: URL(fileURLWithPath: "/a"), date: Date(), size: 1_000_000)
        let b = BackupFileInfo(url: URL(fileURLWithPath: "/b"), date: Date(), size: 500_000)
        XCTAssertEqual(BackupSizes.total([a, b]), 1_500_000)
        XCTAssertTrue(BackupSizes.summary([a, b]).hasPrefix("2 backups, "))
        XCTAssertEqual(BackupSizes.summary([]), "No backups")
        XCTAssertTrue(BackupSizes.summary([a]).hasPrefix("1 backup, "))
    }
}

final class DiagnosticReportTests: XCTestCase {
    func testTheReportLeadsWithProblemsSkipsEmptySectionsAndIsScrubbed() {
        let features = DiagnosticReport.featureLines([("Mouse", true, "Running"), ("Windows", true, "Needs permission"), ("Notes", false, "Off")])
        XCTAssertEqual(features, ["Windows: on, needs permission", "Mouse: running", "Off: Notes"])
        let text = DiagnosticReport.assemble([
            .init(title: "Build", lines: ["Kriya 1.0"]), .init(title: "Empty", lines: []),
            .init(title: "Permissions", lines: DiagnosticReport.permissionLines([("Accessibility", true), ("Microphone", false)])),
        ], generated: Date(timeIntervalSince1970: 0), scrub: { $0.replacingOccurrences(of: "Kriya 1.0", with: "SCRUBBED") })
        XCTAssertTrue(text.contains("== Build ==\nSCRUBBED"))
        XCTAssertFalse(text.contains("Empty"))
        XCTAssertTrue(text.contains("Microphone: not allowed"))
        XCTAssertTrue(text.hasPrefix("Kriya report, 19"))
    }
}
