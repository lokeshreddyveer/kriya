import XCTest
@testable import Kriya

final class FileUndoTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("kriya-undo-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? fm.removeItem(at: root) }

    private func file(_ name: String, _ text: String = "x") throws -> String {
        let url = root.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    private func path(_ name: String) -> String { root.appendingPathComponent(name).path }
    private func text(_ name: String) -> String? { try? String(contentsOfFile: path(name), encoding: .utf8) }

    func testAMovedItemGoesBack() throws {
        let old = path("a.txt")
        let new = try file("b.txt", "hello")
        let report = FileUndo.perform([.moved(from: old, to: new)])
        XCTAssertEqual(report.restored, 1)
        XCTAssertTrue(report.problems.isEmpty)
        XCTAssertTrue(report.remaining.isEmpty)
        XCTAssertEqual(text("a.txt"), "hello")
        XCTAssertFalse(fm.fileExists(atPath: new))
    }

    func testAnItemIsNeverPutOverSomethingThatNowSitsInItsOldPlace() throws {
        let old = try file("a.txt", "newer file")
        let new = try file("b.txt", "moved one")
        let report = FileUndo.perform([.moved(from: old, to: new)])
        XCTAssertEqual(report.restored, 0)
        XCTAssertEqual(report.problems.count, 1)
        XCTAssertEqual(report.remaining, [.moved(from: old, to: new)], "it stays available to try again")
        XCTAssertEqual(text("a.txt"), "newer file")
        XCTAssertEqual(text("b.txt"), "moved one")
    }

    func testSomethingThatHasGoneIsNotAnErrorAndNotKept() throws {
        let report = FileUndo.perform([.moved(from: path("a.txt"), to: path("gone.txt")), .created(path: path("never.txt"))])
        XCTAssertEqual(report.alreadyGone, 2)
        XCTAssertTrue(report.problems.isEmpty)
        XCTAssertTrue(report.remaining.isEmpty)
        XCTAssertEqual(report.summary, "Nothing needed undoing")
    }

    func testAMadeItemGoesToTheTrashNotAwayForGood() throws {
        let made = try file("copy.txt")
        var trashed: [String] = []
        let report = FileUndo.perform([.created(path: made)], trash: { trashed.append($0.path); try FileManager.default.removeItem(at: $0) })
        XCTAssertEqual(trashed, [made])
        XCTAssertEqual(report.trashed, 1)
        XCTAssertEqual(report.summary, "Moved 1 item to the Trash")
    }

    func testATrashThatFailsLeavesTheItemAndSaysSo() throws {
        let made = try file("copy.txt")
        struct Nope: Error {}
        let report = FileUndo.perform([.created(path: made)], trash: { _ in throw Nope() })
        XCTAssertEqual(report.trashed, 0)
        XCTAssertEqual(report.remaining, [.created(path: made)])
        XCTAssertTrue(fm.fileExists(atPath: made))
        XCTAssertTrue(report.summary.contains("could not be undone"))
    }

    func testNamesThatWereSwappedAreSwappedBack() throws {
        // Batch rename: a became b while b became a.
        let a = try file("a.txt", "was a")
        let b = try file("b.txt", "was b")
        // After the rename the file that was "a" is called b.txt, so its contents are "was a".
        let report = FileUndo.perform([.moved(from: a, to: b), .moved(from: b, to: a)])
        XCTAssertEqual(report.restored, 2)
        XCTAssertTrue(report.problems.isEmpty)
        XCTAssertEqual(text("a.txt"), "was b", "each file is moved once, so the two simply trade places")
        XCTAssertEqual(text("b.txt"), "was a")
        XCTAssertFalse((try fm.contentsOfDirectory(atPath: root.path)).contains { $0.hasPrefix(".kriya-undo") }, "no stray temporary names")
    }

    func testAChainOfRenamesUndoesWhenOneOldNameIsAnotherNewName() throws {
        // a -> b, then b -> c in one batch: the old name b is free once the file now called c leaves it.
        let b = try file("b.txt", "first")
        let c = try file("c.txt", "second")
        let report = FileUndo.perform([.moved(from: path("a.txt"), to: b), .moved(from: b, to: c)])
        XCTAssertEqual(report.problems, [])
        XCTAssertEqual(report.restored, 2)
        XCTAssertEqual(text("a.txt"), "first")
        XCTAssertEqual(text("b.txt"), "second")
    }

    func testAChangeOfLetterCaseGoesBack() throws {
        let renamed = try file("Report.txt", "body")
        let report = FileUndo.perform([.moved(from: path("report.txt"), to: renamed)])
        XCTAssertTrue(report.problems.isEmpty, "\(report.problems)")
        XCTAssertTrue((try fm.contentsOfDirectory(atPath: root.path)).contains("report.txt"))
    }

    func testAnItemWhoseOldFolderIsGoneStaysAvailable() throws {
        let new = try file("b.txt")
        let old = root.appendingPathComponent("missing-folder/a.txt").path
        let report = FileUndo.perform([.moved(from: old, to: new)])
        XCTAssertEqual(report.restored, 0)
        XCTAssertEqual(report.remaining.count, 1)
        XCTAssertTrue(report.problems[0].contains("is gone"))
        XCTAssertTrue(fm.fileExists(atPath: new))
    }

    func testProtectedPlacesAreLeftAlone() throws {
        let new = try file("b.txt")
        let report = FileUndo.perform([.moved(from: path("a.txt"), to: new)], isProtected: { _ in true })
        XCTAssertEqual(report.restored, 0)
        XCTAssertEqual(report.remaining.count, 1)
        XCTAssertTrue(fm.fileExists(atPath: new))
    }

    func testOneThatCannotGoBackDoesNotStopTheOthers() throws {
        let taken = try file("a.txt", "in the way")
        let movedA = try file("a-moved.txt")
        let movedB = try file("b-moved.txt", "b")
        let report = FileUndo.perform([.moved(from: taken, to: movedA), .moved(from: path("b.txt"), to: movedB)])
        XCTAssertEqual(report.restored, 1)
        XCTAssertEqual(report.remaining, [.moved(from: taken, to: movedA)])
        XCTAssertEqual(text("b.txt"), "b")
        XCTAssertEqual(report.summary, "Put back 1 item. 1 could not be undone")
    }
}

final class FileOperationHistoryTests: XCTestCase {
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "kriya-tests-\(UUID().uuidString)")! }

    func testOperationsAreListedNewestFirstAndEmptyOnesAreNotKept() {
        let history = FileOperationHistory(defaults: defaults())
        history.record(title: "first", steps: [.created(path: "/tmp/a")], failures: [])
        history.record(title: "second", steps: [.moved(from: "/tmp/b", to: "/tmp/c")], failures: [])
        history.record(title: "nothing", steps: [], failures: [])
        XCTAssertEqual(history.operations.map(\.title), ["second", "first"])
    }

    func testAFailureWithNoChangeIsKeptSoItsReasonCanBeRead() {
        let history = FileOperationHistory(defaults: defaults())
        history.record(title: "An action failed", steps: [], failures: ["Disk is full"])
        XCTAssertEqual(history.operations.count, 1)
        XCTAssertFalse(history.operations[0].canUndo, "nothing was changed, so there is nothing to undo")
        XCTAssertEqual(history.operations[0].failures, ["Disk is full"])
    }

    func testTheListIsCappedAndOldEntriesExpire() {
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let history = FileOperationHistory(defaults: defaults(), now: { clock })
        for index in 0..<(FileOperationHistory.limit + 5) { history.record(title: "op \(index)", steps: [.created(path: "/tmp/\(index)")], failures: []) }
        XCTAssertEqual(history.operations.count, FileOperationHistory.limit)
        XCTAssertEqual(history.operations.first?.title, "op \(FileOperationHistory.limit + 4)")
        clock = clock.addingTimeInterval(FileOperationHistory.maxAge + 1)
        history.record(title: "fresh", steps: [.created(path: "/tmp/fresh")], failures: [])
        XCTAssertEqual(history.operations.map(\.title), ["fresh"])
    }

    func testItSurvivesARestartAndClearingForgetsIt() {
        let store = defaults()
        let first = FileOperationHistory(defaults: store)
        first.record(title: "Moved 2 items", steps: [.moved(from: "/tmp/a", to: "/tmp/b")], failures: ["x"])
        let second = FileOperationHistory(defaults: store)
        XCTAssertEqual(second.operations.map(\.title), ["Moved 2 items"])
        XCTAssertEqual(second.operations.first?.steps, [.moved(from: "/tmp/a", to: "/tmp/b")])
        second.clear()
        XCTAssertTrue(FileOperationHistory(defaults: store).operations.isEmpty)
    }

    func testAnUndoIsWrittenDownAndAPartialOneKeepsWhatIsLeft() {
        let history = FileOperationHistory(defaults: defaults())
        history.record(title: "Moved 2 items", steps: [.moved(from: "/tmp/a", to: "/tmp/b"), .moved(from: "/tmp/c", to: "/tmp/d")], failures: [])
        let id = history.operations[0].id
        var report = FileUndoReport()
        report.restored = 1
        report.problems = ["“d” is already taken"]
        report.remaining = [.moved(from: "/tmp/c", to: "/tmp/d")]
        history.applyUndo(report, to: id)
        XCTAssertEqual(history.operation(id)?.undoState, .partly)
        XCTAssertEqual(history.operation(id)?.steps.count, 1)
        XCTAssertTrue(history.operation(id)?.canUndo == true)
        history.applyUndo(FileUndoReport(restored: 1), to: id)
        XCTAssertEqual(history.operation(id)?.undoState, .undone)
        XCTAssertFalse(history.operation(id)?.canUndo == true)
    }
}

