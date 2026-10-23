import AppKit
import SafariServices
import SwiftUI

/// Where a link is sent: which browser, and which of its profiles. Used for the fallback and for each rule.
private struct LinkTargetPicker: View {
    @Binding var target: LinkTarget
    private let browsers = Browsers.installed()

    private enum Kind: String, CaseIterable, Identifiable {
        case open = "Open in a browser", ask = "Ask which browser", copy = "Copy the link"
        var id: String { rawValue }
    }

    private var kind: Binding<Kind> {
        Binding(
            get: {
                switch target {
                case .open: return .open
                case .ask: return .ask
                case .copy: return .copy
                }
            },
            set: { new in
                switch new {
                case .open: target = .open(appId: browserID.isEmpty ? (browsers.first { $0.id == "com.apple.Safari" }?.id ?? browsers.first?.id ?? "") : browserID, profile: nil)
                case .ask: target = .ask
                case .copy: target = .copy
                }
            }
        )
    }

    private var browserID: String {
        if case .open(let id, _) = target { return id }
        return ""
    }

    private var profileID: String {
        if case .open(_, let profile) = target { return profile ?? "" }
        return ""
    }

    var body: some View {
        Picker("Then", selection: kind) {
            ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
        }
        if case .open = target {
            Picker("Browser", selection: Binding(get: { browserID }, set: { target = .open(appId: $0, profile: nil) })) {
                if !browsers.contains(where: { $0.id == browserID }) { Text(browserID.isEmpty ? "Choose…" : AppChoice.name(for: browserID)).tag(browserID) }
                ForEach(browsers) { Text($0.name).tag($0.id) }
            }
            let profiles = Browsers.profiles(for: browserID)
            if !profiles.isEmpty {
                Picker("Profile", selection: Binding(get: { profileID }, set: { target = .open(appId: browserID, profile: $0.isEmpty ? nil : $0) })) {
                    Text("Browser's choice").tag("")
                    ForEach(profiles) { Text($0.name).tag($0.id) }
                }
            }
        }
    }
}

/// Link routing: which browser opens each link, with rules by site, by the app the link came from and by keys held.
struct LinksPane: View {
    @EnvironmentObject private var store: LinkRoutingStore
    @State private var tab: Tab = .rules

    enum Tab: String, CaseIterable, Identifiable {
        case rules = "Rules", options = "Options", browsers = "Browsers", log = "Log & Test"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) { ForEach(Tab.allCases) { Text($0.rawValue).tag($0) } }
                .paneTabBar(maxWidth: 420)
                .paneHeader()
            Group {
                switch tab {
                case .rules: RulesTab()
                case .options: OptionsTab()
                case .browsers: BrowsersTab()
                case .log: LogTab()
                }
            }
            .id(tab)
            .transition(.opacity)
        }
        .animation(.smooth(duration: 0.22), value: tab)
    }
}

// MARK: - Browser extensions

/// Connecting a browser extension to Kriya: one file per browser tells it how to start the host, and the extension itself is
/// loaded from a folder.
private struct BrowsersTab: View {
    @EnvironmentObject private var bridge: BrowserBridge
    @EnvironmentObject private var safari: SafariInboxWatcher
    @State private var browsers = NativeHostInstaller.installedBrowsers()
    @State private var installed = Set<String>()
    @State private var folder: URL?
    @State private var message: String?

    private var executable: String { Bundle.main.executablePath ?? "" }

