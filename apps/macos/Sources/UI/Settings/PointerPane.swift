import AppKit
import SwiftUI

/// Pointer effects: a halo, click rings, finding the pointer, a magnifier, hiding the pointer when idle, saved positions and
/// presentation settings.
struct PointerPane: View {
    @EnvironmentObject private var store: PointerEffectsStore
    @Environment(\.executor) private var executor
    @State private var editing: SavedPosition?
    @State private var screenAllowed = CGPreflightScreenCaptureAccess()

    private var config: PointerEffectsConfig { store.config }

    private func run(_ command: String) {
        guard let executor else { return }
        Task { _ = await executor.perform(.builtin(command: command)) }
    }

    var body: some View {
        Form {
            Section {
                Toggle("Use pointer effects", isOn: Binding(get: { config.enabled }, set: { v in store.update { $0.enabled = v } }))
            } footer: {
                Text("Off, nothing below is drawn and none of the commands do anything. Each effect also has its own switch.")
            }

            Section {
                Toggle("Highlight the pointer", isOn: Binding(get: { config.haloEnabled }, set: { v in store.update { $0.haloEnabled = v } }))
                Picker("Style", selection: Binding(get: { config.haloStyle }, set: { v in store.update { $0.haloStyle = v } })) {
                    Text("Soft disc").tag(HaloStyle.filled)
                    Text("Ring").tag(HaloStyle.ring)
                }
                .pickerStyle(.segmented)
                ColorPicker("Color", selection: Binding(get: { Color.fromHex(config.haloColor) }, set: { v in store.update { $0.haloColor = v.hexString } }), supportsOpacity: false)
                SliderRow(title: "Size", value: Binding(get: { config.haloSize }, set: { v in store.update { $0.haloSize = v } }), range: 20...300, format: { "\(Int($0)) pt" })
                SliderRow(title: "Strength", value: Binding(get: { config.haloOpacity }, set: { v in store.update { $0.haloOpacity = v } }), range: 0.05...1, format: { "\(Int($0 * 100))%" })
                Toggle("Breathe slowly", isOn: Binding(get: { config.haloPulse }, set: { v in store.update { $0.haloPulse = v } }))
            } header: { Text("Highlight") }

            Section {
                Toggle("Show a ring at every click", isOn: Binding(get: { config.clickEnabled }, set: { v in store.update { $0.clickEnabled = v } }))
                ColorPicker("Left click", selection: Binding(get: { Color.fromHex(config.leftClickColor) }, set: { v in store.update { $0.leftClickColor = v.hexString } }), supportsOpacity: false)
                ColorPicker("Right and other clicks", selection: Binding(get: { Color.fromHex(config.rightClickColor) }, set: { v in store.update { $0.rightClickColor = v.hexString } }), supportsOpacity: false)
                SliderRow(title: "Size", value: Binding(get: { config.clickSize }, set: { v in store.update { $0.clickSize = v } }), range: 20...200, format: { "\(Int($0)) pt" })
                SliderRow(title: "Lasts", value: Binding(get: { Double(config.clickDurationMs) }, set: { v in store.update { $0.clickDurationMs = UInt32(v) } }), range: 150...2000, format: { "\(Int($0)) ms" })
            } header: { Text("Clicks") }

            Section {
                SliderRow(title: "Ring size", value: Binding(get: { config.locateSize }, set: { v in store.update { $0.locateSize = v } }), range: 100...600, format: { "\(Int($0)) pt" })
                Button("Try It") { run("pointer.locate") }
            } header: { Text("Find the pointer") } footer: {
                Text("Three rings spread out from the pointer. Give the command “Find the pointer” a shortcut, a button or a hot corner.")
            }

            Section {
                Picker("Hold to show it", selection: Binding(get: { config.magnifierHoldModifier }, set: { v in store.update { $0.magnifierHoldModifier = v } })) {
                    ForEach(KeyModifiers.choices, id: \.bits) { Text($0.bits == 0 ? "Off" : $0.title).tag($0.bits) }
                }
                SliderRow(title: "Zoom", value: Binding(get: { config.magnifierZoom }, set: { v in store.update { $0.magnifierZoom = v } }), range: 1.5...8, format: { String(format: "%.1f×", $0) })
                SliderRow(title: "Size", value: Binding(get: { config.magnifierSize }, set: { v in store.update { $0.magnifierSize = v } }), range: 120...500, format: { "\(Int($0)) pt" })
                Picker("Shape", selection: Binding(get: { config.magnifierShape }, set: { v in store.update { $0.magnifierShape = v } })) {
                    Text("Circle").tag(MagnifierShape.circle)
                    Text("Square").tag(MagnifierShape.square)
                }
                .pickerStyle(.segmented)
                HStack {
                    StateBadge(text: screenAllowed ? "Screen Recording is allowed" : "Needs Screen Recording", color: screenAllowed ? Theme.ok : Theme.warn)
                    Spacer()
                    if !screenAllowed {
                        Button("Allow…") { CGRequestScreenCaptureAccess(); screenAllowed = CGPreflightScreenCaptureAccess() }
                    }
                    Button("Try It") { run("pointer.magnifier") }
                }
            } header: { Text("Magnifier") } footer: {
                Text("A zoomed view around the pointer, in a small window that follows it. Use “Magnify around the pointer” to turn it on and off, and the zoom in and zoom out commands to change it while it is on. Kriya sees the screen only for this and never records it.")
            }

            Section {
                Toggle("Hide the pointer when it is still", isOn: Binding(get: { config.hideWhenIdle }, set: { v in store.update { $0.hideWhenIdle = v } }))
                SliderRow(title: "After", value: Binding(get: { config.hideAfterSeconds }, set: { v in store.update { $0.hideAfterSeconds = v } }), range: 1...60, format: { "\(Int($0)) s" })
            } header: { Text("Hiding") } footer: {
                Text("The pointer comes back the moment you move it. The command “Show the pointer now” brings it back too. macOS only lets the app in front hide the pointer, so this asks the window server to allow it; if that does not work on your Mac the pointer simply stays visible.")
            }

            Section {
                if config.positions.isEmpty {
                    Text("None yet. A saved position is a spot on a display that the pointer can jump to with a shortcut.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(config.positions) { position in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(position.name)
                            Text("\(position.display.map { "Display \($0 + 1)" } ?? "Current display") · \(Int(position.x * 100))%, \(Int(position.y * 100))%")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Edit") { editing = position }.controlSize(.small)
                        Button { store.delete(position.id) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                    }
                }
            } header: {
                HStack {
                    Text("Saved positions")
                    Spacer()
                    Button { editing = store.newPosition() } label: { Label("Add Position", systemImage: "plus") }.controlSize(.small)
                }
            } footer: {
                Text("Each position is a command named “Pointer: …” for a shortcut, a button or a gesture. Moving the pointer to the next or previous display, and to the middle of the front window, are also commands.")
            }

            Section {
                Toggle("Show the effects to people watching a shared screen or a recording", isOn: Binding(get: { config.showWhenSharing }, set: { v in store.update { $0.showWhenSharing = v } }))
                Button("Presentation Mode On or Off") { run("pointer.presentation") }
            } header: { Text("Presenting") } footer: {
                Text("Presentation mode turns on the highlight and the click rings together, whatever their own switches say. Off, the effects are hidden from screen sharing and recordings where macOS allows it, so you see them and your audience does not; turn this on to show them. Some sharing tools capture regardless.")
            }

            if let error = store.lastError {
                Section { Text(error).font(.callout).foregroundStyle(Theme.danger) }
            }
        }
        .formStyle(.grouped)
        .animation(.smooth(duration: 0.25), value: config.positions)
        .sheet(item: $editing) { position in
            PositionEditor(position: position, onSave: { store.upsert($0); editing = nil }, onCancel: { editing = nil })
        }
        .onAppear { screenAllowed = CGPreflightScreenCaptureAccess() }
    }
}

private struct PositionEditor: View {
    @State var position: SavedPosition
    let onSave: (SavedPosition) -> Void
    let onCancel: () -> Void

