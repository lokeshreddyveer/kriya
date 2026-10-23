import XCTest
@testable import Kriya

final class FolderRuleEngineTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func file(_ name: String, age: TimeInterval = 3600, size: Int64 = 1000, dir: Bool = false, hidden: Bool = false) -> FolderFile {
        FolderFile(name: name, isDirectory: dir, isHidden: hidden, size: size, modified: now.addingTimeInterval(-age))
    }
    private func rule(_ conditions: [FolderCondition], _ action: FolderAction = .moveTo("/tmp/kriya-rule-dest"), folder: String = "/tmp/kriya-rule-src") -> FolderRule {
        FolderRule(name: "r", enabled: true, folder: folder, conditions: conditions, action: action)
    }

    func testOnlyFinishedVisibleFilesAreEverTouched() {
        XCTAssertTrue(FolderRuleEngine.eligible(file("a.pdf"), now: now))
        XCTAssertFalse(FolderRuleEngine.eligible(file("a.pdf", age: 10), now: now), "still being written")
        XCTAssertFalse(FolderRuleEngine.eligible(file("Docs", dir: true), now: now))
        XCTAssertFalse(FolderRuleEngine.eligible(file(".hidden"), now: now))
        XCTAssertFalse(FolderRuleEngine.eligible(file("x.pdf", hidden: true), now: now))
        XCTAssertFalse(FolderRuleEngine.eligible(file("movie.mp4.crdownload"), now: now), "a partial download")
        XCTAssertFalse(FolderRuleEngine.eligible(file("a.part"), now: now))
    }

    func testEveryConditionIsChecked() {
        XCTAssertTrue(FolderRuleEngine.matches(rule([.extensionIs([".PDF", "docx"])]), file("a.pdf"), now: now))
        XCTAssertFalse(FolderRuleEngine.matches(rule([.extensionIs(["pdf"])]), file("a.png"), now: now))
        XCTAssertTrue(FolderRuleEngine.matches(rule([.kind("Images")]), file("photo.JPG"), now: now))
        XCTAssertTrue(FolderRuleEngine.matches(rule([.nameContains("invoice")]), file("My INVOICE 3.pdf"), now: now))
        XCTAssertTrue(FolderRuleEngine.matches(rule([.nameStartsWith("screenshot")]), file("Screenshot 2026.png"), now: now))
        XCTAssertFalse(FolderRuleEngine.matches(rule([.nameStartsWith("")]), file("a.png"), now: now), "empty text matches nothing")
        XCTAssertTrue(FolderRuleEngine.matches(rule([.olderThanDays(7)]), file("a", age: 8 * 86_400), now: now))
        XCTAssertFalse(FolderRuleEngine.matches(rule([.olderThanDays(7)]), file("a", age: 6 * 86_400), now: now))
        XCTAssertTrue(FolderRuleEngine.matches(rule([.largerThanMB(10)]), file("a", size: 11 * 1_048_576), now: now))
        XCTAssertFalse(FolderRuleEngine.matches(rule([.largerThanMB(10)]), file("a", size: 9 * 1_048_576), now: now))
        XCTAssertTrue(FolderRuleEngine.matches(rule([.smallerThanMB(1)]), file("a", size: 100), now: now))
        XCTAssertTrue(FolderRuleEngine.matches(rule([.kind("Documents"), .olderThanDays(1)]), file("a.pdf", age: 2 * 86_400), now: now), "all must hold")
        XCTAssertFalse(FolderRuleEngine.matches(rule([.kind("Documents"), .olderThanDays(30)]), file("a.pdf", age: 2 * 86_400), now: now))
        XCTAssertFalse(FolderRuleEngine.matches(rule([]), file("a.pdf"), now: now), "no conditions never means every file")
    }

    func testUnsafeRulesAreRefusedWithAReason() {
        let ok: (String) -> Bool = { _ in true }
        XCTAssertNil(FolderRuleEngine.problem(for: rule([.kind("Images")], folder: "/Users/x/Downloads"), folderExists: ok))
        XCTAssertNotNil(FolderRuleEngine.problem(for: FolderRule(name: "", folder: "/Users/x/D", conditions: [.kind("Images")], action: .trash), folderExists: ok))
        XCTAssertNotNil(FolderRuleEngine.problem(for: rule([]), folderExists: ok), "no conditions")
        XCTAssertNotNil(FolderRuleEngine.problem(for: rule([.kind("Images")], folder: NSHomeDirectory()), folderExists: ok), "the home folder")
        XCTAssertNotNil(FolderRuleEngine.problem(for: rule([.kind("Images")], folder: "/System/Library"), folderExists: ok))
        XCTAssertNotNil(FolderRuleEngine.problem(for: rule([.kind("Images")], folder: "/"), folderExists: ok))
        XCTAssertNotNil(FolderRuleEngine.problem(for: rule([.kind("Images")], folder: "/Users/x/D"), folderExists: { _ in false }), "missing folder")
        XCTAssertNotNil(FolderRuleEngine.problem(for: rule([.kind("Images")], .moveTo("/Users/x/D"), folder: "/Users/x/D"), folderExists: ok), "into itself")
        XCTAssertNotNil(FolderRuleEngine.problem(for: rule([.kind("Images")], .moveTo("/Users/x/D/Sub"), folder: "/Users/x/D"), folderExists: ok), "inside itself: it would find them again")
        XCTAssertNotNil(FolderRuleEngine.problem(for: rule([.kind("Images")], .moveTo("/System"), folder: "/Users/x/D"), folderExists: ok))
        XCTAssertNotNil(FolderRuleEngine.problem(for: rule([.kind("Images")], .rename("fixed"), folder: "/Users/x/D"), folderExists: ok), "every file would get one name")
        XCTAssertNotNil(FolderRuleEngine.problem(for: rule([.kind("Images")], .rename("{name}/x"), folder: "/Users/x/D"), folderExists: ok))
        XCTAssertNotNil(FolderRuleEngine.problem(for: rule([.extensionIs([" "])]), folderExists: ok))
        XCTAssertNotNil(FolderRuleEngine.problem(for: rule([.nameContains("  ")]), folderExists: ok))
        XCTAssertNil(FolderRuleEngine.problem(for: rule([.kind("Images")], .trash, folder: "/Users/x/D"), folderExists: ok))
    }

    func testMovesNeverOverwriteAndNamesAreHandedOutInOrder() {
        let files = [file("a.pdf"), file("b.pdf"), file("note.txt")]
        let r = rule([.extensionIs(["pdf"])], .moveTo("/tmp/kriya-rule-dest"))
        let plan = FolderRuleEngine.plan(r, files: files, now: now, existingNames: { $0 == "/tmp/kriya-rule-dest" ? ["a.pdf"] : [] })
        XCTAssertEqual(plan.map(\.to), ["/tmp/kriya-rule-dest/a 2.pdf", "/tmp/kriya-rule-dest/b.pdf"])
        XCTAssertEqual(plan.map(\.from), ["/tmp/kriya-rule-src/a.pdf", "/tmp/kriya-rule-src/b.pdf"])
        XCTAssertTrue(plan.allSatisfy { $0.kind == .move })
        // Two files with one name in a plan do not collide either.
        let same = FolderRuleEngine.plan(rule([.nameContains("x")], .copyTo("/tmp/kriya-rule-dest")), files: [file("x.txt"), file("x.txt")], now: now, existingNames: { _ in [] })
        XCTAssertEqual(Set(same.compactMap(\.to)).count, 2)
        XCTAssertTrue(same.allSatisfy { $0.kind == .copy })
    }

    func testRenamingUsesTheTokensAndKeepsTheType() {
        let r = rule([.kind("Images")], .rename("{date} photo {n}"))
        let plan = FolderRuleEngine.plan(r, files: [file("b.png"), file("a.jpg")], now: now, existingNames: { _ in [] })
        let names = plan.compactMap { ($0.to as NSString?)?.lastPathComponent }
        XCTAssertEqual(names.count, 2)
        XCTAssertTrue(names[0].hasSuffix("photo 1.jpg"), names[0])
        XCTAssertTrue(names[1].hasSuffix("photo 2.png"), names[1])
        XCTAssertTrue(names[0].hasPrefix("2027-"), "the file's own date")
        let explicit = FolderRuleEngine.renamed(file("a.png"), pattern: "{name}-copy.{ext}", number: 1)
        XCTAssertEqual(explicit, "a-copy.png")
        XCTAssertEqual(FolderRuleEngine.renamed(file("README"), pattern: "{n}_{name}", number: 3), "3_README", "no type to keep")
    }

    func testSortingByKindOnlyTouchesKnownKinds() {
        let r = rule([.olderThanDays(0)], .sortByKind)
        let plan = FolderRuleEngine.plan(r, files: [file("a.png"), file("b.pdf"), file("mystery.xyz"), file("c.zip")], now: now, existingNames: { _ in [] })
        XCTAssertEqual(plan.compactMap(\.to), ["/tmp/kriya-rule-src/Images/a.png", "/tmp/kriya-rule-src/Documents/b.pdf", "/tmp/kriya-rule-src/Archives/c.zip"])
    }

    func testTrashPlansHaveNoDestinationAndARunIsCapped() {
        let plan = FolderRuleEngine.plan(rule([.kind("Installers")], .trash), files: [file("app.dmg")], now: now, existingNames: { _ in [] })
        XCTAssertEqual(plan, [PlannedChange(kind: .trash, from: "/tmp/kriya-rule-src/app.dmg", to: nil)])
        let many = (0..<500).map { file("f\($0).dmg") }
        XCTAssertEqual(FolderRuleEngine.plan(rule([.kind("Installers")], .trash), files: many, now: now, existingNames: { _ in [] }).count, FolderRuleEngine.maxChangesPerRun)
    }

    func testAnUnsafeRulePlansNothing() {
        XCTAssertTrue(FolderRuleEngine.plan(rule([.kind("Images")], .moveTo("/System"), folder: "/Users/x/D"), files: [file("a.png")], now: now, existingNames: { _ in [] }).isEmpty)
    }
}

