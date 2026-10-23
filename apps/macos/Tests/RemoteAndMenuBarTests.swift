import XCTest
@testable import Kriya

final class RemoteCommandTests: XCTestCase {
    private let token = String(repeating: "ab", count: 32)

    func testAddressesWithTheSecretAreUnderstood() throws {
        func parse(_ text: String) -> Result<RemoteCommand, RemoteCommand.Failure> { RemoteCommand.parse(URL(string: text)!, token: token) }
        XCTAssertEqual(try parse("kriya://run?command=window.left_half&t=\(token)").get(), .command("window.left_half"))
        XCTAssertEqual(try parse("kriya://action?id=abc-123&t=\(token)").get(), .action("abc-123"))
        XCTAssertEqual(try parse("kriya://workflow?id=wf1&t=\(token)").get(), .workflow("wf1"))
        XCTAssertEqual(try parse("kriya://launcher?q=hello%20world&t=\(token)").get(), .launcher("hello world"))
        XCTAssertEqual(try parse("kriya://launcher?t=\(token)").get(), .launcher(nil))
        XCTAssertEqual(try parse("kriya://launcher?q=%20&t=\(token)").get(), .launcher(nil))
    }

    func testNothingWorksWithoutTheRightSecretOrWithOddNames() {
        func parse(_ text: String, token given: String? = nil) -> Result<RemoteCommand, RemoteCommand.Failure> { RemoteCommand.parse(URL(string: text)!, token: given ?? token) }
        XCTAssertEqual(parse("kriya://run?command=window.left_half"), .failure(.unauthorized))
        XCTAssertEqual(parse("kriya://run?command=window.left_half&t=wrong"), .failure(.unauthorized))
        XCTAssertEqual(parse("kriya://run?command=x&t=\(token)", token: ""), .failure(.unauthorized), "an empty secret is never a match")
        XCTAssertEqual(parse("kriya://run?command=a%20b&t=\(token)"), .failure(.invalid))
        XCTAssertEqual(parse("kriya://run?command=a;rm%20-rf&t=\(token)"), .failure(.invalid))
        XCTAssertEqual(parse("kriya://run?t=\(token)"), .failure(.invalid))
        XCTAssertEqual(parse("kriya://run?command=\(String(repeating: "a", count: 101))&t=\(token)"), .failure(.invalid))
        XCTAssertEqual(parse("kriya://launcher?q=\(String(repeating: "a", count: 300))&t=\(token)"), .failure(.invalid))
        XCTAssertEqual(parse("kriya://finder/run?t=\(token)"), .failure(.notOurs))
        XCTAssertEqual(parse("https://run?command=x&t=\(token)"), .failure(.notOurs))
    }

    func testTheAddressWeBuildIsTheOneWeUnderstand() throws {
        for command in [RemoteCommand.command("pointer.spotlight"), .action("id-1"), .workflow("w"), .launcher("two words"), .launcher(nil)] {
            let url = try XCTUnwrap(command.url(token: token))
            XCTAssertEqual(try RemoteCommand.parse(url, token: token).get(), command)
        }
    }

    func testTheCommandLineToolEncodesAnyTextSafely() throws {
        // The shipped script writes every byte as %XX. Run it for real against a stand-in `open`.
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("CLI/kriya")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: source.path), "the script is executable")
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("kriya-cli-\(UUID().uuidString)")
        let bin = home.appendingPathComponent("bin")
        let support = home.appendingPathComponent("Library/Application Support/Kriya")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try token.write(to: support.appendingPathComponent("browser-bridge-token"), atomically: true, encoding: .utf8)
        let log = home.appendingPathComponent("opened.txt")
        let stub = bin.appendingPathComponent("open")
        try "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"\(log.path)\"\n".write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)

        func run(_ arguments: [String]) throws -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [source.path] + arguments
            process.environment = ["HOME": home.path, "PATH": "\(bin.path):/usr/bin:/bin"]
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }
        XCTAssertEqual(try run(["run", "window.left_half"]), 0)
        XCTAssertEqual(try run(["launcher", "héllo & wörld"]), 0)
        XCTAssertEqual(try run(["run"]), 2)
        XCTAssertEqual(try run(["nonsense"]), 2)
        let lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 2)
        for line in lines {
            let url = try XCTUnwrap(URL(string: line.replacingOccurrences(of: "-g ", with: "")), line)
            XCTAssertNoThrow(try RemoteCommand.parse(url, token: token).get(), line)
        }
        let launcher = try XCTUnwrap(URL(string: lines[1]))
        XCTAssertEqual(try RemoteCommand.parse(launcher, token: token).get(), .launcher("héllo & wörld"))
    }

    func testInstallingTheToolNeverReplacesSomeoneElsesProgram() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kriya-bin-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("kriya-src-\(UUID().uuidString)/CLI/kriya")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: source, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.path)
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent().deletingLastPathComponent()) }

        XCTAssertNil(CommandLineTool.install(source: source, into: folder))
        XCTAssertTrue(CommandLineTool.isInstalled(in: folder))
        XCTAssertNil(CommandLineTool.install(source: source, into: folder), "again is fine")
        CommandLineTool.uninstall(from: folder)
        XCTAssertFalse(CommandLineTool.isInstalled(in: folder))

        try "#!/bin/sh\necho mine\n".write(to: folder.appendingPathComponent("kriya"), atomically: true, encoding: .utf8)
        XCTAssertNotNil(CommandLineTool.install(source: source, into: folder), "a real file with that name is left alone")
        CommandLineTool.uninstall(from: folder)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("kriya").path), "and not removed")
        XCTAssertNotNil(CommandLineTool.install(source: nil, into: folder))
        XCTAssertTrue(CommandLineTool.isOnPath(URL(fileURLWithPath: "/usr/bin"), path: "/bin:/usr/bin"))
        XCTAssertFalse(CommandLineTool.isOnPath(URL(fileURLWithPath: "/nope"), path: "/bin:/usr/bin"))
    }
}

final class MenuBarHiderTests: XCTestCase {
    func testTheCollapseCheckNoticesWhenMacOSDidNotMakeRoom() {
        XCTAssertTrue(MenuBarHider.collapseWorked(dividerWidth: 10_000, screenWidth: 1512))
        XCTAssertFalse(MenuBarHider.collapseWorked(dividerWidth: 14, screenWidth: 1512))
        XCTAssertFalse(MenuBarHider.collapseWorked(dividerWidth: 1000, screenWidth: 1512))
    }

    func testTheAutoHideChoicesStartWithNeverAndAreIncreasing() {
        let seconds = MenuBarHider.autoHideChoices.map(\.seconds)
        XCTAssertEqual(seconds.first, 0)
        XCTAssertEqual(seconds, seconds.sorted())
    }
}
