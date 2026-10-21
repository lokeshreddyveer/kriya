import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AutomationPane: View {
    @EnvironmentObject private var engine: AutomationEngine
    @EnvironmentObject private var store: WorkflowStore
    @EnvironmentObject private var config: ConfigStore
    @EnvironmentObject private var services: ServiceManager

    @State private var tab: Tab = .workflows

    enum Tab: String, CaseIterable, Identifiable {
        case workflows = "Workflows", history = "History", safety = "Safety"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            if !config.isEnabled(.automation) || services.state(.automation) != .running {
                Banner(
                    symbol: "gearshape.2", tint: Theme.warn,
                    title: "Automation is \(config.isEnabled(.automation) ? services.state(.automation).label.lowercased() : "off")",
                    message: "Workflows will not start by themselves. They can still be run by hand and tested here."
                ) {
                    if !config.isEnabled(.automation) { Button("Turn On") { services.setFeature(.automation, enabled: true) }.controlSize(.small) }
                }
                .padding(.horizontal, 20).padding(.top, 10).transition(.opacity)
            }
            Picker("", selection: $tab) { ForEach(Tab.allCases) { Text($0.rawValue).tag($0) } }
                .paneTabBar(maxWidth: 360).paneHeader()
            Group {
                switch tab {
                case .workflows: WorkflowsTab()
                case .history: HistoryTab()
                case .safety: SafetyTab()
                }
            }
            .id(tab)
            .transition(.opacity)
        }
        .animation(.smooth(duration: 0.22), value: tab)
        .overlay(alignment: .bottom) {
            if let error = store.lastError {
                Text(error).font(.callout).padding(10).background(Theme.danger.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                    .padding().transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }
}

// MARK: - Workflows

private struct WorkflowsTab: View {
    @EnvironmentObject private var engine: AutomationEngine
    @EnvironmentObject private var store: WorkflowStore
    @State private var editing: Workflow?
    @State private var selected: Set<String> = []
    @State private var message: String?

    var body: some View {
        VStack(spacing: 0) {
            List(store.workflows, selection: $selected) { workflow in
                HStack(spacing: 12) {
                    Toggle("", isOn: Binding(get: { workflow.enabled }, set: { store.setEnabled(workflow.id, $0) })).labelsHidden().toggleStyle(.switch).controlSize(.small)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text(workflow.name).font(.headline)
                            if workflowNeedsAuthorization(workflow: workflow) { Label("Needs authorization", systemImage: "hand.raised.fill").font(.caption).foregroundStyle(Theme.warn) }
                            if engine.isRunning(workflow.id) { ProgressView().controlSize(.mini) }
                        }
                        Text("\(workflow.trigger.title) · \(workflow.steps.count) step\(workflow.steps.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if engine.isRunning(workflow.id) {
                        Button("Stop") { engine.cancelAll() }.controlSize(.small)
                    } else {
                        Button("Run") { engine.fire(workflow.id, source: "Run by hand", test: true) }.controlSize(.small)
                            .disabled(workflowNeedsAuthorization(workflow: workflow))
                            .help(workflowNeedsAuthorization(workflow: workflow) ? "Authorize it first, in the editor" : "Run it now")
                    }
                    Button("Edit") { editing = workflow }.controlSize(.small)
                }
                .tag(workflow.id)
                .padding(.vertical, 3)
            }
            .listStyle(.plain)
            .overlay {
                if store.workflows.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "gearshape.2").font(.largeTitle).foregroundStyle(.tertiary)
                        Text("No workflows yet").font(.headline)
                        Text("A workflow starts on a trigger, checks conditions, and runs steps one after another.").font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }.padding()
                }
            }
            Divider()
            HStack {
                Button { editing = store.newWorkflow() } label: { Label("New Workflow", systemImage: "plus") }
                Menu {
                    Button("Duplicate") { selected.forEach(store.duplicate) }.disabled(selected.isEmpty)
                    Button("Import Workflows…") { importWorkflows() }
                    Button("Export Selected…") { export() }.disabled(selected.isEmpty)
                    Divider()
                    Button("Delete Selected", role: .destructive) { selected.forEach(store.delete); selected.removeAll() }.disabled(selected.isEmpty)
                } label: { MoreMenuLabel() }.menuStyle(.button).menuIndicator(.hidden).fixedSize()
                Spacer()
                if let message { Text(message).font(.caption).foregroundStyle(.secondary).transition(.opacity) }
            }
            .padding(10)
        }
        .animation(.smooth(duration: 0.25), value: store.workflows)
        .animation(.smooth(duration: 0.2), value: message)
        .sheet(item: $editing) { WorkflowEditor(workflow: $0) }
    }

    private func importWorkflows() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let added = try store.importWorkflows(from: url)
            message = "Added \(added.count), switched off. Review and authorize each before turning it on."
        } catch { store.lastError = error.userMessage }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Kriya workflows.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.export(Array(selected), to: url)
            message = "Exported \(selected.count)"
        } catch { store.lastError = error.userMessage }
    }
}