final class FolderDestinationsTests: XCTestCase {
    private func make(folders: Set<String> = [], protected: Set<String> = []) -> FolderDestinations {
        FolderDestinations(defaults: UserDefaults(suiteName: "kriya-tests-\(UUID().uuidString)")!, isFolder: { folders.contains($0) }, isProtected: { protected.contains($0) })
    }

    func testFavoritesComeFirstThenRecentsNewestFirstWithNoRepeats() {
        let all: Set<String> = ["/a/One", "/a/Two", "/a/Three"]
        let destinations = make(folders: all)
        destinations.used("/a/One"); destinations.used("/a/Two"); destinations.used("/a/Three")
        destinations.toggleFavorite("/a/One")
        let choices = destinations.choices()
        XCTAssertEqual(choices.map(\.path), ["/a/One", "/a/Three", "/a/Two"])
        XCTAssertEqual(choices.map(\.isFavorite), [true, false, false])
        destinations.used("/a/Two")
        XCTAssertEqual(destinations.choices().map(\.path), ["/a/One", "/a/Two", "/a/Three"])
    }

    func testRecentsAreCappedButFavoritesAreNot() {
        let paths = (0..<20).map { "/a/f\($0)" }
        let destinations = make(folders: Set(paths))
        for path in paths { destinations.used(path) }
        XCTAssertEqual(destinations.recents.count, FolderDestinations.recentLimit)
        XCTAssertEqual(destinations.recents.first, "/a/f19")
        for path in paths.prefix(15) { destinations.toggleFavorite(path) }
        XCTAssertEqual(destinations.favorites.count, 15)
    }