final class FolderRulesStoreTests: XCTestCase {
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "kriya-tests-\(UUID().uuidString)")! }
    private func rule(_ name: String = "Docs") -> FolderRule {
        FolderRule(name: name, enabled: true, folder: "/Users/x/Downloads", conditions: [.kind("Documents")], action: .moveTo("/Users/x/Documents"))
    }

    func testANewRuleStartsOffEvenIfSavedOn() {
        let store = FolderRulesStore(defaults: defaults(), folderExists: { _ in true })
        XCTAssertNil(store.save(rule()))
        XCTAssertEqual(store.rules.first?.enabled, false)
        let id = store.rules[0].id
        XCTAssertNil(store.setEnabled(id, true))
        XCTAssertEqual(store.rules.first?.enabled, true)
    }

    func testChangingARuleSwitchesItOffAgainButRenamingItDoesNot() {
        let store = FolderRulesStore(defaults: defaults(), folderExists: { _ in true })
        store.save(rule())
        var saved = store.rules[0]
        store.setEnabled(saved.id, true)
        saved = store.rules[0]
        var renamed = saved
        renamed.name = "Documents"
        store.save(renamed)
        XCTAssertEqual(store.rules[0].enabled, true, "only the name changed")
        var changed = store.rules[0]
        changed.conditions = [.kind("Images")]
        store.save(changed)
        XCTAssertEqual(store.rules[0].enabled, false, "a new condition is previewed before it acts")
    }

    func testARuleWithAProblemIsNotSavedOrSwitchedOn() {
        let store = FolderRulesStore(defaults: defaults(), folderExists: { _ in false })
        XCTAssertNotNil(store.save(rule()))
        XCTAssertTrue(store.rules.isEmpty)
        let open = FolderRulesStore(defaults: defaults(), folderExists: { _ in true })
        open.save(rule())
        let gone = FolderRulesStore(defaults: defaults(), folderExists: { _ in false })
        XCTAssertNil(gone.setEnabled("nothing", true), "an unknown rule is ignored")
        XCTAssertNotNil(open.save(FolderRule(name: "x", folder: NSHomeDirectory(), conditions: [.kind("Images")], action: .trash)))
    }

    func testRulesSurviveARestartAndCanBeDeleted() {
        let d = defaults()
        let store = FolderRulesStore(defaults: d, folderExists: { _ in true })
        store.save(rule("One"))
        store.save(rule("Two"))
        XCTAssertEqual(FolderRulesStore(defaults: d, folderExists: { _ in true }).rules.map(\.name), ["One", "Two"])
        store.delete(store.rules[0].id)
        XCTAssertEqual(FolderRulesStore(defaults: d, folderExists: { _ in true }).rules.map(\.name), ["Two"])
        XCTAssertTrue(store.rules[0].summary.contains("Downloads"))
    }
}