// MARK: - History

private struct HistoryTab: View {
    @EnvironmentObject private var store: WorkflowStore
    @State private var filter: String = ""
    @State private var selected: String?

    private var runs: [WorkflowRun] { filter.isEmpty ? store.runs : store.runs.filter { $0.workflowId == filter } }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack {
                    Picker("Workflow", selection: $filter) { Text("All workflows").tag(""); ForEach(store.workflows) { Text($0.name).tag($0.id) } }.labelsHidden()
                    Button("Clear") { store.clearHistory(); selected = nil }.controlSize(.small)
                }
                .padding(10)
                Divider()
                List(runs, selection: $selected) { run in
                    HStack(spacing: 10) {
                        Image(systemName: run.status.symbol).foregroundStyle(run.status.color)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(run.workflowName + (run.test ? " (test)" : "")).font(.callout)
                            Text("\(run.trigger) · \(Date(timeIntervalSince1970: TimeInterval(run.startedAt)).shortDescription)").font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(run.durationMs) ms").font(.caption).foregroundStyle(.tertiary)
                    }
                    .tag(run.id)
                }
                .listStyle(.plain)
                .overlay { if runs.isEmpty { Text("No runs yet").foregroundStyle(.secondary) } }
            }
            .frame(width: 360)
            Divider()
            Group {
                if let run = store.runs.first(where: { $0.id == selected }) {
                    RunDetail(run: run).transition(.opacity)
                } else {
                    Text("Select a run").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .animation(.smooth(duration: 0.15), value: selected)
        }
        .onAppear { store.reloadRuns() }
    }
}

private struct RunDetail: View {
    let run: WorkflowRun

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: run.status.symbol).foregroundStyle(run.status.color).font(.title2)
                    VStack(alignment: .leading) {
                        Text(run.workflowName).font(.title3.bold())
                        Text("\(run.status.title) · version \(run.revision) · \(run.durationMs) ms").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let error = run.error { Text(error).font(.callout).foregroundStyle(run.status.color) }
                Divider()
                ForEach(run.steps, id: \.index) { step in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: step.status.symbol).foregroundStyle(step.status.color).frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(step.index + 1). \(step.title)").font(.callout)
                            if let message = step.message { Text(message).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        Text("\(step.durationMs) ms").font(.caption).foregroundStyle(.tertiary)
                    }
                }
                if run.steps.isEmpty { Text("No steps ran.").font(.callout).foregroundStyle(.secondary) }
                Text("History records what happened, never the text a workflow worked on.").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(16)
        }
    }
}

// MARK: - Safety

private struct SafetyTab: View {
    @EnvironmentObject private var store: WorkflowStore
    @EnvironmentObject private var engine: AutomationEngine

