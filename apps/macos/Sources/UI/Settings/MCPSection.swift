import SwiftUI

/// Tools the AI may use, Kriya as an MCP server for other programs, and the MCP servers Kriya connects to.
struct AIToolsSection: View {
    @ObservedObject private var store = AIProviderStore.shared
    @ObservedObject private var server = MCPHTTPServer.shared
    @ObservedObject private var clients = MCPClientManager.shared
    @State private var editing: MCPServerConfig?
    @State private var copied = false
    /// Where the copied text goes, shown under the buttons while the secret is on the clipboard.
    @State private var copiedHelp: String?

    var body: some View {
        Group {
            Section {
                ForEach(KriyaTools.all, id: \.name) { tool in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(tool.name).font(.callout.monospaced())
                            Text(tool.risk.title).font(.caption).foregroundStyle(tool.risk >= .destructive ? Theme.warn : Color.secondary)
                            if !AIToolEngine.shared.host.isAvailable(tool) { Text("Not connected in this version: it is refused without asking.").font(.caption).foregroundStyle(Theme.danger) }
                        }
                        Spacer()
                        if tool.risk >= .destructive {
                            Text("Always asks").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Picker("", selection: Binding(get: { store.toolSettings.perTool[tool.name] ?? .ask }, set: { store.toolSettings.perTool[tool.name] = $0 })) {
                                ForEach(AIApprovalSetting.allCases, id: \.self) { Text($0.title).tag($0) }
                            }
                            .labelsHidden().frame(width: 140)
                            .accessibilityLabel("Approval for \(tool.name)")
                        }
                    }
                }
                ForEach(AIFeature.allCases) { feature in
                    DisclosureGroup("\(feature.title) may use…") {
                        ForEach(KriyaTools.all, id: \.name) { tool in
                            Toggle(tool.name, isOn: Binding(
                                get: { store.toolSettings.toolsByFeature[feature.rawValue]?.contains(tool.name) ?? false },
                                set: { on in
                                    var list = store.toolSettings.toolsByFeature[feature.rawValue] ?? []
                                    if on { if !list.contains(tool.name) { list.append(tool.name) } } else { list.removeAll { $0 == tool.name } }
                                    store.toolSettings.toolsByFeature[feature.rawValue] = list
                                }
                            ))
                            .font(.callout)
                        }
                    }
                }
            } header: { Text("Tools the AI can use") } footer: {
                Text("A model never runs text it wrote. It can only ask for one of these tools by name, with arguments that must fit the tool's form, and Kriya runs it. Deleting, moving, installing, running scripts and workflows, and changing shortcuts always ask you first. If the text the AI read held wording that looks like instructions, everything above reading asks too.")
            }

