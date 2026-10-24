import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The selection bar as a switchable feature.
final class SelectionFeature: FeatureModule {
    let feature = FeatureId.selectionBar
    private var context: ServiceContext?

    func start(context: ServiceContext) throws {
        self.context = context
        context.selection.start(profiles: context.profiles)
    }

    func stop() {
        context?.selection.stop()
        context = nil
    }
}

struct SelectionPane: View {
    @EnvironmentObject private var selection: SelectionService
    @EnvironmentObject private var store: SelectionStore
    @EnvironmentObject private var config: ConfigStore
    @EnvironmentObject private var services: ServiceManager
    @EnvironmentObject private var permissions: PermissionManager

    @State private var tab: Tab = .actions
    @State private var confirmReset = false

    enum Tab: String, CaseIterable, Identifiable {
        case actions = "Actions", appearance = "Appearance", apps = "Apps", sharing = "Import & Approvals"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            if !config.isEnabled(.selectionBar) || services.state(.selectionBar) != .running {
                Banner(
                    symbol: "text.cursor", tint: Theme.warn,
                    title: "Selection bar is \(config.isEnabled(.selectionBar) ? services.state(.selectionBar).label.lowercased() : "off")",
                    message: "Your actions are saved, but the bar appears only while the feature is on and allowed."
                ) {
                    if !config.isEnabled(.selectionBar) { Button("Turn On") { services.setFeature(.selectionBar, enabled: true) }.controlSize(.small) }
                    else if case .needsPermission(let missing) = services.state(.selectionBar) { AllowPermissionButtons(missing: missing) }
                }
                .padding(.horizontal, 20).padding(.top, 10).transition(.opacity)
            }
            HStack {
                Picker("", selection: $tab) { ForEach(Tab.allCases) { Text($0.rawValue).tag($0) } }
                    .paneTabBar(maxWidth: 380)
                Menu {
                    Button("Restore Default Settings") { store.restoreDefaults(everything: false) }
                    Button("Restore Everything, Including Actions…") { confirmReset = true }
                } label: { MoreMenuLabel() }.menuStyle(.button).menuIndicator(.hidden).fixedSize()
            }
            .paneHeader()
            Group {
                switch tab {
                case .actions: SelectionActionsTab()
                case .appearance: AppearanceTab()
                case .apps: SelectionAppsTab()
                case .sharing: SharingTab()
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
        .confirmationDialog("Restore everything?", isPresented: $confirmReset) {
            Button("Restore Everything", role: .destructive) { store.restoreDefaults(everything: true) }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Your custom actions are removed and the shipped ones come back.") }
    }
}

// MARK: - Actions

private struct SelectionActionsTab: View {
    @EnvironmentObject private var store: SelectionStore
    @State private var editing: SelectionAction?

    var body: some View {
        List {
            Section {
                ForEach(store.actions) { action in
                    HStack(spacing: 12) {
                        Toggle("Use this action", isOn: Binding(get: { action.enabled }, set: { store.setEnabled(action.id, $0) })).labelsHidden().toggleStyle(.switch).controlSize(.small)
                        Image(systemName: action.symbol.isEmpty ? "star" : action.symbol).frame(width: 22).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(action.title).font(.headline)
                            Text("\(action.kind.summary) · \(action.applies.title)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Button("Edit") { editing = action }.controlSize(.small)
                        Button(role: .destructive) { withAnimation(.smooth) { store.delete(action.id) } } label: { Image(systemName: "trash") }.accessibilityLabel("Delete").buttonStyle(.borderless)
                    }
                    .padding(.vertical, 3)
                }
                .onMove { store.move(from: $0, to: $1) }
            } header: {
                HStack {
                    Text("Order in the bar")
                    Spacer()
                    Menu {
                        ForEach(NewSelectionKind.allCases) { kind in Button(kind.rawValue) { editing = kind.blank() } }
                        Divider()
                        Button("Add Common Actions (Markdown, encodings, searches, notes…)") { store.addSuggested() }
                    } label: { Label("Add Action", systemImage: "plus") }.menuStyle(.button).menuIndicator(.hidden).fixedSize()
                }
            } footer: {
                Text("Drag to reorder. The first few show in the bar; the rest are under “…”. Actions that change text appear only where the text can be edited.")
            }
        }
        .animation(.smooth(duration: 0.25), value: store.actions)
        .sheet(item: $editing) { SelectionActionEditor(action: $0) }
    }
}

enum NewSelectionKind: String, CaseIterable, Identifiable {
    case transform = "Change the text", copyResult = "Copy a changed version", url = "Open a web address", translate = "Translate"
    case shell = "Run a shell script", appleScript = "Run an AppleScript", shortcut = "Run a Shortcut", workflow = "Run a workflow"
    case intelligence = "Ask Apple Intelligence"
    var id: String { rawValue }

    func blank() -> SelectionAction {
        let kind: SelectionActionKind
        switch self {
        case .transform: kind = .transform(ops: [.trim], copyOnly: false)
        case .copyResult: kind = .transform(ops: [.trim], copyOnly: true)
        case .url: kind = .urlTemplate(template: "https://www.google.com/search?q={text}")
        case .translate: kind = .translate(target: "en", provider: .google)
        case .shell: kind = .script(language: .shell, source: "echo \"$1\"", replaceWithOutput: false)
        case .appleScript: kind = .script(language: .appleScript, source: "return item 1 of argv", replaceWithOutput: false)
        case .shortcut: kind = .shortcut(name: "", replaceWithOutput: false)
        case .workflow: kind = .workflow(workflowId: "")
        case .intelligence: kind = .intelligence(task: .custom(instruction: ""))
        }
        return SelectionAction(id: UUID().uuidString, title: rawValue, symbol: "star", kind: kind, enabled: true, applies: self == .transform ? .editableOnly : .anything, appIds: [])
    }
}

private struct SelectionActionEditor: View {
    @State var action: SelectionAction
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: SelectionStore
    @EnvironmentObject private var workflows: WorkflowStore

    @State private var ops: [TextOp] = []
    @State private var copyOnly = false
    @State private var text = ""
    @State private var language = "en"
    @State private var provider: TranslateProvider = .google
    @State private var isShell = true
    @State private var replace = false
    @State private var aiTask: AITaskChoice = .custom
    @State private var aiInstruction = ""
    @State private var sample = "  Some sample text\nwith two lines  "

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Action").font(.title3.bold())
            ScrollView {
                Form {
                    TextField("Name", text: $action.title)
                    TextField("Symbol", text: $action.symbol, prompt: Text("SF Symbol name, for example star"))
                    TextField("Group", text: Binding(get: { action.group ?? "" }, set: { action.group = $0.isEmpty ? nil : $0 }),
                              prompt: Text("Optional: actions with the same group share one button"))
                    Picker("Offer it for", selection: $action.applies) { ForEach(SelectionTarget.all, id: \.self) { Text($0.title).tag($0) } }
                    fields
                    Section("Only in these apps") {
                        if action.appIds.isEmpty { Text("Every app").font(.caption).foregroundStyle(.secondary) }
                        ForEach(action.appIds, id: \.self) { id in
                            HStack { Text(AppChoice.name(for: id)); Spacer(); Button(role: .destructive) { action.appIds.removeAll { $0 == id } } label: { Image(systemName: "trash") }.accessibilityLabel("Delete").buttonStyle(.borderless) }
                        }
                        Button { if let id = AppChoice.choose(prompt: "Add"), !action.appIds.contains(id) { action.appIds.append(id) } } label: { Label("Add App", systemImage: "plus") }.controlSize(.small)
                    }
                }
                .formStyle(.grouped)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                if let problem { Text(problem).font(.callout).foregroundStyle(.secondary) }
                Button("Save") { save() }.keyboardShortcut(.defaultAction).disabled(problem != nil)
            }
        }
        .padding(20).frame(width: 600, height: 620)
        .onAppear(perform: load)
    }

    /// What is missing before the action can be saved, said in a sentence.
    private var problem: String? {
        if action.title.trimmingCharacters(in: .whitespaces).isEmpty { return "Give it a name." }
        let blank = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        switch action.kind {
        case .urlTemplate: return blank ? "Enter the web address." : textUrlTemplateProblem(template: text)
        case .translate: return language.trimmingCharacters(in: .whitespaces).isEmpty ? "Enter a language code, such as en." : nil
        case .script: return blank ? "Write the script." : nil
        case .shortcut: return blank ? "Name the Shortcut." : nil
        case .workflow: return blank ? "Choose a workflow." : nil
        case .intelligence: return aiTask == .custom && aiInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Say what it should do with the text." : nil
        case .transform: return ops.isEmpty ? "Add a step." : nil
        default: return nil
        }
    }

    @ViewBuilder
    private var fields: some View {
        switch action.kind {
        case .transform:
            Toggle("Only copy the result (never change the text)", isOn: $copyOnly)
            TextPipelineEditor(ops: $ops, sample: $sample)
        case .urlTemplate:
            TextField("Web address", text: $text)
            Text("Use {text} where the selection goes (encoded for a link), {plus} to turn spaces into +, or {raw} for it unchanged.").font(.caption).foregroundStyle(.secondary)
            if let problem = textUrlTemplateProblem(template: text) { Text(problem).font(.caption).foregroundStyle(Theme.danger) }
        case .translate:
            TextField("Language code", text: $language, prompt: Text("en, fr, pt-BR"))
            Picker("Service", selection: $provider) { ForEach(TranslateProvider.all, id: \.self) { Text($0.title).tag($0) } }
            Text("The selected text is sent to the service you choose when it opens in your browser.").font(.caption).foregroundStyle(.secondary)
        case .script:
            Picker("Language", selection: $isShell) { Text("Shell (zsh)").tag(true); Text("AppleScript").tag(false) }
            TextEditor(text: $text).font(.system(.body, design: .monospaced)).frame(height: 130)
            Toggle("Replace the selection with what it prints", isOn: $replace)
            Text("The selection is the first argument (\"$1\", or argv) and is also in KRIYA_SELECTION. You approve the script before it first runs; changing it asks again.").font(.caption).foregroundStyle(.secondary)
        case .shortcut:
            TextField("Shortcut name", text: $text)
            Toggle("Replace the selection with the Shortcut's output", isOn: $replace)
        case .workflow:
            Picker("Workflow", selection: $text) { Text("Choose…").tag(""); ForEach(workflows.workflows) { Text($0.name).tag($0.id) } }
            Text("The selected text is the workflow's input.").font(.caption).foregroundStyle(.secondary)
        case .intelligence:
            Picker("Task", selection: $aiTask) { ForEach(AITaskChoice.allCases) { Text($0.title).tag($0) } }
            if aiTask == .custom {
                TextField("What should it do with the text?", text: $aiInstruction, axis: .vertical).lineLimit(2...4)
                Text("For example: “turn this into a haiku” or “list the action items”. Up to 600 characters.").font(.caption).foregroundStyle(.secondary)
            }
            Text("Handled by Apple Intelligence's on-device model. The text stays on this Mac. The result is shown in a small window where you can copy it or, for rewrites in an editable field, replace the selection.").font(.caption).foregroundStyle(.secondary)
        default:
            Text(action.kind.summary).font(.callout).foregroundStyle(.secondary)
        }
    }

    private func load() {
        switch action.kind {
        case .transform(let o, let c): ops = o; copyOnly = c
        case .urlTemplate(let t): text = t
        case .translate(let t, let p): language = t; provider = p
        case .script(let l, let s, let r): isShell = l == .shell; text = s; replace = r
        case .shortcut(let n, let r): text = n; replace = r
        case .workflow(let id): text = id
        case .intelligence(let task):
            aiTask = AITaskChoice(task)
            if case .custom(let instruction) = task { aiInstruction = instruction }
        default: break
        }
    }

    private func save() {
        switch action.kind {
        case .transform: action.kind = .transform(ops: ops, copyOnly: copyOnly)
        case .urlTemplate: action.kind = .urlTemplate(template: text)
        case .translate: action.kind = .translate(target: language, provider: provider)
        case .script: action.kind = .script(language: isShell ? .shell : .appleScript, source: text, replaceWithOutput: replace)
        case .shortcut: action.kind = .shortcut(name: text, replaceWithOutput: replace)
        case .workflow: action.kind = .workflow(workflowId: text)
        case .intelligence: action.kind = .intelligence(task: aiTask.task(instruction: aiInstruction))
        default: break
        }
        store.upsert(action)
        if store.lastError == nil { dismiss() }
    }
}

/// Builds a chain of text steps and shows what it does to a sample, as you edit.
struct TextPipelineEditor: View {
    @Binding var ops: [TextOp]
    @Binding var sample: String

