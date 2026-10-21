import AppKit
import SwiftUI

struct FinderPane: View {
    @EnvironmentObject private var finder: FinderService
    @EnvironmentObject private var store: FinderStore
    @EnvironmentObject private var config: ConfigStore
    @EnvironmentObject private var services: ServiceManager

    @State private var tab: Tab = .actions
    @State private var confirmReset = false

    enum Tab: String, CaseIterable, Identifiable {
        case actions = "Actions", templates = "Templates", apps = "Apps", pointer = "Pointer Menu", setup = "Setup"
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
                }
                .padding(.horizontal, 20).padding(.top, 10).transition(.opacity)
            }
            HStack {
                Picker("", selection: $tab) { ForEach(Tab.allCases) { Text($0.rawValue).tag($0) } }
                    .paneTabBar(maxWidth: 500)
                Menu {
                    Button("Add Common Actions (editor, hidden files, parent folder)") { store.addSuggested() }
                    Divider()
                    Button("Restore Default Actions and Settings") { store.restoreDefaults(everything: false) }
                    Button("Restore Everything, Including Templates…") { confirmReset = true }
                } label: { MoreMenuLabel() }.menuStyle(.button).menuIndicator(.hidden).fixedSize()
            }
            .paneHeader()

            Group {
                switch tab {
                case .actions: ActionsTab()
                case .templates: TemplatesTab()
                case .apps: AppsSettingsTab()
                case .pointer: PointerMenuTab()
                case .setup: SetupTab()
                }
            }
            .id(tab)
            .transition(.opacity)
        }
        .animation(.smooth(duration: 0.22), value: tab)
        .animation(.smooth(duration: 0.25), value: services.state(.contextMenu))
        .overlay(alignment: .bottom) {
            if let error = store.lastError {
                Text(error).font(.callout).padding(10).background(Theme.danger.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                    .padding().transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .confirmationDialog("Restore everything?", isPresented: $confirmReset) {
            Button("Restore Everything", role: .destructive) { store.restoreDefaults(everything: true) }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Your custom actions and templates are removed and the shipped ones come back.") }
    }
}

// MARK: - Actions

private struct ActionsTab: View {
    @EnvironmentObject private var store: FinderStore
    @State private var editing: FinderItem?

    var body: some View {
        List {
            Section {
                ForEach(store.items) { item in
                    HStack(spacing: 12) {
                        Toggle("", isOn: Binding(get: { item.enabled }, set: { store.setEnabled(item.id, $0) }))
                            .labelsHidden().toggleStyle(.switch).controlSize(.small)
                        Image(systemName: item.kind.symbol).frame(width: 22).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).font(.headline)
                            Text("\(item.kind.summary) · \(item.applies.title)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Button("Edit") { editing = item }.controlSize(.small)
                        Button(role: .destructive) { withAnimation(.smooth) { store.delete(item.id) } } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
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
        }
        .animation(.smooth(duration: 0.25), value: store.items)
        .sheet(item: $editing) { ItemEditor(item: $0) }
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
                Button("Save") { save() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 560)
        .onAppear(perform: load)
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
                        Button(role: .destructive) { store.deleteTemplate(t.id) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                    }
                }
            } header: {
                HStack {
                    Text("File templates")
                    Spacer()
                    Button { editingFile = FileTemplate(id: UUID().uuidString, name: "", fileName: "untitled.txt", content: "", sourcePath: nil) } label: { Label("New", systemImage: "plus") }.controlSize(.small)
                }
            } footer: { Text("Used by “New File from Template”. A template writes the text you give it, or copies a file you choose.") }

            Section {
                ForEach(store.folderTemplates) { t in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) { Text(t.name).font(.headline); Text("\(t.entries.count) entries").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Button("Edit") { editingFolder = t }.controlSize(.small)
                        Button(role: .destructive) { store.deleteFolderTemplate(t.id) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
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
                        Button(role: .destructive) { store.updateConfig { $0.favoriteApps.removeAll { $0 == id } } } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
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
    private let ticker = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                HStack {
                    StateBadge(text: finder.extensionEnabled ? "Finder extension is on" : "Finder extension is off", color: finder.extensionEnabled ? Theme.ok : Theme.warn)
                    Spacer()
                    Button("Open Extension Settings") { finder.openExtensionSettings() }
                    Button("Relaunch Finder") { _ = try? ToolRunner.run("/usr/bin/killall", ["Finder"]) }
                }
            } header: { Text("Finder extension") } footer: {
                Text("Switch on “Kriya” under Finder extensions, then relaunch Finder. The menu then shows when you right-click files, folders or the empty space in a folder, and from the toolbar button if you add it.")
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