    var body: some View {
        Form {
            Section {
                Text("With the extension, a right-click on a link, a page or some selected text can send it to Kriya. A link goes through your rules, so it opens in the browser and profile you chose. Selected text opens the selection bar. The extension reads no page content, uses no network and loads no code.")
                    .font(.callout).foregroundStyle(.secondary)
            } header: { Text("Kriya in your browser") }

            Section {
                if browsers.isEmpty { Text("No supported browser was found.").foregroundStyle(.secondary) }
                ForEach(browsers) { browser in
                    HStack {
                        Image(systemName: installed.contains(browser.id) ? "checkmark.circle.fill" : "circle.dashed")
                            .foregroundStyle(installed.contains(browser.id) ? Theme.ok : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(browser.name)
                            Text(installed.contains(browser.id) ? "Connection installed" : "Not connected").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if installed.contains(browser.id) {
                            Button("Remove") { NativeHostInstaller.remove(browser); refresh() }.controlSize(.small)
                        } else {
                            Button("Install Connection") { install(browser) }.controlSize(.small)
                        }
                    }
                }
            } header: { Text("Step 1: connect a browser") } footer: {
                Text("This writes one small file in that browser's own folder, naming Kriya as the program it may start and the one extension allowed to use it. Nothing else is changed.")
            }

            Section {
                HStack {
                    Button("Show the Extension Folder") { showFolder() }
                    Spacer()
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Chrome, Edge, Brave, Vivaldi: open chrome://extensions, turn on Developer mode, choose Load unpacked, and pick the “chromium” folder.")
                    Text("Firefox: open about:debugging, choose This Firefox, Load Temporary Add-on, and pick the manifest.json in the “firefox” folder. Firefox only keeps it permanently once Mozilla has signed it, which has not been done.")
                    Text("Safari: switch on “Safari extension” below, then enable Kriya in Safari › Settings › Extensions and allow it on the sites you choose.")
                }
                .font(.callout).foregroundStyle(.secondary)
            } header: { Text("Step 2: load the extension") }

            Section {
                Toggle("Safari extension", isOn: $safari.enabled)
                HStack {
                    Button("Open Safari Extension Settings") {
                        SFSafariApplication.showPreferencesForExtension(withIdentifier: "com.kriya.app.safari") { error in
                            if error != nil { DispatchQueue.main.async { message = "Safari could not show the extension. Open Safari › Settings › Extensions." } }
                        }
                    }
                    Spacer()
                    Text("Handled \(safari.handled)\(safari.refused > 0 ? " · refused \(safari.refused)" : "")").font(.caption).foregroundStyle(.secondary)
                }
            } header: { Text("Safari") } footer: {
                Text("Safari asks you which sites the extension may use, and reads a page only when you choose a Kriya item for it in the right-click menu. The extension cannot reach the network or start programs. It leaves each request as a small file in a folder only you can read, and Kriya checks it and deletes it.")
            }

            Section {
                LabeledContent("Requests handled", value: "\(bridge.handled)")
                if bridge.refused > 0 { LabeledContent("Refused", value: "\(bridge.refused)") }
                if let last = bridge.lastRequest { LabeledContent("Last request", value: last.shortDescription) }
                else { Text("Nothing has come from a browser yet.").font(.callout).foregroundStyle(.secondary) }
            } header: { Text("Activity") } footer: {
                Text("Only the count and time are kept. What was sent is never written down.")
            }

            if let message {
                Section { Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.danger).transition(.opacity) }
            }
        }
        .formStyle(.grouped)
        .animation(.smooth(duration: 0.2), value: message)
        .onAppear { refresh() }
    }

    private func refresh() {
        browsers = NativeHostInstaller.installedBrowsers()
        installed = Set(browsers.filter { NativeHostInstaller.isInstalled($0, executable: executable) }.map(\.id))
    }

    private func install(_ browser: BrowserChoice) {
        do {
            try NativeHostInstaller.install(browser, executable: executable)
            message = nil
        } catch {
            message = "Could not connect \(browser.name): \(error.localizedDescription)"
        }
        refresh()
    }

    private func showFolder() {
        guard let target = NativeHostInstaller.prepareExtensions(into: AppPaths.live.support) else {
            message = "The extension files could not be found in this copy of Kriya."
            return
        }
        message = nil
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }
}

// MARK: - Rules