    var body: some View {
        Section("Steps") {
            if ops.isEmpty { Text("Add a step.").font(.caption).foregroundStyle(.secondary) }
            ForEach(Array(ops.indices), id: \.self) { index in
                if index < ops.count {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("\(index + 1). \(ops[index].title)").font(.headline)
                            Spacer()
                            Button { if index > 0 { ops.swapAt(index, index - 1) } } label: { Image(systemName: "arrow.up") }.accessibilityLabel("Move up").buttonStyle(.borderless).disabled(index == 0)
                            Button { if index < ops.count - 1 { ops.swapAt(index, index + 1) } } label: { Image(systemName: "arrow.down") }.accessibilityLabel("Move down").buttonStyle(.borderless).disabled(index == ops.count - 1)
                            Button(role: .destructive) { withAnimation(.smooth) { _ = ops.remove(at: index) } } label: { Image(systemName: "trash") }.accessibilityLabel("Delete").buttonStyle(.borderless)
                        }
                        TextOpFields(op: Binding(get: { ops[min(index, ops.count - 1)] }, set: { if index < ops.count { ops[index] = $0 } }))
                    }
                    .padding(.vertical, 2)
                }
            }
            Menu {
                ForEach(Array(TextOp.catalog.enumerated()), id: \.offset) { _, op in Button(op.title) { withAnimation(.smooth) { ops.append(op) } } }
            } label: { Label("Add Step", systemImage: "plus") }.menuStyle(.button).menuIndicator(.hidden).fixedSize()
        }
        Section("Try it") {
            TextEditor(text: $sample).font(.system(.callout, design: .monospaced)).frame(height: 70)
            let result = Result { try textApplyAll(ops: ops, text: sample) }
            switch result {
            case .success(let text): Text(text.isEmpty ? "(nothing)" : text).font(.system(.callout, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            case .failure(let error): Text(error.userMessage).font(.callout).foregroundStyle(Theme.danger)
            }
        }
    }
}

struct TextOpFields: View {
    @Binding var op: TextOp

