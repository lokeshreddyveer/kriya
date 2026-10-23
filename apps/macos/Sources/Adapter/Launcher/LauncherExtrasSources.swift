import AppKit
import ApplicationServices
import Contacts

// MARK: - Menu items of the front app

/// One item of an app's menu bar, found through Accessibility.
struct MenuItemRef {
    let path: String
    let shortcut: String?
    let element: AXUIElement
}

enum AppMenuItems {
    static let maxItems = 700
    static let maxDepth = 5

    /// Every enabled item in the app's menu bar, with its path ("Edit › Copy"). Slow for big menus, so it runs off the main thread.
    static func collect(pid: pid_t) -> [MenuItemRef] {
        guard AXIsProcessTrusted() else { return [] }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.4)
        var bar: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &bar) == .success, let raw = bar, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return [] }
        var found: [MenuItemRef] = []
        walk(unsafeBitCast(raw, to: AXUIElement.self), path: [], depth: 0, into: &found)
        return found
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var out: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &out) == .success ? out : nil
    }

    private static func walk(_ element: AXUIElement, path: [String], depth: Int, into found: inout [MenuItemRef]) {
        guard depth <= maxDepth, found.count < maxItems, let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] else { return }
        for child in children {
            if found.count >= maxItems { return }
            let title = (attribute(child, kAXTitleAttribute) as? String) ?? ""
            let role = (attribute(child, kAXRoleAttribute) as? String) ?? ""
            let nested = (attribute(child, kAXChildrenAttribute) as? [AXUIElement]) ?? []
            if role == kAXMenuBarItemRole as String || role == kAXMenuItemRole as String {
                let enabled = (attribute(child, kAXEnabledAttribute) as? Bool) ?? true
                // The Apple menu and separators have no use here.
                if title.isEmpty || title == "Apple" { continue }
                let here = path + [title]
                let hasSubmenu = nested.contains { (attribute($0, kAXRoleAttribute) as? String) == kAXMenuRole as String }
                if !hasSubmenu, enabled { found.append(MenuItemRef(path: here.joined(separator: " › "), shortcut: shortcut(of: child), element: child)) }
                walk(child, path: here, depth: depth + 1, into: &found)
            } else {
                walk(child, path: path, depth: depth + 1, into: &found)
            }
        }
    }

    private static func shortcut(of item: AXUIElement) -> String? {
        guard let char = attribute(item, kAXMenuItemCmdCharAttribute) as? String, !char.isEmpty else { return nil }
        let mods = (attribute(item, kAXMenuItemCmdModifiersAttribute) as? Int) ?? 0
        // Bit 0 shift, 1 option, 2 control, 3 (set means NO command).
        var text = ""
        if mods & 4 != 0 { text += "⌃" }
        if mods & 2 != 0 { text += "⌥" }
        if mods & 1 != 0 { text += "⇧" }
        if mods & 8 == 0 { text += "⌘" }
        return text + char.uppercased()
    }

    static func press(_ ref: MenuItemRef) { AXUIElementPerformAction(ref.element, kAXPressAction as CFString) }
}

/// What the launcher's menu search needs from the front app: its items, gathered when the launcher opens.
final class FrontAppMenu {
    private let lock = NSLock()
    private var items: [MenuItemRef] = []
    private var appName = ""

    func refresh(app: NSRunningApplication?) {
        guard let app, app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        let pid = app.processIdentifier
        let name = app.localizedName ?? "the front app"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let found = AppMenuItems.collect(pid: pid)
            self?.lock.lock()
            self?.items = found
            self?.appName = name
            self?.lock.unlock()
        }
    }

    func snapshot() -> (name: String, items: [MenuItemRef]) {
        lock.lock()
        defer { lock.unlock() }
        return (appName, items)
    }
}

// MARK: - Contacts

struct FoundContact: Equatable {
    let id: String
    let name: String
    let emails: [String]
    let phones: [String]
}

/// People from the Contacts app, read with permission. Off until turned on in Launcher settings.
final class ContactsSource {
    private let store = CNContactStore()

    var isAllowed: Bool { CNContactStore.authorizationStatus(for: .contacts) == .authorized }

    func requestAccess(_ done: @escaping (Bool) -> Void) {
        store.requestAccess(for: .contacts) { granted, _ in DispatchQueue.main.async { done(granted) } }
    }

    func search(_ text: String, limit: Int = 5) -> [FoundContact] {
        guard isAllowed, text.count >= 2, text.count <= 40 else { return [] }
        let keys: [CNKeyDescriptor] = [CNContactFormatter.descriptorForRequiredKeys(for: .fullName), CNContactEmailAddressesKey as CNKeyDescriptor, CNContactPhoneNumbersKey as CNKeyDescriptor]
        let contacts = (try? store.unifiedContacts(matching: CNContact.predicateForContacts(matchingName: text), keysToFetch: keys)) ?? []
        return contacts.prefix(limit).map { contact in
            FoundContact(
                id: contact.identifier, name: CNContactFormatter.string(from: contact, style: .fullName) ?? "Contact",
                emails: contact.emailAddresses.map { $0.value as String }, phones: contact.phoneNumbers.map { $0.value.stringValue }
            )
        }
    }
}

// MARK: - Quit, system commands

enum LauncherSystemCommands {
    /// "quit saf" or "force quit saf" → the words after the verb, and whether it is a force quit.
    static func quitRequest(in text: String) -> (name: String, force: Bool)? {
        let lower = text.trimmingCharacters(in: .whitespaces).lowercased()
        for (prefix, force) in [("force quit ", true), ("force-quit ", true), ("kill ", true), ("quit ", false)] where lower.hasPrefix(prefix) {
            let rest = String(lower.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            return rest.isEmpty ? nil : (rest, force)
        }
        return nil
    }

    /// Runs a line of AppleScript. The Mac asks once whether Kriya may control the app the script names.
    static func appleScript(_ source: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", source]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
        }
    }

    /// Asks before something that closes everything or deletes: the launcher is gone by then, so the question is an alert.
    static func confirm(_ question: String, detail: String, button: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = question
        alert.informativeText = detail
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }
}
