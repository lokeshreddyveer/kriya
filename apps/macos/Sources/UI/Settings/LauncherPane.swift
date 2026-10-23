import SwiftUI

/// The launcher: what it searches, what is pinned, short names, and what it remembers.
struct LauncherPane: View {
    @EnvironmentObject private var prefs: LauncherPrefs
    @EnvironmentObject private var keyboard: KeyboardStore
    @EnvironmentObject private var extras: LauncherExtras
    @EnvironmentObject private var tools: LauncherToolSources
    @State private var confirmReset = false
    @State private var editingLink: Quicklink?
    @State private var editingScript: ScriptCommand?
    @State private var calendarMessage: String?
    @State private var hotkeyProblem: String?
    @State private var spotlightOn = SpotlightShortcut.currentlyEnabled()
    @State private var folderMessage: String?
    @State private var placement = PaletteLayout.Placement.current
    @AppStorage("launcherTheme") private var themeRaw = LauncherTheme.glass.rawValue
    @AppStorage("launcherAccent") private var accentRaw = LauncherAccent.neutral.rawValue

    private var config: KeyboardConfig { keyboard.config }
    private var usesCommandSpace: Bool { config.paletteKey == 49 && config.paletteModifiers == KeyModifiers.command }

    var body: some View {
        Form {
            Section {
                Picker("Theme", selection: $themeRaw) {
                    ForEach(LauncherTheme.allCases) { Text($0.title).tag($0.rawValue) }
                }
                LabeledContent("Highlight") {
                    HStack(spacing: 8) {
                        ForEach(LauncherAccent.allCases) { accent in
                            Button { accentRaw = accent.rawValue } label: {
                                Circle().fill(accent.rgb.map { Color(red: $0.r, green: $0.g, blue: $0.b) } ?? Color.gray.opacity(0.45)).frame(width: 20, height: 20)
                                    .overlay(Circle().strokeBorder(Color.primary.opacity(accentRaw == accent.rawValue ? 0.9 : 0.15), lineWidth: accentRaw == accent.rawValue ? 2 : 1))
                            }.buttonStyle(.plain).help(accent.title)
                        }
                    }
                }
            } header: { Text("Look") } footer: {
                Text("Glass follows the system's light or dark look. Midnight, Paper and Graphite are flat colours. The highlight is the colour of the row you are on; Neutral keeps it a soft grey. Open the launcher to see a change.")
            }

            Section {
                Picker("The launcher opens", selection: Binding(get: { placement }, set: { placement = $0; PaletteLayout.Placement.current = $0 })) {
                    ForEach(PaletteLayout.Placement.allCases) { Text($0.title).tag($0) }
                }
                if placement == .remembered {
                    Button("Put It Back Near the Top") { PaletteLayout.Remembered.saved = nil; placement = .top; PaletteLayout.Placement.current = .top }
                }
            } header: { Text("Position") } footer: {
                Text("Drag the launcher by its search bar, its headings or its bottom strip and it opens where you leave it, on whichever display that was. “At the pointer” opens it under the pointer, and “In the middle” keeps it centred as the results grow.")
            }

            Section {
                LabeledContent("Shortcut") {
                    ShortcutRecorder(shortcut: Binding(
                        get: { config.paletteKey.map { RecordedShortcut(keyCode: $0, modifiers: config.paletteModifiers) } },
                        set: { new in keyboard.updateConfig { $0.paletteKey = new?.keyCode; $0.paletteModifiers = new?.modifiers ?? 0 } }
                    )).frame(width: 190, height: 26)
                }
                HStack(spacing: 10) {
                    StateBadge(text: usesCommandSpace ? (spotlightOn ? "⌘Space: Spotlight answers first" : "⌘Space is yours") : (spotlightOn ? "Spotlight uses ⌘Space" : "⌘Space is free"),
                               color: usesCommandSpace && spotlightOn ? Theme.warn : Theme.ok)
                    Spacer()
                    if spotlightOn { Button("Turn Off Spotlight's Shortcut…") { NSWorkspace.shared.open(SpotlightShortcut.settingsURL) }.controlSize(.small) }
                    if !usesCommandSpace { Button("Use ⌘Space") { keyboard.updateConfig { $0.paletteKey = 49; $0.paletteModifiers = KeyModifiers.command } }.controlSize(.small) }
                }
            } header: { Text("Open it") } footer: {
                Text("To use ⌘Space like Spotlight: choose “Use ⌘Space”, then open System Settings › Keyboard › Keyboard Shortcuts… › Spotlight and untick “Show Spotlight search”. macOS gives the keys to Spotlight first, so this one change is needed. Spotlight is still there from its menu-bar icon and Finder.")
            }
            .onAppear { spotlightOn = SpotlightShortcut.currentlyEnabled() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in spotlightOn = SpotlightShortcut.currentlyEnabled() }

            Section {
                EmptyView()
            } header: { EmptyView() } footer: {
                Text("The search in the menu-bar window uses the same results. In the launcher: ↑ ↓ to move, Return to open, ⌘K for more things to do with a result, ⌘P to pin it, ⌘1 to ⌘9 to open one directly.")
            }

            Section {
                ForEach(fallbackRows, id: \.id) { row in
                    HStack {
                        Toggle(isOn: Binding(get: { row.on }, set: { setFallback(row.id, $0) })) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(row.title)
                                if let note = row.note { Text(note).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                        Spacer()
                        if row.on {
                            Button { moveFallback(row.id, -1) } label: { Image(systemName: "arrow.up") }.buttonStyle(.borderless)
                            Button { moveFallback(row.id, 1) } label: { Image(systemName: "arrow.down") }.buttonStyle(.borderless)
                        }
                    }
                }
            } header: { Text("Fallbacks") } footer: {
                Text("Text that matches nothing is offered to these, in this order, under “Search with”. Turn on Apple Intelligence to ask it, or a quicklink or script to send the text there.")
            }

            Section {
                Picker("Matching", selection: Binding(get: { prefs.data.matchStrictness }, set: { prefs.setStrictness($0) })) {
                    ForEach(LauncherStrictness.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Recent files when nothing is typed", isOn: Binding(get: { prefs.data.showRecentFiles != false }, set: { prefs.setShowRecentFiles($0) }))
                Toggle("Today's events when nothing is typed", isOn: Binding(get: { prefs.data.showTodayEvents != false }, set: { prefs.setShowTodayEvents($0) }))
                Toggle("Find people in Contacts", isOn: Binding(get: { prefs.data.searchContacts == true }, set: { on in
                    prefs.setSearchContacts(on)
                    if on, !tools.contactsAllowed {
                        tools.requestContacts { granted in
                            hotkeyProblem = granted ? nil : "Contacts access was not allowed. Turn it on in System Settings › Privacy & Security › Contacts."
                            if !granted { prefs.setSearchContacts(false) }
                        }
                    }
                }))
                LabeledContent("Actions for selected text") {
                    ShortcutRecorder(shortcut: Binding(
                        get: { prefs.hotkey(for: LauncherHotkeys.selectionID).map { RecordedShortcut(keyCode: $0.keyCode, modifiers: $0.modifiers) } },
                        set: { new in
                            hotkeyProblem = tools.hotkeys?.set(new.map { LauncherHotkey(keyCode: $0.keyCode, modifiers: $0.modifiers) }, for: LauncherHotkeys.selectionID, title: "Actions for selected text")
                        }
                    )).frame(width: 190, height: 26)
                }
                if let hotkeyProblem { Text(hotkeyProblem).font(.caption).foregroundStyle(Theme.warn) }
            } header: { Text("How it behaves") } footer: {
                Text("Select text in any app and press the shortcut: the launcher opens with things to do with it (summarize, change case, search, convert, open). With nothing selected it uses the clipboard. Type a path starting with / or ~ to browse folders: Tab goes into a folder, Shift-Tab goes up, and ⌘K › Add to the File Buffer collects files to move, copy or compress together.")
            }

            Section {
                if extras.scriptFolders.isEmpty { Text("None. A script file starts with #!/bin/zsh and a line “# @raycast.title Say Hello” (or @kriya.title). Raycast's scripts work as they are.").font(.callout).foregroundStyle(.secondary) }
                ForEach(extras.scriptFolders, id: \.self) { folder in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text((folder as NSString).abbreviatingWithTildeInPath)
                            Text("\(tools.scriptFiles().filter { $0.path.hasPrefix(folder + "/") }.count) scripts found").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder)]) }.controlSize(.small)
                        Button(role: .destructive) { extras.removeScriptFolder(folder) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                    }
                }
                if let folderMessage { Text(folderMessage).font(.caption).foregroundStyle(Theme.warn) }
            } header: {
                HStack {
                    Text("Script folders")
                    Spacer()
                    Button { addScriptFolder() } label: { Label("Add Folder", systemImage: "plus") }.controlSize(.small)
                    Button { makeExampleFolder() } label: { Label("Make an Example", systemImage: "wand.and.stars") }.controlSize(.small)
                }
            } footer: {
                Text("Every file in these folders with a title line becomes a launcher command. Add “# @raycast.argument1 {\"type\":\"text\",\"placeholder\":\"Name\"}” to take what you type, “# @raycast.mode silent|compact|fullOutput” for what to show, and “# @kriya.keyword hi” so “hi name” runs it. The file must be executable or start with #!.")
            }

            Section {
                Picker("Search the web with", selection: Binding(get: { prefs.data.webEngine ?? WebSearch.defaultEngineID }, set: { prefs.setWebEngine($0) })) {
                    ForEach(WebSearch.general) { Text($0.name).tag($0.id) }
                }
            } header: { Text("Web search") } footer: {
                Text("Type anything and the last row offers to search the web for it, in your browser. Type an address like “apple.com” to open it. A short word first picks another site: “yt” YouTube, “maps” Apple Maps, “gh” GitHub, “wiki” Wikipedia, “so” Stack Overflow, “ddg” DuckDuckGo, “g” Google. Only the words you type are sent, to the site you pick, and only when you press Return.")
            }

            Section {
                if extras.quicklinks.isEmpty { Text("None. A quicklink opens a web address with what you type: “gh swift” can search GitHub.").font(.callout).foregroundStyle(.secondary) }
                ForEach(extras.quicklinks) { link in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(link.name)
                            Text(link.keyword.isEmpty ? link.template : "\(link.keyword)  ·  \(link.template)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Button("Edit") { editingLink = link }.controlSize(.small)
                        Button(role: .destructive) { extras.deleteQuicklink(link.id) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                    }
                }
            } header: {
                HStack {
                    Text("Quicklinks")
                    Spacer()
                    Button { editingLink = Quicklink(name: "", keyword: "", template: "https://") } label: { Label("Add", systemImage: "plus") }.controlSize(.small)
                }
            } footer: {
                Text("Put {query} in the address where your words go. “gh swift” with the address https://github.com/search?q={query} opens that search in your browser.")
            }

            Section {
                if extras.scripts.isEmpty { Text("None. A script is a shell command you wrote. Type its word, and anything after it arrives as $1.").font(.callout).foregroundStyle(.secondary) }
                ForEach(extras.scripts) { script in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(script.name)
                            Text(script.keyword.isEmpty ? "Found by name" : "Type “\(script.keyword)”").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Edit") { editingScript = script }.controlSize(.small)
                        Button(role: .destructive) { extras.deleteScript(script.id) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                    }
                }
            } header: {
                HStack {
                    Text("Scripts")
                    Spacer()
                    Button { editingScript = ScriptCommand(name: "", keyword: "", source: "echo \"Hello $1\"") } label: { Label("Add", systemImage: "plus") }.controlSize(.small)
                }
            } footer: {
                Text("Scripts run with zsh when you choose them, with whatever access you have. Only add ones you wrote or trust.")
            }

            Section {
                Toggle("Convert currencies", isOn: Binding(get: { prefs.data.currencyRates == true }, set: { prefs.setCurrencyRates($0) }))
                Toggle("Show my next meeting", isOn: Binding(get: { prefs.data.showMeeting == true }, set: { on in
                    prefs.setShowMeeting(on)
                    if on, !tools.meetings.isAllowed {
                        tools.meetings.requestAccess { granted in
                            calendarMessage = granted ? nil : "Calendar access was not allowed. Turn it on in System Settings › Privacy & Security › Calendars."
                            if !granted { prefs.setShowMeeting(false) }
                        }
                    }
                }))
                if let calendarMessage { Text(calendarMessage).font(.caption).foregroundStyle(Theme.warn) }
            } header: { Text("Converters and meetings") } footer: {
                Text("Type “5 km to mi”, “100 f in c”, “time in tokyo”, “3pm nyc in london”, “#ff8800”, “base64 hello”, “sha256 text”, “uuid”, “password 24”, “qr some text”. Currency (“100 usd to eur”) fetches daily reference rates from frankfurter.app and sends only the currency codes. The next meeting is read from your calendar on this Mac and shows with a Join button when it has a video link.")
            }

            Section {
                ForEach(LauncherCategory.allCases) { category in
                    Toggle(isOn: Binding(get: { prefs.data.isEnabled(category) }, set: { prefs.setEnabled(category, $0) })) {
                        VStack(alignment: .leading, spacing: 1) {
                            Label(category.title, systemImage: category.symbol)
                            if !category.detail.isEmpty { Text(category.detail).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
            } header: { Text("What it searches") } footer: {
                Text("Everything stays on this Mac. File names are looked up with Spotlight only for the words you type, and clipboard items are searched only while history is unlocked.")
            }

            Section {
                if prefs.data.pinned.isEmpty { Text("Nothing is pinned. Press ⌘P on a result to pin it; pinned results show first when the search is empty.").font(.callout).foregroundStyle(.secondary) }
                ForEach(prefs.data.pinned, id: \.self) { id in
                    HStack {
                        Text(prefs.data.titles[id] ?? id)
                        Spacer()
                        Button { prefs.movePinned(id, by: -1) } label: { Image(systemName: "arrow.up") }.buttonStyle(.borderless)
                        Button { prefs.movePinned(id, by: 1) } label: { Image(systemName: "arrow.down") }.buttonStyle(.borderless)
                        Button(role: .destructive) { prefs.unpin(id) } label: { Image(systemName: "pin.slash") }.buttonStyle(.borderless)
                    }
                }
            } header: { Text("Pinned") }

            Section {
                if prefs.data.aliases.isEmpty { Text("None. Press ⌘K on a result and choose “Give It a Short Name”, then type that word to get it first.").font(.callout).foregroundStyle(.secondary) }
                ForEach(prefs.data.aliases.sorted { $0.key < $1.key }, id: \.key) { alias, id in
                    HStack {
                        Text(alias).font(.system(.body, design: .monospaced))
                        Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                        Text(prefs.data.titles[id] ?? id)
                        Spacer()
                        Button(role: .destructive) { prefs.setAlias("", for: id) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                    }
                }
            } header: { Text("Short names") }

            Section {
                LabeledContent("Remembered choices", value: "\(prefs.data.usage.count)")
                HStack {
                    Button("Forget What I Used") { prefs.clearHistory() }
                    Button("Reset the Launcher…", role: .destructive) { confirmReset = true }
                }
            } header: { Text("What it remembers") } footer: {
                Text("It remembers which results you chose, and how often, so the ones you use most rise to the top. It never remembers clipboard text, calculator sums or file contents.")
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editingLink) { link in QuicklinkEditor(link: link) { editingLink = nil } }
        .sheet(item: $editingScript) { script in ScriptEditor(script: script) { editingScript = nil } }
        .animation(.smooth(duration: 0.2), value: prefs.data)
        .confirmationDialog("Reset the launcher?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset", role: .destructive) { prefs.reset() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Pins, short names, what you chose before and which kinds are searched go back to how they started.")
        }
    }
}

private struct QuicklinkEditor: View {
    @EnvironmentObject private var extras: LauncherExtras
    @State var link: Quicklink
    let onClose: () -> Void
    @State private var problem: String?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("Name", text: $link.name)
                TextField("Keyword (optional)", text: $link.keyword)
                TextField("Address", text: $link.template)
                if let problem { Text(problem).font(.callout).foregroundStyle(Theme.danger) }
                Text("Use {query} where what you type goes.").font(.caption).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Cancel", action: onClose).keyboardShortcut(.cancelAction)
                Button("Save") { problem = extras.save(link); if problem == nil { onClose() } }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
            .padding(12)
        }
        .frame(width: 480, height: 300)
    }
}

private struct ScriptEditor: View {
    @EnvironmentObject private var extras: LauncherExtras
    @State var script: ScriptCommand
    let onClose: () -> Void
    @State private var problem: String?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("Name", text: $script.name)
                TextField("Keyword (optional)", text: $script.keyword)
                Picker("When it finishes", selection: $script.output) { ForEach(ScriptCommand.Output.allCases) { Text($0.title).tag($0) } }
                VStack(alignment: .leading) {
                    Text("Script (zsh)").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $script.source).font(.system(.body, design: .monospaced)).frame(height: 150)
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.15)))
                }
                if let problem { Text(problem).font(.callout).foregroundStyle(Theme.danger) }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Cancel", action: onClose).keyboardShortcut(.cancelAction)
                Button("Save") { problem = extras.save(script); if problem == nil { onClose() } }.buttonStyle(.borderedProminent)
            }
            .padding(12)
        }
        .frame(width: 520, height: 470)
    }
}