    var body: some View {
        switch op {
        case .sortLines(let d, let c, let n):
            HStack {
                Toggle("Descending", isOn: Binding(get: { d }, set: { op = .sortLines(descending: $0, caseSensitive: c, numeric: n) }))
                Toggle("Match case", isOn: Binding(get: { c }, set: { op = .sortLines(descending: d, caseSensitive: $0, numeric: n) }))
                Toggle("By number", isOn: Binding(get: { n }, set: { op = .sortLines(descending: d, caseSensitive: c, numeric: $0) }))
            }
        case .prefixLines(let t): TextField("Text", text: Binding(get: { t }, set: { op = .prefixLines(text: $0) }))
        case .suffixLines(let t): TextField("Text", text: Binding(get: { t }, set: { op = .suffixLines(text: $0) }))
        case .findReplace(let f, let r):
            TextField("Find", text: Binding(get: { f }, set: { op = .findReplace(find: $0, replace: r) }))
            TextField("Replace with", text: Binding(get: { r }, set: { op = .findReplace(find: f, replace: $0) }))
        case .regexReplace(let p, let r, let i):
            TextField("Pattern", text: Binding(get: { p }, set: { op = .regexReplace(pattern: $0, replacement: r, caseInsensitive: i) }))
            TextField("Replace with ($1, $2 for groups)", text: Binding(get: { r }, set: { op = .regexReplace(pattern: p, replacement: $0, caseInsensitive: i) }))
            Toggle("Ignore case", isOn: Binding(get: { i }, set: { op = .regexReplace(pattern: p, replacement: r, caseInsensitive: $0) }))
        case .wrap(let b, let a):
            TextField("Before", text: Binding(get: { b }, set: { op = .wrap(before: $0, after: a) }))
            TextField("After", text: Binding(get: { a }, set: { op = .wrap(before: b, after: $0) }))
        default:
            EmptyView()
        }
    }
}

// MARK: - Appearance

private struct AppearanceTab: View {
    @AppStorage(SelectionService.startInKeyboardKey) private var startInKeyboard = false
    @AppStorage(SelectionPins.rankKey) private var rankByContext = true
    @AppStorage(ReplacementPeek.enabledKey) private var showReplacement = true
    @State private var pinned = SelectionPins.pinned
    @EnvironmentObject private var store: SelectionStore
    private var config: SelectionConfig { store.config }
    @ObservedObject private var usage = UsageLogStore.selection

