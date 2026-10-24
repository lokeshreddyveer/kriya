import AppKit
import SwiftUI

struct FinderPane: View {
    @EnvironmentObject private var finder: FinderService
    @EnvironmentObject private var store: FinderStore
    @EnvironmentObject private var config: ConfigStore
    @EnvironmentObject private var services: ServiceManager

    @State private var tab: Tab = .actions
    @State private var confirmReset = false
    @State private var confirmDefaults = false

    enum Tab: String, CaseIterable, Identifiable {
        case actions = "Actions", templates = "Templates", menus = "Menus", apps = "Apps", pointer = "Pointer Menu", setup = "Setup"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            if !config.isEnabled(.contextMenu) || services.state(.contextMenu) != .running {
                Banner(
                    symbol: "contextualmenu.and.cursorarrow", tint: Theme.warn,
                    title: "Right-click menu is \(config.isEnabled(.contextMenu) ? services.state(.contextMenu).label.lowercased() : "off")",
                    message: "Your actions are saved, but Finder shows nothing until the feature is on."
                ) {
                    if !config.isEnabled(.contextMenu) { Button("Turn On") { services.setFeature(.contextMenu, enabled: true) }.controlSize(.small) }
                    else if case .needsPermission(let missing) = services.state(.contextMenu) { AllowPermissionButtons(missing: missing) }
                }
                .padding(.horizontal, 20).padding(.top, 10).transition(.opacity)
            }
            HStack {
                Picker("Section", selection: $tab) { ForEach(Tab.allCases) { Text($0.rawValue).tag($0) } }
                    .paneTabBar(maxWidth: 580)
                Menu {
                    Button("Add Common Actions (editor, hidden files, parent folder)") { store.addSuggested() }
                    Divider()
                    Button("Restore Default Actions and Settings…") { confirmDefaults = true }
                    Button("Restore Everything, Including Templates…") { confirmReset = true }
                } label: { MoreMenuLabel() }.menuStyle(.button).menuIndicator(.hidden).fixedSize()
            }
            .paneHeader()