            Section {
                Toggle("Let other programs use Kriya's tools (MCP)", isOn: $server.enabled)
                if server.enabled {
                    Stepper("Port \(server.port)", value: Binding(get: { Int(server.port) }, set: { server.port = UInt16($0) }), in: 1025...65535)
                    LabeledContent("Address", value: server.endpoint)
                    HStack {
                        Menu(copied ? "Copied" : "Copy Setup for…") {
                            ForEach(MCPClientSetup.all(endpoint: server.endpoint, secret: server.secret)) { setup in
                                Button(setup.app) { copySetup(setup) }
                            }
                        }
                        .menuStyle(.button).fixedSize()
                        Button("Make a New Secret", role: .destructive) { server.regenerateSecret() }
                        Spacer()
                        Text("\(server.requests) requests").font(.caption).foregroundStyle(.secondary)
                    }
                    if let help = copiedHelp { Text(help).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                    if let status = server.status { Text(status).font(.caption).foregroundStyle(.secondary) }
                }
            } header: { Text("Kriya as an MCP server") } footer: {
                Text("Listens on this Mac only (127.0.0.1) and answers only requests that carry the secret. Web pages cannot use it. Programs that can only start a command instead of using a web address need a small adapter such as mcp-remote. A program using Kriya is asked for confirmation before it reads private content, and always before it changes or deletes anything. The same address also accepts {\"type\":\"command\",\"id\":\"…\"} at /api/run.")
            }

            Section {
                ForEach(clients.servers) { config in
                    HStack {
                        Toggle("", isOn: Binding(get: { config.enabled }, set: { var c = config; c.enabled = $0; update(c) })).labelsHidden().toggleStyle(.switch).controlSize(.small)
                            .accessibilityLabel("Use \(config.name)")
                        VStack(alignment: .leading, spacing: 2) {
                            Text(config.name).font(.headline)
                            Text("\(config.transport.title) · \(config.allowedTools.count) tool\(config.allowedTools.count == 1 ? "" : "s") allowed" + (config.lastUsed.map { " · used \($0.formatted(.relative(presentation: .named)))" } ?? ""))
                                .font(.caption).foregroundStyle(.secondary)
                            if let problem = clients.problems[config.id] { Text(problem).font(.caption).foregroundStyle(Theme.warn) }
                        }
                        Spacer()
                        Button("Edit") { editing = config }.controlSize(.small)
                    }
                }
                Button("Connect an MCP Server…") { editing = MCPServerConfig(name: "") }
            } header: { Text("MCP servers Kriya connects to") } footer: {
                Text("Each server is switched off until you allow it, and only the tools you tick are ever shown to an AI. A server cannot read Kriya's files, clipboard or Keychain, and a program you add runs with your own access to this Mac, so add only ones you trust.")
            }
        }
        .sheet(item: $editing) { config in MCPServerEditor(config: config, isNew: !clients.servers.contains { $0.id == config.id }) { editing = nil } }
    }

    private func update(_ config: MCPServerConfig) {
        if let i = clients.servers.firstIndex(where: { $0.id == config.id }) { clients.servers[i] = config } else { clients.servers.append(config) }
        if !config.enabled { clients.disconnect(config.id) }
    }

    private func copySetup(_ setup: MCPClientSetup) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(setup.text, forType: .string)
        copied = true
        copiedHelp = "\(setup.app): \(setup.instructions) The secret is on the clipboard for a minute and is then taken back."
        // The secret is on the clipboard now; it is taken back after a short while.
        let count = NSPasteboard.general.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            if NSPasteboard.general.changeCount == count { NSPasteboard.general.clearContents() }
            copied = false
            copiedHelp = nil
        }
    }
}

