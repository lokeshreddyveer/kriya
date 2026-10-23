import AppKit

// Names and symbols for the mouse settings the core defines.

extension MousePreset: Identifiable {}
extension MouseAssignment: Identifiable {}

extension PointerAccelerationPreset {
    static var all: [PointerAccelerationPreset] { [.system, .off, .low, .medium, .high, .custom] }

    var title: String {
        switch self {
        case .system: return "System setting"
        case .off: return "No acceleration"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .custom: return "Custom"
        }
    }
}

extension GestureDirection {
    static var all: [GestureDirection] { [.up, .down, .left, .right] }

    var title: String {
        switch self {
        case .up: return "Up"
        case .down: return "Down"
        case .left: return "Left"
        case .right: return "Right"
        }
    }

    var symbol: String {
        switch self {
        case .up: return "arrow.up"
        case .down: return "arrow.down"
        case .left: return "arrow.left"
        case .right: return "arrow.right"
        }
    }
}

/// Mouse buttons by the numbers macOS uses.
enum MouseButtons {
    /// Buttons a rule or gesture can use. The left and right buttons are not remappable.
    static let remappable: [UInt32] = Array(2...9)

    static func name(_ button: UInt32) -> String {
        switch button {
        case 0: return "Left button"
        case 1: return "Right button"
        case 2: return "Middle button"
        default: return "Button \(button + 1)"
        }
    }
}

extension KeyModifiers {
    /// The modifier combinations offered when a rule should apply only while a key is held.
    static let choices: [(title: String, bits: UInt64)] = [
        ("No modifier", 0),
        ("⌘ Command", command),
        ("⌥ Option", option),
        ("⌃ Control", control),
        ("⇧ Shift", shift),
        ("⌘⇧ Command + Shift", command | shift),
        ("⌘⌥ Command + Option", command | option),
    ]

    static func title(for bits: UInt64) -> String {
        if let known = choices.first(where: { $0.bits == bits }) { return known.title }
        return glyphs(for: bits)
    }

    static func glyphs(for bits: UInt64) -> String {
        var text = ""
        if bits & control != 0 { text += "⌃" }
        if bits & option != 0 { text += "⌥" }
        if bits & shift != 0 { text += "⇧" }
        if bits & command != 0 { text += "⌘" }
        if bits & function != 0 { text += "fn" }
        return text
    }

    static func bits(from flags: NSEvent.ModifierFlags) -> UInt64 {
        var bits: UInt64 = 0
        if flags.contains(.shift) { bits |= shift }
        if flags.contains(.control) { bits |= control }
        if flags.contains(.option) { bits |= option }
        if flags.contains(.command) { bits |= command }
        if flags.contains(.function) { bits |= function }
        return bits
    }
}

/// Key names for showing a recorded shortcut. Covers the keys people bind; anything else shows as "Key 123".
enum KeyNames {
    private static let names: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q", 13: "W",
        14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9",
        26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 37: "L", 38: "J",
        39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 50: "`",
        36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Esc", 117: "Forward Delete",
        115: "Home", 119: "End", 116: "Page Up", 121: "Page Down",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9",
        109: "F10", 103: "F11", 111: "F12",
    ]

    static func name(for keyCode: UInt16) -> String {
        names[keyCode] ?? "Key \(keyCode)"
    }

    private static let aliases: [String: UInt16] = ["escape": 53, "enter": 36, "backspace": 51, "pgup": 116, "pgdn": 121, "left": 123, "right": 124, "down": 125, "up": 126]

    /// The key code for a key written as a person writes it: "k", "Space", "esc", "F5".
    static func keyCode(forName name: String) -> UInt16? {
        let n = name.lowercased()
        if let alias = aliases[n] { return alias }
        return names.first { $0.value.lowercased() == n }?.key
    }

    static func describe(keyCode: UInt16, modifiers: UInt64) -> String {
        KeyModifiers.glyphs(for: modifiers) + name(for: keyCode)
    }
}