            Group {
                switch tab {
                case .actions: ActionsTab(history: finder.runner.history, runner: finder.runner)
                case .templates: TemplatesTab()
                case .menus: FinderMenusTab()
                case .apps: AppsSettingsTab()
                case .pointer: PointerMenuTab()
                case .setup: SetupTab()
                }
            }
            .id(tab)
            .transition(.opacity)
        }
        .animation(.smooth(duration: 0.22), value: tab)
        .tabHint($tab)
        .animation(.smooth(duration: 0.25), value: services.state(.contextMenu))
        .overlay(alignment: .bottom) {
            if let error = store.lastError {
                Text(error).font(.callout).padding(10).background(Theme.danger.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                    .padding().transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .confirmationDialog("Restore the default actions and settings?", isPresented: $confirmDefaults, titleVisibility: .visible) {
            Button("Restore Defaults", role: .destructive) { store.restoreDefaults(everything: false) }
            Button("Cancel", role: .cancel) {}
        } message: { Text("The Finder actions and menu options go back to how they started. Your templates stay.") }
        .confirmationDialog("Restore everything?", isPresented: $confirmReset) {
            Button("Restore Everything", role: .destructive) { store.restoreDefaults(everything: true) }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Your custom actions and templates are removed and the shipped ones come back.") }
    }
}

// MARK: - Actions

private struct ActionsTab: View {
    @EnvironmentObject private var store: FinderStore
    @ObservedObject var history: FileOperationHistory
    let runner: FileActionRunner
    @State private var editing: FinderItem?
    @State private var deleting: FinderItem?

    var body: some View {
        List {
            // With something to undo, the history comes first, where it is seen; empty, it waits below the actions.
            if !history.operations.isEmpty {
                RecentOperationsSection(history: history, runner: runner)
            }
            Section {
                ForEach(store.items) { item in
                    HStack(spacing: 12) {
                        Toggle(item.title, isOn: Binding(get: { item.enabled }, set: { store.setEnabled(item.id, $0) }))
                            .labelsHidden().toggleStyle(.switch).controlSize(.small)
                        Image(systemName: item.kind.symbol).frame(width: 22).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).font(.headline)
                            Text("\(item.kind.summary) · \(item.applies.title)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Button("Edit") { editing = item }.controlSize(.small)
                        Button(role: .destructive) { deleting = item } label: { Image(systemName: "trash") }.accessibilityLabel("Delete the action \(item.title)").buttonStyle(.borderless)
                    }
                    .padding(.vertical, 3)
                }
                .onMove { store.move(from: $0, to: $1) }
            } header: {
                HStack {
                    Text("Order in the menu")
                    Spacer()
                    Menu {
                        ForEach(NewKind.allCases) { kind in Button(kind.rawValue) { editing = kind.blank() } }
                    } label: { Label("Add Action", systemImage: "plus") }.menuStyle(.button).menuIndicator(.hidden).fixedSize()
                }
            } footer: {
                Text("Drag to reorder. The menu in Finder follows this order. Actions that change files ask first; nothing is ever overwritten.")
            }
            if history.operations.isEmpty {
                RecentOperationsSection(history: history, runner: runner)
            }
        }
        .animation(.smooth(duration: 0.25), value: store.items)
        .confirmationDialog("Delete “\(deleting?.title ?? "")”?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) { if let i = deleting { withAnimation(.smooth) { store.delete(i.id) } }; deleting = nil }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: { Text("It disappears from the right-click menu.") }
        .sheet(item: $editing) { ItemEditor(item: $0) }
    }
}

/// What the file actions did lately, each with Undo, a way to see the items and the reason for anything that failed.
private struct RecentOperationsSection: View {
    @ObservedObject var history: FileOperationHistory
    let runner: FileActionRunner
    @State private var open: UUID?

    var body: some View {
        Group {
            FileJobsSection()
            operations
        }
    }

    private var operations: some View {
        Section {
            if history.operations.isEmpty {
                Text("Nothing yet. Moves, copies, renames, archives and new files you make from the menu show up here.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(history.operations) { operation in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        Image(systemName: symbol(operation)).frame(width: 22).foregroundStyle(tint(operation))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(operation.title).font(.headline).lineLimit(2)
                            Text(subtitle(operation)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if operation.canUndo { Button("Undo") { runner.undo(operation.id) }.controlSize(.small) }
                        if !operation.affectedPaths.isEmpty && operation.undoState != .undone {
                            Button("Show") { runner.reveal(operation.id) }.controlSize(.small)
                        }
                        if !operation.failures.isEmpty || operation.undoNote != nil {
                            Button { toggle(operation.id) } label: {
                                Image(systemName: "chevron.right").rotationEffect(.degrees(open == operation.id ? 90 : 0))
                            }.buttonStyle(.borderless).help("Details")
                        }
                        Button { withAnimation(.smooth) { history.remove(operation.id) } } label: { Image(systemName: "xmark") }.accessibilityLabel("Remove this from the list")
                            .buttonStyle(.borderless).foregroundStyle(.tertiary).help("Remove from this list")
                    }
                    if open == operation.id {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(Array(operation.failures.enumerated()), id: \.offset) { _, line in
                                Label(line, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Theme.warn)
                            }
                            if let note = operation.undoNote {
                                Text(note).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .textSelection(.enabled)
                        .padding(.leading, 32).transition(.opacity)
                    }
                }
                .padding(.vertical, 3)
            }
        } header: {
            HStack {
                Text("Recent file operations")
                Spacer()
                if !history.operations.isEmpty { Button("Clear") { withAnimation(.smooth) { history.clear() } }.controlSize(.small) }
            }
        } footer: {
            Text("Undo puts moved and renamed items back where they were, and moves things an action made to the Trash. It never overwrites: an item goes back only if its old place is free. Kept for two weeks.")
        }
        .animation(.smooth(duration: 0.22), value: history.operations)
        .animation(.smooth(duration: 0.22), value: open)
    }

    private func toggle(_ id: UUID) { open = open == id ? nil : id }

    private func symbol(_ operation: FileOperation) -> String {
        if operation.undoState == .undone { return "arrow.uturn.backward.circle" }
        return operation.failures.isEmpty ? "checkmark.circle" : "exclamationmark.triangle"
    }

    private func tint(_ operation: FileOperation) -> Color {
        if operation.undoState == .undone { return .secondary }
        return operation.failures.isEmpty ? Theme.accent : Theme.warn
    }

    private func subtitle(_ operation: FileOperation) -> String {
        var parts = [operation.date.formatted(.relative(presentation: .named))]
        switch operation.undoState {
        case .undone: parts.append("undone")
        case .partly: parts.append("partly undone")
        case .available: break
        }
        if !operation.failures.isEmpty { parts.append("\(operation.failures.count) failed") }
        return parts.joined(separator: " · ")
    }
}

enum NewKind: String, CaseIterable, Identifiable {
    case script = "Run a shell script", appleScript = "Run an AppleScript", shortcut = "Run a Shortcut", openWith = "Open with an app"
    case terminal = "Open in a terminal app", newFile = "Create a file", newFolder = "Create a folder", moveTo = "Move to a folder", copyTo = "Copy to a folder"
    case workflow = "Run a workflow"
    var id: String { rawValue }

    func blank() -> FinderItem {
        let kind: FinderActionKind
        switch self {
        case .script: kind = .runScript(language: .shell, source: "echo \"$@\"")
        case .appleScript: kind = .runScript(language: .appleScript, source: "tell application \"Finder\" to activate")
        case .shortcut: kind = .runShortcut(name: "")
        case .openWith: kind = .openWith(appId: "com.apple.TextEdit")
        case .terminal: kind = .openInTerminal(appId: Terminals.installed.first?.id)
        case .newFile: kind = .newFile(name: "untitled.txt")
        case .newFolder: kind = .newFolder(name: "untitled folder")
        case .moveTo: kind = .moveTo(folder: nil)
        case .copyTo: kind = .copyTo(folder: nil)
        case .workflow: kind = .runWorkflow(workflowId: "")
        }
        let applies: Applies = (self == .newFile || self == .newFolder) ? .folderBackground : .anything
        return FinderItem(id: UUID().uuidString, title: rawValue, kind: kind, enabled: true, applies: applies, extensions: [], appIds: [], confirm: nil)
    }
}

private struct ItemEditor: View {
    @State var item: FinderItem
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: FinderStore
    @EnvironmentObject private var workflows: WorkflowStore

    @State private var text = ""          // script source, shortcut name, file or folder name, folder path
    @State private var appID = ""
    @State private var scriptIsShell = true
    @State private var extensionsText = ""
    @State private var confirmChoice = 0  // 0 default, 1 always, 2 never

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Action").font(.title3.bold())
            Form {
                TextField("Name in the menu", text: $item.title)
                Picker("Offer it for", selection: $item.applies) { ForEach(Applies.all, id: \.self) { Text($0.title).tag($0) } }
                TextField("Only these file types", text: $extensionsText, prompt: Text("any, or for example: png, jpg"))
                kindFields
                Picker("Ask before running", selection: $confirmChoice) {
                    Text("Follow the general setting").tag(0); Text("Always ask").tag(1); Text("Never ask").tag(2)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                if let problem { Text(problem).font(.callout).foregroundStyle(.secondary) }
                Button("Save") { save() }.keyboardShortcut(.defaultAction).disabled(problem != nil)
            }
        }
        .padding(20).frame(width: 560)
        .onAppear(perform: load)
    }

    /// What is missing before this action can be saved, said in a sentence.
    private var problem: String? {
        if item.title.trimmingCharacters(in: .whitespaces).isEmpty { return "Give it a name for the menu." }
        let blank = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        switch item.kind {
        case .runScript where blank: return "Write the script."
        case .runShortcut where blank: return "Name the Shortcut."
        case .runWorkflow where blank: return "Choose a workflow."
        case .newFile where blank: return "Name the new file."
        case .newFolder where blank: return "Name the new folder."
        default: return nil
        }
    }

    @ViewBuilder
    private var kindFields: some View {
        switch item.kind {
        case .runScript:
            Picker("Language", selection: $scriptIsShell) { Text("Shell (zsh)").tag(true); Text("AppleScript").tag(false) }
            TextEditor(text: $text).font(.system(.body, design: .monospaced)).frame(height: 120)
            Text(scriptIsShell ? "The selected files arrive as \"$@\"." : "The selected files arrive in argv.").font(.caption).foregroundStyle(.secondary)
        case .runShortcut:
            TextField("Shortcut name", text: $text)
            Text("The selected files are given to the Shortcut as its input.").font(.caption).foregroundStyle(.secondary)
        case .openWith:
            HStack { TextField("App", text: $appID, prompt: Text("com.apple.TextEdit")); Button("Choose…") { if let id = AppChoice.choose() { appID = id } } }
        case .openInTerminal:
            Picker("Terminal", selection: $appID) { ForEach(Terminals.installed, id: \.id) { Text($0.name).tag($0.id) } }
        case .runWorkflow:
            Picker("Workflow", selection: $text) { Text("Choose…").tag(""); ForEach(workflows.workflows) { Text($0.name).tag($0.id) } }
            Text("The selected files' paths are the workflow's input, one per line.").font(.caption).foregroundStyle(.secondary)
        case .newFile: TextField("File name", text: $text)
        case .newFolder: TextField("Folder name", text: $text)
        case .moveTo, .copyTo:
            HStack {
                TextField("Folder", text: $text, prompt: Text("Ask each time"))
                Button("Choose…") { chooseFolder() }
            }
        default:
            Text(item.kind.summary).font(.callout).foregroundStyle(.secondary)
        }
    }

    private func load() {
        extensionsText = item.extensions.joined(separator: ", ")
        confirmChoice = item.confirm == nil ? 0 : (item.confirm == true ? 1 : 2)
        switch item.kind {
        case .runScript(let language, let source): text = source; scriptIsShell = language == .shell
        case .runShortcut(let name): text = name
        case .runWorkflow(let id): text = id
        case .openWith(let id): appID = id ?? ""
        case .openInTerminal(let id): appID = id ?? Terminals.installed.first?.id ?? ""
        case .newFile(let name), .newFolder(let name): text = name
        case .moveTo(let folder), .copyTo(let folder): text = folder ?? ""
        default: break
        }
    }

    private func save() {
        switch item.kind {
        case .runScript: item.kind = .runScript(language: scriptIsShell ? .shell : .appleScript, source: text)
        case .runShortcut: item.kind = .runShortcut(name: text)
        case .runWorkflow: item.kind = .runWorkflow(workflowId: text)
        case .openWith: item.kind = .openWith(appId: appID.isEmpty ? nil : appID)
        case .openInTerminal: item.kind = .openInTerminal(appId: appID.isEmpty ? nil : appID)
        case .newFile: item.kind = .newFile(name: text)
        case .newFolder: item.kind = .newFolder(name: text)
        case .moveTo: item.kind = .moveTo(folder: text.isEmpty ? nil : text)
        case .copyTo: item.kind = .copyTo(folder: text.isEmpty ? nil : text)
        default: break
        }
        item.extensions = extensionsText.split(whereSeparator: { ",; ".contains($0) }).map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". ")) }.filter { !$0.isEmpty }
        item.confirm = confirmChoice == 0 ? nil : confirmChoice == 1
        store.upsert(item)
        if store.lastError == nil { dismiss() }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { text = url.path }
    }
}

// MARK: - Templates

private struct TemplatesTab: View {
    @EnvironmentObject private var store: FinderStore
    @State private var editingFile: FileTemplate?
    @State private var editingFolder: FolderTemplate?

