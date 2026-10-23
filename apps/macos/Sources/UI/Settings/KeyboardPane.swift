import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct KeyboardPane: View {
    @EnvironmentObject private var keyboard: KeyboardService
    @EnvironmentObject private var store: KeyboardStore
    @EnvironmentObject private var config: ConfigStore
    @EnvironmentObject private var services: ServiceManager
    @EnvironmentObject private var permissions: PermissionManager

    @State private var tab: Tab = .shortcuts
    @State private var confirmReset = false

    enum Tab: String, CaseIterable, Identifiable {
        case shortcuts = "Shortcuts", keys = "Keys", snippets = "Snippets", expansion = "Expansion", launcher = "Launcher"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            if !config.isEnabled(.keyboard) || services.state(.keyboard) != .running {
                Banner(
                    symbol: "keyboard", tint: Theme.warn,
                    title: "Keyboard features are \(config.isEnabled(.keyboard) ? services.state(.keyboard).label.lowercased() : "off")",
                    message: "Your shortcuts and snippets are saved, but they work only while the feature is on and allowed."
                ) {
                    if !config.isEnabled(.keyboard) { Button("Turn On") { services.setFeature(.keyboard, enabled: true) }.controlSize(.small) }
                    else if case .needsPermission(let missing) = services.state(.keyboard), let first = missing.first { Button("Allow \(first.title)…") { permissions.request(first) }.controlSize(.small) }
                }
                .padding(.horizontal, 20).padding(.top, 10).transition(.opacity)
            }
            HStack {
                Picker("", selection: $tab) { ForEach(Tab.allCases) { Text($0.rawValue).tag($0) } }
                    .paneTabBar(maxWidth: 460)
                Menu {
                    Button("Restore Default Settings") { store.restoreDefaults(everything: false) }
                    Button("Remove All Shortcuts and Snippets…") { confirmReset = true }
                } label: { MoreMenuLabel() }.menuStyle(.button).menuIndicator(.hidden).fixedSize()
            }
            .paneHeader()
            Group {
                switch tab {
                case .shortcuts: ShortcutsListTab()
                case .keys: RemapTab()
                case .snippets: SnippetsTab()
                case .expansion: ExpansionTab()
                case .launcher: LauncherTab()
                }
            }
            .id(tab)
            .transition(.opacity)
        }
        .animation(.smooth(duration: 0.22), value: tab)
        .tabHint($tab)
        .overlay(alignment: .bottom) {
            if let error = store.lastError {
                Text(error).font(.callout).padding(10).background(Theme.danger.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                    .padding().transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .confirmationDialog("Remove everything?", isPresented: $confirmReset) {
            Button("Remove All Shortcuts and Snippets", role: .destructive) { store.restoreDefaults(everything: true) }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Your keyboard shortcuts and every snippet are deleted.") }
    }
}

// MARK: - Shortcuts

private struct ShortcutsListTab: View {
    @EnvironmentObject private var store: KeyboardStore
    @EnvironmentObject private var library: ActionLibrary
    @State private var editing: KeyShortcut?

    var body: some View {
        Form {
            Section {
                if store.shortcuts.isEmpty { Text("No shortcuts yet.").font(.callout).foregroundStyle(.secondary) }
                ForEach(store.shortcuts) { shortcut in
                    HStack(spacing: 12) {
                        Toggle("", isOn: Binding(get: { shortcut.enabled }, set: { store.setShortcutEnabled(shortcut.id, $0) })).labelsHidden().toggleStyle(.switch).controlSize(.small)
                        Text(KeyNames.describe(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers))
                            .font(.system(.body, design: .rounded).monospaced()).padding(.horizontal, 6).padding(.vertical, 2).background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(shortcut.name).font(.headline)
                            Text("\(describe(shortcut.target)) · \(shortcut.scope.title)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Button("Edit") { editing = shortcut }.controlSize(.small)
                        Button(role: .destructive) { store.deleteShortcut(shortcut.id) } label: { Image(systemName: "trash") }.accessibilityLabel("Delete").buttonStyle(.borderless)
                    }
                    .padding(.vertical, 3)
                }
            } header: {
                HStack {
                    Text("Keyboard shortcuts")
                    Spacer()
                    Button { editing = KeyShortcut(id: UUID().uuidString, name: "", keyCode: 0, modifiers: 0, scope: .global, target: .command(command: "palette.open"), enabled: true) } label: { Label("New Shortcut", systemImage: "plus") }.controlSize(.small)
                }
            } footer: {
                Text("A shortcut runs a command, a saved action, a workflow or inserts a snippet. It can be limited to certain apps. Kriya checks each one against macOS, the rest of Kriya and your other shortcuts before saving it.")
            }
        }
        .formStyle(.grouped)
        .animation(.smooth(duration: 0.25), value: store.shortcuts)
        .sheet(item: $editing) { ShortcutEditor(shortcut: $0) }
    }

    private func describe(_ target: ShortcutTarget) -> String {
        switch target {
        case .action(let id): return "Action: " + (library.actions.first { $0.id == id }?.name ?? "unknown")
        case .snippet(let id): return "Inserts: " + (store.snippet(id)?.title ?? "unknown")
        case .command(let command): return KeyboardCommands.title(command)
        }
    }
}

/// Commands a shortcut can run by name.
enum KeyboardCommands {
    static var extra: () -> [(command: String, title: String)] = { [] }

    static var all: [(command: String, title: String)] {
        var list: [(String, String)] = windowLayouts().map { ($0.command, "Window: \($0.title)") }
        list += windowExtraCommands().map { ($0.command, "Window: \($0.title)") }
        list += [
            ("palette.open", "Open the command launcher"), ("clipboard.quick", "Open clipboard history"), ("clipboard.plain", "Paste as plain text"),
            ("clipboard.strip", "Remove formatting from the clipboard"), ("clipboard.pause", "Pause or resume clipboard recording"),
            ("selection.manual", "Show selection actions"), ("selection.paste", "Show paste actions here (nothing selected)"), ("finder.launcher", "Finder actions for the selected files"),
        ]
        list += extra().map { ($0.command, $0.title) }
        return list.map { (command: $0.0, title: $0.1) }
    }

    static func title(_ command: String) -> String { all.first { $0.command == command }?.title ?? command }
}

private struct ShortcutEditor: View {
    @State var shortcut: KeyShortcut
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: KeyboardStore
    @EnvironmentObject private var library: ActionLibrary

    private enum Kind: String, CaseIterable, Identifiable { case command = "A command", action = "A saved action", snippet = "Insert a snippet"; var id: String { rawValue } }
    private enum ScopeKind: String, CaseIterable, Identifiable { case global = "Everywhere", only = "Only in these apps", except = "Everywhere except these apps"; var id: String { rawValue } }

    @State private var recorded: RecordedShortcut?
    @State private var kind: Kind = .command
    @State private var command = "palette.open"
    @State private var actionID = ""
    @State private var snippetID = ""
    @State private var scopeKind: ScopeKind = .global
    @State private var apps: [String] = []

    private var candidate: KeyShortcut {
        var s = shortcut
        s.keyCode = recorded?.keyCode ?? s.keyCode
        s.modifiers = recorded?.modifiers ?? s.modifiers
        switch kind {
        case .command: s.target = .command(command: command)
        case .action: s.target = .action(actionId: actionID)
        case .snippet: s.target = .snippet(snippetId: snippetID)
        }
        switch scopeKind {
        case .global: s.scope = .global
        case .only: s.scope = .onlyApps(appIds: apps)
        case .except: s.scope = .exceptApps(appIds: apps)
        }
        if s.name.trimmingCharacters(in: .whitespaces).isEmpty { s.name = suggestedName }
        return s
    }

    private var suggestedName: String {
        switch kind {
        case .command: return KeyboardCommands.title(command)
        case .action: return library.actions.first { $0.id == actionID }?.name ?? ""
        case .snippet: return store.snippet(snippetID).map { "Insert \($0.title)" } ?? ""
        }
    }

    var body: some View {
        let conflicts = recorded == nil && shortcut.name.isEmpty ? [] : store.checkShortcut(candidate)
        VStack(alignment: .leading, spacing: 14) {
            Text("Keyboard Shortcut").font(.title3.bold())
            Form {
                TextField("Name", text: $shortcut.name, prompt: Text(suggestedName.isEmpty ? "Name" : suggestedName))
                LabeledContent("Keys") { ShortcutRecorder(shortcut: $recorded).frame(width: 190, height: 26) }
                Picker("Runs", selection: $kind) { ForEach(Kind.allCases) { Text($0.rawValue).tag($0) } }
                switch kind {
                case .command:
                    Picker("Command", selection: $command) { ForEach(KeyboardCommands.all, id: \.command) { Text($0.title).tag($0.command) } }
                case .action:
                    Picker("Action", selection: $actionID) { Text("Choose…").tag(""); ForEach(library.actions) { Text($0.name).tag($0.id) } }
                case .snippet:
                    Picker("Snippet", selection: $snippetID) { Text("Choose…").tag(""); ForEach(store.snippets) { Text($0.title).tag($0.id) } }
                }
                Picker("Active", selection: $scopeKind) { ForEach(ScopeKind.allCases) { Text($0.rawValue).tag($0) } }
                if scopeKind != .global {
                    ForEach(apps, id: \.self) { id in
                        HStack { Text(AppChoice.name(for: id)); Spacer(); Button(role: .destructive) { apps.removeAll { $0 == id } } label: { Image(systemName: "trash") }.accessibilityLabel("Delete").buttonStyle(.borderless) }
                    }
                    Button { if let id = AppChoice.choose(prompt: "Add"), !apps.contains(id) { apps.append(id) } } label: { Label("Add App", systemImage: "plus") }.controlSize(.small)
                }
                if !conflicts.isEmpty {
                    Section {
                        ForEach(Array(conflicts.enumerated()), id: \.offset) { _, c in
                            Label(c.with, systemImage: c.blocking ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(c.blocking ? Theme.danger : Theme.warn).font(.callout)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }.keyboardShortcut(.defaultAction).disabled(recorded == nil && shortcut.keyCode == 0 && shortcut.modifiers == 0 || conflicts.contains { $0.blocking })
            }
        }
        .padding(20).frame(width: 540)
        .onAppear(perform: load)
    }

    private func load() {
        if shortcut.modifiers != 0 || shortcut.keyCode != 0 { recorded = RecordedShortcut(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers) }
        switch shortcut.target {
        case .command(let c): kind = .command; command = c
        case .action(let id): kind = .action; actionID = id
        case .snippet(let id): kind = .snippet; snippetID = id
        }
        switch shortcut.scope {
        case .global: scopeKind = .global
        case .onlyApps(let ids): scopeKind = .only; apps = ids
        case .exceptApps(let ids): scopeKind = .except; apps = ids
        }
    }

    private func save() {
        store.saveShortcut(candidate)
        if store.lastError == nil { dismiss() }
    }
}

// MARK: - Snippets

private struct SnippetsTab: View {
    @EnvironmentObject private var store: KeyboardStore
    @State private var query = ""
    @State private var category: String?
    @State private var favoritesOnly = false
    @State private var editing: ExpansionSnippet?
    @State private var message: String?
    @State private var selected: Set<String> = []

    private var results: [ExpansionSnippet] { store.search(query, category: category, favoritesOnly: favoritesOnly) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search snippets", text: $query).textFieldStyle(.plain)
                Toggle(isOn: $favoritesOnly) { Image(systemName: favoritesOnly ? "star.fill" : "star") }.toggleStyle(.button).help("Favorites only").accessibilityLabel("Favorites only")
                Menu {
                    Button("All categories") { category = nil }
                    Divider()
                    ForEach(store.categories, id: \.self) { c in Button(c) { category = c } }
                } label: { Label(category ?? "Categories", systemImage: "folder") }.menuStyle(.button).menuIndicator(.hidden).fixedSize()
            }
            .padding(10)
            Divider()
            List(results, selection: $selected) { snippet in
                HStack(spacing: 10) {
                    Button { store.toggleFavorite(snippet.id) } label: { Image(systemName: snippet.favorite ? "star.fill" : "star").foregroundStyle(snippet.favorite ? Theme.warn : .secondary) }.buttonStyle(.borderless)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(snippet.title).font(.headline)
                            if let abbr = snippet.abbreviation { Text(abbr).font(.caption.monospaced()).padding(.horizontal, 4).background(.quaternary, in: RoundedRectangle(cornerRadius: 4)) }
                            if let c = snippet.category { Text(c).font(.caption).foregroundStyle(Theme.accent) }
                            if !snippet.enabled { Text("Off").font(.caption).foregroundStyle(.secondary) }
                        }
                        Text(snippet.body.replacingOccurrences(of: "\n", with: " ⏎ ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    if snippet.useCount > 0 { Text("\(snippet.useCount)×").font(.caption).foregroundStyle(.tertiary) }
                    Button("Edit") { editing = snippet }.controlSize(.small)
                }
                .tag(snippet.id)
                .padding(.vertical, 2)
            }
            .listStyle(.plain)
            .overlay { if results.isEmpty { Text(store.snippets.isEmpty ? "No snippets yet" : "No matching snippets").foregroundStyle(.secondary) } }
            Divider()
            HStack {
                Button { editing = store.newSnippet() } label: { Label("New Snippet", systemImage: "plus") }
                Menu {
                    Button("Import Snippets…") { importSnippets() }
                    Button("Export Selected…") { export(selectedOnly: true) }.disabled(selected.isEmpty)
                    Button("Export All…") { export(selectedOnly: false) }.disabled(store.snippets.isEmpty)
                    Divider()
                    Button("Delete Selected", role: .destructive) { selected.forEach(store.deleteSnippet); selected.removeAll() }.disabled(selected.isEmpty)
                } label: { Image(systemName: "square.and.arrow.up.on.square") }.menuStyle(.button).menuIndicator(.hidden).fixedSize()
                Spacer()
                if let message { Text(message).font(.caption).foregroundStyle(.secondary).transition(.opacity) }
            }
            .padding(10)
        }
        .animation(.smooth(duration: 0.2), value: message)
        .sheet(item: $editing) { SnippetEditorSheet(snippet: $0) }
    }

    private func importSnippets() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let s = try store.importSnippets(from: url)
            message = "Added \(s.added)" + (s.skippedDuplicates > 0 ? ", skipped \(s.skippedDuplicates) already here" : "") + (s.abbreviationsDropped > 0 ? ", \(s.abbreviationsDropped) without abbreviation" : "")
        } catch { store.lastError = error.userMessage }
    }

    private func export(selectedOnly: Bool) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Kriya snippets.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let ids = selectedOnly ? Array(selected) : store.snippets.map(\.id)
        do {
            try store.exportSnippets(ids, to: url)
            message = "Exported \(ids.count)"
        } catch { store.lastError = error.userMessage }
    }
}

private struct SnippetEditorSheet: View {
    @State var snippet: ExpansionSnippet
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: KeyboardStore

    private static let placeholders: [(title: String, token: String)] = [
        ("Today's date", "{date}"), ("Date in a week", "{date+7d}"), ("Long date", "{date:EEEE, MMMM d, yyyy}"), ("Time", "{time}"), ("Date and time", "{datetime}"),
        ("Clipboard", "{clipboard}"), ("Cursor goes here", "{cursor}"), ("Ask me for…", "{prompt:Name}"), ("Unique ID", "{uuid}"),
    ]

    var body: some View {
        let preview = SnippetInserter.preview(snippet.body)
        let problem = snippetProblem(snippet: snippet)
        let conflicts = snippetConflicts(candidate: snippet, all: store.snippets)
        VStack(alignment: .leading, spacing: 14) {
            Text(snippet.title.isEmpty ? "New Snippet" : "Snippet").font(.title3.bold())
            ScrollView {
                Form {
                    TextField("Name", text: $snippet.title)
                    TextField("Abbreviation", text: Binding(get: { snippet.abbreviation ?? "" }, set: { snippet.abbreviation = $0.isEmpty ? nil : $0 }), prompt: Text("for example ;sig  (optional)"))
                    if snippet.abbreviation != nil {
                        Picker("Expand", selection: $snippet.expandOn) { ForEach([ExpandOn.delimiter, .immediately], id: \.self) { Text($0.title).tag($0) } }
                        Toggle("Match capital letters exactly", isOn: $snippet.caseSensitive)
                    }
                    TextField("Category", text: Binding(get: { snippet.category ?? "" }, set: { snippet.category = $0.isEmpty ? nil : $0 }), prompt: Text("optional"))
                    Toggle("Favorite", isOn: $snippet.favorite)
                    Toggle("Turned on", isOn: $snippet.enabled)
                    Section {
                        TextEditor(text: $snippet.body).font(.system(.body, design: .monospaced)).frame(height: 130)
                        Menu("Insert a placeholder") {
                            ForEach(Self.placeholders, id: \.token) { p in Button(p.title) { snippet.body += p.token } }
                        }.menuStyle(.button).menuIndicator(.hidden).fixedSize()
                    } header: { Text("Text") }
                    Section("Preview") {
                        Text(preview.text.isEmpty ? "(empty)" : preview.text).font(.system(.callout, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        if !preview.promptsNeeded.isEmpty { Text("Asks for: " + preview.promptsNeeded.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary) }
                    }
                    Section("Only in these apps") {
                        if snippet.appIds.isEmpty { Text("Every app").font(.caption).foregroundStyle(.secondary) }
                        ForEach(snippet.appIds, id: \.self) { id in
                            HStack { Text(AppChoice.name(for: id)); Spacer(); Button(role: .destructive) { snippet.appIds.removeAll { $0 == id } } label: { Image(systemName: "trash") }.accessibilityLabel("Delete").buttonStyle(.borderless) }
                        }
                        Button { if let id = AppChoice.choose(prompt: "Add"), !snippet.appIds.contains(id) { snippet.appIds.append(id) } } label: { Label("Add App", systemImage: "plus") }.controlSize(.small)
                    }
                    if !conflicts.isEmpty {
                        Section {
                            ForEach(Array(conflicts.enumerated()), id: \.offset) { _, c in
                                Label(c.kind == .duplicate ? "“\(c.title)” already uses \(c.abbreviation)." : "“\(c.abbreviation)” (\(c.title)) expands first and cuts this one short.",
                                      systemImage: c.kind == .duplicate ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                                    .foregroundStyle(c.kind == .duplicate ? Theme.danger : Theme.warn).font(.callout)
                            }
                        }
                    }
                    if let problem, !snippet.title.isEmpty || !snippet.body.isEmpty { Text(problem).font(.callout).foregroundStyle(Theme.danger) }
                }
                .formStyle(.grouped)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { if store.saveSnippet(snippet) { dismiss() } }.keyboardShortcut(.defaultAction)
                    .disabled(problem != nil || conflicts.contains { $0.kind == .duplicate })
            }
        }
        .padding(20).frame(width: 600, height: 700)
    }
}

// MARK: - Expansion settings

private struct ExpansionTab: View {
    @EnvironmentObject private var store: KeyboardStore
    private var config: KeyboardConfig { store.config }

    var body: some View {
        Form {
            Section {
                Picker("New abbreviations expand", selection: Binding(get: { config.expansionDefaultExpandOn }, set: { v in store.updateConfig { $0.expansionDefaultExpandOn = v } })) {
                    ForEach([ExpandOn.delimiter, .immediately], id: \.self) { Text($0.title).tag($0) }
                }
                Toggle("Type short text instead of pasting it", isOn: Binding(get: { config.typeInsteadOfPaste }, set: { v in store.updateConfig { $0.typeInsteadOfPaste = v } }))
            } header: { Text("Typing") } footer: {
                Text("Typing leaves your clipboard alone. Longer text and text with line breaks is pasted, and your clipboard is put back right after.")
            }

            Section {
                ForEach(config.expansionExcludedAppIds, id: \.self) { id in
                    HStack {
                        Text(AppChoice.name(for: id))
                        Spacer()
                        Button(role: .destructive) { store.updateConfig { $0.expansionExcludedAppIds.removeAll { $0 == id } } } label: { Image(systemName: "trash") }.accessibilityLabel("Delete").buttonStyle(.borderless)
                    }
                }
                Button { if let id = AppChoice.choose(prompt: "Exclude"), !config.expansionExcludedAppIds.contains(id) { store.updateConfig { $0.expansionExcludedAppIds.append(id) } } } label: { Label("Exclude an App", systemImage: "plus") }.controlSize(.small)
            } header: { Text("Never expand in these apps") } footer: {
                Text("Kriya never expands in password fields, while macOS protects keyboard input (such as when a password box has focus), or in fields described as a password. Password managers start on this list. Kriya keeps only the last few characters you typed, in memory, and forgets them on a click, an arrow key, a shortcut or a change of app.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Launcher and keyboard navigation

private struct LauncherTab: View {
    @EnvironmentObject private var store: KeyboardStore
    private var config: KeyboardConfig { store.config }

    var body: some View {
        Form {
            Section {
                LabeledContent("Shortcut") {
                    ShortcutRecorder(shortcut: Binding(
                        get: { config.paletteKey.map { RecordedShortcut(keyCode: $0, modifiers: config.paletteModifiers) } },
                        set: { new in store.updateConfig { $0.paletteKey = new?.keyCode; $0.paletteModifiers = new?.modifiers ?? 0 } }
                    )).frame(width: 190, height: 26)
                }
            } header: { Text("Command launcher") } footer: {
                Text("One search box for apps, open windows, files, clipboard history, snippets, saved actions, workflows, window layouts, Kriya and macOS settings, a calculator, timers and emoji. Type a few letters, press Return. What it searches, pins and short names are in the Launcher pane.")
            }
            Section("Moving around Settings with the keyboard") {
                row("⌘1 – ⌘9", "Open the first nine panes")
                row("⌘[  and  ⌘]", "Previous and next pane")
                row("↑ ↓", "Move through the sidebar")
                row("Tab", "Move between controls (turn on Full Keyboard Access in System Settings › Keyboard to reach every control)")
                row("Space", "Switch a switch or press a button")
                row("Launcher", "Open any pane by name")
            }
        }
        .formStyle(.grouped)
    }

    private func row(_ keys: String, _ text: String) -> some View {
        LabeledContent { Text(text).foregroundStyle(.secondary).multilineTextAlignment(.trailing) } label: { Text(keys).font(.system(.body, design: .rounded).monospaced()) }
    }
}