    var body: some View {
        Form {
            Section {
                row("Authorization", "A workflow that runs code, presses keys, quits apps or controls the system must be authorized by you. Authorization belongs to its exact content: change a step and it must be authorized again. Imported and restored workflows start unauthorized and switched off.")
                row("Time limit", "Every workflow stops after its time limit (60 seconds unless you set it, never more than 10 minutes). Programs it started are stopped too.")
                row("Stop", "A running workflow can be stopped at any time. Stopping ends the current step and runs nothing after it.")
                row("Runaway protection", "A workflow that starts more than 8 times in 10 seconds is refused, and workflows can start each other only \(workflowMaxChainDepth()) levels deep. Loops are refused when you save.")
                row("Safe mode", "In safe mode, or with Automation off, nothing starts by itself.")
                row("History", "Every run is written down: what started it, each step, how long it took and any error. The text a workflow worked on is never kept.")
            } header: { Text("How Kriya keeps automation safe") }

            Section("Needs your authorization") {
                let waiting = store.workflows.filter { workflowNeedsAuthorization(workflow: $0) }
                if waiting.isEmpty { Text("None.").font(.callout).foregroundStyle(.secondary) }
                ForEach(waiting) { workflow in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(workflow.name).font(.headline)
                        ForEach(workflowRisks(workflow: workflow), id: \.stepIndex) { Text("• " + $0.summary).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }

            Section {
                let authorized = store.workflows.filter { $0.authorizedFingerprint != nil }
                if authorized.isEmpty { Text("None.").font(.callout).foregroundStyle(.secondary) }
                ForEach(authorized) { workflow in
                    HStack { Text(workflow.name); Spacer(); Button("Revoke") { store.revokeAuthorization(workflow.id) }.controlSize(.small) }
                }
                if !authorized.isEmpty { Button("Revoke All", role: .destructive) { authorized.forEach { store.revokeAuthorization($0.id) } } }
            } header: { Text("Authorized workflows") }
        }
        .formStyle(.grouped)
    }

    private func row(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.headline)
            Text(text).font(.callout).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - The builder

struct WorkflowEditor: View {
    @State var workflow: Workflow
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: WorkflowStore
    @EnvironmentObject private var engine: AutomationEngine

    @State private var log: [StepResult] = []
    @State private var testing = false
    @State private var logStatus: RunStatus?
    @State private var logNote: String?

    private var problem: String? { workflowProblem(workflow: workflow) }
    private var risks: [Risk] { workflowRisks(workflow: workflow) }
    private var isNew: Bool { store.workflow(workflow.id) == nil }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    card("When this happens") { TriggerEditor(trigger: $workflow.trigger) }
                    card("Only if") { ConditionsEditor(group: $workflow.conditions) }
                    card("Do these steps, in order") { StepsEditor(workflow: $workflow) }
                    card("Limits") {
                        Stepper("Stop after \(workflow.timeoutSeconds) seconds", value: Binding(get: { Int(workflow.timeoutSeconds) }, set: { workflow.timeoutSeconds = UInt32($0) }), in: 1...600, step: 5)
                        Toggle("Allow it to start again while it is still running", isOn: $workflow.allowParallel)
                    }
                    if !risks.isEmpty { riskCard }
                    testCard
                }
                .padding(20)
            }
            Divider()
            HStack {
                if let problem, !workflow.name.isEmpty || !workflow.steps.isEmpty { Text(problem).font(.callout).foregroundStyle(Theme.danger).lineLimit(2) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { if save() != nil { dismiss() } }.keyboardShortcut(.defaultAction).disabled(problem != nil)
            }
            .padding(14)
        }
        .frame(width: 780, height: 780)
    }

    private func card<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Name", text: $workflow.name).textFieldStyle(.roundedBorder).font(.title3.bold())
            TextField("Notes", text: Binding(get: { workflow.notes ?? "" }, set: { workflow.notes = $0.isEmpty ? nil : $0 }), prompt: Text("What is this for? (optional)")).textFieldStyle(.roundedBorder)
            Toggle("Turned on", isOn: $workflow.enabled)
        }
    }

    // MARK: Safety and testing

    private var riskCard: some View {
        card("This workflow needs your authorization") {
            Text("These steps run code, press keys, quit apps or control the system. Read them, then authorize.").font(.callout).foregroundStyle(.secondary)
            ForEach(risks, id: \.stepIndex) { Label("Step \($0.stepIndex + 1): \($0.summary)", systemImage: "exclamationmark.shield").font(.callout).foregroundStyle(Theme.warn) }
            HStack {
                if let saved = store.workflow(workflow.id), saved.authorizedFingerprint != nil, !workflowNeedsAuthorization(workflow: saved), workflowFingerprint(workflow: saved) == workflowFingerprint(workflow: workflow) {
                    Label("Authorized", systemImage: "checkmark.shield.fill").foregroundStyle(Theme.ok)
                    Button("Revoke") { store.revokeAuthorization(workflow.id); reloadFromStore() }.controlSize(.small)
                } else {
                    Button("Save and Authorize…") { authorize() }.controlSize(.small).disabled(problem != nil)
                }
            }
        }
    }

    private var testCard: some View {
        card("Test it") {
            HStack {
                Button("Dry Run") { runTest(dry: true) }.disabled(testing || problem != nil)
                Button("Run Test") { runTest(dry: false) }.disabled(testing || problem != nil)
                if testing { Button("Stop") { engine.cancelAll() }; ProgressView().controlSize(.small) }
                Spacer()
            }
            Text("A dry run lists what would happen and checks each step's condition, without doing anything. A test runs it for real, now.").font(.caption).foregroundStyle(.secondary)
            if let logStatus { Label(logStatus.title + (logNote.map { ": \($0)" } ?? ""), systemImage: logStatus.symbol).foregroundStyle(logStatus.color).font(.callout) }
            ForEach(log, id: \.index) { step in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: step.status.symbol).foregroundStyle(step.status.color).frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(step.index + 1). \(step.title)").font(.callout)
                        if let m = step.message { Text(m).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
        }
    }

    @discardableResult
    private func save() -> Workflow? {
        guard let saved = store.save(workflow) else { return nil }
        workflow = saved
        return saved
    }

    private func reloadFromStore() {
        if let saved = store.workflow(workflow.id) { workflow = saved }
    }

    private func authorize() {
        guard let saved = save() else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Authorize “\(saved.name)”?"
        alert.informativeText = "It will be allowed to do the following whenever it runs, including when it starts by itself:\n\n" + risks.map { "• " + $0.summary }.joined(separator: "\n") + "\n\nIf you change any step, you will be asked again."
        alert.addButton(withTitle: "Authorize")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.authorize(saved.id)
        reloadFromStore()
    }

    private func runTest(dry: Bool) {
        guard let saved = save() else { return }
        var approved = false
        if !dry, workflowNeedsAuthorization(workflow: saved) {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Run this test for real?"
            alert.informativeText = "It is not authorized yet. This test will really do:\n\n" + risks.map { "• " + $0.summary }.joined(separator: "\n")
            alert.addButton(withTitle: "Run Test")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            approved = true
        }
        log = []
        logStatus = nil
        logNote = nil
        testing = true
        engine.fire(saved.id, source: dry ? "Dry run" : "Test run", input: NSPasteboard.general.string(forType: .string) ?? "", test: true, dryRun: dry, approvedForTest: approved, progress: { step in
            DispatchQueue.main.async { log.append(step) }
        }, completion: { run in
            testing = false
            logStatus = run.status
            logNote = run.error
            if log.isEmpty { log = run.steps }
        })
    }
}

