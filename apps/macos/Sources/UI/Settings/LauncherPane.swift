import SwiftUI

/// The launcher: what it searches, what is pinned, short names, and what it remembers.
struct LauncherPane: View {
    @EnvironmentObject private var prefs: LauncherPrefs
    @EnvironmentObject private var keyboard: KeyboardStore
    @EnvironmentObject private var extras: LauncherExtras
    @EnvironmentObject private var tools: LauncherToolSources
    @State private var confirmReset = false
    @State private var pendingRemoval: PendingRemoval?
    @State private var why: (query: String, rows: [LauncherEngine.Explanation])?
    @State private var speed = LauncherLatencyStore.shared.snapshot
    @ObservedObject private var linkChecker = LinkChecker.shared
    @State private var editingLink: Quicklink?
    @State private var editingScript: ScriptCommand?
    @State private var editingAPI: APICommand?
    @ObservedObject private var approvals = LauncherApprovals.shared
    @State private var spotlightStatus = "Checking the Spotlight index…"
    @ObservedObject private var history = SearchHistoryStore.shared
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
                Button("Explain the Last Search") { why = LauncherWhy.shared.explainAll() }.controlSize(.small)
                if let why {
                    if why.rows.isEmpty { Text("Search in the launcher first, then come back and press the button.").font(.callout).foregroundStyle(.secondary) }
                    else { Text("For “\(why.query)”").font(.caption).foregroundStyle(.secondary) }
                    ForEach(Array(why.rows.enumerated()), id: \.offset) { _, row in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.title)
                            Text(row.lines.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: { Text("Why was this shown?") }
            Section {
                if speed.stats.isEmpty { Text("Search in the launcher first, then press Refresh.").font(.callout).foregroundStyle(.secondary) }
                ForEach(speed.stats.sorted { $0.value.average > $1.value.average }, id: \.key) { name, stat in
                    HStack {
                        Text(name)
                        if speed.isSlow(name) { Text("slow").font(.caption).foregroundStyle(Theme.warn) }
                        Spacer()
                        Text("\(Int(stat.average.rounded())) ms average · worst \(stat.worst) ms").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                Button("Refresh") { speed = LauncherLatencyStore.shared.snapshot }.controlSize(.small)
            } header: { Text("How fast each source answers") } footer: { Text("Measured on this Mac while you search, kept in memory only. A source that is slow slows every search.") }
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
                Text("Drag the launcher by its search bar, its headings or its bottom strip and it opens where you leave it, on whichever display that was. “At the pointer” opens it under the pointer. “In the middle” puts the search bar at the centre of the screen with results opening below it. The bottom choices put the search bar at the bottom with results opening upward.")
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
                            Button { moveFallback(row.id, -1) } label: { Image(systemName: "arrow.up") }.accessibilityLabel("Move up").buttonStyle(.borderless)
                            Button { moveFallback(row.id, 1) } label: { Image(systemName: "arrow.down") }.accessibilityLabel("Move down").buttonStyle(.borderless)
                        }
                    }
                }
            } header: { Text("Fallbacks") } footer: {
                Text("Whatever you type is offered to these, in this order, under “Search with”, a few rows down, and Return on one opens it in your browser. Press ⌘K on one for the other sites. They need “Web” turned on under the kinds of result above. Turn on Apple Intelligence to ask it, or a quicklink or script to send the text there.")
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
                Toggle("Read requests typed in plain words", isOn: Binding(get: { prefs.data.interpretsRequests }, set: { prefs.setInterpretRequests($0) }))
                Toggle("Understand natural-language requests", isOn: Binding(get: { prefs.data.understandsRequests }, set: { prefs.setUnderstandRequests($0) }))
                    .disabled(!prefs.data.interpretsRequests || LocalOnly.isOn)
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
                Text("Plain-word requests (“mute Spotify for an hour”, “move this window to the left half”, “set a timer for 20 minutes”, “find PDFs from last week”) are read on this Mac with fixed patterns and shown as one row with what it understood and whether it asks first. Anything that deletes, installs, changes where all sound plays or runs a script asks before it runs. “Understand natural-language requests” adds a row, for requests the patterns cannot read, that sends the request (secrets hidden first, never while you type, never in Local-only mode) to your AI provider and shows its answer for approval before anything happens; start a request with ? to use it once. Requests are never kept in search history. Select text in any app and press the shortcut: the launcher opens with things to do with it (summarize, change case, search, convert, open). With nothing selected it uses the clipboard. Type a path starting with / or ~ to browse folders: Tab goes into a folder, Shift-Tab goes up, and ⌘K › Add to the File Buffer collects files to move, copy or compress together.")
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
                        Button(role: .destructive) { extras.removeScriptFolder(folder) } label: { Image(systemName: "trash") }.accessibilityLabel("Stop using the script folder \((folder as NSString).lastPathComponent)").buttonStyle(.borderless)
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
                            Text(link.example).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                            if let health = linkChecker.results[link.id] {
                                Text(health.summary).font(.caption).foregroundStyle(health.isProblem ? Theme.warn : Theme.ok)
                            }
                        }
                        Spacer()
                        Button("Test") { if let url = link.testURL { NSWorkspace.shared.open(url) } }.controlSize(.small).disabled(link.testURL == nil)
                            .help("Opens this link in your browser with the words “kriya test”")
                        Button("Edit") { editingLink = link }.controlSize(.small)
                        Button(role: .destructive) { pendingRemoval = PendingRemoval(title: "Delete the quicklink “\(link.name)”?") { extras.deleteQuicklink(link.id) } } label: { Image(systemName: "trash") }.accessibilityLabel("Delete the quicklink \(link.name)").buttonStyle(.borderless)
                    }
                }
            } header: {
                HStack {
                    Text("Quicklinks")
                    Spacer()
                    if linkChecker.running { ProgressView().controlSize(.small) }
                    Button("Check Links") { linkChecker.check(extras.quicklinks) }.controlSize(.small).disabled(linkChecker.running || extras.quicklinks.isEmpty)
                        .help("Asks each link's site once whether it still answers. Nothing is opened.")
                    Button { editingLink = Quicklink(name: "", keyword: "", template: "https://") } label: { Label("Add", systemImage: "plus") }.controlSize(.small)
                }
            } footer: {
                Text("Put {query} in the address where your words go: “gh swift” with https://github.com/search?q={query} opens that search. {clipboard} and {selection} fill in from the clipboard or the selected text, so typing just the keyword is enough. Test opens the link with the words “kriya test”.")
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
                        Button(role: .destructive) { pendingRemoval = PendingRemoval(title: "Delete the script “\(script.name)”?") { extras.deleteScript(script.id) } } label: { Image(systemName: "trash") }.accessibilityLabel("Delete the script \(script.name)").buttonStyle(.borderless)
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
                if extras.apiCommands.isEmpty { Text("None. An API command sends a web request that you define and shows part of the answer, such as the weather for a city you type.").font(.callout).foregroundStyle(.secondary) }
                ForEach(extras.apiCommands) { command in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(command.name)
                            Text("Type “\(command.keyword)\(command.takesQuery ? " …" : "")”  ·  \(command.method.rawValue) \(command.host ?? "")").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Button("Edit") { editingAPI = command }.controlSize(.small)
                        Button(role: .destructive) { pendingRemoval = PendingRemoval(title: "Delete the API command “\(command.name)”?") { extras.deleteAPICommand(command.id) } } label: { Image(systemName: "trash") }.accessibilityLabel("Delete the API command \(command.name)").buttonStyle(.borderless)
                    }
                }
            } header: {
                HStack {
                    Text("API commands")
                    Spacer()
                    Button { editingAPI = APICommand(name: "", keyword: "", url: "https://") } label: { Label("Add", systemImage: "plus") }.controlSize(.small)
                }
            } footer: {
                Text("Type the keyword, then your words; they go into {query} in the address or body and nowhere else, and only when you press Return. Keys in headers are kept in the keychain. Only https:// addresses are used (http:// for localhost).")
            }

            Section {
                Toggle("Search 1Password logins", isOn: Binding(get: { prefs.data.searchPasswords == true }, set: { prefs.setSearchPasswords($0) }))
                    .disabled(!OnePasswordIndex.shared.isInstalled)
                if !OnePasswordIndex.shared.isInstalled { Text("Needs the 1Password command-line tool: brew install 1password-cli, then turn on “Integrate with 1Password CLI” in 1Password › Settings › Developer.").font(.caption).foregroundStyle(.secondary) }
                if let problem = OnePasswordIndex.shared.lastProblem { Text(problem).font(.caption).foregroundStyle(Theme.warn) }
            } header: { Text("Password manager") } footer: {
                Text("Finds logins by name, user name or address. Return copies the password; ⌘K offers the user name, the one-time code and the website. Kriya only ever holds the list of names. A password is fetched when you copy it, 1Password asks for Touch ID itself, the copy is marked secret and leaves the clipboard after 30 seconds.")
            }

            Section {
                ForEach(prefs.data.fileSearchExcluded ?? [], id: \.self) { folder in
                    HStack {
                        Text((folder as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button(role: .destructive) { prefs.setFileSearchExcluded((prefs.data.fileSearchExcluded ?? []).filter { $0 != folder }) } label: { Image(systemName: "trash") }.accessibilityLabel("Include \((folder as NSString).lastPathComponent) in file search again").buttonStyle(.borderless)
                    }
                }
                Button {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = false
                    panel.canChooseDirectories = true
                    panel.prompt = "Leave Out"
                    if panel.runModal() == .OK, let url = panel.url { prefs.setFileSearchExcluded((prefs.data.fileSearchExcluded ?? []) + [url.path]) }
                } label: { Label("Leave a Folder Out of File Search…", systemImage: "plus") }
                HStack {
                    Text(spotlightStatus).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                    Spacer()
                    Button("Spotlight Settings…") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Spotlight-Settings.extension")!) }.controlSize(.small)
                }
            } header: { Text("File search") } footer: {
                Text("File results come from the Spotlight index. Folders left out here never show in the launcher, even when Spotlight has them. To change what Spotlight indexes at all, use its own settings.")
            }
            .onAppear { loadSpotlightStatus() }

            ExtensionsSection()

            Section {
                Toggle("Ask before a script or API command runs for the first time", isOn: $approvals.asksFirst)
                ForEach(approvals.approved) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.label)
                            Text("\(item.kind) · approved \(item.at.shortDescription)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Revoke") { approvals.revoke(item.fingerprint) }.controlSize(.small)
                    }
                }
                if !approvals.approved.isEmpty { Button("Revoke All", role: .destructive) { approvals.revokeAll() }.controlSize(.small) }
            } header: { Text("Approvals") } footer: {
                Text("A script or API command is shown to you, exactly as it will run, the first time. If it changes, you are asked again. Nothing the launcher shows ever runs by itself.")
            }

            Section {
                Toggle("Search open browser tabs", isOn: Binding(get: { prefs.data.searchBrowserTabs == true }, set: { prefs.setSearchBrowserTabs($0) }))
            } header: { Text("Browser tabs") } footer: {
                Text("Finds tabs by title or address in Safari, Chrome, Brave, Edge and Arc, and brings the one you choose to the front. It asks each running browser for its tab list with AppleScript, so macOS asks you to allow Kriya to control each browser the first time. Only titles and addresses are read, only while the launcher is open, and nothing is stored.")
            }

            Section {
                Toggle("Keep a history of what I search for", isOn: Binding(get: { history.isEnabled }, set: { history.isEnabled = $0 }))
                if history.isEnabled {
                    if history.history.entries.isEmpty { Text("Nothing yet.").font(.callout).foregroundStyle(.secondary) }
                    ForEach(history.history.recent(30)) { item in
                        HStack {
                            Text(item.text).lineLimit(1)
                            if item.count > 1 { Text("×\(item.count)").font(.caption).foregroundStyle(.tertiary) }
                            Spacer()
                            Text(RelativeDateTimeFormatter().localizedString(for: item.last, relativeTo: Date())).font(.caption).foregroundStyle(.secondary)
                            Button(role: .destructive) { history.remove(item.id) } label: { Image(systemName: "xmark.circle") }.accessibilityLabel("Remove “\(item.text)” from the history").buttonStyle(.borderless)
                        }
                    }
                    if !history.history.entries.isEmpty { Button("Clear the History…", role: .destructive) { pendingRemoval = PendingRemoval(title: "Clear the search history?") { history.clear() } } }
                }
            } header: { Text("Search history") } footer: {
                Text("Off unless you turn it on, because it keeps the words you type. When on, the words are saved on this Mac after you choose a result, shown under “Recent searches” when the box is empty, and ⌥↑ and ⌥↓ step through them. Clipboard searches and anything that looks like a key are never saved. Turning it off erases it.")
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
                        Button { prefs.movePinned(id, by: -1) } label: { Image(systemName: "arrow.up") }.accessibilityLabel("Move up").buttonStyle(.borderless)
                        Button { prefs.movePinned(id, by: 1) } label: { Image(systemName: "arrow.down") }.accessibilityLabel("Move down").buttonStyle(.borderless)
                        Button(role: .destructive) { prefs.unpin(id) } label: { Image(systemName: "pin.slash") }.accessibilityLabel("Unpin \(prefs.data.titles[id] ?? id)").buttonStyle(.borderless)
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
                        Button(role: .destructive) { prefs.setAlias("", for: id) } label: { Image(systemName: "trash") }.accessibilityLabel("Delete the short name \(alias)").buttonStyle(.borderless)
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
        .confirmationDialog(pendingRemoval?.title ?? "", isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) { pendingRemoval?.action(); pendingRemoval = nil }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: { Text("This cannot be undone.") }
        .sheet(item: $editingLink) { link in QuicklinkEditor(link: link) { editingLink = nil } }
        .sheet(item: $editingScript) { script in ScriptEditor(script: script) { editingScript = nil } }
        .sheet(item: $editingAPI) { command in APICommandEditor(command: command) { editingAPI = nil } }
        .animation(.smooth(duration: 0.2), value: prefs.data)
        .confirmationDialog("Reset the launcher?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset", role: .destructive) { prefs.reset() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Pins, short names, what you chose before and which kinds are searched go back to how they started.")
        }
    }
}