final class FolderRulesServiceTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("kriya-rules-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root.appendingPathComponent("Inbox"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? fm.removeItem(at: root) }

    private func make(_ name: String, age: TimeInterval = 3600, in folder: String = "Inbox") throws {
        let url = root.appendingPathComponent(folder).appendingPathComponent(name)
        try "data".write(to: url, atomically: true, encoding: .utf8)
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
    }

    func testARuleMovesMatchingFilesIntoANewFolderAndNeverOverwrites() throws {
        try make("a.pdf"); try make("b.pdf"); try make("keep.txt"); try make("fresh.pdf", age: 5)
        try fm.createDirectory(at: root.appendingPathComponent("Docs"), withIntermediateDirectories: true)
        try "old".write(to: root.appendingPathComponent("Docs/a.pdf"), atomically: true, encoding: .utf8)
        let rule = FolderRule(name: "PDFs", enabled: true, folder: root.appendingPathComponent("Inbox").path, conditions: [.extensionIs(["pdf"])], action: .moveTo(root.appendingPathComponent("Docs").path))
        let changes = FolderRuleEngine.plan(rule, files: FolderRulesService.files(in: rule.folder), now: Date())
        XCTAssertEqual(changes.count, 2, "the fresh file waits")
        let result = FolderRulesService.apply(changes)
        XCTAssertTrue(result.failures.isEmpty, "\(result.failures)")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("Docs/a.pdf"), encoding: .utf8), "old", "never overwritten")
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("Docs/a 2.pdf").path))
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("Docs/b.pdf").path))
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("Inbox/keep.txt").path))
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("Inbox/fresh.pdf").path))
        XCTAssertEqual(result.steps.count, 2)
        // The steps are what Undo needs.
        let undone = FileUndo.perform(result.steps, trash: { _ in })
        XCTAssertEqual(undone.restored, 2)
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("Inbox/a.pdf").path))
    }

    func testTheServiceRecordsWhatItDidSoItCanBeUndone() throws {
        try make("one.png"); try make("two.png")
        let history = FileOperationHistory(defaults: UserDefaults(suiteName: "kriya-tests-\(UUID().uuidString)")!)
        let store = FolderRulesStore(defaults: UserDefaults(suiteName: "kriya-tests-\(UUID().uuidString)")!)
        let service = FolderRulesService(store: store, history: history)
        let rule = FolderRule(name: "Pictures", enabled: true, folder: root.appendingPathComponent("Inbox").path, conditions: [.kind("Images")], action: .sortByKind)
        service.run(rule, announce: false)
        let done = expectation(description: "ran")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { done.fulfill() }
        wait(for: [done], timeout: 5)
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("Inbox/Images/one.png").path))
        let operation = try XCTUnwrap(history.operations.first)
        XCTAssertTrue(operation.title.contains("Pictures"), operation.title)
        XCTAssertEqual(operation.steps.count, 2)
        XCTAssertNotNil(service.lastResult[rule.id])
    }

    func testAFileThatCannotBeMovedIsReportedAndTheRestStillGo() throws {
        try make("a.pdf"); try make("b.pdf")
        let changes = [
            PlannedChange(kind: .move, from: root.appendingPathComponent("Inbox/missing.pdf").path, to: root.appendingPathComponent("Out/missing.pdf").path),
            PlannedChange(kind: .move, from: root.appendingPathComponent("Inbox/b.pdf").path, to: root.appendingPathComponent("Out/b.pdf").path),
        ]
        let result = FolderRulesService.apply(changes)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertTrue(result.failures[0].contains("missing.pdf"))
        XCTAssertEqual(result.steps.count, 1)
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("Out/b.pdf").path))
    }
}

