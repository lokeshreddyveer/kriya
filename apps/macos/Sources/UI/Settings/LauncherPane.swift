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

    private var config: KeyboardConfig { keyboard.config }

    var body: some View {
        Form {
            Section {
                LabeledContent("Shortcut") {
                    ShortcutRecorder(shortcut: Binding(
                        get: { config.paletteKey.map { RecordedShortcut(keyCode: $0, modifiers: config.paletteModifiers) } },
                        set: { new in keyboard.updateConfig { $0.paletteKey = new?.keyCode; $0.paletteModifiers = new?.modifiers ?? 0 } }
                    )).frame(width: 190, height: 26)
                }
            } header: { Text("Open it") } footer: {
                Text("The search in the menu-bar window uses the same results. In the launcher: ↑ ↓ to move, Return to open, ⌘K for more things to do with a result, ⌘P to pin it, ⌘1 to ⌘9 to open one directly.")
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
