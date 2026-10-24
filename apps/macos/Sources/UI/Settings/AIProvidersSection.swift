import SwiftUI
import UniformTypeIdentifiers

/// AI providers: add and edit them, keep their keys in the Keychain, choose which feature uses which, and see what was sent where.
struct AIProvidersSection: View {
    @ObservedObject private var store = AIProviderStore.shared
    @ObservedObject private var gateway = AIGateway.shared
    @State private var editing: AIProviderConfig?
    @State private var message: String?
    @State private var confirmDeleteKeys = false
    @State private var confirmDeleteHistory = false

    var body: some View {
        Group {
            Section {
                ForEach(store.providers) { config in
                    HStack(spacing: 10) {
                        Toggle(config.name, isOn: Binding(get: { config.enabled }, set: { var c = config; c.enabled = $0; store.update(c) })).labelsHidden().toggleStyle(.switch).controlSize(.small)
                            .accessibilityLabel("Use \(config.name)")
                        VStack(alignment: .leading, spacing: 2) {
                            Text(config.name).font(.headline)
                            Text(describe(config)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if config.isOnThisMac { StateBadge(text: "On this Mac", color: Theme.ok) }
                        else if config.kind.needsKey { StateBadge(text: store.hasKey(config) ? "Key saved" : "No key", color: store.hasKey(config) ? Theme.ok : Theme.warn) }
                        Button("Edit") { editing = config }.controlSize(.small)
                    }
                }
                HStack {
                    Menu("Add a Provider (your own key or a local model)…") {
                        ForEach(AIProviderKind.allCases.filter { $0 != .appleIntelligence }) { kind in
                            Button(kind.title) { editing = AIProviderConfig(name: kind.title, kind: kind) }
                        }
                    }
                    .fixedSize()
                    Spacer()
                    if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
                }
            } header: { Text("AI providers · bring your own key") } footer: {
                Text("Add your own account (OpenAI, Anthropic, Gemini), a model running on this Mac (Ollama, LM Studio), or your company's endpoint. Keys are kept in the Keychain and nowhere else. A provider does nothing until you switch it on for a feature below.")
            }

            Section {
                ForEach(AIFeature.allCases) { feature in
                    let options = store.providers.filter { $0.enabled && $0.enabledFeatures.contains(feature) }
                    Picker(feature.title, selection: Binding(
                        get: { store.featureProvider[feature.rawValue] ?? options.first?.id ?? "" },
                        set: { store.featureProvider[feature.rawValue] = $0 }
                    )) {
                        if options.isEmpty { Text("None").tag("") }
                        ForEach(options) { Text($0.name).tag($0.id) }
                    }
                    .disabled(options.count < 2)
                }
            } header: { Text("Which provider each part uses") } footer: {
                Text("A part of Kriya can use a provider only if that provider is switched on for it in the provider's settings. With Local-only mode on, only providers on this Mac are used.")
            }

            Section {
                Toggle("If a provider cannot be reached, answer on this Mac instead", isOn: $store.fallbackOnDevice)
                Toggle("Also hide email addresses and phone numbers before sending", isOn: $store.redactPersonal)
                Toggle("Allow embeddings from a provider that is not on this Mac", isOn: $store.allowCloudEmbeddings)
                Text("Secrets (keys, tokens, passwords, card numbers) are always hidden before text is sent to a provider that is not on this Mac. Embeddings send the text you index to that provider, so they are off unless you allow them.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Privacy") }

            Section {
                if gateway.history.isEmpty { Text("Nothing yet.").font(.callout).foregroundStyle(.secondary) }
                ForEach(gateway.history.prefix(12)) { entry in
                    VStack(alignment: .leading, spacing: 1) {
                        HStack {
                            Text("\(entry.feature) · \(entry.provider)").font(.callout)
                            Spacer()
                            Text(entry.at.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(detail(entry)).font(.caption).foregroundStyle(entry.status == "ok" ? Color.secondary : Theme.warn)
                    }
                }
                HStack {
                    Button("Delete All AI History", role: .destructive) { confirmDeleteHistory = true }.disabled(gateway.history.isEmpty)
                    Spacer()
                    Button("Export Providers (no keys)…") { exportSettings() }
                    Button("Import…") { importSettings() }
                }
                Button("Delete All AI Keys…", role: .destructive) { confirmDeleteKeys = true }
            } header: { Text("Activity") } footer: {
                Text("Each entry says which part of Kriya asked, which provider answered, how much was sent and whether secrets were hidden. What you sent and what came back is never written down.")
            }
        }
        .sheet(item: $editing) { config in
            AIProviderEditor(config: config, isNew: store.config(config.id) == nil) { editing = nil }
        }
        .confirmationDialog("Delete every AI key?", isPresented: $confirmDeleteKeys, titleVisibility: .visible) {
            Button("Delete All Keys", role: .destructive) { store.deleteAllCredentials(); message = "All AI keys deleted." }
        } message: { Text("Providers stay listed, but cannot be used until you save a key again.") }
        .confirmationDialog("Delete the AI history?", isPresented: $confirmDeleteHistory, titleVisibility: .visible) {
            Button("Delete History and Usage Counts", role: .destructive) { gateway.deleteHistory() }
        }
    }

    private func describe(_ c: AIProviderConfig) -> String {
        var parts = [c.kind.title]
        if !c.model.isEmpty { parts.append(c.model) }
        let used = gateway.usageToday(c.id)
        if used.requests > 0 { parts.append("\(used.requests) today, \(used.tokens) tokens") }
        if c.enabledFeatures.isEmpty && c.kind != .appleIntelligence { parts.append("not switched on for anything") }
        return parts.joined(separator: " · ")
    }

    private func detail(_ e: AIActivity) -> String {
        var parts = ["sent \(e.inputCharacters) characters"]
        if e.outputCharacters > 0 { parts.append("got \(e.outputCharacters)") }
        if e.secretsHidden > 0 { parts.append("\(e.secretsHidden) secret\(e.secretsHidden == 1 ? "" : "s") hidden") }
        if let note = e.note { parts.append(note) }
        if e.status != "ok" { parts.append(e.status) }
        return parts.joined(separator: " · ")
    }

    private func exportSettings() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Kriya AI providers.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try store.exportSettings().write(to: url, options: .atomic); message = "Saved without keys." } catch { message = error.localizedDescription }
    }

    private func importSettings() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        let added = store.importSettings(data)
        message = added == 0 ? "That file has no providers Kriya can use." : "Added \(added), switched off. Add a key to each, then switch it on."
    }
}

private struct AIProviderEditor: View {
    @ObservedObject private var store = AIProviderStore.shared
    @ObservedObject private var gateway = AIGateway.shared
    @State var config: AIProviderConfig
    let isNew: Bool
    let close: () -> Void
    @State private var newKey = ""
    @State private var revealed: String?
    @State private var testing = false
    @State private var result: String?
    @State private var models: [AIModel] = []