    var body: some View {
        Form {
            Section {
                if usage.log.entries.isEmpty { Text("Nothing used yet.").font(.callout).foregroundStyle(.secondary) }
                ForEach(usage.log.top(5), id: \.title) { item in
                    HStack { Text(item.title); Spacer(); Text("\(item.uses) time\(item.uses == 1 ? "" : "s")").foregroundStyle(.secondary).font(.callout) }
                }
                ForEach(usage.log.entries.prefix(5)) { entry in
                    HStack { Text(entry.title); if !entry.detail.isEmpty { Text("in \(entry.detail)").foregroundStyle(.secondary) }; Spacer()
                        Text(entry.at.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(.secondary) }.font(.callout)
                }
                if !usage.log.entries.isEmpty { Button("Clear") { usage.clear() }.controlSize(.small) }
            } header: { Text("Most used") } footer: { Text("Only the name of the action and the app it was used in are kept, never the text.") }
            Section {
                Toggle("Put the actions that fit the selection first", isOn: $rankByContext)
                Toggle("Show what changed after a replacement, with Undo", isOn: $showReplacement)
                ForEach(pinned, id: \.self) { id in
                    HStack {
                        Label(store.current.actions.first { $0.id == id }?.title ?? id, systemImage: "pin.fill")
                        Spacer()
                        Button(role: .destructive) { pinned.removeAll { $0 == id }; SelectionPins.pinned = pinned } label: { Image(systemName: "xmark.circle") }.buttonStyle(.borderless).accessibilityLabel("Unpin")
                    }
                }
                Menu("Pin an Action") {
                    ForEach(store.current.actions.filter { !pinned.contains($0.id) }) { action in
                        Button { pinned.append(action.id); SelectionPins.pinned = pinned } label: { Label(action.title, systemImage: action.symbol.isEmpty ? "star" : action.symbol) }
                    }
                }.fixedSize()
            } header: { Text("Which actions come first") } footer: {
                Text("With this on, a link puts Open Link first, JSON puts Format JSON first, a path puts Show in Finder first, a long text puts the AI actions first, and so on; then what you use most, with slow actions (scripts, AI, web) after quick ones. Pinned actions always come first. The extras go under headings in the “…” menu: Transform, Search, Share, Developer, AI, Apps. Turn it off to keep exactly your own order.")
            }
            Section("Look") {
                Picker("Style", selection: Binding(get: { config.theme }, set: { v in store.updateConfig { $0.theme = v } })) {
                    Text("Match the system").tag(ToolbarTheme.system); Text("Light").tag(ToolbarTheme.light); Text("Dark").tag(ToolbarTheme.dark); Text("Accent color").tag(ToolbarTheme.accent)
                }
                Picker("Size", selection: Binding(get: { config.size }, set: { v in store.updateConfig { $0.size = v } })) {
                    Text("Small").tag(ToolbarSize.small); Text("Regular").tag(ToolbarSize.regular); Text("Large").tag(ToolbarSize.large)
                }
                Picker("Appears", selection: Binding(get: { config.position }, set: { v in store.updateConfig { $0.position = v } })) {
                    Text("Above the selection").tag(ToolbarPosition.aboveSelection); Text("Below the selection").tag(ToolbarPosition.belowSelection); Text("Near the pointer").tag(ToolbarPosition.nearPointer)
                }
                Toggle("Show names beside the icons", isOn: Binding(get: { config.showLabels }, set: { v in store.updateConfig { $0.showLabels = v } }))
                Stepper("Show \(config.maxVisible) buttons before “…”", value: Binding(get: { Int(config.maxVisible) }, set: { v in store.updateConfig { $0.maxVisible = UInt32(v) } }), in: 2...14)
            }
            Section {
                SliderRow(title: "Wait before it appears", value: Binding(get: { Double(config.activationDelayMs) }, set: { v in store.updateConfig { $0.activationDelayMs = UInt32(v) } }),
                          range: 0...1500, format: { "\(Int($0)) ms" }, help: "How long text must stay selected.")
                Stepper(config.autoHideSeconds == 0 ? "Stay until something else is clicked" : "Hide after \(config.autoHideSeconds) seconds", value: Binding(get: { Int(config.autoHideSeconds) }, set: { v in store.updateConfig { $0.autoHideSeconds = UInt32(v) } }), in: 0...60)
                LabeledContent("Show it with a shortcut") {
                    ShortcutRecorder(shortcut: Binding(
                        get: { config.manualKey.map { RecordedShortcut(keyCode: $0, modifiers: config.manualModifiers) } },
                        set: { new in store.updateConfig { $0.manualKey = new?.keyCode; $0.manualModifiers = new?.modifiers ?? 0 } }
                    )).frame(width: 190, height: 26)
                }
                Toggle("Open straight in keyboard mode", isOn: $startInKeyboard)
            } header: { Text("Timing") } footer: {
                Text("The shortcut shows the bar for the text selected right now, which also works in apps where the bar does not appear by itself. Keyboard mode: with the bar showing, press the shortcut a second time and use the arrow keys or Tab to move, Return to run, 1 to 9 to pick a button, and Esc to close. The position is read out by VoiceOver. Switch the option on to skip the second press.")
            }
            Section("Length") {
                Stepper("At least \(config.minLength) characters", value: Binding(get: { Int(config.minLength) }, set: { v in store.updateConfig { $0.minLength = UInt32(v) } }), in: 1...100)
                Stepper("At most \(config.maxLength) characters", value: Binding(get: { Int(config.maxLength) }, set: { v in store.updateConfig { $0.maxLength = UInt32(v) } }), in: 100...200_000, step: 1000)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Apps

private struct SelectionAppsTab: View {
    @EnvironmentObject private var store: SelectionStore
    private var config: SelectionConfig { store.config }

    var body: some View {
        Form {
            Section {
                Toggle("Copy the selection when an app will not say what it is (and put the clipboard back)", isOn: Binding(get: { config.copyFallbackDefault }, set: { v in store.updateConfig { $0.copyFallbackDefault = v } }))
            } header: { Text("Copy and restore") } footer: {
                Text("Some apps, such as many Electron and Java apps and terminals, do not share their selection. This briefly copies it and restores your clipboard, so it flashes through clipboard history tools and can interfere if you copy at the same moment. It never runs in password fields or in the apps listed below. It is off by default; you can also turn it on for single apps.")
            }

            Section {
                if config.appBehaviors.isEmpty { Text("No app-specific behavior.").font(.callout).foregroundStyle(.secondary) }
                ForEach(config.appBehaviors, id: \.appId) { behavior in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(AppChoice.name(for: behavior.appId)).font(.headline)
                            Spacer()
                            Button(role: .destructive) { store.updateConfig { $0.appBehaviors.removeAll { $0.appId == behavior.appId } } } label: { Image(systemName: "trash") }.accessibilityLabel("Delete").buttonStyle(.borderless)
                        }
                        Picker("Bar", selection: modeBinding(behavior)) {
                            Text("Appears by itself").tag(SelectionMode.automatic); Text("Only with the shortcut").tag(SelectionMode.manualOnly); Text("Never").tag(SelectionMode.off)
                        }
                        Toggle("Allow copy and restore here", isOn: Binding(get: { behavior.allowCopyFallback }, set: { v in edit(behavior.appId) { $0.allowCopyFallback = v } }))
                        DisclosureGroup("Only these actions (\(behavior.actionIds.isEmpty ? "all" : "\(behavior.actionIds.count)"))") {
                            ForEach(store.actions) { action in
                                Toggle(action.title, isOn: Binding(
                                    get: { behavior.actionIds.contains(action.id) },
                                    set: { on in edit(behavior.appId) { b in b.actionIds.removeAll { $0 == action.id }; if on { b.actionIds.append(action.id) } } }
                                ))
                            }
                            Text("Leave all off to allow every action.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 3)
                }
            } header: {
                HStack {
                    Text("Behavior in particular apps")
                    Spacer()
                    Button { if let id = AppChoice.choose(prompt: "Add"), !config.appBehaviors.contains(where: { $0.appId == id }) { store.updateConfig { $0.appBehaviors.append(AppBehavior(appId: id, mode: .automatic, allowCopyFallback: false, actionIds: [])) } } } label: { Label("Add App", systemImage: "plus") }.controlSize(.small)
                }
            }

            Section {
                ForEach(config.excludedAppIds, id: \.self) { id in
                    HStack {
                        Text(AppChoice.name(for: id))
                        Spacer()
                        Button(role: .destructive) { store.updateConfig { $0.excludedAppIds.removeAll { $0 == id } } } label: { Image(systemName: "trash") }.accessibilityLabel("Delete").buttonStyle(.borderless)
                    }
                }
                Button { if let id = AppChoice.choose(prompt: "Exclude"), !config.excludedAppIds.contains(id) { store.updateConfig { $0.excludedAppIds.append(id) } } } label: { Label("Exclude an App", systemImage: "plus") }.controlSize(.small)
            } header: { Text("Never in these apps") } footer: {
                Text("Password managers start on this list. The bar also never appears in password fields, or while macOS is protecting keyboard input.")
            }
        }
        .formStyle(.grouped)
        .animation(.smooth(duration: 0.25), value: config.appBehaviors)
    }

    private func modeBinding(_ behavior: AppBehavior) -> Binding<SelectionMode> {
        Binding(get: { behavior.mode }, set: { v in edit(behavior.appId) { $0.mode = v } })
    }

    private func edit(_ appID: String, _ change: @escaping (inout AppBehavior) -> Void) {
        store.updateConfig { config in
            if let index = config.appBehaviors.firstIndex(where: { $0.appId == appID }) { change(&config.appBehaviors[index]) }
        }
    }
}

// MARK: - Sharing and approvals

private struct SharingTab: View {
    @EnvironmentObject private var store: SelectionStore
    @EnvironmentObject private var approvals: ScriptApprovals
    @State private var message: String?
    @State private var chosen: Set<String> = []

    var body: some View {
        Form {
            Section {
                Text("This tab is for moving your actions between Macs and for scripts you have approved. It does not share anything over the network.").font(.callout).foregroundStyle(.secondary)
            } header: { Text("What this tab is") } footer: {
                Text("Nothing selected, such as blank space in a document? Give “Show paste actions here” a shortcut under Keyboard › Shortcuts, or run it from the launcher. It shows Paste and Paste without formatting next to the pointer. Showing the bar by shortcut with nothing selected does the same.")
            }

            Section {
                ForEach(store.actions) { action in
                    Toggle(action.title, isOn: Binding(get: { chosen.contains(action.id) }, set: { on in if on { chosen.insert(action.id) } else { chosen.remove(action.id) } }))
                }
                HStack {
                    Button("Export Selected…") { export() }.disabled(chosen.isEmpty)
                    Button("Import Actions…") { importPackage() }
                    if let message { Text(message).font(.caption).foregroundStyle(.secondary).transition(.opacity) }
                }
            } header: { Text("Export and import actions") } footer: {
                Text("An exported file holds the actions you tick. Imported actions are checked first, are added at the end, and any script in them asks for your approval before it first runs. Only import files from people you trust.")
            }

            Section {
                if approvals.approved.isEmpty { Text("No scripts approved yet.").font(.callout).foregroundStyle(.secondary) }
                ForEach(approvals.approved, id: \.fingerprint) { script in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(script.label).font(.headline)
                            Text("Approved \(Date(timeIntervalSince1970: TimeInterval(script.approvedAt)).shortDescription)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Revoke") { approvals.revoke(script.fingerprint) }.controlSize(.small)
                    }
                }
            } header: { Text("Approved scripts") } footer: {
                Text("A script is approved by its exact text. Revoking makes it ask again.")
            }
        }
        .formStyle(.grouped)
        .animation(.smooth(duration: 0.2), value: message)
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Kriya selection actions.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.exportActions(Array(chosen), name: "Kriya selection actions", to: url)
            message = "Exported \(chosen.count)"
        } catch { store.lastError = error.userMessage }
    }

    private func importPackage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let added = try store.importActions(from: url)
            message = "Added \(added.count)"
        } catch { store.lastError = error.userMessage }
    }
}

/// The tasks Apple Intelligence can be given, as the editor lists them.
enum AITaskChoice: String, CaseIterable, Identifiable {
    case summarize, keyPoints, fixGrammar, friendlier, professional, concise, explain, reply, custom
    var id: String { rawValue }

    init(_ task: IntelligenceTask) {
        switch task {
        case .summarize: self = .summarize
        case .keyPoints: self = .keyPoints
        case .fixGrammar: self = .fixGrammar
        case .friendlier: self = .friendlier
        case .professional: self = .professional
        case .concise: self = .concise
        case .explain: self = .explain
        case .reply: self = .reply
        case .custom: self = .custom
        }
    }

    func task(instruction: String) -> IntelligenceTask {
        switch self {
        case .summarize: return .summarize
        case .keyPoints: return .keyPoints
        case .fixGrammar: return .fixGrammar
        case .friendlier: return .friendlier
        case .professional: return .professional
        case .concise: return .concise
        case .explain: return .explain
        case .reply: return .reply
        case .custom: return .custom(instruction: instruction)
        }
    }

    var title: String { intelligenceTitle(task: task(instruction: "x")) }
}
