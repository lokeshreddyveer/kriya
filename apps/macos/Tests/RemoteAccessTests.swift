import XCTest
@testable import Kriya

final class RemoteAccessTests: XCTestCase {
    private var support: URL!
    private var suite: String!
    private var defaults: UserDefaults!
    private var told: [String] = []
    private var ran: [String] = []

    override func setUpWithError() throws {
        support = FileManager.default.temporaryDirectory.appendingPathComponent("kriya-remote-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        suite = "kriya.test.remote.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        told = []
        ran = []
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: support)
        defaults.removePersistentDomain(forName: suite)
    }

    private func remote() -> RemoteCommands {
        let r = RemoteCommands(support: support, defaults: defaults)
        r.tell = { [unowned self] in told.append($0) }
        r.runCommand = { [unowned self] in ran.append("command \($0)") }
        r.runAction = { [unowned self] in ran.append("action \($0)") }
        r.runWorkflow = { [unowned self] in ran.append("workflow \($0)") }
        r.showLauncher = { [unowned self] in ran.append("launcher \($0 ?? "")") }
        return r
    }

    private func link(_ host: String, _ query: String, token: String) -> URL { URL(string: "kriya://\(host)?\(query)&t=\(token)")! }

    /// Lets the main queue run what `perform` handed it.
    private func drain() {
        let done = expectation(description: "main queue drained")
        DispatchQueue.main.async { done.fulfill() }
        wait(for: [done], timeout: 2)
    }

    // MARK: The switch

    func testRemoteCommandsAreOnUnlessTurnedOffSoExistingScriptsKeepWorking() {
        XCTAssertTrue(RemoteAccess.isEnabled(defaults))
        RemoteAccess.setEnabled(false, defaults: defaults)
        XCTAssertFalse(RemoteAccess.isEnabled(defaults))
        RemoteAccess.setEnabled(true, defaults: defaults)
        XCTAssertTrue(RemoteAccess.isEnabled(defaults))
    }

    func testWhenOnARequestWithTheTokenRuns() throws {
        let r = remote()
        let token = try XCTUnwrap(r.tokens.current)
        XCTAssertTrue(r.handle(link("run", "command=window.left_half", token: token)))
        drain()
        XCTAssertEqual(ran, ["command window.left_half"])
        XCTAssertTrue(told.isEmpty)
    }

    func testWhenOffRunIsRejectedNothingRunsAndTheCallerIsToldWhy() throws {
        let r = remote()
        let token = try XCTUnwrap(r.tokens.current)
        r.setEnabled(false)
        XCTAssertFalse(r.handle(link("run", "command=window.left_half", token: token)), "even with the right token")
        drain()
        XCTAssertTrue(ran.isEmpty, "the command was not executed")
        XCTAssertEqual(told, [RemoteAccess.disabledMessage])
        XCTAssertEqual(r.refused, 1)
        XCTAssertEqual(r.handled, 0)
        XCTAssertTrue(RemoteAccess.disabledMessage.contains("turned off"))
        XCTAssertTrue(RemoteAccess.disabledMessage.contains("settings"))
    }

    func testEveryKindOfRequestIsTurnedAwayWhenOff() throws {
        let r = remote()
        let token = try XCTUnwrap(r.tokens.current)
        r.setEnabled(false)
        for url in [link("run", "command=x.y", token: token), link("action", "id=abc", token: token), link("workflow", "id=abc", token: token), URL(string: "kriya://launcher?t=\(token)")!] {
            XCTAssertFalse(r.handle(url), url.absoluteString)
        }
        drain()
        XCTAssertTrue(ran.isEmpty)
        XCTAssertEqual(r.refused, 4)
    }

    func testTheShortcutsAndWebAddressPathIsRefusedWhenOff() {
        let r = remote()
        r.setEnabled(false)
        XCTAssertEqual(r.perform(.command("window.left_half")), .disabled, "what the Shortcuts actions and the local web address call")
        drain()
        XCTAssertTrue(ran.isEmpty)
        XCTAssertNil(r.setEnabledAndPerform(true))
    }

