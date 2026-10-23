import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MousePane: View {
    @EnvironmentObject private var mouse: MouseStore
    @EnvironmentObject private var config: ConfigStore
    @EnvironmentObject private var services: ServiceManager
    @EnvironmentObject private var permissions: PermissionManager

    @State private var tab: Tab = .devices

    enum Tab: String, CaseIterable, Identifiable {
        case devices = "Devices", presets = "Presets", apps = "Apps", drag = "Drag"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            if !config.isEnabled(.mouse) || services.state(.mouse) != .running {
                statusBar
                    .padding(.horizontal, 20).padding(.top, 10)
                    .transition(.opacity)
            }
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .paneTabBar(maxWidth: 400)
            .paneHeader()

            Group {
                switch tab {
                case .devices: MouseDevicesTab()
                case .presets: MousePresetsTab()
                case .apps: MouseAppsTab()
                case .drag: DragToolsTab()
                }
            }
            .id(tab)
            .transition(.opacity)
        }
        .animation(.smooth(duration: 0.22), value: tab)
        .animation(.smooth(duration: 0.25), value: services.state(.mouse))
        .overlay(alignment: .bottom) {
            if let error = mouse.lastError {
                Text(error)
                    .font(.callout).padding(10)
                    .background(Theme.danger.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                    .padding()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.25), value: mouse.lastError)
    }

    private var statusBar: some View {
        let state = services.state(.mouse)
        return Banner(
            symbol: "computermouse", tint: state == .running ? Theme.ok : Theme.warn, title: "Mouse & Trackpad is \(config.isEnabled(.mouse) ? state.label.lowercased() : "off")",
            message: "Your changes are saved, but they only take effect while the feature is on and allowed."
        ) {
            if !config.isEnabled(.mouse) {
                Button("Turn On") { services.setFeature(.mouse, enabled: true) }.controlSize(.small)
            } else if case .needsPermission(let missing) = state, let first = missing.first {
                Button("Allow \(first.title)…") { permissions.request(first) }.controlSize(.small)
            }
        }
    }
}

// MARK: - Devices

private struct MouseDevicesTab: View {
    @EnvironmentObject private var devices: DeviceRegistry
    @EnvironmentObject private var mouse: MouseStore

