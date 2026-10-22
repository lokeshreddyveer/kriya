import CryptoKit
import XCTest
@testable import Kriya

final class BrowserBridgeTests: XCTestCase {
    private let token = String(repeating: "ab", count: 32)

    private func address(_ message: [String: Any]) throws -> URL {
        try BridgeProtocol.address(for: message, token: token).get()
    }

    func testALinkSurvivesTheRoundTrip() throws {
        let link = "https://example.com/path?a=1&b=two words#frag"
        let url = try address(["type": "open", "url": link, "title": "Tom & Jerry = fun"])
        guard case .open(let opened, let title) = try BridgeProtocol.request(from: url, token: token).get() else { return XCTFail("not an open request") }
        XCTAssertEqual(opened.absoluteString, URL(string: link)?.absoluteString)
        XCTAssertEqual(title, "Tom & Jerry = fun")
    }

    func testSelectedTextSurvivesTheRoundTripAndIsCut() throws {
        let text = "line one\nline two & more = text, 100% sure +plus"
        guard case .selection(let received, let page) = try BridgeProtocol.request(from: try address(["type": "selection", "text": "  \(text)  ", "url": "https://example.org/a"]), token: token).get() else { return XCTFail() }
        XCTAssertEqual(received, text)
        XCTAssertEqual(page?.host, "example.org")
        let long = String(repeating: "x", count: BridgeProtocol.maxTextLength + 500)
        guard case .selection(let cut, _) = try BridgeProtocol.request(from: try address(["type": "selection", "text": long]), token: token).get() else { return XCTFail() }
        XCTAssertEqual(cut.count, BridgeProtocol.maxTextLength)
    }

    func testOnlyWebAddressesAreAccepted() {
        for bad in ["javascript:alert(1)", "file:///etc/passwd", "kriya://finder/run", "data:text/html,hi", "https://", "not a url", ""] {
            XCTAssertThrowsError(try address(["type": "open", "url": bad]), bad)
        }
        XCTAssertThrowsError(try address(["type": "open", "url": "https://example.com/" + String(repeating: "a", count: 5000)]))
        XCTAssertThrowsError(try address(["type": "open"]))
        XCTAssertThrowsError(try address(["type": "selection", "text": "   "]))
        XCTAssertThrowsError(try address(["type": "run", "url": "https://example.com"]), "unknown requests are refused")
        XCTAssertThrowsError(try address([:]))
    }

    func testARequestWithoutTheSecretIsRefused() throws {
        let good = try address(["type": "open", "url": "https://example.com"])
        XCTAssertThrowsError(try BridgeProtocol.request(from: good, token: String(repeating: "cd", count: 32)).get()) { XCTAssertEqual($0 as? BridgeError, .unauthorized) }
        XCTAssertThrowsError(try BridgeProtocol.request(from: good, token: "").get())
        let bare = URL(string: "kriya://browser/open?u=https%3A%2F%2Fexample.com")!
        XCTAssertThrowsError(try BridgeProtocol.request(from: bare, token: token).get()) { XCTAssertEqual($0 as? BridgeError, .unauthorized) }
        let other = URL(string: "kriya://finder/run?t=\(token)")!
        XCTAssertThrowsError(try BridgeProtocol.request(from: other, token: token).get())
        let unknown = URL(string: "kriya://browser/delete?t=\(token)")!
        XCTAssertThrowsError(try BridgeProtocol.request(from: unknown, token: token).get())
    }

    func testTheBridgeCountsWhatItHandlesAndRefusesTheRest() throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("kriya-bridge-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: support) }
        let bridge = BrowserBridge(support: support)
        var opened: URL?
        var shown: String?
        bridge.openLink = { opened = $0 }
        bridge.showSelection = { shown = $0 }
        let real = try XCTUnwrap(BridgeToken.read(in: support))
        XCTAssertEqual(real.count, 64)
        let attributes = try FileManager.default.attributesOfItem(atPath: BridgeToken.fileURL(in: support).path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600, "only this Mac user can read the secret")
        XCTAssertTrue(bridge.handle(try BridgeProtocol.address(for: ["type": "open", "url": "https://example.com/x"], token: real).get()))
        XCTAssertTrue(bridge.handle(try BridgeProtocol.address(for: ["type": "selection", "text": "hello"], token: real).get()))
        XCTAssertFalse(bridge.handle(try BridgeProtocol.address(for: ["type": "open", "url": "https://evil.example"], token: "wrong").get()))
        XCTAssertEqual(opened?.host, "example.com")
        XCTAssertEqual(shown, "hello")
        XCTAssertEqual(bridge.handled, 2)
        XCTAssertEqual(bridge.refused, 1)
        XCTAssertEqual(BridgeToken.loadOrCreate(in: support), real, "the secret stays the same")
    }
}