    func testTurningItBackOnWorksAgainWithTheSameToken() throws {
        let r = remote()
        let token = try XCTUnwrap(r.tokens.current)
        r.setEnabled(false)
        XCTAssertFalse(r.handle(link("run", "command=a.b", token: token)))
        r.setEnabled(true)
        XCTAssertTrue(r.handle(link("run", "command=a.b", token: token)), "the token stayed stored")
        drain()
        XCTAssertEqual(ran, ["command a.b"])
    }

    func testOtherAddressesAreNotOursAndAreLeftAlone() throws {
        let r = remote()
        r.setEnabled(false)
        XCTAssertFalse(r.handle(URL(string: "kriya://finder/run?x=1")!))
        XCTAssertFalse(r.handle(URL(string: "https://example.com")!))
        XCTAssertTrue(told.isEmpty, "no message for something that was never a request for Kriya")
        XCTAssertEqual(r.refused, 0)
    }

    func testAnErrorBodyForProgramsIsValidJSONWithTheReason() throws {
        let body = RemoteRefusalBody.json(.disabled)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        XCTAssertEqual(object["ok"] as? Bool, false)
        XCTAssertEqual(object["error"] as? String, RemoteAccess.disabledMessage)
    }

    func testEveryRefusalHasAClearSentenceExceptNotOurs() {
        XCTAssertNil(RemoteRefusal.notOurs.message)
        for refusal in [RemoteRefusal.disabled, .noToken, .unauthorized, .invalid] {
            let message = refusal.message ?? ""
            XCTAssertTrue(message.hasSuffix("."), "\(refusal)")
            XCTAssertTrue(message.contains("was not run") || message.contains("nothing was run") || message.contains("not run"), message)
        }
    }

    func testTheSwitchIsAGrantOfTrustSoABackupNeverTurnsItOn() throws {
        let entry = try XCTUnwrap(SettingsRegistry.entries.first { $0.key == RemoteAccess.enabledKey })
        XCTAssertEqual(entry.kind, .approval)
    }

    // MARK: The pure decision

    func testAuthorizeMatrix() {
        let url = URL(string: "kriya://run?command=a.b&t=secret")!
        XCTAssertEqual(try? RemoteCommand.authorize(url, enabled: true, token: "secret").get(), .command("a.b"))
        XCTAssertEqual(RemoteCommand.authorize(url, enabled: false, token: "secret"), .failure(.disabled))
        XCTAssertEqual(RemoteCommand.authorize(url, enabled: true, token: nil), .failure(.noToken))
        XCTAssertEqual(RemoteCommand.authorize(url, enabled: true, token: ""), .failure(.noToken))
        XCTAssertEqual(RemoteCommand.authorize(url, enabled: true, token: "other"), .failure(.unauthorized))
        XCTAssertEqual(RemoteCommand.authorize(URL(string: "kriya://run?t=secret")!, enabled: true, token: "secret"), .failure(.invalid))
        XCTAssertEqual(RemoteCommand.authorize(URL(string: "kriya://finder/x")!, enabled: false, token: nil), .failure(.notOurs))
        XCTAssertEqual(RemoteCommand.authorize(URL(string: "mailto:a@b.c")!, enabled: true, token: "secret"), .failure(.notOurs))
    }

    func testOffBeatsEverythingElseSoAWrongTokenIsNotAProbe() {
        let url = URL(string: "kriya://run?command=a.b&t=guess")!
        XCTAssertEqual(RemoteCommand.authorize(url, enabled: false, token: "secret"), .failure(.disabled))
    }

    // MARK: Rotating and revoking the token

    func testANewTokenMakesOldLinksStopWorkingAtOnce() throws {
        let r = remote()
        let old = try XCTUnwrap(r.tokens.current)
        XCTAssertTrue(r.handle(link("run", "command=a.b", token: old)))
        let fresh = try XCTUnwrap(r.rotateToken())
        XCTAssertNotEqual(fresh, old)
        XCTAssertEqual(fresh.count, 64)
        XCTAssertFalse(r.handle(link("run", "command=a.b", token: old)), "the old link no longer works")
        XCTAssertTrue(r.handle(link("run", "command=a.b", token: fresh)))
        drain()
        XCTAssertEqual(ran, ["command a.b", "command a.b"])
        XCTAssertTrue(told.contains(RemoteAccess.unauthorizedMessage))
    }

