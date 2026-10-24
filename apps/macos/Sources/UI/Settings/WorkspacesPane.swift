import AppKit
import SwiftUI

/// Workspaces (sets of apps that open together), focus mode, "quit all", favourite windows and how to run them.
struct WorkspacesPane: View {
    @EnvironmentObject private var store: WorkspaceStore
    @EnvironmentObject private var windows: WindowStore
    @State private var editing: Workspace?
    @State private var transferNote: String?
    @ObservedObject private var launchLog = WorkspaceLaunchLogStore.shared

    var body: some View {
        Form {
            Section {
                if store.config.workspaces.isEmpty {
                    Text("No workspaces yet. A workspace opens a set of apps and addresses together, can hide everything else, and can arrange the windows in a saved layout.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(store.config.workspaces) { workspace in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(workspace.name)
                            Text(summary(workspace)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            Text("Now: " + WorkspaceLaunchPlan.make(appIDs: workspace.appIds, running: Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)), installed: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }).sentence(name: AppChoice.name(for:)))
                                .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                        }
                        Spacer()
                        Button("Edit") { editing = workspace }.controlSize(.small)
                        Button { store.delete(workspace.id) } label: { Image(systemName: "trash") }.accessibilityLabel("Delete").buttonStyle(.borderless)
                    }
                }
                .onMove { store.move(from: $0, to: $1) }
            } header: {
                HStack {
                    Text("Workspaces")
                    Spacer()
                    Button {
                        // The apps open right now become a new workspace, ready to name.
                        var workspace = store.newWorkspace()
                        workspace.name = "Open apps"
                        workspace.appIds = Array(NSWorkspace.shared.runningApplications
                            .filter { $0.activationPolicy == .regular && !$0.isHidden && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
                            .compactMap(\.bundleIdentifier).prefix(30))
                        editing = workspace
                    } label: { Label("Save Open Apps", systemImage: "square.and.arrow.down") }.controlSize(.small)
                    Menu {
                        Button("Import Workspaces…") { importWorkspaces() }
                        Button("Export Workspaces…") { exportWorkspaces() }.disabled(store.config.workspaces.isEmpty)
                    } label: { MoreMenuLabel() }.menuStyle(.button).menuIndicator(.hidden).fixedSize()
                    Button { editing = store.newWorkspace() } label: { Label("Add Workspace", systemImage: "plus") }.controlSize(.small)
                }
                if let transferNote { Text(transferNote).font(.callout).foregroundStyle(.secondary) }
            } footer: {
                Text("Each workspace is a command. Give it a shortcut under Keyboard, a button or gesture under Mouse, or a hot corner under Automation: choose a built-in command named “Workspace: …”.")
            }

            Section {
                let entries = launchLog.log.entries
                if entries.isEmpty { Text("Nothing opened yet.").font(.callout).foregroundStyle(.secondary) }
                ForEach(entries.prefix(6)) { entry in
                    VStack(alignment: .leading, spacing: 1) {
                        HStack {
                            Text(entry.workspaceName)
                            Spacer()
                            Text(entry.at.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(logLine(entry)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Button("Clear Log") { launchLog.clear() }.controlSize(.small).disabled(entries.isEmpty)
                }
            } header: { Text("Launch log") } footer: {
                Text("Only apps a workspace opened itself are quit when you undo it, and only apps it hid are shown again. Give “Undo the last workspace” a shortcut under Keyboard.")
            }

            Section {
                AppList(title: "Apps that stay visible", ids: Binding(get: { store.config.focusAppIds }, set: { v in store.update { $0.focusAppIds = v } }))
            } header: { Text("Focus mode") } footer: {
                Text("Turn it on with the command “Turn focus mode on or off”. Every other app is hidden, and stays hidden: one that comes to the front is hidden again. Turn it off the same way.")
            }

            Section {
                Toggle("Ask before quitting", isOn: Binding(get: { store.config.confirmQuitAll }, set: { v in store.update { $0.confirmQuitAll = v } }))
                AppList(title: "Apps to leave running", ids: Binding(get: { store.config.quitKeepAppIds }, set: { v in store.update { $0.quitKeepAppIds = v } }))
            } header: { Text("Quit all apps") } footer: {
                Text("The command “Quit all apps” closes every app except the Finder, Kriya and the ones listed here. Each app still asks about unsaved work.")
            }

            Section {
                if store.config.favorites.isEmpty {
                    Text("None yet. Bring a window to the front and run “Make this window favorite 1” (up to 5). “Go to favorite window 1” brings it back, opening the app if it has to.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(store.config.favorites, id: \.slot) { favorite in
                    HStack {
                        Text("\(favorite.slot)").font(.headline).frame(width: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(favorite.title.isEmpty ? AppChoice.name(for: favorite.appId) : favorite.title).lineLimit(1)
                            Text(AppChoice.name(for: favorite.appId)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { store.update { $0.favorites.removeAll { $0.slot == favorite.slot } } } label: { Image(systemName: "minus.circle") }.accessibilityLabel("Remove").buttonStyle(.borderless)
                    }
                }
            } header: { Text("Favorite windows") }

            Section {
                Text("Also here as commands: switch to the previous app, hide all apps, hide other apps, relaunch the front app, cycle the windows under the pointer, focus a window on the next display, and bring back a minimized window. Add them under Actions › Add Common Actions, then give them a shortcut.")
                    .font(.callout).foregroundStyle(.secondary)
            } header: { Text("More commands") }

            if let error = store.lastError {
                Section { Text(error).font(.callout).foregroundStyle(Theme.danger) }
            }
        }
        .formStyle(.grouped)
        .animation(.smooth(duration: 0.25), value: store.config.workspaces)
        .sheet(item: $editing) { workspace in
            WorkspaceEditor(workspace: workspace, onSave: { store.upsert($0); editing = nil }, onCancel: { editing = nil })
        }
    }

    private func importWorkspaces() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let report = try store.importWorkspaces(from: url)
            let skipped = report.skipped.isEmpty ? "" : " Left out: " + report.skipped.joined(separator: "; ") + "."
            transferNote = "Added \(report.added.count) workspace\(report.added.count == 1 ? "" : "s") and \(report.layoutsAdded) layout\(report.layoutsAdded == 1 ? "" : "s")." + skipped
        } catch { transferNote = error.userMessage }
    }

    private func exportWorkspaces() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Kriya workspaces.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try store.exportWorkspaces(to: url); transferNote = "Saved \(url.lastPathComponent)." } catch { transferNote = error.userMessage }
    }

    private func logLine(_ entry: WorkspaceLaunchLog.Entry) -> String {
        var parts: [String] = []
        if !entry.opened.isEmpty { parts.append("opened " + entry.opened.map(AppChoice.name(for:)).joined(separator: ", ")) }
        if !entry.alreadyRunning.isEmpty { parts.append("\(entry.alreadyRunning.count) already open") }
        if !entry.notInstalled.isEmpty { parts.append("\(entry.notInstalled.count) not installed") }
        if !entry.hidden.isEmpty { parts.append("hid \(entry.hidden.count)") }
        if entry.urlsOpened > 0 { parts.append("\(entry.urlsOpened) address\(entry.urlsOpened == 1 ? "" : "es")") }
        if entry.undone { parts.append("undone") }
        return parts.isEmpty ? "nothing to do" : parts.joined(separator: " · ")
    }

    private func summary(_ workspace: Workspace) -> String {
        var parts: [String] = []
        if !workspace.appIds.isEmpty { parts.append(workspace.appIds.map(AppChoice.name(for:)).joined(separator: ", ")) }
        if !workspace.urls.isEmpty { parts.append("\(workspace.urls.count) address\(workspace.urls.count == 1 ? "" : "es")") }
        if workspace.hideOthers { parts.append("hides the rest") }
        if workspace.layoutId != nil { parts.append("arranges windows") }
        return parts.joined(separator: " · ")
    }
}

/// A list of apps with add and remove, kept as bundle ids.
private struct AppList: View {
    let title: String
    @Binding var ids: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.callout).foregroundStyle(.secondary)
            if ids.isEmpty { Text("None").font(.caption).foregroundStyle(.tertiary) }
            ForEach(ids, id: \.self) { id in
                HStack {
                    Text(AppChoice.name(for: id))
                    Spacer()
                    Button { ids.removeAll { $0 == id } } label: { Image(systemName: "minus.circle") }.accessibilityLabel("Remove").buttonStyle(.borderless)
                }
            }
            Button("Add App…") {
                if let id = AppChoice.choose(prompt: "Add"), !ids.contains(id) { ids.append(id) }
            }
            .controlSize(.small)
        }
    }
}