    var body: some View {
        Form {
            Section {
                ForEach(store.fileTemplates) { t in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) { Text(t.name).font(.headline); Text(t.fileName).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Button("Edit") { editingFile = t }.controlSize(.small)
                        Button(role: .destructive) { store.deleteTemplate(t.id) } label: { Image(systemName: "trash") }.accessibilityLabel("Delete the template \(t.name)").buttonStyle(.borderless)
                    }
                }
            } header: {
                HStack {
                    Text("File templates")
                    Spacer()
                    Button { store.addStarterTemplates() } label: { Label("Add Starter Types", systemImage: "doc.badge.plus") }.controlSize(.small).help("JSON, CSV, YAML, Python, JavaScript, TypeScript, Swift, SQL, CSS and Markdown with front matter")
                    Button { editingFile = FileTemplate(id: UUID().uuidString, name: "", fileName: "untitled.txt", content: "", sourcePath: nil) } label: { Label("New", systemImage: "plus") }.controlSize(.small)
                }
            } footer: { Text("Used by “New File from Template”. A template writes the text you give it, or copies a file you choose.") }

            Section {
                ForEach(store.folderTemplates) { t in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) { Text(t.name).font(.headline); Text("\(t.entries.count) entries").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Button("Edit") { editingFolder = t }.controlSize(.small)
                        Button(role: .destructive) { store.deleteFolderTemplate(t.id) } label: { Image(systemName: "trash") }.accessibilityLabel("Delete the folder template \(t.name)").buttonStyle(.borderless)
                    }
                }
            } header: {
                HStack {
                    Text("Folder templates")
                    Spacer()
                    Button { editingFolder = FolderTemplate(id: UUID().uuidString, name: "", folderName: "New Folder", entries: []) } label: { Label("New", systemImage: "plus") }.controlSize(.small)
                }
            } footer: { Text("A folder template creates a folder with the files and subfolders you list.") }
        }
        .formStyle(.grouped)
        .animation(.smooth(duration: 0.25), value: store.fileTemplates)
        .sheet(item: $editingFile) { FileTemplateEditor(template: $0) }
        .sheet(item: $editingFolder) { FolderTemplateEditor(template: $0) }
    }
}