// MARK: Trigger

private struct TriggerEditor: View {
    @Binding var trigger: WorkflowTrigger

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Menu {
                ForEach(Dictionary(grouping: workflowTriggerCatalog(), by: \.category).sorted { $0.key < $1.key }, id: \.key) { category, list in
                    Section(category) { ForEach(list) { template in Button { trigger = template.trigger } label: { Label(template.title, systemImage: template.symbol) } } }
                }
            } label: { Label(trigger.title, systemImage: "bolt") }.menuStyle(.button).menuIndicator(.hidden).fixedSize()
            fields
        }
    }

    @ViewBuilder
    private var fields: some View {
        switch trigger {
        case .manual:
            Text("Run it from the Run button, a keyboard shortcut or mouse rule that runs “workflow.<id>”, the Finder menu, the selection bar, the command launcher, or another workflow.").font(.caption).foregroundStyle(.secondary)
        case .hotkey(let key, let modifiers):
            LabeledContent("Keys") {
                ShortcutRecorder(shortcut: Binding(get: { RecordedShortcut(keyCode: key, modifiers: modifiers) }, set: { if let n = $0 { trigger = .hotkey(keyCode: n.keyCode, modifiers: n.modifiers) } })).frame(width: 190, height: 26)
            }
        case .mouseButton(let button, let modifiers):
            Picker("Button", selection: Binding(get: { button }, set: { trigger = .mouseButton(button: $0, modifiers: modifiers) })) { ForEach(MouseButtons.remappable, id: \.self) { Text(MouseButtons.name($0)).tag($0) } }
            Picker("With", selection: Binding(get: { modifiers }, set: { trigger = .mouseButton(button: button, modifiers: $0) })) { ForEach(KeyModifiers.choices, id: \.bits) { Text($0.title).tag($0.bits) } }
            Text("The click still reaches the app.").font(.caption).foregroundStyle(.secondary)
        case .trackpad(let gesture):
            Picker("Gesture", selection: Binding(get: { gesture }, set: { trigger = .trackpad(gesture: $0) })) {
                Text("Swipe left").tag(TrackpadGesture.swipeLeft); Text("Swipe right").tag(TrackpadGesture.swipeRight)
                Text("Swipe up").tag(TrackpadGesture.swipeUp); Text("Swipe down").tag(TrackpadGesture.swipeDown)
                Text("Pinch in").tag(TrackpadGesture.pinchIn); Text("Pinch out").tag(TrackpadGesture.pinchOut)
            }
            Text("Works where macOS passes the gesture on: gestures set in System Settings › Trackpad are used by macOS itself and may not reach Kriya.").font(.caption).foregroundStyle(.secondary)
        case .windowPlaced(let layout):
            Picker("Layout", selection: Binding(get: { layout?.command ?? "" }, set: { trigger = .windowPlaced(layout: windowLayoutFromCommand(command: $0)) })) {
                Text("Any layout").tag(""); ForEach(windowLayouts()) { Text($0.title).tag($0.command) }
            }
        case .clipboardChanged(let kind, let contains):
            Picker("Kind", selection: Binding(get: { kind.map(\.title) ?? "" }, set: { new in trigger = .clipboardChanged(kind: ClipKind.all.first { $0.title == new }, contains: contains) })) {
                Text("Anything").tag(""); ForEach(ClipKind.all, id: \.self) { Text($0.title).tag($0.title) }
            }
            TextField("Contains", text: Binding(get: { contains ?? "" }, set: { trigger = .clipboardChanged(kind: kind, contains: $0.isEmpty ? nil : $0) }), prompt: Text("any text"))
        case .hotCorner(let corner, let ms):
            Picker("Corner", selection: Binding(get: { corner }, set: { trigger = .hotCorner(corner: $0, dwellMs: ms) })) {
                Text("Top left").tag(Corner.topLeft); Text("Top right").tag(Corner.topRight); Text("Bottom left").tag(Corner.bottomLeft); Text("Bottom right").tag(Corner.bottomRight)
            }
            SliderRow(title: "Rest for", value: Binding(get: { Double(ms) }, set: { trigger = .hotCorner(corner: corner, dwellMs: UInt32($0)) }), range: 100...3000, format: { "\(Int($0)) ms" })
            Text("macOS has its own hot corners; use different corners or turn those off.").font(.caption).foregroundStyle(.secondary)
        case .screenEdge(let edge, let ms):
            Picker("Edge", selection: Binding(get: { edge }, set: { trigger = .screenEdge(edge: $0, dwellMs: ms) })) {
                Text("Top").tag(Edge.top); Text("Bottom").tag(Edge.bottom); Text("Left").tag(Edge.left); Text("Right").tag(Edge.right)
            }
            SliderRow(title: "Rest for", value: Binding(get: { Double(ms) }, set: { trigger = .screenEdge(edge: edge, dwellMs: UInt32($0)) }), range: 100...3000, format: { "\(Int($0)) ms" })
        case .appActivated(let id): appField(id) { trigger = .appActivated(appId: $0) }
        case .appLaunched(let id): appField(id) { trigger = .appLaunched(appId: $0) }
        case .appQuit(let id): appField(id) { trigger = .appQuit(appId: $0) }
        case .displayConnected, .displayDisconnected:
            Text("Runs after a display is added or removed, once macOS has settled.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func appField(_ id: String, set: @escaping (String) -> Void) -> some View {
        HStack {
            Text(id.isEmpty ? "No app chosen" : AppChoice.name(for: id)).foregroundStyle(id.isEmpty ? .secondary : .primary)
            Spacer()
            Button("Choose App…") { if let chosen = AppChoice.choose() { set(chosen) } }.controlSize(.small)
        }
    }
}

// MARK: Conditions

private struct ConditionsEditor: View {
    @Binding var group: ConditionGroup?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Check conditions first", isOn: Binding(get: { group != nil }, set: { group = $0 ? ConditionGroup(mode: .all, items: []) : nil }))
            if let current = group {
                Picker("", selection: Binding(get: { current.mode }, set: { group?.mode = $0 })) { Text("All of these must hold").tag(ConditionMode.all); Text("Any one of these").tag(ConditionMode.any) }
                    .paneTabBar(maxWidth: 360)
                ForEach(Array(current.items.enumerated()), id: \.offset) { index, item in
                    ConditionRow(item: Binding(get: { group?.items[index] ?? item }, set: { if (group?.items.indices.contains(index)) == true { group?.items[index] = $0 } }), onDelete: { group?.items.remove(at: index) })
                }
                Menu {
                    ForEach(workflowConditionCatalog()) { template in Button(template.title) { group?.items.append(ConditionItem(kind: template.kind, negate: false)) } }
                } label: { Label("Add Condition", systemImage: "plus") }.menuStyle(.button).menuIndicator(.hidden).fixedSize()
            }
        }
    }
}