final class NativeHostTests: XCTestCase {
    func testMessagesAreFramedAndSplitAgain() throws {
        let one = Data(#"{"a":1}"#.utf8), two = Data(#"{"b":2}"#.utf8)
        var stream = NativeHost.frame(one) + NativeHost.frame(two)
        let first = try XCTUnwrap(NativeHost.unframe(stream))
        XCTAssertEqual(first.message, one)
        stream = first.rest
        XCTAssertEqual(try XCTUnwrap(NativeHost.unframe(stream)).message, two)
        XCTAssertNil(NativeHost.unframe(Data([1, 0, 0])), "not even a whole length")
        XCTAssertNil(NativeHost.unframe(NativeHost.frame(one).dropLast()), "a message cut short")
        var huge = UInt32(NativeHost.maxMessageBytes + 1)
        XCTAssertNil(NativeHost.unframe(Data(bytes: &huge, count: 4) + Data(count: NativeHost.maxMessageBytes + 1)), "too big")
        var none = UInt32(0)
        XCTAssertNil(NativeHost.unframe(Data(bytes: &none, count: 4)))
    }

    func testTheHostIsStartedOnlyInTheWaysBrowsersDoIt() {
        XCTAssertTrue(NativeHost.isRequested(["/Applications/Kriya.app/Contents/MacOS/Kriya", "chrome-extension://abc/"]))
        XCTAssertTrue(NativeHost.isRequested(["Kriya", "/Users/me/NativeMessagingHosts/app.kriya.bridge.json", "kriya-bridge@kriya.app"]))
        XCTAssertTrue(NativeHost.isRequested(["Kriya", "--native-host"]))
        XCTAssertFalse(NativeHost.isRequested(["Kriya"]))
        XCTAssertFalse(NativeHost.isRequested(["Kriya", "-NSDocumentRevisionsDebugMode", "YES"]))
    }

    func testTheHostAnswersAndOnlyActsOnGoodMessages() throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("kriya-host-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: support) }
        var opened: [URL] = []
        let record: (URL) -> Bool = { opened.append($0); return true }
        func ask(_ object: Any) throws -> [String: Any] {
            let body = try JSONSerialization.data(withJSONObject: object)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: NativeHost.reply(to: body, support: support, open: record)) as? [String: Any])
        }
        let before = try ask(["type": "open", "url": "https://example.com"])
        XCTAssertEqual(before["ok"] as? Bool, false, "Kriya has never run, so there is no secret yet")
        XCTAssertTrue(opened.isEmpty)
        let token = BridgeToken.loadOrCreate(in: support)
        XCTAssertEqual(try ask(["type": "open", "url": "https://example.com/page"])["ok"] as? Bool, true)
        XCTAssertEqual(opened.count, 1)
        XCTAssertEqual(try BridgeProtocol.request(from: opened[0], token: token).get(), .open(URL(string: "https://example.com/page")!, title: nil))
        XCTAssertEqual(try ask(["type": "open", "url": "javascript:alert(1)"])["ok"] as? Bool, false)
        XCTAssertEqual(try ask(["type": "wipe"])["ok"] as? Bool, false)
        XCTAssertEqual(opened.count, 1, "nothing else was opened")
        let junk = NativeHost.reply(to: Data("not json".utf8), support: support, open: record)
        XCTAssertEqual((try JSONSerialization.jsonObject(with: junk) as? [String: Any])?["ok"] as? Bool, false)
        let failing = NativeHost.reply(to: try JSONSerialization.data(withJSONObject: ["type": "open", "url": "https://example.com"]), support: support, open: { _ in false })
        XCTAssertEqual((try JSONSerialization.jsonObject(with: failing) as? [String: Any])?["error"] as? String, "Kriya could not be started.")
    }
}