    func testFoldersThatAreGoneOrProtectedAreNeverOffered() {
        let destinations = make(folders: ["/a/Here", "/System"], protected: ["/System"])
        destinations.used("/a/Here"); destinations.used("/a/Deleted"); destinations.used("/System")
        XCTAssertEqual(destinations.choices().map(\.path), ["/a/Here"])
        destinations.toggleFavorite("/System")
        XCTAssertFalse(destinations.isFavorite("/System"), "a system folder cannot be starred")
    }

    func testSearchMatchesEveryWordInTheNameOrPathIgnoringCase() {
        let destinations = make(folders: ["/Users/me/Documents/Taxes 2025", "/Users/me/Documents/Photos", "/Users/me/Downloads"])
        for path in ["/Users/me/Documents/Taxes 2025", "/Users/me/Documents/Photos", "/Users/me/Downloads"] { destinations.used(path) }
        XCTAssertEqual(destinations.choices(matching: "tax").map(\.name), ["Taxes 2025"])
        XCTAssertEqual(destinations.choices(matching: "docs").count, 0)
        XCTAssertEqual(Set(destinations.choices(matching: "me documents").map(\.name)), ["Taxes 2025", "Photos"])
        XCTAssertEqual(destinations.choices(matching: "   ").count, 3, "a blank search shows everything")
        XCTAssertTrue(destinations.choices(matching: "zzz").isEmpty)
    }