private struct FileTemplateEditor: View {
    @State var template: FileTemplate
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: FinderStore
    @State private var useFile = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("File Template").font(.title3.bold())
            Form {
                TextField("Name in the menu", text: $template.name)
                TextField("New file's name", text: $template.fileName)
                Picker("Contents", selection: $useFile) { Text("Text").tag(false); Text("Copy of a file").tag(true) }.pickerStyle(.segmented)
                if useFile {
                    HStack {
                        TextField("File", text: Binding(get: { template.sourcePath ?? "" }, set: { template.sourcePath = $0.isEmpty ? nil : $0 }))
                        Button("Choose…") { let p = NSOpenPanel(); if p.runModal() == .OK, let url = p.url { template.sourcePath = url.path } }
                    }
                } else {
                    TextEditor(text: Binding(get: { template.content ?? "" }, set: { template.content = $0 })).font(.system(.body, design: .monospaced)).frame(height: 140)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    if useFile { template.content = nil } else { template.sourcePath = nil }
                    store.saveTemplate(template)
                    if store.lastError == nil { dismiss() }
                }.keyboardShortcut(.defaultAction)
                    .disabled(template.name.trimmingCharacters(in: .whitespaces).isEmpty || template.fileName.trimmingCharacters(in: .whitespaces).isEmpty || (useFile && (template.sourcePath ?? "").isEmpty))
            }
        }
        .padding(20).frame(width: 520)
        .onAppear { useFile = template.sourcePath != nil }
    }
}

