import SwiftUI

extension RemapRule: Identifiable {}

/// Key remapping: a key that does one thing when tapped and another when held, a Hyper key, a double tap, or two keys
/// pressed together that act as one.
struct RemapTab: View {
    @EnvironmentObject private var remap: RemapStore
    @State private var editing: RemapRule?

    private var config: RemapConfig { remap.config }

    var body: some View {
        Form {
            Section {
                Toggle("Remap keys", isOn: Binding(get: { config.enabled }, set: { v in remap.update { $0.enabled = v } }))
            } header: { Text("Key remapping") } footer: {
                Text("Off by default, and normal typing is untouched until you add a rule and turn this on. Turning it off puts every key back at once. Needs Input Monitoring.")
            }

            Section {
                Button("Caps Lock: Escape when tapped, Hyper (⌃⌥⇧⌘) when held") {
                    remap.upsert(RemapRule(id: "caps-hyper", name: "Caps Lock as Hyper", enabled: true, keyCode: RemapKeys.capsLock, modifiers: 0, appIds: [],
                        tap: .key(keyCode: RemapKeys.escape, modifiers: 0), hold: .modifiers(modifiers: RemapKeys.hyper), doubleTap: nil, chordWith: [], keyboard: nil))
                }
                Button("Caps Lock: Escape when tapped, Control when held") {
                    remap.upsert(RemapRule(id: "caps-control", name: "Caps Lock as Control", enabled: true, keyCode: RemapKeys.capsLock, modifiers: 0, appIds: [],
                        tap: .key(keyCode: RemapKeys.escape, modifiers: 0), hold: .modifiers(modifiers: KeyModifiers.control), doubleTap: nil, chordWith: [], keyboard: nil))
                }
                Button("Right ⌘ acts as Control") {
                    remap.upsert(RemapRule(id: "rcmd-control", name: "Right ⌘ as Control", enabled: true, keyCode: 54, modifiers: 0, appIds: [],
                        tap: .modifiers(modifiers: KeyModifiers.control), hold: nil, doubleTap: nil, chordWith: [], keyboard: nil))
                }
            } header: { Text("Quick setups") } footer: {
                Text("Hyper is all four modifier keys at once, for shortcuts nothing else uses. Caps Lock is switched to an ordinary key while a rule uses it, and switched back when you turn remapping off or quit Kriya.")
            }

            Section {
                if config.rules.isEmpty {
                    Text("No rules yet. Use a quick setup or add your own.").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(config.rules) { rule in
                    HStack {
                        Toggle("", isOn: Binding(get: { rule.enabled }, set: { v in var copy = rule; copy.enabled = v; remap.upsert(copy) })).labelsHidden()
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rule.name)
                            Text(RemapKeys.summary(rule)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Edit") { editing = rule }.controlSize(.small)
                        Button(role: .destructive) { remap.delete(rule.id) } label: { Image(systemName: "trash") }.accessibilityLabel("Delete").buttonStyle(.borderless)
                    }
                }
            } header: {
                HStack {
                    Text("Your rules")
                    Spacer()
                    Button { editing = newRule() } label: { Label("Add Rule", systemImage: "plus") }.controlSize(.small)
                }
            }

            Section {
                SliderRow(title: "Held after", value: Binding(get: { Double(config.holdMs) }, set: { v in remap.update { $0.holdMs = UInt32(v) } }),
                          range: 100...1000, format: { "\(Int($0)) ms" }, help: "How long a key is down before it counts as held.")
                SliderRow(title: "Double tap within", value: Binding(get: { Double(config.doubleTapMs) }, set: { v in remap.update { $0.doubleTapMs = UInt32(v) } }),
                          range: 100...600, format: { "\(Int($0)) ms" })
                SliderRow(title: "Pressed together within", value: Binding(get: { Double(config.chordMs) }, set: { v in remap.update { $0.chordMs = UInt32(v) } }),
                          range: 20...150, format: { "\(Int($0)) ms" })
            } header: { Text("Timing") }

            if let error = remap.lastError {
                Section { Text(error).font(.callout).foregroundStyle(Theme.danger) }
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editing) { rule in
            RemapRuleEditor(rule: rule) { saved in
                remap.upsert(saved)
                editing = nil
            } onCancel: { editing = nil }
        }
    }

    private func newRule() -> RemapRule {
        RemapRule(id: UUID().uuidString, name: "", enabled: true, keyCode: 54, modifiers: 0, appIds: [], tap: nil, hold: nil, doubleTap: nil, chordWith: [], keyboard: nil)
    }
}

// MARK: - Editing one rule

private struct RemapRuleEditor: View {
    @State var rule: RemapRule
    let onSave: (RemapRule) -> Void
    let onCancel: () -> Void
    @EnvironmentObject private var keyboards: KeyboardDevices
    @State private var together = false
    @State private var recordedFrom: RecordedShortcut?
    @State private var recordedTogether: RecordedShortcut?

    /// A rule saved with a keyboard's name (before keyboards had their own identity) is shown as that keyboard when it is connected.
    static func selectedKeyboard(_ saved: String?, _ devices: [KeyboardDevice]) -> String {
        guard let saved, !saved.isEmpty else { return "" }
        if devices.contains(where: { $0.id == saved }) { return saved }
        return devices.first(where: { $0.name == saved })?.id ?? saved
    }

    init(rule: RemapRule, onSave: @escaping (RemapRule) -> Void, onCancel: @escaping () -> Void) {
        _rule = State(initialValue: rule)
        self.onSave = onSave
        self.onCancel = onCancel
        _together = State(initialValue: !rule.chordWith.isEmpty)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Rule") {
                    TextField("Name", text: $rule.name, prompt: Text("For example, Caps Lock as Hyper"))
                    Picker("Key", selection: Binding(get: { rule.keyCode }, set: { rule.keyCode = $0 })) {
                        ForEach(RemapKeys.common, id: \.code) { Text($0.title).tag($0.code) }
                        if !RemapKeys.common.contains(where: { $0.code == rule.keyCode }) { Text(RemapKeys.name(rule.keyCode)).tag(rule.keyCode) }
                    }
                    Picker("Only on keyboard", selection: Binding(get: { Self.selectedKeyboard(rule.keyboard, keyboards.devices) }, set: { rule.keyboard = $0.isEmpty ? nil : $0 })) {
                        Text("Any keyboard").tag("")
                        ForEach(keyboards.devices) { Text($0.name).tag($0.id) }
                        // A keyboard this rule was made for that is not connected now, kept so saving does not quietly change the rule.
                        if let saved = rule.keyboard, !saved.isEmpty, !keyboards.devices.contains(where: { $0.id == Self.selectedKeyboard(saved, keyboards.devices) }) {
                            Text("\(KeyboardRuleMatch.title(for: saved, connected: keyboards.devices, remembered: keyboards.remembered)) (not connected)").tag(saved)
                        }
                    }
                    if rule.keyboard != nil {
                        Text("macOS does not say which keyboard a key press came from, so a rule for one keyboard is in force while that keyboard is connected, and then applies to typing on any keyboard.").font(.caption).foregroundStyle(.secondary)
                    }
                    if !KeyboardRuleMatch.lookAlikes(keyboards.devices).isEmpty {
                        Text("Two keyboards of one model that report no serial number look the same to Kriya, so a rule for one covers both.").font(.caption).foregroundStyle(.secondary)
                    }
                    LabeledContent("Or press another key") {
                        ShortcutRecorder(shortcut: Binding(get: { recordedFrom }, set: { v in
                            recordedFrom = v
                            if let v { rule.keyCode = v.keyCode }
                        }))
                    }
                }

                Section {
                    Toggle("Works only when pressed together with another key", isOn: $together.animation())
                    if together {
                        LabeledContent("The other key") {
                            ShortcutRecorder(shortcut: Binding(get: { recordedTogether }, set: { v in
                                recordedTogether = v
                                rule.chordWith = v.map { [$0.keyCode] } ?? []
                            }))
                        }
                    }
                } footer: { Text(together ? "Press both keys within a few milliseconds and they act as the one result below." : "") }

                Section(together ? "Result" : "When tapped") { OutputEditor(output: $rule.tap) }
                if !together {
                    Section("When held") { OutputEditor(output: $rule.hold) }
                    Section("When tapped twice") { OutputEditor(output: $rule.doubleTap) }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Save") {
                    var saved = rule
                    if saved.name.trimmingCharacters(in: .whitespaces).isEmpty { saved.name = RemapKeys.summary(saved) }
                    if !together { saved.chordWith = [] }
                    onSave(saved)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(rule.tap == nil && rule.hold == nil && rule.doubleTap == nil)
            }
            .padding(12)
        }
        .frame(width: 520, height: 600)
    }
}