final class NativeHostInstallerTests: XCTestCase {
    private func temporarySupport() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("kriya-hosts-\(UUID().uuidString)")
    }

    func testEachBrowserGetsOnlyItsOwnExtensionAllowed() throws {
        let chrome = try XCTUnwrap(NativeHostInstaller.browsers.first { $0.kind == .chromium })
        let firefox = try XCTUnwrap(NativeHostInstaller.browsers.first { $0.kind == .firefox })
        let chromeFile = try XCTUnwrap(JSONSerialization.jsonObject(with: NativeHostInstaller.manifest(for: chrome, executable: "/Applications/Kriya.app/Contents/MacOS/Kriya")) as? [String: Any])
        XCTAssertEqual(chromeFile["name"] as? String, "app.kriya.bridge")
        XCTAssertEqual(chromeFile["type"] as? String, "stdio")
        XCTAssertEqual(chromeFile["allowed_origins"] as? [String], ["chrome-extension://\(NativeHostInstaller.chromiumExtensionID)/"])
        XCTAssertNil(chromeFile["allowed_extensions"])
        let firefoxFile = try XCTUnwrap(JSONSerialization.jsonObject(with: NativeHostInstaller.manifest(for: firefox, executable: "/x")) as? [String: Any])
        XCTAssertEqual(firefoxFile["allowed_extensions"] as? [String], [NativeHostInstaller.firefoxExtensionID])
        XCTAssertNil(firefoxFile["allowed_origins"])
    }

    func testInstallingWritesOneFileAndRemovingTakesItAway() throws {
        let support = temporarySupport()
        defer { try? FileManager.default.removeItem(at: support) }
        let brave = try XCTUnwrap(NativeHostInstaller.browsers.first { $0.id == "com.brave.Browser" })
        XCTAssertFalse(NativeHostInstaller.isInstalled(brave, executable: "/a", applicationSupport: support))
        try NativeHostInstaller.install(brave, executable: "/a", applicationSupport: support)
        XCTAssertTrue(NativeHostInstaller.isInstalled(brave, executable: "/a", applicationSupport: support))
        XCTAssertFalse(NativeHostInstaller.isInstalled(brave, executable: "/somewhere/else", applicationSupport: support), "a copy that moved is not connected")
        XCTAssertTrue(NativeHostInstaller.manifestURL(for: brave, applicationSupport: support).path.hasSuffix("BraveSoftware/Brave-Browser/NativeMessagingHosts/app.kriya.bridge.json"))
        NativeHostInstaller.remove(brave, applicationSupport: support)
        XCTAssertFalse(NativeHostInstaller.isInstalled(brave, executable: "/a", applicationSupport: support))
    }

    /// The extension folders ship inside the app. Their identity and permissions must match what Kriya allows.
    func testTheShippedExtensionsMatchWhatKriyaAllowsAndAskForLittle() throws {
        guard let folder = Bundle.main.resourceURL?.appendingPathComponent("Extensions"), FileManager.default.fileExists(atPath: folder.path) else {
            throw XCTSkip("The extensions are not in this test host's bundle.")
        }
        func manifest(_ name: String) throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("\(name)/manifest.json"))) as? [String: Any])
        }
        let chromium = try manifest("chromium")
        let key = try XCTUnwrap(chromium["key"] as? String)
        let der = try XCTUnwrap(Data(base64Encoded: key))
        let hex = SHA256.hash(data: der).prefix(16).map { String(format: "%02x", $0) }.joined()
        let id = String(hex.map { Character(UnicodeScalar(UInt8(ascii: "a") + UInt8(String($0), radix: 16)!)) })
        XCTAssertEqual(id, NativeHostInstaller.chromiumExtensionID, "the pinned key gives the id the host file allows")
        let firefox = try manifest("firefox")
        let gecko = (firefox["browser_specific_settings"] as? [String: Any])?["gecko"] as? [String: Any]
        XCTAssertEqual(gecko?["id"] as? String, NativeHostInstaller.firefoxExtensionID)
        for name in ["chromium", "firefox"] {
            let m = try manifest(name)
            XCTAssertEqual(Set(m["permissions"] as? [String] ?? []), ["contextMenus", "nativeMessaging", "activeTab"])
            XCTAssertNil(m["host_permissions"]); XCTAssertNil(m["content_scripts"]); XCTAssertNil(m["externally_connectable"])
            let script = try String(contentsOf: folder.appendingPathComponent("\(name)/background.js"), encoding: .utf8)
            for forbidden in ["fetch(", "XMLHttpRequest", "eval(", "new Function", "importScripts", "WebSocket"] {
                XCTAssertFalse(script.contains(forbidden), "\(name) must not use \(forbidden)")
            }
        }
    }
}