private struct FolderTemplateEditor: View {
    @State var template: FolderTemplate
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: FinderStore
    @State private var lines = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Folder Template").font(.title3.bold())
            Form {
                TextField("Name in the menu", text: $template.name)
                TextField("New folder's name", text: $template.folderName)
                Text("Inside it, one per line. End a line with / for a folder. Anything else is an empty file.").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $lines).font(.system(.body, design: .monospaced)).frame(height: 160)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    let existing = Dictionary(template.entries.map { ($0.path, $0.content) }, uniquingKeysWith: { first, _ in first })
                    template.entries = lines.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                        .map { TemplateEntry(path: $0, content: existing[$0] ?? nil) }
                    store.saveFolderTemplate(template)
                    if store.lastError == nil { dismiss() }
                }.keyboardShortcut(.defaultAction)
                    .disabled(template.name.trimmingCharacters(in: .whitespaces).isEmpty || template.folderName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20).frame(width: 520)
        .onAppear { lines = template.entries.map(\.path).joined(separator: "\n") }
    }
}

// MARK: - Apps and behavior

private struct AppsSettingsTab: View {
    @EnvironmentObject private var store: FinderStore

    var body: some View {
        Form {
            Section {
                if store.config.favoriteApps.isEmpty { Text("No favorite apps.").font(.callout).foregroundStyle(.secondary) }
                ForEach(store.config.favoriteApps, id: \.self) { id in
                    HStack {
                        Text(AppChoice.name(for: id))
                        Spacer()
                        Button(role: .destructive) { store.updateConfig { $0.favoriteApps.removeAll { $0 == id } } } label: { Image(systemName: "trash") }.accessibilityLabel("Remove \(AppChoice.name(for: id)) from the favorites").buttonStyle(.borderless)
                    }
                }
            } header: {
                HStack {
                    Text("Favorite apps for “Open With”")
                    Spacer()
                    Button { if let id = AppChoice.choose(prompt: "Add"), !store.config.favoriteApps.contains(id) { store.updateConfig { $0.favoriteApps.append(id) } } } label: { Label("Add App", systemImage: "plus") }.controlSize(.small)
                }
            }

            Section("Terminal") {
                Picker("Open in", selection: Binding(get: { store.config.defaultTerminal ?? "com.apple.Terminal" }, set: { id in store.updateConfig { $0.defaultTerminal = id } })) {
                    ForEach(Terminals.installed, id: \.id) { Text($0.name).tag($0.id) }
                }
            }

            Section {
                Toggle("Ask before actions that change files", isOn: Binding(get: { store.config.confirmDestructive }, set: { v in store.updateConfig { $0.confirmDestructive = v } }))
                Stepper("Also ask before copying \(store.config.confirmOver) or more items", value: Binding(get: { Int(store.config.confirmOver) }, set: { v in store.updateConfig { $0.confirmOver = UInt32(v) } }), in: 2...1000)
            } header: { Text("Safety") } footer: {
                Text("Moving, renaming, extracting, converting, and running scripts or Shortcuts ask first. A name that is already taken becomes “name 2”, so nothing is overwritten.")
            }

            Section("Finder menu") {
                Picker("Layout", selection: Binding(get: { store.config.menuStyle }, set: { v in store.updateConfig { $0.menuStyle = v } })) {
                    Text("One submenu").tag(MenuStyle.submenu); Text("Directly in Finder's menu").tag(MenuStyle.flat)
                }
                TextField("Submenu title", text: Binding(get: { store.config.menuTitle }, set: { v in store.updateConfig { $0.menuTitle = v } }))
            }
        }
        .formStyle(.grouped)
        .animation(.smooth(duration: 0.25), value: store.config.favoriteApps)
    }
}