extension LauncherPane {
    /// What `mdutil` says about the index of the main volume, in a line. Reading it needs no administrator.
    fileprivate func loadSpotlightStatus() {
        DispatchQueue.global(qos: .utility).async {
            let output = (try? ToolRunner.run("/usr/bin/mdutil", ["-s", "/System/Volumes/Data"], timeout: 6)) ?? ""
            let line = Self.describeSpotlight(output)
            DispatchQueue.main.async { spotlightStatus = line }
        }
    }

    static func describeSpotlight(_ output: String) -> String {
        let lower = output.lowercased()
        if lower.contains("indexing enabled") { return "Spotlight indexing is on for this Mac." }
        if lower.contains("indexing disabled") { return "Spotlight indexing is off for this Mac, so file results will be missing. Turn it on in Spotlight settings." }
        return "The Spotlight index could not be read."
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
                Text("Use {query} where what you type goes, or {clipboard} / {selection} for the clipboard or selected text.").font(.caption).foregroundStyle(.secondary)
                if link.problem == nil { Text(link.example).font(.caption).foregroundStyle(.secondary) }
                if let url = link.testURL {
                    Text(url.absoluteString).font(.caption.monospaced()).foregroundStyle(.tertiary).lineLimit(2).textSelection(.enabled)
                    Button("Test in Browser") { NSWorkspace.shared.open(url) }.controlSize(.small)
                }
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
        .frame(width: 480, height: 380)
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

private struct PendingRemoval {
    let title: String
    let action: () -> Void
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

private struct APICommandEditor: View {
    @EnvironmentObject private var extras: LauncherExtras
    @State var command: APICommand
    let onClose: () -> Void
    @State private var problem: String?
    @State private var headerValues: [String: String] = [:]
    @State private var newHeader = ""
    @State private var testing = false
    @State private var testResult: String?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("Name", text: $command.name)
                TextField("Keyword", text: $command.keyword)
                Picker("Method", selection: $command.method) { ForEach(APICommand.Method.allCases) { Text($0.rawValue).tag($0) } }
                TextField("Address", text: $command.url, prompt: Text("https://api.example.com/search?q={query}"))
                Section("Headers") {
                    ForEach(command.headerNames, id: \.self) { name in
                        HStack {
                            Text(name).frame(width: 130, alignment: .leading)
                            if APICommand.looksSecret(name) {
                                SecureField("Value", text: binding(for: name))
                            } else {
                                TextField("Value", text: binding(for: name))
                            }
                            Button(role: .destructive) { command.headerNames.removeAll { $0 == name }; headerValues[name] = nil } label: { Image(systemName: "minus.circle") }.accessibilityLabel("Remove the \(name) header").buttonStyle(.borderless)
                        }
                    }
                    HStack {
                        TextField("Add a header, such as Authorization", text: $newHeader).onSubmit(addHeader)
                        Button("Add", action: addHeader).disabled(!APICommand.isHeaderName(newHeader.trimmingCharacters(in: .whitespaces)))
                    }
                }
                if command.method.sendsBody {
                    VStack(alignment: .leading) {
                        Text("Body (JSON). {query} is your words, escaped for JSON text.").font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $command.body).font(.system(.callout, design: .monospaced)).frame(height: 70)
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.15)))
                    }
                }
                TextField("Use this part of the answer", text: $command.resultPath, prompt: Text("data.items.0.name  (empty: all of it)"))
                Picker("Then", selection: $command.output) { ForEach(APICommand.Output.allCases) { Text($0.title).tag($0) } }
                Toggle("Show the answer first and ask before using it", isOn: Binding(get: { command.previewFirst == true }, set: { command.previewFirst = $0 }))
                if let problem { Text(problem).font(.callout).foregroundStyle(Theme.danger) }
                if let testResult { Text(testResult).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(6) }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Button(testing ? "Calling…" : "Try It with “test”") { test() }.disabled(testing || command.problem != nil)
                Spacer()
                Button("Cancel", action: onClose).keyboardShortcut(.cancelAction)
                Button("Save") { save() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
            .padding(12)
        }
        .frame(width: 560, height: 640)
        .onAppear { headerValues = APICommandRunner.headerValues(for: command) }
    }

    private func binding(for name: String) -> Binding<String> {
        Binding(get: { headerValues[name] ?? "" }, set: { headerValues[name] = $0 })
    }

    private func addHeader() {
        let name = newHeader.trimmingCharacters(in: .whitespaces)
        guard APICommand.isHeaderName(name), !command.headerNames.contains(name), command.headerNames.count < APICommand.maxHeaders else { return }
        command.headerNames.append(name)
        newHeader = ""
    }

    private func save() {
        problem = extras.save(command)
        guard problem == nil else { return }
        // The keys go to the keychain; only their names are kept with the command.
        for name in command.headerNames { KeychainSecrets.set(headerValues[name] ?? "", for: APICommandRunner.account(command, header: name)) }
        onClose()
    }

    private func test() {
        guard !LocalOnly.isOn else { testResult = LocalOnly.blockedMessage; return }
        guard let request = command.request(for: "test", headerValues: headerValues) else { testResult = "The address could not be built."; return }
        if command.method.sendsBody || request.httpMethod?.uppercased() != "GET" {
            // A test is a real request: one that writes or deletes on the other side must be agreed to first.
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Send a real \(request.httpMethod ?? "") request?"
            alert.informativeText = "Trying it calls \(request.url?.host ?? "the server") for real, with the word “test”. A \(request.httpMethod ?? "") request can change or delete something there."
            alert.addButton(withTitle: "Send It")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        testing = true
        testResult = nil
        let path = command.resultPath
        Task {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                let text = data.count > APICommand.maxResponseBytes ? "Too big." : (JSONResult.extract(data, path: path) ?? (path.isEmpty ? "No text in the answer." : "The answer has no “\(path)”."))
                await MainActor.run { testResult = "\(status): " + String(text.prefix(400)); testing = false }
            } catch {
                await MainActor.run { testResult = error.localizedDescription; testing = false }
            }
        }
    }
}