private struct WorkspaceEditor: View {
    @State var workspace: Workspace
    let onSave: (Workspace) -> Void
    let onCancel: () -> Void

    @EnvironmentObject private var windows: WindowStore
    @EnvironmentObject private var sound: SoundRuleRunner
    @State private var addresses: String

    init(workspace: Workspace, onSave: @escaping (Workspace) -> Void, onCancel: @escaping () -> Void) {
        _workspace = State(initialValue: workspace)
        _addresses = State(initialValue: workspace.urls.joined(separator: "\n"))
        self.onSave = onSave
        self.onCancel = onCancel
    }

    private var problem: String? {
        if workspace.name.trimmingCharacters(in: .whitespaces).isEmpty { return "Give the workspace a name." }
        if workspace.appIds.isEmpty && addresses.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Add an app or an address." }
        let rejected = WorkspaceAddress.parse(addresses).rejected
        if !rejected.isEmpty { return "These are not web addresses: \(rejected.prefix(2).joined(separator: ", "))\(rejected.count > 2 ? "…" : ""). Only http and https pages open." }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $workspace.name)
                    Picker("Sound mode", selection: Binding(get: { workspace.soundModeId ?? "" }, set: { workspace.soundModeId = $0.isEmpty ? nil : $0 })) {
                        Text("Leave the sound alone").tag("")
                        ForEach(sound.modes) { Text($0.name).tag($0.id) }
                        if let id = workspace.soundModeId, !sound.modes.contains(where: { $0.id == id }) { Text("A mode that is not on this Mac").tag(id) }
                    }
                }
                Section("Apps to open") {
                    AppList(title: "", ids: $workspace.appIds)
                }
                Section {
                    TextEditor(text: $addresses).font(.system(.body, design: .monospaced)).frame(height: 70)
                } header: { Text("Addresses to open") } footer: {
                    Text("One web address per line. Only web pages (http or https) open; an address without a scheme gets https.")
                }
                Section {
                    Toggle("Hide every other app", isOn: $workspace.hideOthers)
                    Picker("Arrange windows", selection: Binding(get: { workspace.layoutId ?? "" }, set: { workspace.layoutId = $0.isEmpty ? nil : $0 })) {
                        Text("Leave them where they are").tag("")
                        ForEach(windows.layouts.filter { !$0.isAuto && !$0.isGroup }) { Text($0.name).tag($0.id) }
                    }
                } footer: {
                    Text("Layouts are saved under Windows › Layouts. The windows are arranged a moment after the apps have opened.")
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                if let problem { Text(problem).font(.callout).foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Save") {
                    var saved = workspace
                    saved.urls = WorkspaceAddress.parse(addresses).valid
                    onSave(saved)
                }
                .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(problem != nil)
            }
            .padding(14)
        }
        .frame(width: 480, height: 620)
    }
}