// MARK: - Setup

private struct SetupTab: View {
    @EnvironmentObject private var finder: FinderService
    @EnvironmentObject private var store: FinderStore
    @State private var checks: [FinderCheckResult] = []
    @ObservedObject private var dialogFolders = DialogAppFolders.shared
    private let ticker = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                HStack {
                    StateBadge(text: finder.extensionEnabled ? "Finder extension is on" : "Finder extension is off", color: finder.extensionEnabled ? Theme.ok : Theme.warn)
                    Spacer()
                    Button("Open Extension Settings") { finder.openExtensionSettings() }
                    Button("Restart Extension") { finder.restartExtension(); checks = [] }
                    Button("Relaunch Finder…") {
                        let alert = NSAlert()
                        alert.messageText = "Relaunch Finder?"
                        alert.informativeText = "Finder quits and opens again at once. Its windows are closed and reopen where macOS puts them; copies in progress may stop."
                        alert.addButton(withTitle: "Relaunch")
                        alert.addButton(withTitle: "Cancel")
                        if alert.runModal() == .alertFirstButtonReturn { _ = try? ToolRunner.run("/usr/bin/killall", ["Finder"]) }
                    }
                }
            } header: { Text("Finder extension") } footer: {
                Text("Switch on “Kriya” under Finder extensions, then relaunch Finder. The menu then shows when you right-click files, folders or the empty space in a folder, and from the toolbar button if you add it.")
            }

            Section {
                ForEach(checks) { check in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: check.ok ? "checkmark.circle.fill" : "xmark.octagon.fill").foregroundStyle(check.ok ? Theme.ok : Theme.danger)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(check.title)
                            Text(check.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                HStack {
                    Button("Check the Right-Click Menu") { withAnimation(.smooth) { checks = finder.selfCheck() } }
                    if !checks.isEmpty, checks.allSatisfy(\.ok) {
                        Text("Everything Kriya can see is fine. If the menu still does not show, restart the extension, then relaunch Finder.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: { Text("If it does not work") } footer: {
                Text("This looks at each link between Finder and Kriya and says which one is broken. It changes nothing.")
            }

            Section {
                HStack {
                    Text("Shortcut")
                    Spacer()
                    ShortcutRecorder(shortcut: Binding(
                        get: { store.config.launcherKeyCode.map { RecordedShortcut(keyCode: $0, modifiers: store.config.launcherModifiers) } },
                        set: { new in store.updateConfig { $0.launcherKeyCode = new?.keyCode; $0.launcherModifiers = new?.modifiers ?? 0 } }
                    )).frame(width: 190, height: 26)
                }
            } header: { Text("Action launcher") } footer: {
                Text("A search box for every action that fits what is selected in Finder. The first time, macOS asks to let Kriya control Finder so it can read the selection.")
            }

            Section {
                Toggle("Jump to a folder by itself when an app opens a dialog", isOn: $dialogFolders.enabled)
                    .onChange(of: dialogFolders.enabled) { _, _ in NotificationCenter.default.post(name: .kriyaDialogAutoJumpChanged, object: nil) }
                ForEach(dialogFolders.folders.sorted { $0.key < $1.key }, id: \.key) { id, path in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(AppChoice.name(for: id))
                            Text((path as NSString).abbreviatingWithTildeInPath).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Button(role: .destructive) { dialogFolders.set(nil, for: id) } label: { Image(systemName: "trash") }.accessibilityLabel("Remove the folder set for \(AppChoice.name(for: id))").buttonStyle(.borderless)
                    }
                }
                Button {
                    guard let app = AppChoice.choose(prompt: "Choose the app") else { return }
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = false
                    panel.canChooseDirectories = true
                    panel.prompt = "Use This Folder"
                    panel.message = "The folder its Open and Save dialogs should start in."
                    if panel.runModal() == .OK, let url = panel.url { dialogFolders.set(url.path, for: app) }
                } label: { Label("Set a Folder for an App…", systemImage: "plus") }
            } header: { Text("Open and Save dialogs") } footer: {
                Text("Give an app a folder and its Open and Save dialogs go there as soon as they appear, by typing the path into the dialog's “Go to the folder” sheet. It needs Accessibility, and it checks the front app a little more than once a second only while an app with a folder is in front. The “Dialog Folders” command shows a searchable list of Finder's folders, favorites and recent folders, with a button for hidden files.")
            }

            FolderMemorySection()

            DefaultAppsSection()

            Section {
                Text("Select files in Finder, then choose Finder › Services › Kriya: … or right-click ▸ Services. Assign keys to them in System Settings › Keyboard › Keyboard Shortcuts › Services.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Open Keyboard Settings") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!) }
            } header: { Text("Services menu") }
        }
        .formStyle(.grouped)
        .onAppear { finder.refreshExtensionStatus() }
        .onReceive(ticker) { _ in finder.refreshExtensionStatus() }
    }
}