    func testRevokingLeavesNoTokenAndNothingWorksUntilANewOneIsCreated() throws {
        let r = remote()
        let old = try XCTUnwrap(r.tokens.current)
        XCTAssertTrue(r.revokeToken())
        XCTAssertEqual(r.tokens.state, .revoked)
        XCTAssertNil(r.tokens.current)
        XCTAssertNil(r.tokens.tokenForUse(), "opening the settings does not quietly make another")
        XCTAssertFalse(r.handle(link("run", "command=a.b", token: old)))
        XCTAssertFalse(r.handle(link("run", "command=a.b", token: "")))
        XCTAssertEqual(told.last, RemoteAccess.noTokenMessage)
        let fresh = try XCTUnwrap(r.rotateToken())
        XCTAssertTrue(r.handle(link("run", "command=a.b", token: fresh)), "a new token brings it back")
        XCTAssertFalse(r.handle(link("run", "command=a.b", token: old)), "the revoked one never does")
    }

    func testARevokedTokenIsNotTakenOverAgainFromTheBrowserExtensionsSecret() throws {
        let bridge = BridgeToken.loadOrCreate(in: support)
        let r = remote()
        XCTAssertEqual(r.tokens.current, bridge, "the first time, links people already made keep working")
        r.revokeToken()
        let again = remote()
        XCTAssertNil(again.tokens.current)
        XCTAssertEqual(again.tokens.state, .revoked)
    }

    func testRotatingDoesNotTouchTheBrowserExtensionsSecret() throws {
        let bridge = BridgeToken.loadOrCreate(in: support)
        let r = remote()
        r.rotateToken()
        XCTAssertEqual(BridgeToken.read(in: support), bridge, "the extensions stay connected")
        XCTAssertNotEqual(r.tokens.current, bridge)
    }

    func testTheTokenFileIsPrivateAndAnEmptyOrDamagedOneIsNeverOpen() throws {
        let r = remote()
        let attributes = try FileManager.default.attributesOfItem(atPath: r.tokens.fileURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        try Data("short".utf8).write(to: r.tokens.fileURL)
        XCTAssertEqual(r.tokens.state, .revoked, "anything but a whole token is treated as revoked, not as open")
        XCTAssertNil(r.tokens.current)
    }

    func testANewTokenIsRandom() {
        let tokens = (0..<20).map { _ in RemoteTokenStore.newToken() }
        XCTAssertEqual(Set(tokens).count, 20)
        XCTAssertTrue(tokens.allSatisfy { $0.count == 64 && $0.allSatisfy(\.isHexDigit) })
    }

    // MARK: What the command-line tool reads

    func testTheCommandLineToolIsToldWhetherRemoteCommandsAreOn() throws {
        let r = remote()
        XCTAssertEqual(try String(contentsOf: r.tokens.stateURL, encoding: .utf8), "enabled\n")
        r.setEnabled(false)
        XCTAssertEqual(try String(contentsOf: r.tokens.stateURL, encoding: .utf8), "disabled\n")
        r.setEnabled(true)
        XCTAssertEqual(try String(contentsOf: r.tokens.stateURL, encoding: .utf8), "enabled\n")
    }

    func testTheCommandLineToolSaysWhyWhenOffOrRevoked() throws {
        let script = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("CLI/kriya"), encoding: .utf8)
        XCTAssertTrue(script.contains("remote-commands-state"))
        XCTAssertTrue(script.contains("remote commands are turned off in Kriya"))
        XCTAssertTrue(script.contains("the access token was revoked"))
        XCTAssertTrue(script.contains("remote-commands-token"))
        XCTAssertTrue(script.contains("browser-bridge-token"), "still reads the older secret until Kriya makes its own")
    }
}

private extension RemoteCommands {
    /// Turns remote commands back on and runs a harmless request, to show the switch is what stopped the earlier one.
    func setEnabledAndPerform(_ on: Bool) -> RemoteRefusal? {
        setEnabled(on)
        return perform(.launcher(nil))
    }
}