private struct MCPServerEditor: View {
    @ObservedObject private var clients = MCPClientManager.shared
    @State var config: MCPServerConfig
    let isNew: Bool
    let close: () -> Void
    @State private var argumentsText = ""
    @State private var environmentText = ""
    @State private var resourcesText = ""
    @State private var scopeText = ""
    @State private var token = ""
    @State private var looking = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $config.name)
                    Picker("Connects through", selection: $config.transport) { ForEach(MCPServerConfig.Transport.allCases) { Text($0.title).tag($0) } }
                    if config.transport == .stdio {
                        TextField("Full path of the program", text: $config.command)
                        VStack(alignment: .leading) { Text("Arguments, one per line").font(.caption); TextEditor(text: $argumentsText).frame(height: 54).font(.callout.monospaced()) }
                        VStack(alignment: .leading) { Text("Environment, NAME=value per line (no secrets)").font(.caption); TextEditor(text: $environmentText).frame(height: 54).font(.callout.monospaced()) }
                    } else {
                        TextField("Address", text: $config.url)
                        TextField("Allowed hosts, one per line", text: $scopeText, axis: .vertical).lineLimit(1...3)
                        Toggle("Uses a bearer token", isOn: $config.usesToken)
                        if config.usesToken {
                            SecureField(KeychainSecrets.get(config.tokenAccount) == nil ? "Token" : "Replace the token", text: $token)
                            Button("Save Token") { if KeychainSecrets.set(token.trimmingCharacters(in: .whitespacesAndNewlines), for: config.tokenAccount) { token = "" } }.disabled(token.isEmpty)
                        }
                    }
                    Picker("Approval", selection: $config.approval) { ForEach(MCPServerConfig.Approval.allCases) { Text($0.title).tag($0) } }
                } header: { Text("Server") }

                Section {
                    HStack {
                        Button("Look Up Its Tools") { look() }.disabled(looking || !config.problems.isEmpty)
                        if looking { ProgressView().controlSize(.small) }
                        Spacer()
                        if let problem = clients.problems[config.id] { Text(problem).font(.caption).foregroundStyle(Theme.warn).lineLimit(2) }
                    }
                    ForEach(clients.listed[config.id] ?? [], id: \.name) { tool in
                        HStack {
                            Toggle(isOn: Binding(get: { config.isToolAllowed(tool.name) }, set: { on in
                                if on { config.allowedTools.append(tool.name) } else { config.allowedTools.removeAll { $0 == tool.name } }
                            })) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(tool.name).font(.callout.monospaced())
                                    Text(tool.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    if !MCPClientRules.descriptionWarnings(tool.description).isEmpty {
                                        Label("Its description has wording that looks like instructions to an AI. Do not allow it unless you trust the server.", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(Theme.warn)
                                    }
                                }
                            }
                            Picker("", selection: Binding(get: { config.toolRisk[tool.name] ?? (config.transport == .http ? .externalNetwork : .privileged) }, set: { config.toolRisk[tool.name] = $0 })) {
                                ForEach(AIRisk.allCases, id: \.self) { Text($0.title).tag($0) }
                            }.labelsHidden().frame(width: 190).accessibilityLabel("Risk of \(tool.name)")
                        }
                    }
                    TextField("Resource addresses that may be read (prefixes, one per line)", text: $resourcesText, axis: .vertical).lineLimit(1...3)
                } header: { Text("What an AI may use") } footer: {
                    Text("Tick only the tools you want an AI to be able to ask for. How risky each is decides whether Kriya asks first; a tool with no mark is treated as reaching the network (web address) or as running programs (program).")
                }

                Section { ForEach(config.problems, id: \.self) { Label($0, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(Theme.warn) } }
            }
            .formStyle(.grouped)
            HStack {
                if !isNew { Button("Remove", role: .destructive) { clients.disconnect(config.id); clients.servers.removeAll { $0.id == config.id }; KeychainSecrets.delete(config.tokenAccount); close() } }
                Spacer()
                Button("Cancel") { close() }.keyboardShortcut(.cancelAction)
                Button("Save") { commit(); close() }.keyboardShortcut(.defaultAction).disabled(!config.problems.isEmpty)
            }.padding(14)
        }
        .frame(width: 620, height: 700)
        .onAppear {
            argumentsText = config.arguments.joined(separator: "\n")
            environmentText = config.environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
            resourcesText = config.allowedResources.joined(separator: "\n")
            scopeText = config.networkScope.joined(separator: "\n")
        }
        .onChange(of: argumentsText) { _, _ in sync() }
        .onChange(of: environmentText) { _, _ in sync() }
        .onChange(of: resourcesText) { _, _ in sync() }
        .onChange(of: scopeText) { _, _ in sync() }
    }

    private func lines(_ text: String) -> [String] { text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }

    private func sync() {
        config.arguments = argumentsText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).filter { !$0.isEmpty }
        var env: [String: String] = [:]
        for line in lines(environmentText) { if let eq = line.firstIndex(of: "=") { env[String(line[..<eq])] = String(line[line.index(after: eq)...]) } }
        config.environment = env
        config.allowedResources = lines(resourcesText)
        config.networkScope = lines(scopeText)
    }

    private func commit() {
        sync()
        if let i = clients.servers.firstIndex(where: { $0.id == config.id }) { clients.servers[i] = config } else { clients.servers.append(config) }
    }

    private func look() {
        sync()
        looking = true
        let copy = config
        var temporary = copy
        temporary.enabled = true
        Task { await clients.refresh(temporary); await MainActor.run { looking = false } }
    }
}
