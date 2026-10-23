import AppKit
import ApplicationServices
import SwiftUI

/// While an Open or Save dialog is up, shows the folders you use, and jumps the dialog to the one you click (it types the path into
/// the dialog's own "Go to the folder" sheet). It is shown only when you ask for it.
final class DialogFolderHelper {
    private let destinations: FolderDestinations
    private let toast = Toast()
    private var panel: NSPanel?
    /// Types text into the app in front. Set by the app.
    var type: (String) -> Void = { _ in }

    init(destinations: FolderDestinations) { self.destinations = destinations }

    func toggle() { panel?.isVisible == true ? close() : show() }

    func show() {
        guard AXIsProcessTrusted() else { toast.show("Allow Accessibility for Kriya so it can move the dialog to a folder.", isError: true); return }
        guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        let window = AXWindow.focused()
        var role: CFTypeRef?, subrole: CFTypeRef?, title: CFTypeRef?
        if let w = window {
            AXUIElementCopyAttributeValue(w.element, kAXRoleAttribute as CFString, &role)
            AXUIElementCopyAttributeValue(w.element, kAXSubroleAttribute as CFString, &subrole)
            AXUIElementCopyAttributeValue(w.element, kAXTitleAttribute as CFString, &title)
        }
        guard DialogFolders.looksLikeDialog(role: role as? String, subrole: subrole as? String, title: title as? String) || hasSheet(app) else {
            toast.show("There is no Open or Save dialog in front.", isError: true)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let (current, others) = Self.finderFolders()
            DispatchQueue.main.async {
                let choices = DialogFolders.choices(finder: current, windows: others, favorites: self.destinations.favorites, recents: self.destinations.recents)
                self.present(choices, for: app)
            }
        }
    }

    private func hasSheet(_ app: NSRunningApplication) -> Bool {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.3)
        var windows: CFTypeRef?
        guard AXUIElementCopyAttributeValue(root, kAXWindowsAttribute as CFString, &windows) == .success, let list = windows as? [AXUIElement] else { return false }
        for w in list {
            var kids: CFTypeRef?
            if AXUIElementCopyAttributeValue(w, kAXChildrenAttribute as CFString, &kids) == .success, let children = kids as? [AXUIElement] {
                for c in children { var r: CFTypeRef?; if AXUIElementCopyAttributeValue(c, kAXRoleAttribute as CFString, &r) == .success, (r as? String) == "AXSheet" { return true } }
            }
        }
        return false
    }

    private func present(_ choices: [DialogFolders.Choice], for app: NSRunningApplication) {
        close()
        guard !choices.isEmpty else { toast.show("No folders to offer yet. Move or copy something, or star a folder, and they will appear here."); return }
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 330, height: min(CGFloat(choices.count) * 40 + 64, 460)), styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        p.isOpaque = false; p.backgroundColor = .clear; p.level = .floating; p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = NSHostingView(rootView: DialogFolderView(choices: choices, onPick: { [weak self] choice in self?.go(to: choice, in: app) }, onClose: { [weak self] in self?.close() }))
        let mouse = NSEvent.mouseLocation
        p.setFrameOrigin(NSPoint(x: mouse.x + 20, y: max(mouse.y - p.frame.height - 20, 40)))
        p.orderFrontRegardless()
        panel = p
    }

    func close() { panel?.orderOut(nil); panel = nil }

    /// ⌘⇧G opens the dialog's "Go to the folder" sheet; the path is typed in and Return goes there.
    private func go(to choice: DialogFolders.Choice, in app: NSRunningApplication) {
        close()
        destinations.used(choice.path)
        app.activate()
        DispatchQueue.global(qos: .userInitiated).async { [type] in
            usleep(180_000)
            Self.key(5, flags: [.maskCommand, .maskShift])   // G
            usleep(350_000)
            type(choice.path)
            usleep(250_000)
            Self.key(36, flags: [])                           // Return
        }
    }

    private static func key(_ code: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { continue }
            e.flags = flags
            e.setIntegerValueField(.eventSourceUserData, value: EventMonitor.syntheticMarker)
            e.post(tap: .cghidEventTap)
        }
    }

    /// The folder of Finder's front window, and the folders of its other windows.
    private static func finderFolders() -> (String?, [String]) {
        let source = """
        tell application "Finder"
            set out to {}
            repeat with w in (every Finder window)
                try
                    set end of out to POSIX path of (target of w as alias)
                end try
            end repeat
            return out
        end tell
        """
        guard NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == "com.apple.finder" }),
              let script = NSAppleScript(source: source) else { return (nil, []) }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        guard error == nil else { return (nil, []) }
        var paths: [String] = []
        if result.numberOfItems > 0 { for i in 1...result.numberOfItems { if let p = result.atIndex(i)?.stringValue { paths.append(p) } } }
        return (paths.first, Array(paths.dropFirst()))
    }
}

private struct DialogFolderView: View {
    let choices: [DialogFolders.Choice]
    let onPick: (DialogFolders.Choice) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Go to a folder").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }.buttonStyle(.plain)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(choices) { choice in
                        Button { onPick(choice) } label: {
                            HStack(spacing: 10) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: choice.path)).resizable().frame(width: 24, height: 24)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(choice.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                    Text(choice.shortPath).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                }
                                Spacer()
                                Text(choice.kindTitle).font(.system(size: 10)).foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 5).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }.padding(.horizontal, 6).padding(.bottom, 8)
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.75))
    }
}