private struct RulesTab: View {
    @EnvironmentObject private var store: LinkRoutingStore
    @State private var editing: LinkRule?
    @State private var isDefault = false
    @State private var message: String?
    private let ticker = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                Toggle("Route links with Kriya", isOn: Binding(get: { store.config.enabled }, set: { v in store.update { $0.enabled = v } }))
                HStack {
                    StateBadge(text: isDefault ? "Kriya is your default browser" : "Kriya is not your default browser", color: isDefault ? Theme.ok : Theme.warn)
                    Spacer()
                    Button("Make Kriya the Default Browser") { makeDefault() }.disabled(isDefault)
                    Button("Open Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension") { NSWorkspace.shared.open(url) }
                    }
                }
                if let message { Text(message).font(.callout).foregroundStyle(.secondary) }
            } header: { Text("Link routing") } footer: {
                Text("Links only reach Kriya while it is your default browser. Kriya then opens each one where your rules say; a link is never lost: anything that cannot be done opens in Safari. Turning this off sends every link to the browser below, untouched.")
            }

            Section {
                LinkTargetPicker(target: Binding(get: { store.config.fallback }, set: { v in store.update { $0.fallback = v } }))
            } header: { Text("When no rule matches") }

            Section {
                if store.config.rules.isEmpty {
                    Text("No rules yet. A rule sends links that match a site, an address or a source app to a chosen browser and profile.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(store.config.rules) { rule in row(rule) }
                    .onMove { store.move(from: $0, to: $1) }
            } header: {
                HStack {
                    Text("Rules")
                    Spacer()
                    Menu {
                        Button("Add Experimental App Rules (Zoom, Figma, Notion, Spotify, Discord, Linear)") {
                            let have = Set(store.config.rules.map(\.id))
                            store.update { $0.rules.append(contentsOf: suggestedLinkRules().filter { !have.contains($0.id) }) }
                        }
                    } label: { MoreMenuLabel() }.menuStyle(.button).menuIndicator(.hidden).fixedSize().controlSize(.small)
                    Button { editing = store.newRule() } label: { Label("Add Rule", systemImage: "plus") }.controlSize(.small)
                }
            } footer: {
                Text("The first rule that matches wins, so put the specific ones first. Drag to reorder.")
            }

            if let error = store.lastError {
                Section { Text(error).font(.callout).foregroundStyle(Theme.danger) }
            }
        }
        .formStyle(.grouped)
        .animation(.smooth(duration: 0.25), value: store.config.rules)
        .sheet(item: $editing) { rule in
            LinkRuleEditor(rule: rule, onSave: { store.upsert($0); editing = nil }, onCancel: { editing = nil })
        }
        .onAppear { isDefault = Self.kriyaIsDefault() }
        .onReceive(ticker) { _ in isDefault = Self.kriyaIsDefault() }
    }

    private func row(_ rule: LinkRule) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { rule.enabled }, set: { on in var copy = rule; copy.enabled = on; store.upsert(copy) }))
                .labelsHidden().toggleStyle(.switch).controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text(rule.name)
                Text(summary(rule)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button("Edit") { editing = rule }.controlSize(.small)
            Button { store.delete(rule.id) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
        }
    }

    private func summary(_ rule: LinkRule) -> String {
        let kind: String
        switch rule.matchKind {
        case .domain: kind = "Site"
        case .prefix: kind = "Starts with"
        case .contains: kind = "Contains"
        case .regex: kind = "Matches"
        }
        var parts = ["\(kind) \(rule.pattern)"]
        if !rule.sourceAppIds.isEmpty { parts.append("from " + rule.sourceAppIds.map(AppChoice.name(for:)).joined(separator: ", ")) }
        if rule.modifiers != 0 { parts.append("holding keys") }
        let target: String
        switch rule.target {
        case .open(let id, let profile): target = AppChoice.name(for: id) + (profile.map { " (\($0))" } ?? "")
        case .ask: target = "ask"
        case .copy: target = "copy"
        }
        return parts.joined(separator: " · ") + " → " + target
    }

    private func makeDefault() {
        Task {
            do {
                for scheme in ["http", "https"] {
                    try await NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: scheme)
                }
                message = "Done. macOS may have asked you to confirm."
            } catch {
                message = "macOS did not allow it: \(error.localizedDescription). Choose Kriya under Default web browser in System Settings › Desktop & Dock."
            }
            isDefault = Self.kriyaIsDefault()
        }
    }

    private static func kriyaIsDefault() -> Bool {
        guard let probe = URL(string: "https://example.com"), let url = NSWorkspace.shared.urlForApplication(toOpen: probe) else { return false }
        return Bundle(url: url)?.bundleIdentifier == Bundle.main.bundleIdentifier
    }
}

/// Adds or changes one rule.
private struct LinkRuleEditor: View {
    @State var rule: LinkRule
    let onSave: (LinkRule) -> Void
    let onCancel: () -> Void

    private var problem: String? {
        if rule.name.trimmingCharacters(in: .whitespaces).isEmpty { return "Give the rule a name." }
        if rule.pattern.trimmingCharacters(in: .whitespaces).isEmpty { return "Say what to match." }
        if case .open(let id, _) = rule.target, id.isEmpty { return "Choose a browser." }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $rule.name)
                    Picker("Match", selection: $rule.matchKind) {
                        Text("A site and its subpages").tag(MatchKind.domain)
                        Text("An address that starts with").tag(MatchKind.prefix)
                        Text("An address that contains").tag(MatchKind.contains)
                        Text("A regular expression").tag(MatchKind.regex)
                    }
                    TextField(prompt, text: $rule.pattern)
                } header: { Text("Links that match") } footer: {
                    Text(footnote)
                }
                Section {
                    ForEach(rule.sourceAppIds, id: \.self) { id in
                        HStack {
                            Text(AppChoice.name(for: id))
                            Spacer()
                            Button { rule.sourceAppIds.removeAll { $0 == id } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                        }
                    }
                    Button("Add App…") {
                        if let id = AppChoice.choose(prompt: "Add"), !rule.sourceAppIds.contains(id) { rule.sourceAppIds.append(id) }
                    }
                } header: { Text("Only for links from these apps") } footer: {
                    Text(rule.sourceAppIds.isEmpty ? "Any app." : "Links clicked in one of these apps. Not every app tells Kriya where a link came from.")
                }
                Section {
                    Picker("Only while holding", selection: $rule.modifiers) {
                        ForEach(KeyModifiers.choices, id: \.bits) { Text($0.bits == 0 ? "No keys needed" : $0.title).tag($0.bits) }
                    }
                }
                Section { LinkTargetPicker(target: $rule.target) } header: { Text("Send it") }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                if let problem { Text(problem).font(.callout).foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Save") { onSave(rule) }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(problem != nil)
            }
            .padding(14)
        }
        .frame(width: 500, height: 640)
    }

    private var prompt: String {
        switch rule.matchKind {
        case .domain: return "example.com"
        case .prefix: return "github.com/my-company"
        case .contains: return "/pull/"
        case .regex: return "^https://[a-z]+\\.zoom\\.us/j/"
        }
    }

    private var footnote: String {
        switch rule.matchKind {
        case .domain: return "Matches the site and all its subdomains, with or without www."
        case .prefix: return "Matches addresses that begin with this, ignoring https:// and www."
        case .contains: return "Matches any address with this text in it."
        case .regex: return "Not case sensitive. An expression that is not valid is not saved."
        }
    }
}