struct ConditionRow: View {
    @Binding var item: ConditionItem
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("not", isOn: $item.negate).toggleStyle(.checkbox).help("Require that it does NOT hold")
            VStack(alignment: .leading, spacing: 6) { fields }
            Spacer()
            Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }.buttonStyle(.borderless)
        }
    }

    @ViewBuilder
    private var fields: some View {
        switch item.kind {
        case .frontApp(let ids):
            Text("The app in front is one of:").font(.callout)
            ForEach(ids, id: \.self) { id in HStack { Text(AppChoice.name(for: id)); Button { item.kind = .frontApp(appIds: ids.filter { $0 != id }) } label: { Image(systemName: "xmark.circle") }.buttonStyle(.borderless) } }
            Button("Add App…") { if let id = AppChoice.choose(), !ids.contains(id) { item.kind = .frontApp(appIds: ids + [id]) } }.controlSize(.small)
        case .appRunning(let id):
            HStack { Text("Running:"); Text(id.isEmpty ? "choose an app" : AppChoice.name(for: id)); Button("Choose…") { if let c = AppChoice.choose() { item.kind = .appRunning(appId: c) } }.controlSize(.small) }
        case .timeBetween(let start, let end):
            HStack {
                Text("Between")
                DatePicker("", selection: minuteBinding(start) { item.kind = .timeBetween(startMinute: $0, endMinute: end) }, displayedComponents: .hourAndMinute).labelsHidden()
                Text("and")
                DatePicker("", selection: minuteBinding(end) { item.kind = .timeBetween(startMinute: start, endMinute: $0) }, displayedComponents: .hourAndMinute).labelsHidden()
            }
        case .weekdays(let days):
            HStack(spacing: 4) {
                ForEach(Array(["S", "M", "T", "W", "T", "F", "S"].enumerated()), id: \.offset) { index, label in
                    Toggle(label, isOn: Binding(get: { days.contains(UInt8(index)) }, set: { on in item.kind = .weekdays(days: Data(on ? (Array(days) + [UInt8(index)]).sorted() : days.filter { $0 != UInt8(index) })) })).toggleStyle(.button)
                }
            }
        case .displayCount(let min, let max):
            Stepper("At least \(min) display\(min == 1 ? "" : "s")", value: Binding(get: { Int(min) }, set: { item.kind = .displayCount(min: UInt32($0), max: max) }), in: 0...8)
            Stepper(max == 0 ? "No upper limit" : "At most \(max)", value: Binding(get: { Int(max) }, set: { item.kind = .displayCount(min: min, max: UInt32($0)) }), in: 0...8)
        case .clipboardContains(let text, let sensitive):
            TextField("The clipboard contains", text: Binding(get: { text }, set: { item.kind = .clipboardContains(text: $0, caseSensitive: sensitive) }))
            Toggle("Match case", isOn: Binding(get: { sensitive }, set: { item.kind = .clipboardContains(text: text, caseSensitive: $0) }))
        case .featureEnabled(let feature):
            Picker("Feature is on", selection: Binding(get: { feature }, set: { item.kind = .featureEnabled(feature: $0) })) { ForEach(FeatureId.all) { Text($0.title).tag($0) } }
        }
    }

    private func minuteBinding(_ minute: UInt32, set: @escaping (UInt32) -> Void) -> Binding<Date> {
        Binding(
            get: { Calendar.current.date(bySettingHour: Int(minute) / 60, minute: Int(minute) % 60, second: 0, of: Date()) ?? Date() },
            set: { set(UInt32(Calendar.current.component(.hour, from: $0) * 60 + Calendar.current.component(.minute, from: $0))) }
        )
    }
}