/// Finder's open and recently closed windows, groups of folders, and the folders left out of the recent lists.
private struct FolderMemorySection: View {
    @ObservedObject private var tracker = FinderWindowTracker.shared
    @ObservedObject private var sets = FolderSetStore.shared
    @ObservedObject private var destinations = FolderDestinations.shared
    @State private var newName = ""

    var body: some View {
        Section {
            Toggle("Remember Finder windows I close", isOn: $tracker.enabled)
            ForEach(tracker.history.closed.prefix(8), id: \.self) { path in
                HStack {
                    Text((path as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Reopen") { tracker.reopen(path) }.controlSize(.small)
                    Button { tracker.forget(path) } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).help("Forget this window").accessibilityLabel("Forget this window")
                }
            }
        } header: { Text("Finder windows") } footer: {
            Text("Off by default. When on, Kriya asks Finder which folders it has open every few seconds and keeps the last closed ones (folder names only) so “Reopen Finder window” in the launcher can bring them back. Turning it off forgets them.")
        }

        Section {
            ForEach(sets.sets) { set in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(set.name)
                        Text("\(set.paths.count) folders").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Open") { sets.open(set) }.controlSize(.small)
                    Button(role: .destructive) { sets.sets.removeAll { $0.id == set.id } } label: { Image(systemName: "trash") }.buttonStyle(.borderless).accessibilityLabel("Delete \(set.name)")
                }
            }
            HStack {
                TextField("Name for the folders open in Finder now", text: $newName)
                Button("Save as Set") { if sets.saveOpenFolders(named: newName) { newName = "" } else { Toast().show("Open some Finder windows and type a name first.", isError: true) } }
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: { Text("Folder sets") } footer: {
            Text("Saves the folders Finder has open under a name. “Open folder set” in the launcher opens them all again.")
        }

        Section {
            ForEach(destinations.excluded, id: \.self) { folder in
                HStack {
                    Text((folder as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button(role: .destructive) { destinations.include(folder) } label: { Image(systemName: "trash") }.buttonStyle(.borderless).accessibilityLabel("Stop leaving this folder out")
                }
            }
            Button {
                let panel = NSOpenPanel()
                panel.canChooseFiles = false
                panel.canChooseDirectories = true
                panel.prompt = "Leave Out"
                if panel.runModal() == .OK, let url = panel.url { destinations.exclude(url.path) }
            } label: { Label("Leave a Folder Out of Recent Folders…", systemImage: "plus") }
        } header: { Text("Recent folders") } footer: {
            Text("A folder left out here, and everything inside it, never shows up in recent folders or in Finder window history.")
        }
    }
}


/// File jobs waiting and running. Pausing holds back the ones that have not started; one already running finishes.
private struct FileJobsSection: View {
    @ObservedObject private var jobs = FinderJobs.shared

    var body: some View {
        if jobs.state.isBusy || jobs.state.paused {
            Section {
                Text(jobs.state.summary).font(.callout)
                ForEach(jobs.state.jobs.filter { $0.status == .waiting || $0.status == .running }) { job in
                    HStack {
                        Image(systemName: job.status == .running ? "arrow.triangle.2.circlepath" : "clock").foregroundStyle(.secondary)
                        Text(job.title)
                        Spacer()
                        if job.status == .waiting { Button("Cancel") { jobs.cancelWaiting(job.id) }.controlSize(.small) }
                    }
                }
                Button(jobs.state.paused ? "Resume" : "Pause Waiting Jobs") { jobs.setPaused(!jobs.state.paused) }.controlSize(.small)
            } header: { Text("In progress") } footer: { Text("A job that has already started cannot be stopped part-way; it finishes.") }
        }
    }
}