// MARK: - Options

private struct OptionsTab: View {
    @EnvironmentObject private var store: LinkRoutingStore
    @State private var extra = ""

    var body: some View {
        Form {
            Section {
                Toggle("Remove tracking parameters", isOn: Binding(get: { store.config.stripTracking }, set: { v in store.update { $0.stripTracking = v } }))
                TextField("Also remove", text: $extra, prompt: Text("Extra names, separated by commas, like spm, ref_id"))
                    .onSubmit { commit() }
                    .onAppear { extra = store.config.extraTrackingParams.joined(separator: ", ") }
                Toggle("Replace redirect links with the real address", isOn: Binding(get: { store.config.expandRedirects }, set: { v in store.update { $0.expandRedirects = v } }))
            } header: { Text("Cleaning") } footer: {
                Text("Removes parameters such as utm_source and fbclid, leaving the rest of the address as it was. Redirects from search engines, Facebook, LinkedIn, Slack, YouTube and mail scanners are replaced with the address inside them. Nothing is fetched to do this.")
            }
            Section {
                Picker("Hold to choose a browser", selection: Binding(get: { store.config.askModifier }, set: { v in store.update { $0.askModifier = v } })) {
                    ForEach(KeyModifiers.choices, id: \.bits) { Text($0.bits == 0 ? "Off" : $0.title).tag($0.bits) }
                }
            } header: { Text("Choosing") } footer: {
                Text("Hold these keys while clicking a link to pick a browser from a small menu, or copy the link, whatever the rules say.")
            }
            Section {
                Toggle("Keep a log of links", isOn: Binding(get: { store.config.logEnabled }, set: { v in store.update { $0.logEnabled = v } }))
            } header: { Text("Log") } footer: {
                Text("The last 200 links and what was done with each, kept on this Mac only.")
            }
        }
        .formStyle(.grouped)
        .onDisappear { commit() }
    }

    private func commit() {
        let names = extra.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if names != store.config.extraTrackingParams { store.update { $0.extraTrackingParams = names } }
    }
}

// MARK: - Log and test

private struct LogTab: View {
    @EnvironmentObject private var store: LinkRoutingStore
    @State private var sample = ""
    @State private var testSource: String?

    private var decision: LinkDecision? {
        let text = sample.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, URL(string: text) != nil else { return nil }
        return resolveLink(config: store.config, url: text, sourceAppId: testSource, modifiers: 0)
    }

    var body: some View {
        Form {
            Section {
                TextField("Paste a link", text: $sample)
                HStack {
                    Text(testSource.map { "From \(AppChoice.name(for: $0))" } ?? "From any app").foregroundStyle(.secondary)
                    Spacer()
                    Button("Choose Source App…") { testSource = AppChoice.choose(prompt: "Use") }.controlSize(.small)
                    if testSource != nil { Button("Clear") { testSource = nil }.controlSize(.small) }
                }
                if let decision {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(decision.url).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                        Text(decision.ruleName.map { "Rule: \($0)" } ?? "No rule matched: the fallback")
                        Text("→ " + LinkRouter(store: store).describe(decision.target)).foregroundStyle(.secondary)
                        ForEach(decision.changes, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                    }
                    .padding(.vertical, 2)
                }
            } header: { Text("Try a link") } footer: {
                Text("Shows what Kriya would do with it, without opening anything.")
            }

            Section {
                if store.log.isEmpty { Text("Nothing yet.").font(.callout).foregroundStyle(.secondary) }
                ForEach(store.log) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(entry.final).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(entry.date.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                        }
                        Text([entry.source.map { "From \($0)" }, entry.rule.map { "Rule: \($0)" }, entry.outcome].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(entry.changes, id: \.self) { Text($0).font(.caption2).foregroundStyle(.tertiary) }
                    }
                }
            } header: {
                HStack {
                    Text("Recent links")
                    Spacer()
                    Button("Clear") { store.clearLog() }.controlSize(.small).disabled(store.log.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
    }
}