final class FolderRuleTagAndArchiveTests: XCTestCase {
    private func rule(_ action: FolderAction) -> FolderRule {
        FolderRule(name: "r", enabled: true, folder: NSTemporaryDirectory(), conditions: [.nameContains("")], action: action)
    }

    func testTagSkipsFilesThatAlreadyHaveIt() {
        let r = FolderRule(name: "t", enabled: true, folder: NSTemporaryDirectory(), conditions: [.olderThanDays(0)], action: .tag("Review"))
        let old = Date(timeIntervalSinceNow: -86_400 * 3)
        let files = [FolderFile(name: "a.pdf", modified: old), FolderFile(name: "b.pdf", modified: old, tags: ["review"])]
        let changes = FolderRuleEngine.plan(r, files: files, now: Date(), existingNames: { _ in [] })
        XCTAssertEqual(changes.map(\.kind), [.tag])
        XCTAssertEqual(changes.first?.to, "Review")
        XCTAssertTrue(changes.first?.from.hasSuffix("a.pdf") == true)
    }

    func testArchiveGoesIntoMonthFoldersInsideTheWatchedFolder() {
        let r = FolderRule(name: "a", enabled: true, folder: NSTemporaryDirectory(), conditions: [.olderThanDays(0)], action: .archiveByMonth)
        var cal = Calendar(identifier: .gregorian); cal.timeZone = .current
        let date = cal.date(from: DateComponents(year: 2026, month: 3, day: 9, hour: 12))!
        let changes = FolderRuleEngine.plan(r, files: [FolderFile(name: "x.txt", modified: date)], now: Date(), existingNames: { _ in [] })
        XCTAssertEqual(changes.count, 1)
        XCTAssertTrue(changes[0].to?.contains("/Archive/2026-03/x.txt") == true, changes[0].to ?? "")
    }