/// What a key becomes: nothing, a key, a modifier or Hyper held down, or a saved action.
private struct OutputEditor: View {
    @Binding var output: RemapOutput?
    @EnvironmentObject private var library: ActionLibrary
    @State private var recorded: RecordedShortcut?

    private enum Choice: String, CaseIterable, Identifiable {
        case none = "Nothing", escape = "Escape", hyper = "Hyper (⌃⌥⇧⌘)", control = "Control", option = "Option", command = "Command"
        case shift = "Shift", key = "A key or shortcut", media = "A media key", action = "A saved action", disabled = "Disable the key"
        var id: String { rawValue }
    }

    private var choice: Choice {
        switch output {
        case .none: return .none
        case .some(.key(let code, let mods)):
            if code >= 1000 { return .media }
            return code == RemapKeys.escape && mods == 0 ? .escape : .key
        case .some(.modifiers(let mods)):
            switch mods {
            case RemapKeys.hyper: return .hyper
            case KeyModifiers.control: return .control
            case KeyModifiers.option: return .option
            case KeyModifiers.command: return .command
            case KeyModifiers.shift: return .shift
            default: return .hyper
            }
        case .some(.action): return .action
        case .some(.nothing): return .disabled
        }
    }

    private func set(_ choice: Choice) {
        switch choice {
        case .none: output = nil
        case .escape: output = .key(keyCode: RemapKeys.escape, modifiers: 0)
        case .hyper: output = .modifiers(modifiers: RemapKeys.hyper)
        case .control: output = .modifiers(modifiers: KeyModifiers.control)
        case .option: output = .modifiers(modifiers: KeyModifiers.option)
        case .command: output = .modifiers(modifiers: KeyModifiers.command)
        case .shift: output = .modifiers(modifiers: KeyModifiers.shift)
        case .key: if case .key(let code, _) = output, code < 1000 {} else { output = .key(keyCode: RemapKeys.escape, modifiers: 0) }
        case .media: output = .key(keyCode: RemapKeys.media[0].code, modifiers: 0)
        case .action: output = library.actions.first.map { .action(actionId: $0.id) }
        case .disabled: output = RemapOutput.nothing
        }
    }

    var body: some View {
        Picker("Does", selection: Binding(get: { choice }, set: { set($0) })) {
            ForEach(Choice.allCases) { Text($0.rawValue).tag($0) }
        }
        if choice == .key, case .some(.key(let code, let mods)) = output {
            LabeledContent("Key") {
                ShortcutRecorder(shortcut: Binding(
                    get: { recorded ?? RecordedShortcut(keyCode: code, modifiers: mods) },
                    set: { v in
                        recorded = v
                        if let v { output = .key(keyCode: v.keyCode, modifiers: v.modifiers) }
                    }
                ))
            }
        }
        if choice == .media, case .some(.key(let code, _)) = output {
            Picker("Media key", selection: Binding(get: { code }, set: { output = .key(keyCode: $0, modifiers: 0) })) {
                ForEach(RemapKeys.media, id: \.code) { Text($0.title).tag($0.code) }
            }
        }
        if choice == .action, case .some(.action(let id)) = output {
            Picker("Action", selection: Binding(get: { id }, set: { output = .action(actionId: $0) })) {
                ForEach(library.actions, id: \.id) { Text($0.name).tag($0.id) }
            }
        }
    }
}