    private var problem: String? {
        position.name.trimmingCharacters(in: .whitespaces).isEmpty ? "Give the position a name." : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $position.name)
                    Picker("Display", selection: Binding(get: { Int(position.display ?? 99) }, set: { position.display = $0 == 99 ? nil : UInt32($0) })) {
                        Text("The one the pointer is on").tag(99)
                        ForEach(0..<4, id: \.self) { Text("Display \($0 + 1) (left to right)").tag($0) }
                    }
                }
                Section {
                    HStack(spacing: 12) {
                        anchors
                        VStack {
                            SliderRow(title: "Across", value: $position.x, range: 0...1, format: { "\(Int($0 * 100))%" })
                            SliderRow(title: "Down", value: $position.y, range: 0...1, format: { "\(Int($0 * 100))%" })
                        }
                    }
                } header: { Text("Where on the display") }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                if let problem { Text(problem).font(.callout).foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Save") { onSave(position) }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(problem != nil)
            }
            .padding(14)
        }
        .frame(width: 520, height: 420)
    }

    /// Nine spots to start from: corners, edges and the middle.
    private var anchors: some View {
        VStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { row in
                HStack(spacing: 4) {
                    ForEach(0..<3, id: \.self) { column in
                        let x = Double(column) / 2
                        let y = Double(row) / 2
                        let selected = abs(position.x - x) < 0.01 && abs(position.y - y) < 0.01
                        Button { position.x = x; position.y = y } label: {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(selected ? Theme.accent : Color.primary.opacity(0.12))
                                .frame(width: 26, height: 18)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}