    func testBadTagNamesAreRefused() {
        XCTAssertNotNil(FolderRuleEngine.problem(for: rule(.tag("  ")), folderExists: { _ in true }))
        XCTAssertNotNil(FolderRuleEngine.problem(for: rule(.tag("a,b")), folderExists: { _ in true }))
    }

    func testExportedRulesImportSwitchedOffWithNewIds() throws {
        let d = UserDefaults(suiteName: "kriya.test.\(UUID().uuidString)")!
        let a = FolderRulesStore(defaults: d, folderExists: { _ in true })
        var r = FolderRule(name: "Tidy", enabled: false, folder: NSHomeDirectory() + "/Downloads", conditions: [.olderThanDays(30)], action: .tag("Old"))
        r.enabled = false
        XCTAssertNil(a.save(r))
        _ = a.setEnabled(a.rules[0].id, true)
        let data = try XCTUnwrap(a.exported())
        let b = FolderRulesStore(defaults: UserDefaults(suiteName: "kriya.test.\(UUID().uuidString)")!, folderExists: { _ in true })
        let result = try XCTUnwrap(b.importRules(data))
        XCTAssertEqual(result.added, 1)
        XCTAssertFalse(b.rules[0].enabled, "an imported rule is never on")
        XCTAssertNotEqual(b.rules[0].id, a.rules[0].id)
        XCTAssertNil(b.importRules(Data("nope".utf8)))
    }
}
