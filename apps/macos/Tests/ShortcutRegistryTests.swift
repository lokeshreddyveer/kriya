import XCTest
@testable import Kriya

/// A stand-in for macOS's hot-key service, so the tests never take a real shortcut.
private final class FakeHotKeyBackend: HotKeyBackend {
    var onPressed: ((UInt32) -> Bool)?
    /// Combinations the "system" already gives to someone else.
    var heldByOthers: Set<String> = []
    var live: [UInt32: String] = [:]

    private func key(_ code: UInt16, _ mods: UInt64) -> String { "\(code):\(mods)" }

    func register(keyCode: UInt16, modifiers: UInt64, id: UInt32) -> Bool {
        let k = key(keyCode, modifiers)
        if heldByOthers.contains(k) || live.values.contains(k) { return false }
        live[id] = k
        return true
    }

    func unregister(id: UInt32) { live[id] = nil }

    /// Presses the shortcut registered with this key, as the system would.
    func press(_ code: UInt16, _ mods: UInt64) -> Bool {
        guard let id = live.first(where: { $0.value == key(code, mods) })?.key else { return false }
        return onPressed?(id) ?? false
    }
}

final class ShortcutRegistryTests: XCTestCase {
    private func binding(_ command: String, _ code: UInt16, _ mods: UInt64 = KeyModifiers.control) -> ShortcutBinding {
        ShortcutBinding(command: command, keyCode: code, modifiers: mods)
    }

    func testEachFeatureGetsOnlyItsOwnPresses() {
        let backend = FakeHotKeyBackend()
        let registry = ShortcutRegistry(backend: backend)
        var fired: [String] = []
        registry.register(owner: "Windows", bindings: [binding("window.left_half", 123)], title: { $0 }) { fired.append("windows:\($0)") }
        registry.register(owner: "Clipboard", bindings: [binding("clipboard.quick", 9)], title: { $0 }) { fired.append("clipboard:\($0)") }
        XCTAssertTrue(backend.press(9, KeyModifiers.control))
        XCTAssertTrue(backend.press(123, KeyModifiers.control))
        XCTAssertEqual(fired, ["clipboard:clipboard.quick", "windows:window.left_half"], "no press reaches the wrong feature")
        XCTAssertEqual(Set(backend.live.keys).count, 2, "every shortcut has its own identifier")
    }

    func testWindowsKeyboardClipboardSelectionFinderAndAutomationEachGetTheirOwnPresses() {
        let backend = FakeHotKeyBackend()
        let registry = ShortcutRegistry(backend: backend)
        var received: [String: [String]] = [:]
        let owners: [(String, String, UInt16)] = [
            ("Windows", "window.left_half", 123), ("Keyboard", "palette.open", 49), ("Clipboard", "clipboard.quick", 9),
            ("Selection bar", "selection.manual", 1), ("Right-click menu", "finder.launcher", 3), ("Automation", "workflow-7", 4),
        ]
        for (owner, command, key) in owners {
            registry.register(owner: owner, bindings: [binding(command, key)], title: { $0 }) { received[owner, default: []].append($0) }
        }
        for (_, _, key) in owners.reversed() { XCTAssertTrue(backend.press(key, KeyModifiers.control)) }
        XCTAssertEqual(received.count, 6)
        for (owner, command, _) in owners {
            XCTAssertEqual(received[owner], [command], "\(owner) got exactly its own press, once")
        }
        // One feature changing its list leaves the others working.
        registry.register(owner: "Windows", bindings: [], title: { $0 }) { _ in }
        XCTAssertFalse(backend.press(123, KeyModifiers.control))
        XCTAssertTrue(backend.press(9, KeyModifiers.control))
        XCTAssertEqual(received["Clipboard"], ["clipboard.quick", "clipboard.quick"])
    }

    func testRegisteringFromManyThreadsWhileKeysArePressedIsSafe() {
        final class LockedBackend: HotKeyBackend {
            var onPressed: ((UInt32) -> Bool)?
            private let lock = NSLock()
            private var taken = Set<String>()
            private var live: [UInt32: String] = [:]
            func register(keyCode: UInt16, modifiers: UInt64, id: UInt32) -> Bool {
                lock.lock(); defer { lock.unlock() }
                let key = "\(keyCode):\(modifiers)"
                if taken.contains(key) { return false }
                taken.insert(key)
                live[id] = key
                return true
            }
            func unregister(id: UInt32) {
                lock.lock(); defer { lock.unlock() }
                if let key = live.removeValue(forKey: id) { taken.remove(key) }
            }
            func someID() -> UInt32? {
                lock.lock(); defer { lock.unlock() }
                return live.keys.first
            }
        }
        let backend = LockedBackend()
        let registry = ShortcutRegistry(backend: backend)
        let fired = NSLock()
        var count = 0
        DispatchQueue.concurrentPerform(iterations: 400) { i in
            let owner = "Feature \(i % 8)"
            registry.register(owner: owner, bindings: [ShortcutBinding(command: "c\(i)", keyCode: UInt16(i % 50), modifiers: UInt64(i % 3))], title: { $0 }) { _ in
                fired.lock(); count += 1; fired.unlock()
            }
            if let id = backend.someID() { _ = backend.onPressed?(id) }
            if i % 7 == 0 { registry.unregister(owner: owner) }
            registry.setPassive(owner: "Passive", entries: [])
        }
        // Reaching here without a crash or a hang is the point; the list is still self-consistent.
        let waited = expectation(description: "main queue drained")
        DispatchQueue.main.async { waited.fulfill() }
        wait(for: [waited], timeout: 5)
        XCTAssertEqual(Set(registry.entries.map(\.id)).count, registry.entries.count, "no entry is listed twice")
    }