/// Window actions that Window Management (a later phase) will provide. A button can be set to one now; it starts working
/// when that feature arrives.
enum WindowCommands {
    /// Every window command the core knows, then the pointer commands the mouse feature adds.
    static var all: [(command: String, title: String)] {
        var list = windowLayouts().map { (command: $0.command, title: $0.title) }
        list += windowExtraCommands().map { (command: $0.command, title: $0.title) }
        list += [
            (command: "mouse.next_display", title: "Move pointer to next display"),
            (command: "mouse.previous_display", title: "Move pointer to previous display"),
            (command: "menu.pointer", title: "Open the pointer menu"),
            (command: "menu.app", title: "Open the app's menu at the pointer"),
        ]
        list += WorkspaceController.commands.map { (command: $0.command, title: $0.title) }
        list += PointerEffects.commands.map { (command: $0.command, title: $0.title) }
        list.append((command: "notes.open", title: "Open Notes"))
        list.append((command: "automation.pause_toggle", title: "Pause or resume all automation"))
        list.append((command: "automation.emergency_stop", title: "Emergency stop: cancel running workflows and pause automation"))
        list.append((command: "dialog.folders", title: "Go to a folder in the Open or Save dialog"))
        list.append((command: "dictation.toggle", title: "Start or stop dictation"))
        list.append((command: "clipboard.send_other", title: "Send the clipboard to my other Macs"))
        list.append((command: "clipboard.receive_other", title: "Paste what another Mac sent"))
        list.append((command: "clipboard.paste_as_file", title: "Paste the clipboard as a file in the front folder"))
        list.append((command: "focus.session", title: "Start or end a focus session"))
        list.append((command: "color.pick", title: "Pick a colour from the screen"))
        list += AudioControl.commands.map { (command: $0.command, title: $0.title) }
        list += dynamic().map { (command: $0.command, title: $0.title) }
        return list
    }

    /// Commands that depend on what the person has set up, such as one for each workspace. Set when the app starts.
    static var dynamic: () -> [(command: String, title: String)] = { [] }

    static func title(for command: String) -> String? {
        all.first { $0.command == command }?.title
    }
}

/// A key combination written in words, such as "cmd+shift+k" or "ctrl+option+F5".
enum ShortcutText {
    static func parse(_ text: String) -> (keyCode: UInt16, modifiers: UInt64)? {
        let parts = text.lowercased().replacingOccurrences(of: " ", with: "+").split(separator: "+").map(String.init).filter { !$0.isEmpty }
        guard parts.count >= 1, parts.count <= 5 else { return nil }
        var modifiers: UInt64 = 0
        var key: UInt16?
        for part in parts {
            switch part {
            case "cmd", "command", "⌘": modifiers |= KeyModifiers.command
            case "shift", "⇧": modifiers |= KeyModifiers.shift
            case "opt", "option", "alt", "⌥": modifiers |= KeyModifiers.option
            case "ctrl", "control", "⌃": modifiers |= KeyModifiers.control
            case "fn": modifiers |= KeyModifiers.function
            default:
                guard key == nil, let code = KeyNames.keyCode(forName: part) else { return nil }
                key = code
            }
        }
        guard let key else { return nil }
        // A plain letter or digit with no command, control or option would take over ordinary typing.
        let name = KeyNames.name(for: key)
        let isFunctionKey = name.hasPrefix("F") && name.count <= 3
        guard modifiers & (KeyModifiers.command | KeyModifiers.control | KeyModifiers.option) != 0 || isFunctionKey else { return nil }
        return (key, modifiers)
    }
}

/// Clipboard items written out as Markdown, for exporting. Anything that looks like a secret is replaced first.
enum ClipboardExport {
    static func markdown(_ items: [(title: String, text: String, at: Date)], title: String = "Kriya clipboard export") -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        var out = "# \(title)\n\n"
        for item in items {
            let safe = SecretRedactor.redact(item.text).text
            out += "## \(item.title.isEmpty ? formatter.string(from: item.at) : item.title)\n\n"
            out += "~~~\n\(safe)\n~~~\n\n"
        }
        return out
    }
}