// MARK: Steps

private struct StepsEditor: View {
    @Binding var workflow: Workflow
    @EnvironmentObject private var store: WorkflowStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if workflow.steps.isEmpty { Text("No steps yet. Add the first one below.").font(.callout).foregroundStyle(.secondary) }
            ForEach(Array(workflow.steps.enumerated()), id: \.element.id) { index, step in
                StepCard(
                    index: index, step: Binding(get: { workflow.steps.indices.contains(index) ? workflow.steps[index] : step }, set: { if workflow.steps.indices.contains(index) { workflow.steps[index] = $0 } }),
                    workflowID: workflow.id, count: workflow.steps.count,
                    move: { delta in withAnimation(.smooth) { workflow.steps.swapAt(index, index + delta) } },
                    delete: { withAnimation(.smooth) { _ = workflow.steps.remove(at: index) } }
                )
            }
            Menu {
                ForEach(Dictionary(grouping: workflowStepCatalog(), by: \.category).sorted { $0.key < $1.key }, id: \.key) { category, list in
                    Section(category) {
                        ForEach(list) { template in
                            Button { withAnimation(.smooth) { workflow.steps.append(store.newStep(template.kind)) } } label: { Label(template.title + (template.risk == .needsAuthorization ? "  ⚠︎" : ""), systemImage: template.symbol) }
                        }
                    }
                }
            } label: { Label("Add Step", systemImage: "plus") }.menuStyle(.button).menuIndicator(.hidden).fixedSize()
            Text("⚠︎ marks steps that need your authorization.").font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct StepCard: View {
    let index: Int
    @Binding var step: WorkflowStep
    let workflowID: String
    let count: Int
    let move: (Int) -> Void
    let delete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("\(index + 1)").font(.caption.bold()).frame(width: 20, height: 20).background(Theme.accent.opacity(0.25), in: Circle())
                Text(workflowStepSummary(step: step)).font(.callout.weight(.medium)).lineLimit(1)
                if step.kind.risk == .needsAuthorization { Image(systemName: "exclamationmark.shield").foregroundStyle(Theme.warn).help("Needs authorization") }
                Spacer()
                Button { move(-1) } label: { Image(systemName: "arrow.up") }.buttonStyle(.borderless).disabled(index == 0)
                Button { move(1) } label: { Image(systemName: "arrow.down") }.buttonStyle(.borderless).disabled(index == count - 1)
                Button(role: .destructive, action: delete) { Image(systemName: "trash") }.buttonStyle(.borderless)
            }
            StepFields(kind: $step.kind, workflowID: workflowID)
            HStack(spacing: 14) {
                Toggle("Only if…", isOn: Binding(get: { step.when != nil }, set: { step.when = $0 ? ConditionGroup(mode: .all, items: [ConditionItem(kind: .frontApp(appIds: []), negate: false)]) : nil })).toggleStyle(.checkbox)
                Picker("If it fails", selection: $step.onError) { Text("Stop").tag(OnError.stop); Text("Carry on").tag(OnError.continue) }.frame(maxWidth: 200)
                Spacer()
            }
            .font(.callout)
            if let when = step.when {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(when.items.enumerated()), id: \.offset) { i, item in
                        ConditionRow(item: Binding(get: { step.when?.items[i] ?? item }, set: { if (step.when?.items.indices.contains(i)) == true { step.when?.items[i] = $0 } }), onDelete: { step.when?.items.remove(at: i) })
                    }
                    Menu {
                        ForEach(workflowConditionCatalog()) { t in Button(t.title) { step.when?.items.append(ConditionItem(kind: t.kind, negate: false)) } }
                    } label: { Label("Add Condition", systemImage: "plus") }.menuStyle(.button).menuIndicator(.hidden).fixedSize()
                }
                .padding(.leading, 20)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator))
    }
}

