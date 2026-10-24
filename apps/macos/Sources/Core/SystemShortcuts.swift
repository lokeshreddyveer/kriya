import AppKit

/// macOS's own screenshot shortcuts (⌘⇧3, ⌘⇧4, ⌘⇧5 and their clipboard variants). The system handles them before any app sees the
/// keys, so an app that wants the same keys (or wants to record them as a shortcut) has to have them turned off first. That is how
/// other capture apps do it, and this reads and plans it as plain values so it can be tested.
enum SystemScreenshotKeys {
    struct Known: Equatable {
        let id: Int
        let name: String
        let keyCode: UInt16
        /// The modifiers as macOS stores them (device-independent flag bits).
        let flags: UInt
    }

    private static let shift: UInt = 0x20000, control: UInt = 0x40000, command: UInt = 0x100000

    /// The five screenshot shortcuts macOS has, with the keys they have unless the person changed them.
    static let known: [Known] = [
        Known(id: 28, name: "Save a picture of the screen", keyCode: 20, flags: shift | command),
        Known(id: 29, name: "Copy a picture of the screen", keyCode: 20, flags: control | shift | command),
        Known(id: 30, name: "Save a picture of an area", keyCode: 21, flags: shift | command),
        Known(id: 31, name: "Copy a picture of an area", keyCode: 21, flags: control | shift | command),
        Known(id: 184, name: "Screenshot and recording options", keyCode: 23, flags: shift | command),
    ]

    /// The ones a capture app normally takes over: the screen, an area, and the options toolbar.
    static let usual = [28, 30, 184]

    /// What the system says about one shortcut.
    struct State: Equatable {
        var enabled: Bool
        /// The keys it is set to, if the system says (it does when they were changed).
        var keyCode: UInt16?
        var flags: UInt?
    }

    /// The states in the system's `AppleSymbolicHotKeys` dictionary (keys are the shortcut numbers written as text).
    static func parse(_ dictionary: [String: Any]?) -> [Int: State] {
        guard let dictionary else { return [:] }
        var result: [Int: State] = [:]
        for (key, value) in dictionary {
            guard let id = Int(key), let entry = value as? [String: Any] else { continue }
            let enabled = (entry["enabled"] as? NSNumber)?.boolValue ?? (entry["enabled"] as? Bool) ?? true
            var keyCode: UInt16?, flags: UInt?
            if let parameters = (entry["value"] as? [String: Any])?["parameters"] as? [Any], parameters.count >= 3,
               let code = (parameters[1] as? NSNumber)?.intValue, let mask = (parameters[2] as? NSNumber)?.intValue, code >= 0, code < 200, mask >= 0 {
                keyCode = UInt16(code); flags = UInt(mask)
            }
            result[id] = State(enabled: enabled, keyCode: keyCode, flags: flags)
        }
        return result
    }

    /// The keys a macOS screenshot shortcut is using now (its own, or the person's change), as the app's key code and modifier bits.
    static func keys(of shortcut: Known, state: State?) -> (keyCode: UInt16, modifiers: UInt64) {
        let code = state?.keyCode ?? shortcut.keyCode
        let flags = state?.flags ?? shortcut.flags
        return (code, KeyModifiers.bits(from: NSEvent.ModifierFlags(rawValue: flags & 0xFFFF0000)))
    }

    /// The macOS screenshot shortcut that is turned on and uses these keys, if there is one.
    static func occupant(keyCode: UInt16, modifiers: UInt64, states: [Int: State]) -> Known? {
        known.first { shortcut in
            let state = states[shortcut.id]
            guard state?.enabled ?? true else { return false }
            let keys = Self.keys(of: shortcut, state: state)
            return keys.keyCode == keyCode && keys.modifiers == modifiers
        }
    }

    /// The macOS screenshot shortcuts that are on now.
    static func enabled(states: [Int: State], among ids: [Int]) -> [Known] {
        known.filter { ids.contains($0.id) && (states[$0.id]?.enabled ?? true) }
    }

    /// The plan for turning some off: which numbers to switch off, and what each was (so they can be given back).
    static func releasePlan(states: [Int: State], ids: [Int]) -> (switchOff: [Int], wasEnabled: [Int: Bool]) {
        var off: [Int] = []
        var was: [Int: Bool] = [:]
        for id in ids where known.contains(where: { $0.id == id }) {
            let on = states[id]?.enabled ?? true
            was[id] = on
            if on { off.append(id) }
        }
        return (off, was)
    }
}

/// Turning macOS's screenshot shortcuts off and on again. The system keeps them in the preferences of `com.apple.symbolichotkeys`;
/// a change there is picked up after `activateSettings -u` (or at the next sign-in, if that tool is not there).
final class SystemShortcutEditor {
    static let domain = "com.apple.symbolichotkeys" as CFString
    static let key = "AppleSymbolicHotKeys" as CFString
    /// Which shortcuts Kriya turned off, so only those are given back.
    static let releasedKey = "capture.systemKeysReleased"

    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func states() -> [Int: SystemScreenshotKeys.State] {
        SystemScreenshotKeys.parse(CFPreferencesCopyAppValue(Self.key, Self.domain) as? [String: Any])
    }

    /// The ids Kriya turned off and has not given back.
    var released: [Int] { (defaults.array(forKey: Self.releasedKey) as? [Int]) ?? [] }

    /// Turns these macOS shortcuts off. Returns false if the preferences could not be written.
    @discardableResult
    func release(_ ids: [Int]) -> Bool {
        let current = states()
        let plan = SystemScreenshotKeys.releasePlan(states: current, ids: ids)
        guard !plan.switchOff.isEmpty else { return true }
        guard write(enabled: false, ids: plan.switchOff) else { return false }
        defaults.set(Array(Set(released).union(plan.switchOff)).sorted(), forKey: Self.releasedKey)
        return true
    }

    /// Gives back the ones Kriya turned off.
    @discardableResult
    func giveBack() -> Bool {
        let ids = released
        guard !ids.isEmpty else { return true }
        guard write(enabled: true, ids: ids) else { return false }
        defaults.removeObject(forKey: Self.releasedKey)
        return true
    }

    private func write(enabled: Bool, ids: [Int]) -> Bool {
        var all = (CFPreferencesCopyAppValue(Self.key, Self.domain) as? [String: Any]) ?? [:]
        for id in ids {
            var entry = (all[String(id)] as? [String: Any]) ?? Self.defaultEntry(id)
            entry["enabled"] = enabled
            all[String(id)] = entry
        }
        CFPreferencesSetValue(Self.key, all as CFDictionary, Self.domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        guard CFPreferencesSynchronize(Self.domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else { return false }
        activate()
        return true
    }

    /// An entry for a shortcut the system has not written down (it is then using its defaults).
    private static func defaultEntry(_ id: Int) -> [String: Any] {
        guard let shortcut = SystemScreenshotKeys.known.first(where: { $0.id == id }) else { return ["enabled": true] }
        return ["enabled": true, "value": ["type": "standard", "parameters": [65535, Int(shortcut.keyCode), Int(shortcut.flags)]]]
    }

    /// Asks the system to read the changed preferences now. The tool is part of macOS but not promised; without it the change
    /// shows after the next sign-in.
    private func activate() {
        let tool = "/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings"
        guard FileManager.default.isExecutableFile(atPath: tool) else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = ["-u"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }
}