private struct FallbackRow {
    let id: String
    let title: String
    let note: String?
    let on: Bool
}

extension LauncherPane {
    /// Every fallback that could be offered, those that are on first and in their order.
    fileprivate var fallbackRows: [FallbackRow] {
        let active = prefs.data.activeFallbacks
        var all: [FallbackRow] = []
        func title(_ id: String) -> (String, String?)? {
            if id == "web" { return ("Search the web", "With the site chosen below") }
            if id == "ai" { return ("Ask Apple Intelligence", "Answered on this Mac") }
            if id.hasPrefix("engine:") { return WebSearch.engines.first { $0.id == String(id.dropFirst(7)) }.map { ("Search \($0.name)", nil) } }
            if id.hasPrefix("quicklink:") { return extras.quicklinks.first { $0.id == String(id.dropFirst(10)) && $0.takesQuery }.map { ("Quicklink: \($0.name)", $0.template) } }
            if id.hasPrefix("script:") { return extras.scripts.first { $0.id == String(id.dropFirst(7)) }.map { ("Script: \($0.name)", nil) } }
            return nil
        }
        for id in active { if let (name, note) = title(id) { all.append(FallbackRow(id: id, title: name, note: note, on: true)) } }
        var offered = ["web", "ai"] + WebSearch.general.map { "engine:\($0.id)" }
        offered += extras.quicklinks.filter(\.takesQuery).map { "quicklink:\($0.id)" } + extras.scripts.map { "script:\($0.id)" }
        for id in offered where !active.contains(id) { if let (name, note) = title(id) { all.append(FallbackRow(id: id, title: name, note: note, on: false)) } }
        return all
    }

