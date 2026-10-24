import XCTest
@testable import Kriya

/// Workflows that start on the clock or on a folder: when they are due, what counts as a new item, and a real watched folder.
final class ScheduleTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    func testWeekdaysCountFromMonday() {
        XCTAssertEqual(ScheduleClock.weekday(date("2026-10-19T12:00:00Z"), calendar: calendar), 1, "Monday")
        XCTAssertEqual(ScheduleClock.weekday(date("2026-10-24T12:00:00Z"), calendar: calendar), 6, "Saturday")
        XCTAssertEqual(ScheduleClock.weekday(date("2026-10-25T12:00:00Z"), calendar: calendar), 7, "Sunday")
        var sundayFirst = calendar; sundayFirst.firstWeekday = 1
        XCTAssertEqual(ScheduleClock.weekday(date("2026-10-25T12:00:00Z"), calendar: sundayFirst), 7, "the calendar's first weekday does not matter")
    }

    func testAnIntervalIsDueOnlyOnceItHasPassed() {
        let last = date("2026-10-24T10:00:00Z")
        XCTAssertFalse(ScheduleClock.intervalDue(minutes: 15, now: date("2026-10-24T10:14:59Z"), lastRun: last))
        XCTAssertTrue(ScheduleClock.intervalDue(minutes: 15, now: date("2026-10-24T10:15:00Z"), lastRun: last))
        XCTAssertTrue(ScheduleClock.intervalDue(minutes: 1, now: date("2026-10-24T10:01:00Z"), lastRun: last))
        XCTAssertFalse(ScheduleClock.intervalDue(minutes: 0, now: date("2026-10-24T12:00:00Z"), lastRun: last), "no interval at all is never due")
    }

    func testATimeOfDayRunsOnceAtItsMinuteAndOnWakingShortlyAfter() {
        func due(_ now: String, last: String? = nil, days: [UInt8] = [], hour: UInt8 = 9, minute: UInt8 = 0) -> Bool {
            ScheduleClock.dailyDue(hour: hour, minute: minute, weekdays: days, now: date(now), lastRun: last.map(date), calendar: calendar)
        }
        XCTAssertFalse(due("2026-10-24T08:59:59Z"), "not yet")
        XCTAssertTrue(due("2026-10-24T09:00:20Z"), "at its time")
        XCTAssertFalse(due("2026-10-24T09:00:40Z", last: "2026-10-24T09:00:20Z"), "only once")
        XCTAssertTrue(due("2026-10-24T09:10:00Z", last: "2026-10-23T09:00:20Z"), "the Mac woke ten minutes late: run it once")
        XCTAssertFalse(due("2026-10-24T09:20:00Z", last: "2026-10-23T09:00:20Z"), "twenty minutes late is too late to be useful")
        XCTAssertTrue(due("2026-10-24T09:30:10Z", hour: 9, minute: 30))
        XCTAssertFalse(due("2026-10-24T09:00:20Z", days: [1, 2, 3, 4, 5]), "Saturday is not a weekday")
        XCTAssertTrue(due("2026-10-24T09:00:20Z", days: [6, 7]))
        XCTAssertTrue(due("2026-10-19T09:00:20Z", days: [1]))
        XCTAssertFalse(due("2026-10-24T09:00:20Z", hour: 25), "an impossible time never runs")
    }

    func testOnlyFinishedVisibleItemsAreNew() {
        let before: Set<String> = ["old.txt"]
        let after: Set<String> = ["old.txt", "b.pdf", "a.png", ".DS_Store", "movie.mp4.crdownload", "x.part", "~$report.docx", "notes.tmp", "Draft.PART"]
        XCTAssertEqual(FolderChange.newItems(before: before, after: after), ["a.png", "b.pdf"])
        XCTAssertEqual(FolderChange.counted(["a", ".hidden", "b.download"]), ["a"])
        XCTAssertTrue(FolderChange.newItems(before: after, after: before).isEmpty, "something removed is not new")
    }

    func testOnlyFoldersInTheHomeFolderAndOnDrivesAreWatched() {
        let home = URL(fileURLWithPath: "/Users/tester")
        XCTAssertEqual(FolderChange.resolve("~/Downloads", home: home)?.path, "/Users/tester/Downloads")
        XCTAssertEqual(FolderChange.resolve("/Users/tester/Desktop/Inbox", home: home)?.path, "/Users/tester/Desktop/Inbox")
        XCTAssertEqual(FolderChange.resolve("~", home: home)?.path, "/Users/tester")
        XCTAssertEqual(FolderChange.resolve("/Volumes/Backup/Inbox", home: home)?.path, "/Volumes/Backup/Inbox")
        for bad in ["/etc", "/", "/System/Library", "/Users/other/Documents", "/Users/tester/../other", "~/../other", "Downloads", "", "  ", "/Users/testerx"] {
            XCTAssertNil(FolderChange.resolve(bad, home: home), bad)
        }
    }

    func testAWatchedFolderReportsNewFinishedItemsOnce() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kriya-watch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data().write(to: folder.appendingPathComponent("existing.txt"))
        var reported: [[String]] = []
        let watcher = FolderWatcher(url: folder) { reported.append($0) }
        XCTAssertTrue(watcher.start())
        defer { watcher.stop() }

        try Data("a".utf8).write(to: folder.appendingPathComponent("a.txt"))
        try Data("b".utf8).write(to: folder.appendingPathComponent("b.pdf.crdownload"))
        pump(FolderWatcher.settle + 1.5)
        XCTAssertEqual(reported, [["a.txt"]], "the existing file is not new and the download is not finished")

        try FileManager.default.moveItem(at: folder.appendingPathComponent("b.pdf.crdownload"), to: folder.appendingPathComponent("b.pdf"))
        pump(FolderWatcher.settle + 1.5)
        XCTAssertEqual(reported, [["a.txt"], ["b.pdf"]], "it counts when it has its final name")

        pump(FolderWatcher.settle + 0.5)
        XCTAssertEqual(reported.count, 2, "nothing is reported twice")
        XCTAssertFalse(FolderWatcher(url: folder.appendingPathComponent("missing")) { _ in }.start(), "a folder that is not there cannot be watched")
    }

    func testEachAIAppGetsTheFormItUnderstands() throws {
        let setups = MCPClientSetup.all(endpoint: "http://127.0.0.1:8765/mcp", secret: "S3CRET")
        let byApp = Dictionary(uniqueKeysWithValues: setups.map { ($0.id, $0) })
        XCTAssertEqual(setups.map(\.id), ["claude-code", "cursor", "claude-desktop", "other"])
        XCTAssertEqual(byApp["claude-code"]?.text, "claude mcp add --transport http kriya http://127.0.0.1:8765/mcp --header \"Authorization: Bearer S3CRET\"")
        for id in ["cursor", "other"] {
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(byApp[id]).text.utf8)) as? [String: Any])
            let server = try XCTUnwrap((json["mcpServers"] as? [String: Any])?["kriya"] as? [String: Any])
            XCTAssertEqual(server["url"] as? String, "http://127.0.0.1:8765/mcp")
            XCTAssertEqual((server["headers"] as? [String: String])?["Authorization"], "Bearer S3CRET")
        }
        let desktop = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(byApp["claude-desktop"]).text.utf8)) as? [String: Any])
        let server = try XCTUnwrap((desktop["mcpServers"] as? [String: Any])?["kriya"] as? [String: Any])
        XCTAssertEqual(server["command"] as? String, "npx", "Claude Desktop starts a local program, so a bridge reaches the server")
        XCTAssertEqual(server["args"] as? [String], ["-y", "mcp-remote", "http://127.0.0.1:8765/mcp", "--header", "Authorization:${KRIYA_AUTH}"])
        XCTAssertEqual((server["env"] as? [String: String])?["KRIYA_AUTH"], "Bearer S3CRET", "the secret is in env, not in the arguments")
        XCTAssertFalse(try XCTUnwrap(byApp["claude-desktop"]).masked(secret: "S3CRET").contains("S3CRET"))
        for setup in setups { XCTAssertFalse(setup.instructions.isEmpty) }
    }

    func testCommandLineToolsAreSearchedDescribedAndInstalledAsFormulae() {
        let output = "==> Formulae\nripgrep\nripgrep-all\nopenssl@3\n\n==> Casks\nripgrep-gui\n"
        XCTAssertEqual(HomebrewParsing.parseSearch(output, kind: .formula), ["ripgrep", "ripgrep-all", "openssl@3"])
        XCTAssertEqual(HomebrewParsing.parseSearch(output, kind: .cask), ["ripgrep-gui"], "apps are unchanged")
        XCTAssertEqual(HomebrewParsing.parseSearch("jq\nyq\n", kind: .formula), ["jq", "yq"], "no headings: all of the kind searched")
        XCTAssertEqual(HomebrewParsing.installCommand("jq", kind: .formula), "brew install jq")
        XCTAssertEqual(HomebrewParsing.installCommand("firefox", kind: .cask), "brew install --cask firefox")
        XCTAssertEqual(HomebrewParsing.installArguments("jq", kind: .formula), ["install", "jq"])
        XCTAssertEqual(HomebrewParsing.installArguments("firefox", kind: .cask), ["install", "--cask", "firefox"])
        XCTAssertEqual(HomebrewManager.command(install: "firefox"), "brew install --cask firefox", "the default is still an app")
        XCTAssertEqual(HomebrewParsing.Kind.formula.flag, "--formula")
        for bad in ["jq; rm -rf /", "-v", "../x", "A", "", "a b"] { XCTAssertFalse(HomebrewParsing.isValidToken(bad), bad) }
        for good in ["openssl@3", "c++", "python@3.12", "gcc@13"] { XCTAssertTrue(HomebrewParsing.isValidToken(good), good) }
        let json = #"{"formulae":[{"name":"jq","desc":"Lightweight JSON processor","homepage":"https://jqlang.github.io/jq/","versions":{"stable":"1.7.1"}},{"name":"bad name"}],"casks":[]}"#
        let info = HomebrewParsing.parseInfo(Data(json.utf8), kind: .formula)
        XCTAssertEqual(info.map(\.token), ["jq"])
        XCTAssertEqual(info.first?.version, "1.7.1")
        XCTAssertEqual(info.first?.description, "Lightweight JSON processor")
        XCTAssertTrue(HomebrewParsing.parseInfo(Data(json.utf8), kind: .cask).isEmpty, "a formula answer is not read as a cask")
        XCTAssertEqual(HomebrewParsing.stage(forOutput: "==> Pouring jq--1.7.1.arm64_sonoma.bottle.tar.gz"), "Installing…")
        XCTAssertTrue(HomebrewParsing.featuredTools.allSatisfy(HomebrewParsing.isValidToken))
    }

    private func pump(_ seconds: TimeInterval) {
        let done = expectation(description: "wait")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { done.fulfill() }
        wait(for: [done], timeout: seconds + 5)
    }
}