    var body: some View {
        Form {
            if devices.devices.isEmpty {
                Section {
                    Text("No mice or trackpads found yet. Plug one in or pair a Bluetooth device.")
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                ForEach(devices.devices) { device in
                    DeviceAssignmentRow(device: device)
                }
            } header: {
                Text("Settings for each device")
            } footer: {
                Text("Each mouse or trackpad can use its own preset. “Same as default” uses the default preset, set under Presets. Kriya tells devices apart by watching which one you used last, which can be off by a moment if you use two at once.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct DeviceAssignmentRow: View {
    let device: InputDevice
    @EnvironmentObject private var mouse: MouseStore
    @EnvironmentObject private var registry: DeviceRegistry

    private var choice: Binding<String> {
        Binding(
            get: { mouse.assignment(device: device.id, app: nil)?.presetId ?? "" },
            set: { mouse.setAssignment(device: device.id, app: nil, preset: $0.isEmpty ? nil : $0) }
        )
    }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: device.record.kind.symbol)
                .font(.title2).frame(width: 30)
                .foregroundStyle(device.isConnected ? Theme.accent : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.displayName).font(.headline)
                HStack(spacing: 6) {
                    Label(device.connection.title, systemImage: device.connection.symbol)
                    Text("·")
                    Text(device.isConnected ? "Connected" : "Not connected")
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Preset", selection: choice) {
                Text("Same as default").tag("")
                ForEach(mouse.presets) { Text($0.name).tag($0.id) }
            }
            .labelsHidden()
            .frame(width: 200)
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Presets

private struct MousePresetsTab: View {
    @EnvironmentObject private var mouse: MouseStore

    @State private var selectedID: String = MouseStore.defaultPresetID
    @State private var naming = false
    @State private var newName = ""
    @State private var confirmReset = false
    @State private var message: String?

    private var selected: MousePreset? { mouse.preset(selectedID) ?? mouse.defaultPreset }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 220)
            Divider()
            if let preset = selected {
                PresetEditor(preset: preset)
                    .id(preset.id)
                    .transition(.opacity)
                    .frame(maxWidth: .infinity)
            }
        }
        .animation(.smooth(duration: 0.2), value: selected?.id)
        .alert("New preset", isPresented: $naming) {
            TextField("Name", text: $newName)
            Button("Create") { create() }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Restore mouse settings?", isPresented: $confirmReset) {
            Button("Reset the Default Preset") { mouse.restoreDefaults(everything: false) }
            Button("Reset Everything", role: .destructive) {
                selectedID = MouseStore.defaultPresetID
                mouse.restoreDefaults(everything: true)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("“Everything” also removes your own presets, device and app assignments and app exclusions.")
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: Binding(get: { selected?.id }, set: { if let id = $0 { selectedID = id } })) {
                Section("Presets") {
                    ForEach(mouse.presets) { preset in
                        HStack(spacing: 8) {
                            Image(systemName: preset.id == mouse.config.defaultPresetId ? "star.fill" : (preset.isBuiltin ? "lock" : "slider.horizontal.3"))
                                .foregroundStyle(preset.id == mouse.config.defaultPresetId ? Theme.warn : .secondary)
                                .frame(width: 16)
                            Text(preset.name).lineLimit(1)
                        }
                        .tag(preset.id)
                    }
                }
            }
            Divider()
            HStack(spacing: 4) {
                Button { newName = ""; naming = true } label: { Image(systemName: "plus") }
                Button { duplicate() } label: { Image(systemName: "plus.square.on.square") }.help("Duplicate").accessibilityLabel("Duplicate")
                Button { delete() } label: { Image(systemName: "minus") }
                    .disabled(selected?.isBuiltin ?? true)
                Spacer()
                Menu {
                    Button("Import Preset…") { importPreset() }
                    Button("Export Preset…") { exportPreset() }
                    Divider()
                    Button("Restore Defaults…") { confirmReset = true }
                } label: { MoreMenuLabel() }
                    .menuStyle(.button).menuIndicator(.hidden).fixedSize()
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
    }

    private func create() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let id = mouse.createPreset(named: name) else { return }
        withAnimation(.smooth) { selectedID = id }
    }

    private func duplicate() {
        guard let id = mouse.duplicate(presetID: selectedID) else { return }
        withAnimation(.smooth) { selectedID = id }
    }

    private func delete() {
        guard let preset = selected, !preset.isBuiltin else { return }
        mouse.deletePreset(preset.id)
        withAnimation(.smooth) { selectedID = MouseStore.defaultPresetID }
    }

    private func exportPreset() {
        guard let preset = selected else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(preset.name).kriyapreset.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try mouse.exportPreset(preset.id, to: url) } catch { mouse.lastError = error.userMessage }
    }

    private func importPreset() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let preset = try mouse.importPreset(from: url)
            withAnimation(.smooth) { selectedID = preset.id }
        } catch {
            mouse.lastError = error.userMessage
        }
    }
}

private struct PresetEditor: View {
    let preset: MousePreset
    @EnvironmentObject private var mouse: MouseStore

    @State private var section: Section = .scrolling
    @State private var name = ""

    enum Section: String, CaseIterable, Identifiable {
        case scrolling = "Scrolling", pointer = "Pointer", buttons = "Buttons", gestures = "Gestures"
        var id: String { rawValue }
    }

    private var readOnly: Bool { preset.id.hasPrefix("builtin.") }