    func testAPressThatIsNotOursIsPassedOn() {
        let backend = FakeHotKeyBackend()
        let registry = ShortcutRegistry(backend: backend)
        registry.register(owner: "Windows", bindings: [binding("a", 1)], title: { $0 }) { _ in }
        XCTAssertEqual(backend.onPressed?(9999), false, "an unknown identifier is reported as not handled, so the next handler can take it")
    }

    func testTheSameKeysFromTwoFeaturesClash() {
        let backend = FakeHotKeyBackend()
        let registry = ShortcutRegistry(backend: backend)
        let first = registry.register(owner: "Windows", bindings: [binding("window.radial", 15)], title: { _ in "Radial" }) { _ in }
        let second = registry.register(owner: "Clipboard", bindings: [binding("clipboard.quick", 15)], title: { _ in "Quick paste" }) { _ in }
        XCTAssertTrue(first.isEmpty)
        XCTAssertEqual(second, ["clipboard.quick"], "the second feature is told its shortcut was refused")
        XCTAssertEqual(registry.entries.filter { $0.status == .refused }.map(\.owner), ["Clipboard"])
        XCTAssertEqual(registry.conflicts.count, 1)
        XCTAssertEqual(registry.conflicts[0].map(\.owner), ["Clipboard", "Windows"])
        XCTAssertEqual(registry.users(of: 15, modifiers: KeyModifiers.control).count, 2)
    }

    func testKeysTakenByAnotherAppAreReportedAsRefused() {
        let backend = FakeHotKeyBackend()
        backend.heldByOthers = ["15:2"]
        let registry = ShortcutRegistry(backend: backend)
        let failed = registry.register(owner: "Windows", bindings: [binding("window.radial", 15, 2)], title: { $0 }) { _ in }
        XCTAssertEqual(failed, ["window.radial"])
        XCTAssertEqual(registry.entries.first?.status, .refused)
    }

    func testReplacingAFeaturesShortcutsFreesTheOldKeys() {
        let backend = FakeHotKeyBackend()
        let registry = ShortcutRegistry(backend: backend)
        registry.register(owner: "Windows", bindings: [binding("a", 1), binding("b", 2)], title: { $0 }) { _ in }
        // The same feature saves a new list that includes a key it already had: nothing is refused.
        let failed = registry.register(owner: "Windows", bindings: [binding("a", 1)], title: { $0 }) { _ in }
        XCTAssertTrue(failed.isEmpty)
        XCTAssertEqual(backend.live.count, 1)
        registry.unregister(owner: "Windows")
        XCTAssertTrue(backend.live.isEmpty)
        XCTAssertTrue(registry.entries.isEmpty)
    }

    func testShortcutsFoundByWatchingKeysTakePartInTheCheck() {
        let backend = FakeHotKeyBackend()
        let registry = ShortcutRegistry(backend: backend)
        registry.register(owner: "Windows", bindings: [binding("window.radial", 15)], title: { _ in "Radial" }) { _ in }
        registry.setPassive(owner: "Keyboard shortcuts", entries: [
            ShortcutEntry(owner: "Keyboard shortcuts", command: "id1", title: "Open mail", keyCode: 15, modifiers: KeyModifiers.control),
        ])
        XCTAssertEqual(registry.conflicts.count, 1)
        XCTAssertEqual(registry.entries.filter { !$0.viaHotKey }.count, 1)
        registry.setPassive(owner: "Keyboard shortcuts", entries: [])
        XCTAssertTrue(registry.conflicts.isEmpty)
    }

    func testAppSpecificShortcutsOnlyClashWhereTheyOverlap() {
        func entry(_ owner: String, _ apps: [String]) -> ShortcutEntry {
            ShortcutEntry(owner: owner, command: owner, title: owner, keyCode: 5, modifiers: 1, apps: apps)
        }
        XCTAssertTrue(ShortcutConflicts.groups([entry("A", ["x"]), entry("B", ["y"])]).isEmpty, "different apps never meet")
        XCTAssertEqual(ShortcutConflicts.groups([entry("A", ["x"]), entry("B", ["x", "y"])]).count, 1, "one app in common")
        XCTAssertEqual(ShortcutConflicts.groups([entry("A", []), entry("B", ["y"])]).count, 1, "everywhere overlaps every app")
        XCTAssertTrue(ShortcutConflicts.groups([entry("A", [])]).isEmpty, "one shortcut alone is no clash")
        let other = ShortcutEntry(owner: "C", command: "c", title: "c", keyCode: 6, modifiers: 1)
        XCTAssertTrue(ShortcutConflicts.groups([entry("A", []), other]).isEmpty, "different keys never clash")
    }

    func testCommandsWithoutANameAreMadeReadable() {
        XCTAssertEqual(ShortcutRegistry.title(for: "clipboard.quick"), "Open the quick paste panel")
        XCTAssertEqual(ShortcutRegistry.title(for: "window.left_half"), "window › left half")
    }
}
