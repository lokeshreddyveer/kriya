import AppKit
import Carbon.HIToolbox

/// Whether some app has asked the system for "secure input", which hides keystrokes from every other app. While it is on,
/// Kriya's remapping, shortcuts that read the keyboard and text expansion cannot see what is typed.
struct SecureInputStatus: Equatable {
    var enabled: Bool
    var pid: pid_t?
    var appName: String?
}

enum SecureInput {
    static func current() -> SecureInputStatus {
        parse(enabled: IsSecureEventInputEnabled(), session: CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]) { pid in
            NSRunningApplication(processIdentifier: pid)?.localizedName
        }
    }

    /// Reads the answer. The system names the app holding secure input in the login session's details, when it says.
    static func parse(enabled: Bool, session: [String: Any], appName: (pid_t) -> String?) -> SecureInputStatus {
        guard enabled else { return SecureInputStatus(enabled: false, pid: nil, appName: nil) }
        let raw = session["kCGSSessionSecureInputPID"]
        let value = (raw as? Int) ?? (raw as? NSNumber)?.intValue
        guard let value, value > 0 else { return SecureInputStatus(enabled: true, pid: nil, appName: nil) }
        return SecureInputStatus(enabled: true, pid: pid_t(value), appName: appName(pid_t(value)))
    }
}

/// Letting go of modifier keys that seem stuck down, for when a remap or an app lost track of them.
enum ModifierReset {
    /// Left and right command, shift, option and control, caps lock and fn.
    static let keyCodes: [CGKeyCode] = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]

    /// The release events, marked as Kriya's own so Kriya's features ignore them.
    static func events() -> [CGEvent] {
        let source = CGEventSource(stateID: .hidSystemState)
        return keyCodes.compactMap { code in
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else { return nil }
            event.flags = []
            event.setIntegerValueField(.eventSourceUserData, value: EventMonitor.syntheticMarker)
            return event
        }
    }

    static func run(post: (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) }) {
        for event in events() { post(event) }
    }
}