private struct StepFields: View {
    @Binding var kind: StepKind
    let workflowID: String
    @EnvironmentObject private var workflows: WorkflowStore
    @EnvironmentObject private var mouse: MouseStore

    var body: some View {
        switch kind {
        case .action(let action): ActionFields(action: Binding(get: { action }, set: { kind = .action(action: $0) }))
        case .quitApp(let id, let force):
            appRow(id) { kind = .quitApp(appId: $0, force: force) }
            Toggle("Force quit (unsaved work is lost)", isOn: Binding(get: { force }, set: { kind = .quitApp(appId: id, force: $0) }))
        case .hideApp(let id): appRow(id) { kind = .hideApp(appId: $0) }
        case .activateApp(let id): appRow(id) { kind = .activateApp(appId: $0) }
        case .script(let language, let source):
            Picker("Language", selection: Binding(get: { language }, set: { kind = .script(language: $0, source: source) })) { Text("Shell (zsh)").tag(FinderScript.shell); Text("AppleScript").tag(FinderScript.appleScript) }
            TextEditor(text: Binding(get: { source }, set: { kind = .script(language: language, source: $0) })).font(.system(.callout, design: .monospaced)).frame(height: 90)
            Text("The workflow's text is \"$1\" (or argv) and KRIYA_INPUT. You authorize the workflow, with this exact script, before it runs.").font(.caption).foregroundStyle(.secondary)
        case .system(let op, let value):
            Picker("Do", selection: Binding(get: { op }, set: { kind = .system(op: $0, value: value) })) {
                Text("Lock the screen").tag(SystemOp.lockScreen); Text("Put the display to sleep").tag(SystemOp.sleepDisplay); Text("Put the Mac to sleep").tag(SystemOp.sleep)
                Text("Start the screen saver").tag(SystemOp.startScreenSaver); Text("Switch light/dark").tag(SystemOp.toggleAppearance); Text("Mute").tag(SystemOp.mute)
                Text("Unmute").tag(SystemOp.unmute); Text("Set the volume").tag(SystemOp.setVolume); Text("Open System Settings").tag(SystemOp.openSystemSettings)
            }
            if op == .setVolume { SliderRow(title: "Volume", value: Binding(get: { Double(value) }, set: { kind = .system(op: op, value: UInt32($0)) }), range: 0...100, format: { "\(Int($0))%" }) }
        case .switchMousePreset(let id):
            Picker("Mouse preset", selection: Binding(get: { id }, set: { kind = .switchMousePreset(presetId: $0) })) { Text("Choose…").tag(""); ForEach(mouse.presets) { Text($0.name).tag($0.id) } }
        case .setFeature(let feature, let enabled):
            Picker("Feature", selection: Binding(get: { feature }, set: { kind = .setFeature(feature: $0, enabled: enabled) })) { ForEach(FeatureId.all) { Text($0.title).tag($0) } }
            Toggle("Turn it on", isOn: Binding(get: { enabled }, set: { kind = .setFeature(feature: feature, enabled: $0) }))
        case .setClipboardPaused(let paused):
            Toggle("Pause (off resumes)", isOn: Binding(get: { paused }, set: { kind = .setClipboardPaused(paused: $0) }))
        case .delay(let ms):
            Stepper("Wait \(String(format: "%.1f", Double(ms) / 1000)) seconds", value: Binding(get: { Int(ms) }, set: { kind = .delay(ms: UInt32($0)) }), in: 0...60_000, step: 250)
        case .runWorkflow(let id):
            Picker("Workflow", selection: Binding(get: { id }, set: { kind = .runWorkflow(workflowId: $0) })) { Text("Choose…").tag(""); ForEach(workflows.workflows.filter { $0.id != workflowID }) { Text($0.name).tag($0.id) } }
        case .notify(let message):
            TextField("Message", text: Binding(get: { message }, set: { kind = .notify(message: $0) }))
        case .textTransform(let ops):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(ops.enumerated()), id: \.offset) { index, op in
                    HStack(alignment: .top) {
                        Text(op.title).font(.callout)
                        Spacer()
                        Button(role: .destructive) { var next = ops; next.remove(at: index); kind = .textTransform(ops: next) } label: { Image(systemName: "xmark.circle") }.buttonStyle(.borderless)
                    }
                    TextOpFields(op: Binding(get: { ops.indices.contains(index) ? ops[index] : op }, set: { var next = ops; if next.indices.contains(index) { next[index] = $0 }; kind = .textTransform(ops: next) }))
                }
                Menu { ForEach(Array(TextOp.catalog.enumerated()), id: \.offset) { _, op in Button(op.title) { kind = .textTransform(ops: ops + [op]) } } } label: { Label("Add a change", systemImage: "plus") }.menuStyle(.button).menuIndicator(.hidden).fixedSize()
                Text("Works on the text the workflow was given (a selection, copied text, or file paths).").font(.caption).foregroundStyle(.secondary)
            }
        case .copyText(let template):
            templateEditor(template, "Copied to the clipboard") { kind = .copyText(template: $0) }
        case .insertText(let template):
            templateEditor(template, "Typed into the app in front") { kind = .insertText(template: $0) }
        }
    }

    private func appRow(_ id: String, set: @escaping (String) -> Void) -> some View {
        HStack {
            Text(id.isEmpty ? "No app chosen" : AppChoice.name(for: id)).foregroundStyle(id.isEmpty ? .secondary : .primary)
            Spacer()
            Button("Choose App…") { if let c = AppChoice.choose() { set(c) } }.controlSize(.small)
        }
    }

    private func templateEditor(_ text: String, _ caption: String, set: @escaping (String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            TextEditor(text: Binding(get: { text }, set: set)).font(.system(.callout, design: .monospaced)).frame(height: 70)
            Text("\(caption). {selection} is the workflow's text; {date}, {clipboard} and the other snippet placeholders work too.").font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct ActionFields: View {
    @Binding var action: Action

    var body: some View {
        switch action {
        case .openApplication(let target):
            HStack { TextField("App", text: Binding(get: { target }, set: { action = .openApplication(target: $0) }), prompt: Text("com.apple.Notes or /Applications/Notes.app")); Button("Choose…") { if let id = AppChoice.choose() { action = .openApplication(target: id) } }.controlSize(.small) }
        case .openUrl(let url):
            TextField("Address", text: Binding(get: { url }, set: { action = .openUrl(url: $0) }))
        case .runShortcut(let name):
            TextField("Shortcut name", text: Binding(get: { name }, set: { action = .runShortcut(name: $0) }))
        case .builtin(let command):
            Picker("Command", selection: Binding(get: { command }, set: { action = .builtin(command: $0) })) {
                if !KeyboardCommands.all.contains(where: { $0.command == command }) { Text(command).tag(command) }
                ForEach(KeyboardCommands.all, id: \.command) { Text($0.title).tag($0.command) }
            }
        case .keyPress(let key, let modifiers):
            LabeledContent("Keys") {
                ShortcutRecorder(shortcut: Binding(get: { RecordedShortcut(keyCode: UInt16(key), modifiers: modifiers) }, set: { if let n = $0 { action = .keyPress(keyCode: n.keyCode, modifiers: n.modifiers) } })).frame(width: 190, height: 26)
            }
            Text("Needs Accessibility, and goes to the app in front.").font(.caption).foregroundStyle(.secondary)
        case .runShell(let script):
            TextEditor(text: Binding(get: { script }, set: { action = .runShell(script: $0) })).font(.system(.callout, design: .monospaced)).frame(height: 70)
        case .runScript(let language, let source):
            TextEditor(text: Binding(get: { source }, set: { action = .runScript(language: language, source: $0) })).font(.system(.callout, design: .monospaced)).frame(height: 70)
        case .noop, .sequence:
            Text(action.summary).font(.callout).foregroundStyle(.secondary)
        }
    }
}