    func testTheHomeFolderCanBeADestinationButTheSameFolderIsNotListedTwice() {
        let home = NSHomeDirectory()
        let destinations = FolderDestinations(defaults: UserDefaults(suiteName: "kriya-tests-\(UUID().uuidString)")!, isFolder: { _ in true })
        destinations.used(home)
        destinations.used(home + "/")
        XCTAssertEqual(destinations.recents, [FolderDestinations.normalized(home)])
    }

    func testChoicesAreKeptAcrossARestart() {
        let store = UserDefaults(suiteName: "kriya-tests-\(UUID().uuidString)")!
        let first = FolderDestinations(defaults: store, isFolder: { _ in true }, isProtected: { _ in false })
        first.used("/a/One"); first.toggleFavorite("/a/Two")
        let second = FolderDestinations(defaults: store, isFolder: { _ in true }, isProtected: { _ in false })
        XCTAssertEqual(second.choices().map(\.path), ["/a/Two", "/a/One"])
    }

    func testForgettingARecentRemovesOnlyThat() {
        let destinations = make(folders: ["/a/One", "/a/Two"])
        destinations.used("/a/One"); destinations.used("/a/Two")
        destinations.forget("/a/One")
        XCTAssertEqual(destinations.choices().map(\.path), ["/a/Two"])
    }
}

final class FileRunnerHistoryTests: XCTestCase {
    private func settle(_ seconds: Double = 1.2) {
        let done = expectation(description: "settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { done.fulfill() }
        wait(for: [done], timeout: seconds + 3)
    }

    private func setUpRunner(_ world: TestWorld) -> (FileActionRunner, FinderStore, FileOperationHistory) {
        let store = FinderStore(core: world.core, menuFile: world.folder.appendingPathComponent("m.json"), defaults: UserDefaults(suiteName: "kriya-tests-\(UUID().uuidString)")!)
        let history = FileOperationHistory(defaults: UserDefaults(suiteName: "kriya-tests-\(UUID().uuidString)")!)
        let destinations = FolderDestinations(defaults: UserDefaults(suiteName: "kriya-tests-\(UUID().uuidString)")!)
        return (FileActionRunner(store: store, history: history, destinations: destinations), store, history)
    }

    func testCreatingAFileIsRecordedAndUndoMovesItToTheTrash() throws {
        let world = try TestWorld()
        defer { world.cleanUp() }
        let (runner, store, history) = setUpRunner(world)
        runner.run(try XCTUnwrap(store.item("new-file")), paths: [], target: world.folder.path, child: nil)
        settle()
        let operation = try XCTUnwrap(history.operations.first)
        XCTAssertEqual(operation.steps, [.created(path: world.folder.appendingPathComponent("untitled.txt").path)])
        XCTAssertTrue(operation.canUndo)
    }

    func testAMoveWithOneImpossibleItemMovesTheRestAndReportsTheOne() throws {
        let world = try TestWorld()
        defer { world.cleanUp() }
        let (runner, store, history) = setUpRunner(world)
        let fm = FileManager.default
        let target = world.folder.appendingPathComponent("Target", isDirectory: true)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        let loose = world.folder.appendingPathComponent("loose.txt")
        try "data".write(to: loose, atomically: true, encoding: .utf8)
        store.upsert(FinderItem(id: "test-move", title: "Move there", kind: .moveTo(folder: target.path), enabled: true, applies: .anything, extensions: [], appIds: [], confirm: false))
        // The folder cannot go into itself; the file can go in.
        runner.run(try XCTUnwrap(store.item("test-move")), paths: [target.path, loose.path], target: nil, child: nil)
        settle()
        XCTAssertTrue(fm.fileExists(atPath: target.appendingPathComponent("loose.txt").path), "the other item still moved")
        let operation = try XCTUnwrap(history.operations.first)
        XCTAssertEqual(operation.steps, [.moved(from: loose.path, to: target.appendingPathComponent("loose.txt").path)])
        XCTAssertEqual(operation.failures.count, 1)
        XCTAssertTrue(operation.title.contains("1 of 2"), operation.title)

        runner.undo(operation.id)
        settle()
        XCTAssertTrue(fm.fileExists(atPath: loose.path), "undo put the file back")
        XCTAssertEqual(history.operation(operation.id)?.undoState, .undone)
    }
}
