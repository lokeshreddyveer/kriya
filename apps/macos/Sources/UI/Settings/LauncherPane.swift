import SwiftUI

/// The launcher: what it searches, what is pinned, short names, and what it remembers.
struct LauncherPane: View {
    @EnvironmentObject private var prefs: LauncherPrefs
    @EnvironmentObject private var keyboard: KeyboardStore
    @State private var confirmReset = false

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
        .animation(.smooth(duration: 0.2), value: prefs.data)
        .confirmationDialog("Reset the launcher?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset", role: .destructive) { prefs.reset() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Pins, short names, what you chose before and which kinds are searched go back to how they started.")
        }
    }
}