    var body: some View {
        VStack(spacing: 0) {
            header
            Picker("", selection: $section) {
                ForEach(Section.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            .padding(.horizontal, 20).padding(.bottom, 4)

            Group {
                switch section {
                case .scrolling: ScrollingEditor(presetID: preset.id)
                case .pointer: PointerEditor(presetID: preset.id)
                case .buttons: ButtonsEditor(presetID: preset.id)
                case .gestures: GesturesEditor(presetID: preset.id)
                }
            }
            .disabled(readOnly)
            .id(section)
            .transition(.opacity)
        }
        .animation(.smooth(duration: 0.2), value: section)
        .onAppear { name = preset.name }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if preset.id == MouseStore.defaultPresetID || readOnly {
                    Text(preset.name).font(.title3.bold())
                } else {
                    TextField("Name", text: $name)
                        .textFieldStyle(.roundedBorder).font(.title3.bold()).frame(maxWidth: 280)
                        .onSubmit { mouse.rename(presetID: preset.id, to: name) }
                }
                Spacer()
                if preset.id != mouse.config.defaultPresetId {
                    Button("Use as Default") { mouse.setDefaultPreset(preset.id) }.controlSize(.small)
                } else {
                    Label("Default", systemImage: "star.fill").foregroundStyle(Theme.warn).font(.callout)
                }
            }
            if readOnly {
                HStack {
                    Image(systemName: "lock").foregroundStyle(.secondary)
                    Text("Built-in presets cannot be changed.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Duplicate to Edit") { mouse.duplicate(presetID: preset.id) }.controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }
}

// MARK: - Scrolling

private struct ScrollingEditor: View {
    let presetID: String
    @EnvironmentObject private var mouse: MouseStore

    @State private var linked = true

    private var vertical: Binding<ScrollAxis> { mouse.binding(presetID, \.vertical) }
    private var horizontal: Binding<ScrollAxis> { mouse.binding(presetID, \.horizontal) }

    var body: some View {
        Form {
            Section {
                Toggle("Same settings for both directions", isOn: $linked.animation(.smooth))
            }
            axisSection(title: linked ? "Scrolling" : "Vertical scrolling", axis: vertical, linkedTo: linked ? horizontal : nil)
            if !linked {
                axisSection(title: "Horizontal scrolling", axis: horizontal, linkedTo: nil)
            }
            Section {
                Picker("Hold to scroll sideways", selection: mouse.binding(presetID, \.horizontalScrollModifier)) {
                    ForEach(KeyModifiers.choices, id: \.bits) { Text($0.bits == 0 ? "Off" : $0.title).tag($0.bits) }
                }
                Picker("Hold for plain scrolling", selection: mouse.binding(presetID, \.rawScrollModifier)) {
                    ForEach(KeyModifiers.choices, id: \.bits) { Text($0.bits == 0 ? "Off" : $0.title).tag($0.bits) }
                }
            } header: { Text("With a key held") } footer: {
                Text("Sideways turns the wheel's up and down into left and right. Plain scrolling skips smoothing, acceleration and speed changes for as long as the keys are held.")
            }
            Section {
                Text("A mouse wheel gets every setting. A trackpad or Magic Mouse already scrolls smoothly, so only direction and speed apply to it. “Reverse” flips how macOS is set for the device; set it against the Natural scrolling option in System Settings.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { linked = mouse.preset(presetID)?.settings.vertical == mouse.preset(presetID)?.settings.horizontal }
    }

    @ViewBuilder
    private func axisSection(title: String, axis: Binding<ScrollAxis>, linkedTo other: Binding<ScrollAxis>?) -> some View {
        let write: (ScrollAxis) -> Void = { new in
            axis.wrappedValue = new
            other?.wrappedValue = new
        }
        let value = axis.wrappedValue
        Section(title) {
            Toggle("Reverse direction", isOn: Binding(get: { value.reverse }, set: { var v = value; v.reverse = $0; write(v) }))
            SliderRow(title: "Speed", value: Binding(get: { value.speed }, set: { var v = value; v.speed = $0; write(v) }),
                      range: 0.2...4, format: { String(format: "%.1f×", $0) })
            SliderRow(title: "Smooth scrolling", value: Binding(get: { value.smoothing }, set: { var v = value; v.smoothing = $0; write(v) }),
                      range: 0...1, format: { $0 == 0 ? "Off" : "\(Int($0 * 100))%" },
                      help: "Glides to a stop after each wheel click.")
            SliderRow(title: "Acceleration", value: Binding(get: { value.acceleration }, set: { var v = value; v.acceleration = $0; write(v) }),
                      range: 0...1, format: { $0 == 0 ? "Off" : "\(Int($0 * 100))%" },
                      help: "Scrolls further the faster you turn the wheel.")
            SliderRow(title: "Sensitivity", value: Binding(get: { value.sensitivity }, set: { var v = value; v.sensitivity = $0; write(v) }),
                      range: 0.25...4, format: { String(format: "%.2f×", $0) },
                      help: "How strongly small wheel movements count.")
        }
    }
}

// MARK: - Pointer

private struct PointerEditor: View {
    let presetID: String
    @EnvironmentObject private var mouse: MouseStore

    private var pointer: Binding<PointerSettings> { mouse.binding(presetID, \.pointer) }

    var body: some View {
        let value = pointer.wrappedValue
        Form {
            Section {
                Picker("Acceleration", selection: Binding(get: { value.acceleration }, set: { var v = value; v.acceleration = $0; pointer.wrappedValue = v })) {
                    ForEach(PointerAccelerationPreset.all, id: \.self) { Text($0.title).tag($0) }
                }
                if value.acceleration == .custom {
                    SliderRow(title: "Tracking speed", value: Binding(get: { value.customSpeed }, set: { var v = value; v.customSpeed = $0; pointer.wrappedValue = v }),
                              range: 0...3, format: { String(format: "%.2f", $0) })
                        .transition(.opacity)
                }
            } header: {
                Text("Pointer speed")
            } footer: {
                Text("“System setting” leaves macOS alone. Kriya sets the speed for this device only and puts it back when the feature is turned off or Kriya quits.")
            }

            Section {
                Picker("Hold to slow down", selection: Binding(get: { value.precisionModifier }, set: { var v = value; v.precisionModifier = $0; pointer.wrappedValue = v })) {
                    ForEach(KeyModifiers.choices, id: \.bits) { Text($0.title).tag($0.bits) }
                }
                if value.precisionModifier != 0 {
                    SliderRow(title: "Slow-down", value: Binding(get: { value.precisionFactor }, set: { var v = value; v.precisionFactor = $0; pointer.wrappedValue = v }),
                              range: 0.1...1, format: { "\(Int($0 * 100))%" }, help: "The share of normal speed while the key is held.")
                        .transition(.opacity)
                }
            } header: {
                Text("Precision mode")
            } footer: {
                Text("Hold the key to move the pointer slowly for fine work. It has no effect when acceleration is set to “System setting” or “No acceleration”.")
            }
        }
        .formStyle(.grouped)
        .animation(.smooth(duration: 0.25), value: value.acceleration)
        .animation(.smooth(duration: 0.25), value: value.precisionModifier)
    }
}

// MARK: - Buttons

private struct ButtonsEditor: View {
    let presetID: String
    @EnvironmentObject private var mouse: MouseStore

    private var rules: Binding<[ButtonRule]> { mouse.binding(presetID, \.buttons) }

    var body: some View {
        Form {
            Section {
                if rules.wrappedValue.isEmpty {
                    Text("No button rules. Add one to make an extra button, the middle button, or a button with a key held do something.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(rules.wrappedValue.indices, id: \.self) { index in
                    if index < rules.wrappedValue.count { row(index) }
                }
            } header: {
                HStack {
                    Text("Button rules")
                    Spacer()
                    Button { addRule() } label: { Label("Add Rule", systemImage: "plus") }.controlSize(.small)
                }
            } footer: {
                Text("A rule replaces the button's normal click with an action: a keyboard shortcut, an app, a window action, a script or a Shortcut. The left and right buttons cannot be changed. “When held” runs the rule only if the button is kept down for a moment: let go sooner and the click goes through as usual. A button can have a click rule and a hold rule.")
            }

            if rules.wrappedValue.contains(where: { $0.trigger == .hold }) {
                Section {
                    SliderRow(
                        title: "Hold time", value: Binding(get: { Double(holdMs.wrappedValue) }, set: { holdMs.wrappedValue = UInt32($0) }),
                        range: 150...1500, format: { "\(Int($0)) ms" }, help: "How long a button is held before its hold rule runs."
                    )
                } header: { Text("Holding") } footer: {
                    Text("A button with a hold rule is held back for this long to tell a hold from a click, so a plain click of that button reaches the app a moment later. The button that starts gestures cannot also have a hold rule.")
                }
            }
        }
        .formStyle(.grouped)
        .animation(.smooth(duration: 0.25), value: rules.wrappedValue.count)
    }

    private var holdMs: Binding<UInt32> { mouse.binding(presetID, \.holdMs) }

    private func row(_ index: Int) -> some View {
        let rule = rules.wrappedValue[index]
        return HStack(spacing: 12) {
            Picker("Button", selection: Binding(get: { rule.button }, set: { new in edit(index) { $0.button = new } })) {
                ForEach(MouseButtons.remappable, id: \.self) { Text(MouseButtons.name($0)).tag($0) }
            }
            .labelsHidden().frame(width: 150)
            Picker("When", selection: Binding(get: { rule.trigger }, set: { new in edit(index) { $0.trigger = new } })) {
                Text("Clicked").tag(ButtonTrigger.click)
                Text("Held").tag(ButtonTrigger.hold)
            }
            .labelsHidden().frame(width: 100)
            Picker("With", selection: Binding(get: { rule.modifiers }, set: { new in edit(index) { $0.modifiers = new } })) {
                ForEach(KeyModifiers.choices, id: \.bits) { Text($0.title).tag($0.bits) }
            }
            .labelsHidden().frame(width: 150)
            Image(systemName: "arrow.right").foregroundStyle(.secondary)
            ActionPicker(actionID: Binding(
                get: { rule.actionId },
                set: { if let id = $0 { edit(index) { $0.actionId = id } } }
            ), allowNone: false)
            Spacer()
            Button(role: .destructive) { remove(index) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
        }
    }

    private func edit(_ index: Int, _ change: (inout ButtonRule) -> Void) {
        var list = rules.wrappedValue
        guard index < list.count else { return }
        change(&list[index])
        rules.wrappedValue = list
    }

    private func remove(_ index: Int) {
        var list = rules.wrappedValue
        guard index < list.count else { return }
        list.remove(at: index)
        withAnimation(.smooth) { rules.wrappedValue = list }
    }

    private func addRule() {
        let used = Set(rules.wrappedValue.filter { $0.trigger == .click }.map { ButtonKey(button: $0.button, modifiers: $0.modifiers) })
        guard let button = MouseButtons.remappable.first(where: { !used.contains(ButtonKey(button: $0, modifiers: 0)) }) else { return }
        guard let action = mouse.firstActionID else {
            mouse.lastError = "Create a saved action first, under Actions."
            return
        }
        withAnimation(.smooth) { rules.wrappedValue.append(ButtonRule(button: button, modifiers: 0, actionId: action, trigger: .click)) }
    }
}

// MARK: - Gestures

private struct GesturesEditor: View {
    let presetID: String
    @EnvironmentObject private var mouse: MouseStore

    private var gestures: Binding<GestureSettings> { mouse.binding(presetID, \.gestures) }

    var body: some View {
        let value = gestures.wrappedValue
        Form {
            Section {
                Toggle("Turn on gestures", isOn: Binding(get: { value.enabled }, set: { var v = value; v.enabled = $0; gestures.wrappedValue = v }))
                if value.enabled {
                    Picker("Hold this button", selection: Binding(get: { value.activationButton }, set: { var v = value; v.activationButton = $0; gestures.wrappedValue = v })) {
                        ForEach(MouseButtons.remappable, id: \.self) { Text(MouseButtons.name($0)).tag($0) }
                    }
                    SliderRow(title: "Distance", value: Binding(get: { value.threshold }, set: { var v = value; v.threshold = $0; gestures.wrappedValue = v }),
                              range: 20...300, format: { "\(Int($0)) pt" }, help: "How far to move. Smaller is more sensitive.")
                    SliderRow(title: "Time limit", value: Binding(get: { Double(value.timeoutMs) }, set: { var v = value; v.timeoutMs = UInt32($0); gestures.wrappedValue = v }),
                              range: 200...2000, format: { "\(Int($0)) ms" }, help: "A slower movement counts as an ordinary click.")
                }
            } header: {
                Text("Button gestures")
            } footer: {
                Text("Hold the button, move the mouse in a direction, then let go. A quick click without moving still works as a normal click.")
            }

            if value.enabled {
                Section("Directions") {
                    ForEach(GestureDirection.all, id: \.self) { direction in
                        LabeledContent {
                            ActionPicker(actionID: Binding(
                                get: { value.bindings.first { $0.direction == direction }?.actionId },
                                set: { setBinding(direction, $0) }
                            ))
                        } label: { Label(direction.title, systemImage: direction.symbol) }
                    }
                }
                Section {
                    LabeledContent("Hold right, click left") {
                        ActionPicker(actionID: Binding(get: { value.rockerRightThenLeft }, set: { var v = value; v.rockerRightThenLeft = $0; gestures.wrappedValue = v }))
                    }
                    LabeledContent("Hold left, click right") {
                        ActionPicker(actionID: Binding(get: { value.rockerLeftThenRight }, set: { var v = value; v.rockerLeftThenRight = $0; gestures.wrappedValue = v }))
                    }
                } header: {
                    Text("Rocker gestures")
                } footer: {
                    Text("Common choices are Back and Forward. While a rocker gesture is set, the second click does not reach the app.")
                }
            }
        }
        .formStyle(.grouped)
        .animation(.smooth(duration: 0.25), value: value.enabled)
    }

    private func setBinding(_ direction: GestureDirection, _ id: String?) {
        var value = gestures.wrappedValue
        value.bindings.removeAll { $0.direction == direction }
        if let id { value.bindings.append(GestureBinding(direction: direction, actionId: id)) }
        gestures.wrappedValue = value
    }
}

// MARK: - Apps

private struct MouseAppsTab: View {
    @EnvironmentObject private var mouse: MouseStore
    @EnvironmentObject private var profiles: ProfileStore

    private var appAssignments: [MouseAssignment] {
        mouse.assignments.filter { $0.appId != nil && $0.deviceId == nil }
    }

    var body: some View {
        Form {
            Section {
                if appAssignments.isEmpty {
                    Text("No app-specific presets.").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(appAssignments) { assignment in
                    HStack {
                        Text(AppChoice.name(for: assignment.appId ?? ""))
                        Spacer()
                        Picker("Preset", selection: Binding(
                            get: { assignment.presetId },
                            set: { mouse.setAssignment(device: nil, app: assignment.appId, preset: $0) }
                        )) {
                            ForEach(mouse.presets) { Text($0.name).tag($0.id) }
                        }
                        .labelsHidden().frame(width: 200)
                        Button(role: .destructive) { mouse.deleteAssignment(assignment.id) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }
            } header: {
                HStack {
                    Text("Presets for apps")
                    Spacer()
                    Button { addApp() } label: { Label("Add App", systemImage: "plus") }.controlSize(.small)
                }
            } footer: {
                Text("When one of these apps is in front, its preset is used instead of the device's. Kriya switches by itself as you change apps. An app with its own preset for a particular device would be set the same way, under that device.")
            }

            Section {
                if mouse.config.excludedAppIds.isEmpty {
                    Text("No excluded apps.").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(mouse.config.excludedAppIds, id: \.self) { id in
                    HStack {
                        Text(AppChoice.name(for: id))
                        Spacer()
                        Button(role: .destructive) { mouse.setExcludedApps(mouse.config.excludedAppIds.filter { $0 != id }) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }
            } header: {
                HStack {
                    Text("Leave alone in these apps")
                    Spacer()
                    Button { addExcluded() } label: { Label("Add App", systemImage: "plus") }.controlSize(.small)
                }
            } footer: {
                Text("Kriya does not touch the mouse at all while one of these is in front. Good for games and drawing apps.")
            }
        }
        .formStyle(.grouped)
        .animation(.smooth(duration: 0.25), value: mouse.assignments)
        .animation(.smooth(duration: 0.25), value: mouse.config)
    }

    private func addApp() {
        guard let id = AppChoice.choose(prompt: "Add") else { return }
        mouse.setAssignment(device: nil, app: id, preset: mouse.config.defaultPresetId)
    }

    private func addExcluded() {
        guard let id = AppChoice.choose(prompt: "Exclude"), !mouse.config.excludedAppIds.contains(id) else { return }
        mouse.setExcludedApps(mouse.config.excludedAppIds + [id])
    }
}

extension MouseStore {
    /// Any saved action, to fill a new rule with something valid the person then changes.
    var firstActionID: String? { actionIDs.first }
}