    private var isApple: Bool { config.kind == .appleIntelligence }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $config.name)
                    if !isApple {
                        Picker("Kind", selection: $config.kind) { ForEach(AIProviderKind.allCases.filter { $0 != .appleIntelligence }) { Text($0.title).tag($0) } }
                            .onChange(of: config.kind) { _, kind in
                                if AIProviderKind.allCases.map(\.defaultBaseURL).contains(config.baseURL) || config.baseURL.isEmpty { config.baseURL = kind.defaultBaseURL }
                                if config.model.isEmpty { config.model = kind.suggestedModel }
                                config.localOnly = kind.staysOnThisMac
                            }
                        TextField("Base address", text: $config.baseURL).textContentType(.URL)
                        HStack {
                            TextField("Model", text: $config.model)
                            if !models.isEmpty {
                                Menu("Choose") { ForEach(models.prefix(60)) { m in Button(m.name) { config.model = m.id } } }.fixedSize()
                            }
                        }
                        TextField("Embedding model (optional)", text: $config.embeddingModel)
                        Toggle("Understands images", isOn: $config.supportsVision)
                        Toggle("Supports tool calls", isOn: $config.supportsTools)
                        Toggle("Runs on this Mac (localhost only)", isOn: $config.localOnly)
                    }
                } header: { Text("Provider") }

                if config.kind.needsKey {
                    Section {
                        HStack {
                            SecureField(store.hasKey(config) ? "Replace the key" : "API key", text: $newKey)
                            Button("Save Key") { if store.saveKey(newKey, for: config) { newKey = ""; result = "Key saved in the Keychain." } else { result = "That is not a usable key." } }
                                .disabled(newKey.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                        if store.hasKey(config) {
                            HStack {
                                if let revealed { Text(revealed).font(.caption.monospaced()).textSelection(.enabled).lineLimit(1) }
                                Spacer()
                                Button(revealed == nil ? "Reveal…" : "Hide") {
                                    if revealed != nil { revealed = nil } else { store.reveal(config) { revealed = $0 } }
                                }.controlSize(.small)
                                Button("Revoke", role: .destructive) { store.revokeKey(config); revealed = nil }.controlSize(.small)
                            }
                        }
                    } header: { Text("API key") } footer: {
                        Text("Stored in the macOS Keychain on this Mac only. Showing it asks for Touch ID or your password. It is never written to settings, backups, exports, logs or reports.")
                    }
                }

                if !isApple {
                    Section {
                        Stepper("Time limit: \(Int(config.timeout)) s", value: $config.timeout, in: AIProviderConfig.timeoutRange, step: 5)
                        Stepper("Longest answer: \(config.maxTokens) tokens", value: $config.maxTokens, in: AIProviderConfig.maxTokensRange, step: 128)
                        optionalNumber("Daily token limit", value: $config.dailyTokenLimit)
                        optionalNumber("Daily cost limit (USD)", value: $config.dailyCostLimit)
                        optionalNumber("Price per million input tokens (USD)", value: $config.costPerMillionInput)
                        optionalNumber("Price per million output tokens (USD)", value: $config.costPerMillionOutput)
                    } header: { Text("Limits") } footer: { Text("Leave a limit empty for none. Kriya stops sending when a daily limit is reached. Cost is worked out from the prices you enter and the token counts the provider reports.") }
                }

                Section {
                    ForEach(AIFeature.allCases) { feature in
                        let info = feature.integration
                        Toggle(isOn: Binding(
                            get: { config.enabledFeatures.contains(feature) },
                            set: { if $0 { config.enabledFeatures.insert(feature) } else { config.enabledFeatures.remove(feature) } }
                        )) {
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 6) {
                                    Text(feature.title)
                                    StateBadge(text: info.level.title, color: info.level == .connected ? Theme.ok : (info.level == .partial ? Theme.warn : Theme.danger))
                                    StateBadge(text: config.isOnThisMac ? "On this Mac" : "Sends text out", color: config.isOnThisMac ? Theme.ok : Theme.warn)
                                }
                                Text(info.does.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                                if !info.lacks.isEmpty { Text("Not yet: " + info.lacks.joined(separator: " · ")).font(.caption).foregroundStyle(.tertiary) }
                            }
                        }
                    }
                } header: { Text("Use it for") } footer: {
                    Text(config.isOnThisMac ? "This provider runs on this Mac, so nothing leaves it." : "Text from the parts you switch on is sent to this provider, with secrets hidden first.")
                }

                Section {
                    ForEach(config.problems, id: \.self) { Label($0, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(Theme.warn) }
                    HStack {
                        Button("Test Connection") { test() }.disabled(testing || !config.problems.isEmpty)
                        if testing { ProgressView().controlSize(.small) }
                        Spacer()
                        if let result { Text(result).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                if !isNew && !isApple {
                    Button("Forget This Provider…", role: .destructive) {
                        let alert = NSAlert()
                        alert.alertStyle = .warning
                        alert.messageText = "Forget “\(config.name)”?"
                        alert.informativeText = "The provider is removed from Kriya, and its key is deleted from the Keychain."
                        alert.addButton(withTitle: "Forget")
                        alert.addButton(withTitle: "Cancel")
                        if alert.runModal() == .alertFirstButtonReturn { store.forget(config); close() }
                    }
                }
                Spacer()
                Button("Cancel") { close() }.keyboardShortcut(.cancelAction)
                Button("Save") { store.update(config); close() }.keyboardShortcut(.defaultAction).disabled(!config.problems.isEmpty)
            }
            .padding(14)
        }
        .frame(width: 560, height: 680)
    }

    private func optionalNumber<T: Numeric & LosslessStringConvertible>(_ title: String, value: Binding<T?>) -> some View {
        TextField(title, text: Binding(get: { value.wrappedValue.map { String($0) } ?? "" }, set: { value.wrappedValue = T($0.trimmingCharacters(in: .whitespaces)) }))
    }

    private func test() {
        testing = true
        result = nil
        let copy = config
        Task {
            let outcome = await gateway.testConnection(copy)
            var list: [AIModel] = []
            if case .success = outcome, copy.kind != .appleIntelligence { list = (try? await gateway.models(for: copy)) ?? [] }
            await MainActor.run {
                testing = false
                models = list
                switch outcome {
                case .success(let text): result = text
                case .failure(let error): result = error.localizedDescription
                }
            }
        }
    }
}