    fileprivate func setFallback(_ id: String, _ on: Bool) {
        var list = prefs.data.activeFallbacks
        if on { if !list.contains(id) { list.append(id) } } else { list.removeAll { $0 == id } }
        prefs.setFallbacks(list)
    }

    fileprivate func moveFallback(_ id: String, _ delta: Int) {
        var list = prefs.data.activeFallbacks
        guard let index = list.firstIndex(of: id) else { return }
        let target = min(max(index + delta, 0), list.count - 1)
        list.remove(at: index)
        list.insert(id, at: target)
        prefs.setFallbacks(list)
    }

    fileprivate func addScriptFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Add"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        folderMessage = extras.addScriptFolder(url.path)
    }

    /// A folder in Application Support with one working script, added, so there is something to look at and copy.
    fileprivate func makeExampleFolder() {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Kriya/Scripts", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("hello.sh")
            if !FileManager.default.fileExists(atPath: file.path) {
                try """
                #!/bin/zsh

                # @raycast.schemaVersion 1
                # @raycast.title Say Hello
                # @raycast.mode compact
                # @raycast.packageName Examples
                # @raycast.argument1 { "type": "text", "placeholder": "Name", "optional": true }
                # @kriya.keyword hi

                echo "Hello, ${1:-world}!"
                """.write(to: file, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
            }
            folderMessage = extras.addScriptFolder(folder.path)
            if folderMessage == "That folder is already added." { folderMessage = nil }
        } catch {
            folderMessage = "The example could not be made: \(error.localizedDescription)"
        }
    }
}
