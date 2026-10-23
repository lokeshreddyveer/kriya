import SwiftUI

/// Brightness and input for external monitors that answer DDC/CI, and presets that set several at once.
struct MonitorControlTab: View {
    @ObservedObject private var ddc = DDCController.shared
    @State private var presetName = ""
    @State private var switching: (id: String, code: Int)?
    @State private var applying: MonitorPreset?
    @State private var draft: [String: Double] = [:]

    var body: some View {
        Form {
            Section {
                if ddc.monitors.isEmpty {
                    Text(ddc.busy ? "Asking the monitors…" : (ddc.status ?? "Press Look for Monitors.")).font(.callout).foregroundStyle(.secondary)
                }
                ForEach(ddc.monitors) { monitor in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(monitor.name).font(.headline)
                        if let percent = monitor.brightnessPercent {
                            HStack {
                                Image(systemName: "sun.min").accessibilityHidden(true)
                                Slider(value: Binding(get: { draft[monitor.id] ?? Double(percent) }, set: { draft[monitor.id] = $0 }), in: 0...100, step: 1) { editing in
                                    if !editing, let value = draft[monitor.id] { ddc.setBrightness(monitor.id, percent: Int(value)); draft[monitor.id] = nil }
                                }
                                .accessibilityLabel("\(monitor.name) brightness")
                                Image(systemName: "sun.max").accessibilityHidden(true)
                                Text("\(Int(draft[monitor.id] ?? Double(percent)))%").monospacedDigit().frame(width: 44, alignment: .trailing)
                            }
                        }
                        if let input = monitor.input {
                            HStack {
                                Picker("Input", selection: Binding(get: { input.current }, set: { switching = (monitor.id, $0) })) {
                                    ForEach(inputChoices(current: input.current), id: \.code) { Text($0.name).tag($0.code) }
                                }
                                if monitor.previousInput != nil { Button("Switch Back") { ddc.switchBack(monitor.id) }.controlSize(.small) }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                HStack {
                    Button("Look for Monitors") { ddc.refresh() }.disabled(ddc.busy)
                    if ddc.busy { ProgressView().controlSize(.small) }
                }
            } header: { Text("External monitors") } footer: {
                Text("Works with monitors that accept DDC/CI over their cable, on Apple silicon Macs. Many monitors, docks and adapters do not, and the settings that appear are only those the monitor reports. Switching to an input with nothing connected can make the screen go dark: change it back with the monitor's own buttons, or use Switch Back here from another display.")
            }

            Section {
                ForEach(ddc.presets) { preset in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(preset.name)
                            Text(MonitorPresets.plan(preset, connected: ddc.monitors.map(\.name)).joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer()
                        Button("Apply…") { applying = preset }.controlSize(.small)
                        Button(role: .destructive) { ddc.presets.removeAll { $0.id == preset.id } } label: { Image(systemName: "trash") }.buttonStyle(.borderless).accessibilityLabel("Delete \(preset.name)")
                    }
                }
                HStack {
                    TextField("Name for the current settings", text: $presetName)
                    Button("Save as Preset") { ddc.savePreset(named: presetName); presetName = "" }.disabled(presetName.trimmingCharacters(in: .whitespaces).isEmpty || ddc.monitors.isEmpty)
                }
                if ddc.undoSettings != nil { Button("Undo the Last Preset") { ddc.undoLastPreset() } }
            } header: { Text("Presets") } footer: {
                Text("A preset keeps each monitor's brightness and input. Applying one shows what it will change first, and the settings before it are kept so it can be undone.")
            }
        }
        .formStyle(.grouped)
        .onAppear { ddc.startWatching(); if ddc.monitors.isEmpty { ddc.refresh() } }
        .confirmationDialog("Switch input?", isPresented: Binding(get: { switching != nil }, set: { if !$0 { switching = nil } }), titleVisibility: .visible) {
            Button("Switch to \(DDC.inputName(switching?.code ?? 0))") { if let s = switching { ddc.setInput(s.id, code: s.code) }; switching = nil }
        } message: {
            Text("If nothing is connected to that input, the monitor may show nothing. Switch Back, or the monitor's own buttons, return it.")
        }
        .confirmationDialog("Apply \(applying?.name ?? "")?", isPresented: Binding(get: { applying != nil }, set: { if !$0 { applying = nil } }), titleVisibility: .visible) {
            Button("Apply") { if let p = applying { ddc.apply(p) }; applying = nil }
        } message: {
            Text(applying.map { MonitorPresets.plan($0, connected: ddc.monitors.map(\.name)).joined(separator: "\n") } ?? "")
        }
    }

    private func inputChoices(current: Int) -> [(code: Int, name: String)] {
        DDC.inputs.contains { $0.code == current } ? DDC.inputs : DDC.inputs + [(current, DDC.inputName(current))]
    }
}
