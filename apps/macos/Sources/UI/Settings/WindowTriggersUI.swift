import AppKit
import SwiftUI

/// The window commands a trigger can run: the layouts, the extra window commands, the saved sizes and saved layouts.
private func windowCommandChoices(_ store: WindowStore) -> [(command: String, title: String)] {
    var list: [(String, String)] = windowLayouts().map { ($0.command, $0.title) }
    list += windowExtraCommands().map { ($0.command, $0.title) }
    list += WindowCommands.all.filter { $0.command.hasPrefix("window.throw") }.map { ($0.command, $0.title) }
    list += store.sizes.map { (store.sizeCommand($0), "Size: \($0.name)") }
    list += store.layouts.map { (store.layoutCommand($0), "Layout: \($0.name)") }
    var seen = Set<String>()
    return list.filter { seen.insert($0.0).inserted }.map { (command: $0.0, title: $0.1) }
}

/// Run a command by double-tapping a modifier key on its own.
struct ModifierTapSection: View {
    @ObservedObject private var triggers = WindowTriggerStore.shared
    @State private var modifier = "option"
    @State private var command = "window.list"

    var body: some View {
        Section {
            if triggers.taps.isEmpty { Text("None yet.").font(.callout).foregroundStyle(.secondary) }
            ForEach(triggers.taps) { tap in
                HStack {
                    Text("Double-tap \(ModifierTap.modifiers.first { $0.id == tap.modifier }?.title ?? tap.modifier)")
                    Spacer()
                    Text(KeyboardCommands.title(tap.command)).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    Button(role: .destructive) { triggers.removeTap(tap.id) } label: { Image(systemName: "trash") }.accessibilityLabel("Delete").buttonStyle(.borderless)
                }
            }
            HStack {
                Picker("", selection: $modifier) { ForEach(ModifierTap.modifiers, id: \.id) { Text($0.title).tag($0.id) } }.labelsHidden().fixedSize()
                Picker("", selection: $command) { ForEach(KeyboardCommands.all, id: \.command) { Text($0.title).tag($0.command) } }.labelsHidden()
                Button("Add") { triggers.addTap(ModifierTap(modifier: modifier, command: command)) }.controlSize(.small)
            }
        } header: { Text("Double-tap a modifier") } footer: {
            Text("Tap the key twice quickly, on its own: no other key, and not held. Each key can run one command. A tap that is part of a shortcut, like ⌘C, is never counted. Needs Input Monitoring.")
        }
    }
}

/// Put an app's window in place when the app opens or comes forward.
struct AppLayoutTriggerSection: View {
    @EnvironmentObject private var store: WindowStore
    @ObservedObject private var triggers = WindowTriggerStore.shared
    @State private var when: AppLayoutTrigger.When = .launch
    @State private var command = "window.left_half"

    var body: some View {
        Section {
            if triggers.layoutTriggers.isEmpty { Text("None yet.").font(.callout).foregroundStyle(.secondary) }
            ForEach(triggers.layoutTriggers) { trigger in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(AppChoice.name(for: trigger.appID))
                        Text("\(trigger.when.title): \(KeyboardCommands.title(trigger.command))").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(role: .destructive) { triggers.removeLayoutTrigger(trigger.id) } label: { Image(systemName: "trash") }.accessibilityLabel("Delete").buttonStyle(.borderless)
                }
            }
            HStack {
                Picker("When", selection: $when) { ForEach(AppLayoutTrigger.When.allCases) { Text($0.title).tag($0) } }.fixedSize()
                Picker("Do", selection: $command) {
                    ForEach(windowCommandChoices(store), id: \.command) { Text($0.title).tag($0.command) }
                }
                Button { if let id = AppChoice.choose(prompt: "Choose the app") { triggers.addLayoutTrigger(AppLayoutTrigger(appID: id, command: command, when: when)) } } label: { Label("Choose App…", systemImage: "plus") }.controlSize(.small)
            }
        } header: { Text("When an app opens or comes forward") } footer: {
            Text("Kriya waits for the app's window to appear, then runs the command on it: a half, a custom size or a saved layout. A window you have locked under Layouts is never moved.")
        }
    }
}

/// Hide the Dock while chosen apps are in front.
struct DockHideSection: View {
    @ObservedObject private var triggers = WindowTriggerStore.shared

    var body: some View {
        Section {
            if triggers.dockHideApps.isEmpty { Text("The Dock stays as it is.").font(.callout).foregroundStyle(.secondary) }
            ForEach(triggers.dockHideApps, id: \.self) { id in
                HStack {
                    Text(AppChoice.name(for: id))
                    Spacer()
                    Button(role: .destructive) { triggers.setDockHide(id, false) } label: { Image(systemName: "trash") }.accessibilityLabel("Delete").buttonStyle(.borderless)
                }
            }
            Button { if let id = AppChoice.choose(prompt: "Hide the Dock while this app is in front") { triggers.setDockHide(id, true) } } label: { Label("Add App…", systemImage: "plus") }.controlSize(.small)
        } header: { Text("Hide the Dock for some apps") } footer: {
            Text("While one of these apps is in front the Dock slides away; it comes back when you leave, or when Kriya quits. If the Dock was already set to hide, it is left alone. macOS asks once whether Kriya may control System Events.")
        }
    }
}

/// The pointer running off one edge and coming back at the other.
struct PointerWrapSection: View {
    @ObservedObject private var triggers = WindowTriggerStore.shared

    var body: some View {
        Section {
            Picker("Wrap the pointer around", selection: Binding(get: { triggers.wrapMode }, set: { triggers.wrapMode = $0 })) {
                ForEach(PointerWrapMode.allCases) { Text($0.title).tag($0) }
            }
        } header: { Text("Pointer") } footer: {
            Text("With more than one display, the pointer that runs off the far left edge of all of them comes back on the far right, and the other way round. “Move the pointer to the active window” and “to the middle of its display” are commands you can give shortcuts.")
        }
    }
}

/// How to run a window command from a script, a web link or the Shortcuts app.
struct WindowAutomationSection: View {
    @EnvironmentObject private var store: WindowStore
    @Environment(\.paths) private var paths
    @State private var command = "window.left_half"
    @State private var copied: String?

    private var token: String { BridgeToken.loadOrCreate(in: paths.support) }

    var body: some View {
        Section {
            Picker("Command", selection: $command) { ForEach(windowCommandChoices(store), id: \.command) { Text($0.title).tag($0.command) } }
            copyRow("Terminal", "kriya run \(command)")
            copyRow("Web link", "kriya://run?command=\(command)&t=\(token)")
            copyRow("AppleScript", "do shell script \"open 'kriya://run?command=\(command)&t=\(token)'\"")
            copyRow("Shell", "open 'kriya://run?command=\(command)&t=\(token)'")
        } header: { Text("Control from outside") } footer: {
            Text("Every window command can be run from the Terminal (Settings › General › Command line and Shortcuts installs “kriya”), from a link, an AppleScript or the Shortcuts app (“Run a Kriya Command”). A command for the window under the pointer instead of the one in front is the same name with “window.pointer.” in front, such as window.pointer.left_half. The link carries a secret only your account can read; keep it to yourself.")
        }
    }

    private func copyRow(_ title: String, _ text: String) -> some View {
        HStack {
            Text(title).frame(width: 88, alignment: .leading)
            Text(text).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Spacer()
            Button(copied == title ? "Copied" : "Copy") {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
                copied = title
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { if copied == title { copied = nil } }
            }.controlSize(.small)
        }
    }
}
