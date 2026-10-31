import SwiftUI

/// Mouse buttons held together, with keys, doing something when the chord is pressed, released, clicked, held or dragged. Off by default,
/// because a button that could join a chord is held back for a moment, so it cannot click the instant it is pressed.
struct ButtonChordSection: View {
    @EnvironmentObject private var mouse: MouseStore
    @EnvironmentObject private var drag: DragToolsStore
    @State private var settings = ButtonChordStore().settings

    private let buttons: [UInt32] = [0, 1, 2, 3, 4, 5]
    private let keys: [(String, UInt64)] = [("No keys", 0), ("⌥ Option", KeyModifiers.option), ("⌃ Control", KeyModifiers.control), ("⇧ Shift", KeyModifiers.shift), ("⌘ Command", KeyModifiers.command)]

    private var conflicts: [ChordConflict] {
        let defaultRules = mouse.defaultPreset?.settings.buttons ?? []
        return ButtonChordConflicts.find(rules: settings.rules, buttonRules: defaultRules, doubleClicks: drag.config.doubleClicks, drag: drag.config)
    }

    private func rule(_ index: Int) -> Binding<ButtonChordRule> {
        Binding(get: { settings.rules.indices.contains(index) ? settings.rules[index] : ButtonChordRule(chord: ButtonChord(pressedButtons: [], modifiers: 0, phase: .down), actionId: "") },
                set: { if settings.rules.indices.contains(index) { settings.rules[index] = $0 } })
    }

    private func has(_ button: UInt32, in index: Int) -> Binding<Bool> {
        Binding(get: { settings.rules.indices.contains(index) && settings.rules[index].chord.pressedButtons.contains(button) },
                set: { on in
                    guard settings.rules.indices.contains(index) else { return }
                    if on { settings.rules[index].chord.pressedButtons.insert(button) } else { settings.rules[index].chord.pressedButtons.remove(button) }
                })
    }

    private func action(_ index: Int) -> Binding<String?> {
        Binding(get: { settings.rules.indices.contains(index) ? Optional(settings.rules[index].actionId).flatMap { $0.isEmpty ? nil : $0 } : nil },
                set: { if settings.rules.indices.contains(index) { settings.rules[index].actionId = $0 ?? "" } })
    }

    var body: some View {
        Section {
            Toggle("Button chords", isOn: $settings.enabled)
            if settings.enabled {
                let all = conflicts
                ForEach(Array(settings.rules.enumerated()), id: \.element.id) { index, item in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(item.chord.pressedButtons.isEmpty ? "New chord" : item.chord.title).font(.headline)
                            Spacer()
                            Button(role: .destructive) { settings.rules.remove(at: index) } label: { Image(systemName: "trash") }.buttonStyle(.borderless).help("Remove this chord")
                        }
                        HStack(spacing: 10) {
                            ForEach(buttons, id: \.self) { b in
                                Toggle(ButtonChord.name(b), isOn: has(b, in: index)).toggleStyle(.checkbox)
                            }
                        }
                        HStack {
                            Picker("Keys", selection: rule(index).chord.modifiers) { ForEach(keys, id: \.1) { Text($0.0).tag($0.1) } }
                            Picker("When", selection: rule(index).chord.phase) { ForEach(ButtonPhase.allCases) { Text($0.title).tag($0) } }
                        }
                        ActionPicker(actionID: action(index))
                        if !item.chord.isValid {
                            Label("A chord needs two to four buttons.", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
                        } else if !item.isSafe {
                            Label("Left or right with no keys held would hold back every ordinary click, so this chord is never run. Add a key, or use other buttons.", systemImage: "xmark.octagon.fill").foregroundStyle(.red).font(.callout)
                        }
                        ForEach(Array(Set(all.filter { $0.index == index })).sorted { ($0.severity.rawValue, $0.message) > ($1.severity.rawValue, $1.message) }, id: \.self) { c in
                            Label(c.message, systemImage: c.severity == .info ? "info.circle" : "exclamationmark.triangle.fill")
                                .foregroundStyle(c.severity == .error ? Color.red : c.severity == .warning ? Color.orange : Color.secondary).font(.callout)
                        }
                    }
                    .padding(.vertical, 4)
                }
                HStack {
                    Button("Add a Chord") {
                        settings.rules.append(ButtonChordRule(chord: ButtonChord(pressedButtons: [3, 4], modifiers: 0, phase: .down), actionId: ""))
                    }
                    Spacer()
                }
                if settings.rules.contains(where: { $0.chord.phase == .hold }) {
                    LabeledContent("Held means") { slider($settings.holdMs, 150...3000, "ms") }
                }
                if settings.rules.contains(where: { $0.chord.phase == .click || $0.chord.phase == .doubleClick }) {
                    LabeledContent("A click is no longer than") { slider($settings.clickMs, 80...1000, "ms") }
                }
                if settings.rules.contains(where: { $0.chord.phase == .doubleClick }) {
                    LabeledContent("Two clicks within") { slider($settings.doubleClickMs, 100...1500, "ms") }
                }
                LabeledContent("Buttons pressed together within") { slider($settings.settleMs, 30...400, "ms") }
                HStack {
                    Button("Reset Timings") {
                        let d = ButtonChordSettings()
                        settings.holdMs = d.holdMs; settings.clickMs = d.clickMs; settings.doubleClickMs = d.doubleClickMs; settings.settleMs = d.settleMs
                    }.controlSize(.small)
                    Spacer()
                }
            }
        } header: { Text("Button chords") } footer: {
            Text("A chord is two to four buttons held together, with keys if you like. A button that could still become part of a chord waits a moment (the “together within” time) before the app sees it; if no chord forms, it is sent on as the ordinary press it was, so the button’s own rule or click still happens. Left and right with no keys are never used, since that would delay every click. A chord that clashes with a drag tool, a hold rule or a double-click rule is shown in red: the other one takes the button first. Buttons are numbered Left, Right, Middle, then Button 4 and up.")
        }
        .onChange(of: settings) { _, value in ButtonChordStore().settings = value }
    }

    private func slider(_ value: Binding<Double>, _ range: ClosedRange<Double>, _ unit: String) -> some View {
        HStack { Slider(value: value, in: range).frame(width: 150); Text("\(Int(value.wrappedValue)) \(unit)").monospacedDigit().frame(width: 62, alignment: .trailing) }
    }
}
