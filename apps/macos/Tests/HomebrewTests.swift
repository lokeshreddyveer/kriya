import XCTest
@testable import Kriya

final class HomebrewTests: XCTestCase {
    func testOnlyOrdinaryCaskNamesAreAccepted() {
        for good in ["firefox", "visual-studio-code", "font-fira-code", "1password", "docker@2", "a.b_c+d"] {
            XCTAssertTrue(HomebrewParsing.isValidToken(good), good)
        }
        for bad in ["", "-rf", "Firefox", "a b", "a;rm", "a/b", "$(x)", "a\nb", "--cask", ".hidden", String(repeating: "a", count: 90)] {
            XCTAssertFalse(HomebrewParsing.isValidToken(bad), bad)
        }
    }

    func testSearchOutputKeepsOnlyCaskNames() {
        let output = """
        ==> Casks
        firefox
        firefox@beta
        firefox@developer-edition

        ==> Formulae
        Not A Name
        firefox
        """
        XCTAssertEqual(HomebrewParsing.parseSearch(output), ["firefox", "firefox@beta", "firefox@developer-edition"], "headings, odd lines and repeats are dropped")
        XCTAssertEqual(HomebrewParsing.parseSearch("").count, 0)
        let many = (0..<100).map { "app\($0)" }.joined(separator: "\n")
        XCTAssertEqual(HomebrewParsing.parseSearch(many).count, 40, "no more than forty are shown")
    }

    func testOnlyWhatIsUnderCasksIsOfferedAsACask() {
        let output = """
        ==> Formulae
        only-a-formula
        ==> Casks
        real-cask
        another-cask
        ==> Formulae
        later-formula
        """
        XCTAssertEqual(HomebrewParsing.parseSearch(output), ["real-cask", "another-cask"], "formulae are never shown as installable apps")
        XCTAssertEqual(HomebrewParsing.parseSearch("plain-one\nplain-two"), ["plain-one", "plain-two"], "no headings: all casks")
        XCTAssertEqual(HomebrewParsing.parseSearch("==> Formulae\nx\n"), [])
    }

    func testStopPressedBeforeTheProcessStartsStillStopsEverything() throws {
        let standIn = try makeStandIn()
        defer { standIn.cleanup() }
        let manager = HomebrewManager(brewPath: standIn.path)
        manager.install(["first", "second"])
        manager.cancel()   // straight away, before the first one can have started
        XCTAssertTrue(waitUntil(8) { !manager.isRunning }, "it does not hang")
        XCTAssertTrue(manager.log.contains("Stopped."))
        XCTAssertFalse(manager.log.contains("ARG["), "nothing was started after Stop")
    }

    func testUpgradesRunOneAtATimeAndOnlyForValidNames() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kriya-upg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = folder.appendingPathComponent("log.txt")
        let script = folder.appendingPathComponent("brew")
        try """
        #!/bin/sh
        echo "start $3" >> "\(log.path)"
        sleep 0.4
        echo "end $3" >> "\(log.path)"
        exit 0
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let inventory = AppInventory()
        inventory.brewExecutableOverride = script.path
        let done = expectation(description: "both finished")
        done.expectedFulfillmentCount = 2
        inventory.runBrewUpgrade("alpha") { _ in done.fulfill() }
        inventory.runBrewUpgrade("beta") { _ in done.fulfill() }
        var refused = ""
        inventory.runBrewUpgrade("bad name;x") { refused = $0 }
        XCTAssertTrue(refused.contains("not a name"), "an invalid name is turned away at once")
        wait(for: [done], timeout: 15)
        let lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 4)
        XCTAssertEqual(lines[0].prefix(5), "start")
        XCTAssertEqual(lines[1].prefix(3), "end", "the first upgrade finishes before the second starts")
        XCTAssertEqual(lines[2].prefix(5), "start")
        XCTAssertEqual(lines[3].prefix(3), "end")
    }

    func testAnAppListSurvivesSavingAndReading() throws {
        let data = try HomebrewParsing.encodeList(casks: ["zoom", "firefox", "bad name", "firefox"], apps: [("Zoom", "us.zoom.xos")])
        XCTAssertEqual(try HomebrewParsing.decodeList(data), ["firefox", "zoom"], "sorted, tidy, and invalid names left out")
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("us.zoom.xos"))
    }

    func testAListThatIsNotOursOrIsTooNewIsRefused() {
        XCTAssertThrowsError(try HomebrewParsing.decodeList(Data("not json".utf8)))
        XCTAssertThrowsError(try HomebrewParsing.decodeList(Data(#"{"format":2,"casks":["a"],"apps":[]}"#.utf8)))
        XCTAssertThrowsError(try HomebrewParsing.decodeList(Data(repeating: 0x20, count: 2_100_000)))
        // Names that would be unsafe are dropped when the file is read.
        let sneaky = Data(#"{"format":1,"casks":["good","$(touch x)","--force","good"],"apps":[]}"#.utf8)
        XCTAssertEqual(try HomebrewParsing.decodeList(sneaky), ["good"])
    }

    func testMissingCasksAreTheWantedOnesNotInstalledYet() {
        XCTAssertEqual(HomebrewParsing.missing(wanted: ["a", "b", "c"], installed: ["b", "x"]), ["a", "c"])
        XCTAssertTrue(HomebrewParsing.missing(wanted: [], installed: ["b"]).isEmpty)
        XCTAssertEqual(HomebrewParsing.missing(wanted: ["a"], installed: []), ["a"])
    }

    /// A stand-in for `brew` that writes the arguments it was given, one per line, and then waits.
    private func makeStandIn() throws -> (path: String, cleanup: () -> Void) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kriya-brew-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let script = folder.appendingPathComponent("brew")
        try """
        #!/bin/sh
        if [ "$1" = "install" ]; then
          for a in "$@"; do echo "ARG[$a]"; done
          sleep 30
        fi
        exit 0
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return (script.path, { try? FileManager.default.removeItem(at: folder) })
    }

    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
    }

    func testCaskNamesReachHomebrewAsSeparateArgumentsAndStopEndsTheInstall() throws {
        let standIn = try makeStandIn()
        defer { standIn.cleanup() }
        let manager = HomebrewManager(brewPath: standIn.path)
        // A name with characters a shell would treat specially is refused before anything runs.
        manager.install(["good-app", "bad;name", "$(touch /tmp/kriya-should-not-exist)", "docker@2"])
        XCTAssertTrue(waitUntil(5) { manager.log.contains("ARG[good-app]") }, "the first valid name is passed as one argument")
        XCTAssertTrue(manager.log.contains("ARG[install]") && manager.log.contains("ARG[--cask]"))
        XCTAssertFalse(manager.log.contains("bad;name") || manager.log.contains("$(touch"), "names that are not valid never reach the command")
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/tmp/kriya-should-not-exist"))
        XCTAssertTrue(manager.isRunning)

        manager.cancel()
        XCTAssertTrue(waitUntil(8) { !manager.isRunning }, "Stop ends the running install")
        XCTAssertTrue(manager.log.contains("Stopped."), "and the ones waiting behind it do not start")
        XCTAssertFalse(manager.log.contains("ARG[docker@2]"), "the next cask was not started after Stop")
    }

    func testTheCommandShownIsTheOneThatRuns() {
        XCTAssertEqual(HomebrewManager.command(install: "firefox"), "brew install --cask firefox")
    }
}