/// Signed extension bundles: install from a folder, switch on, remove, and sign one's own.
private struct ExtensionsSection: View {
    @ObservedObject private var catalog = ExtensionCatalog.shared
    @State private var message: String?

    var body: some View {
        Section {
            if catalog.installed.isEmpty { Text("No extensions are installed.").font(.callout).foregroundStyle(.secondary) }
            ForEach(catalog.installed) { ext in
                HStack(alignment: .top) {
                    Toggle(ext.manifest.name, isOn: Binding(get: { ext.enabled }, set: { catalog.setEnabled(ext.id, $0) })).labelsHidden().toggleStyle(.switch).controlSize(.small)
                        .accessibilityLabel("Turn \(ext.manifest.name) on")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(ext.manifest.name)  \(ext.manifest.version)").font(.headline)
                        Text("\(ext.manifest.author) · \(ext.manifest.commands.count) command\(ext.manifest.commands.count == 1 ? "" : "s")" + (ext.manifest.permissions.isEmpty ? "" : " · " + ext.manifest.permissions.map(\.title).joined(separator: ", ")))
                            .font(.caption).foregroundStyle(.secondary)
                        if let summary = ext.manifest.summary { Text(summary).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    Button(role: .destructive) { catalog.uninstall(ext.id) } label: { Image(systemName: "trash") }.buttonStyle(.borderless).accessibilityLabel("Remove \(ext.manifest.name)")
                }
            }
            HStack {
                Button("Install from a Folder…") { install() }
                if let message { Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
            }
            ForEach(catalog.trusted.sorted { $0.key < $1.key }, id: \.key) { fingerprint, name in
                HStack {
                    VStack(alignment: .leading, spacing: 1) { Text(name); Text(fingerprint).font(.caption.monospaced()).foregroundStyle(.secondary) }
                    Spacer()
                    Button("Stop Trusting") { catalog.untrust(fingerprint) }.controlSize(.small)
                }
            }
            DisclosureGroup("Publish your own") {
                if catalog.hasSigningKey {
                    LabeledContent("Your key", value: catalog.signingFingerprint ?? "?")
                    Button("Sign a Folder…") { signFolder() }
                } else {
                    Button("Make a Signing Key") { if !catalog.createSigningKey() { message = "The key could not be saved in the Keychain." } }
                }
                Text("Put a manifest.json (id, name, version, author, commands) and the scripts in a folder, then sign it. Signing lists every file with its hash and signs the lot with your key, so anyone installing it can tell it is yours and unchanged.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } header: { Text("Extensions") } footer: {
            Text("An extension is a signed folder of scripts that adds commands to the launcher. Kriya checks the signature and every file before installing, asks you to trust the publisher by their key's fingerprint, installs it switched off, checks it again before each run, and asks before the first run of each command. Scripts run with your access to this Mac, so install only ones you have read or trust.")
        }
    }

    private func install() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = "Check"
        panel.message = "Choose the extension's folder."
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        do {
            let candidate = try catalog.inspect(folder)
            let alert = NSAlert()
            let m = candidate.manifest
            alert.messageText = "Install “\(m.name)” \(m.version)?"
            alert.informativeText = """
            Publisher: \(m.author)
            Key fingerprint: \(candidate.fingerprint)\(candidate.publisherTrusted ? " (trusted)" : " (not trusted yet)")
            \(candidate.installedVersion.map { "Replaces version \($0).\n" } ?? "")
            Commands: \(m.commands.map(\.title).joined(separator: ", "))
            May: \(m.permissions.isEmpty ? "nothing beyond running its commands" : m.permissions.map(\.title).joined(separator: ", "))

            It is installed switched off. Only trust the key if you have checked the fingerprint with its publisher.
            """
            alert.addButton(withTitle: candidate.publisherTrusted ? "Install" : "Trust Publisher and Install")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            if !candidate.publisherTrusted { catalog.trust(fingerprint: candidate.fingerprint, name: m.author) }
            try catalog.install(candidate)
            message = "Installed. Switch it on to use its commands."
        } catch {
            message = error.localizedDescription
        }
    }

    private func signFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = "Sign"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        do { try catalog.sign(folder: folder); message = "Signed \(folder.lastPathComponent)." } catch { message = error.localizedDescription }
    }
}
