import AppKit
import SwiftUI

struct WindowsPane: View {
    @EnvironmentObject private var store: WindowStore
    @EnvironmentObject private var config: ConfigStore
    @EnvironmentObject private var services: ServiceManager
    @EnvironmentObject private var permissions: PermissionManager
    @EnvironmentObject private var controller: WindowController

    @State private var tab: Tab = .shortcuts
    @State private var confirmReset = false

    enum Tab: String, CaseIterable, Identifiable {
        case shortcuts = "Shortcuts", options = "Options", sizes = "Sizes", layouts = "Layouts", apps = "Apps"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            if !config.isEnabled(.windowManagement) || services.state(.windowManagement) != .running {
                statusBanner.padding(.horizontal, 20).padding(.top, 10).transition(.opacity)
            }
            HStack {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .paneTabBar(maxWidth: 420)
                Menu {
                    Button("Restore Default Shortcuts") { store.resetShortcuts() }
                    Button("Restore All Window Settings…") { confirmReset = true }
                } label: { MoreMenuLabel() }
                    .menuStyle(.button).menuIndicator(.hidden).fixedSize()
            }
            .paneHeader()

            Group {
                switch tab {
                case .shortcuts: ShortcutsTab()
                case .options: OptionsTab()
                case .sizes: SizesTab()
                case .layouts: LayoutsTab()
                case .apps: AppsTab()
                }
            }
            .id(tab)
            .transition(.opacity)
        }
        .animation(.smooth(duration: 0.22), value: tab)
        .tabHint($tab)
        .animation(.smooth(duration: 0.25), value: services.state(.windowManagement))
        .overlay(alignment: .bottom) {
            if let error = store.lastError ?? controller.lastMessage {
                Text(error).font(.callout).padding(10)
                    .background(Theme.danger.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                    .padding().transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.25), value: store.lastError)
        .confirmationDialog("Restore window settings?", isPresented: $confirmReset) {
            Button("Reset Options and Shortcuts") { store.restoreDefaults(everything: false) }
            Button("Reset Everything", role: .destructive) { store.restoreDefaults(everything: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("“Everything” also removes custom sizes, saved layouts and placement rules.")
        }
    }

    private var statusBanner: some View {
        let state = services.state(.windowManagement)
        return Banner(
            symbol: "rectangle.split.2x2", tint: state == .running ? Theme.ok : Theme.warn,
            title: "Window management is \(config.isEnabled(.windowManagement) ? state.label.lowercased() : "off")",
            message: "Your changes are saved, but shortcuts and snapping work only while the feature is on and allowed."
        ) {
            if !config.isEnabled(.windowManagement) {
                Button("Turn On") { services.setFeature(.windowManagement, enabled: true) }.controlSize(.small)
            } else if case .needsPermission(let missing) = state, let first = missing.first {
                Button("Allow \(first.title)…") { permissions.request(first) }.controlSize(.small)
            }
        }
    }
}

// MARK: - Shortcuts

private struct ShortcutsTab: View {
    @EnvironmentObject private var store: WindowStore
    @EnvironmentObject private var controller: WindowController

    private static let groups: [(String, [WindowLayout])] = [
        ("Halves", [.leftHalf, .rightHalf, .topHalf, .bottomHalf]),
        ("Quarters", [.topLeft, .topRight, .bottomLeft, .bottomRight]),
        ("Thirds", [.firstThird, .centerThird, .lastThird, .firstTwoThirds, .lastTwoThirds]),
        ("Sixths", [.topLeftSixth, .topCenterSixth, .topRightSixth, .bottomLeftSixth, .bottomCenterSixth, .bottomRightSixth]),
        ("Size", [.maximize, .center]),
    ]

    var body: some View {
        Form {
            if !controller.diagnostics.hotkeyFailures.isEmpty {
                Section {
                    Label("Another app already uses: \(controller.diagnostics.hotkeyFailures.joined(separator: ", ")). Choose different keys for these.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.warn).font(.callout)
                }
            }
            ForEach(Self.groups, id: \.0) { title, layouts in
                Section(title) {
                    ForEach(layouts) { row(command: $0.command, title: $0.title) }
                }
            }
            Section {
                ForEach(windowExtraCommands(), id: \.command) { row(command: $0.command, title: $0.title) }
            } header: { Text("Windows and displays") } footer: {
                Text("Press a shortcut again to cycle a half through a third and two thirds. Every shortcut needs at least one modifier key.")
            }
            if !store.sizes.isEmpty {
                Section("Custom sizes") {
                    ForEach(store.sizes) { row(command: store.sizeCommand($0), title: $0.name) }
                }
            }
            if store.layouts.contains(where: { !$0.isGroup }) {
                Section("Saved layouts") {
                    ForEach(store.layouts.filter { !$0.isGroup }) { row(command: store.layoutCommand($0), title: $0.name) }
                }
            }
            if store.layouts.contains(where: \.isGroup) {
                Section("Window groups") {
                    ForEach(store.layouts.filter(\.isGroup)) { row(command: store.layoutCommand($0), title: $0.name) }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func row(command: String, title: String) -> some View {
        // A plain row: the label and the field sit on one centred line.
        HStack(spacing: 8) {
            Text(title)
            Spacer(minLength: 12)
            HStack(spacing: 6) {
                ShortcutRecorder(shortcut: Binding(
                    get: { store.shortcut(for: command).map { RecordedShortcut(keyCode: $0.keyCode, modifiers: $0.modifiers) } },
                    set: { new in store.setShortcut(command, keyCode: new?.keyCode, modifiers: new?.modifiers ?? 0) }
                ))
                .frame(width: 170, height: 26)
                Button { store.setShortcut(command, keyCode: nil, modifiers: 0) } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel("Close")
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                    .opacity(store.shortcut(for: command) == nil ? 0 : 1)
                    .help("Clear")
            }
        }
    }
}

// MARK: - Options

private struct OptionsTab: View {
    @AppStorage(SwitcherStyle.key) private var switcherStyle = SwitcherStyle.cards.rawValue
    @EnvironmentObject private var store: WindowStore
    @EnvironmentObject private var permissions: PermissionManager

    @EnvironmentObject private var navigator: SettingsNavigator

    private var config: WindowConfig { store.config }

    private var todoName: String {
        guard let id = config.todoAppId else { return "None" }
        return NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == id }?.localizedName ?? id
    }

    var body: some View {
        Form {
            Section("Layout") {
                SliderRow(title: "Gap between windows", value: Binding(get: { config.gap }, set: { v in store.updateConfig { $0.gap = v } }),
                          range: 0...40, format: { "\(Int($0)) pt" })
                Toggle("Keep proportions when moving between displays", isOn: Binding(get: { config.preserveProportions }, set: { v in store.updateConfig { $0.preserveProportions = v } }))
                Toggle("Press a shortcut again to cycle sizes", isOn: Binding(get: { config.cycleSizes }, set: { v in store.updateConfig { $0.cycleSizes = v } }))
            }

            Section {
                Toggle("Snap when dragging a window to an edge", isOn: Binding(get: { config.snapOnDrag }, set: { v in store.updateConfig { $0.snapOnDrag = v } }))
                if config.snapOnDrag {
                    Toggle("Show a preview first", isOn: Binding(get: { config.showPreview }, set: { v in store.updateConfig { $0.showPreview = v } }))
                    SliderRow(title: "Edge distance", value: Binding(get: { config.edgeMargin }, set: { v in store.updateConfig { $0.edgeMargin = v } }),
                              range: 1...40, format: { "\(Int($0)) pt" }, help: "How close to the edge counts.")
                    SliderRow(title: "Corner size", value: Binding(get: { config.cornerSize }, set: { v in store.updateConfig { $0.cornerSize = v } }),
                              range: 10...150, format: { "\(Int($0)) pt" })
                    Picker("Only while holding", selection: Binding(get: { config.snapDragModifier }, set: { v in store.updateConfig { $0.snapDragModifier = v } })) {
                        ForEach(KeyModifiers.choices, id: \.bits) { Text($0.bits == 0 ? "No key needed" : $0.title).tag($0.bits) }
                    }
                    Toggle("Tap the trackpad when a window snaps", isOn: Binding(get: { config.hapticOnSnap }, set: { v in store.updateConfig { $0.hapticOnSnap = v } }))
                }
            } header: { Text("Drag to snap") } footer: {
                Text("Edges: left and right make halves, the top maximizes, the bottom makes the bottom half. Corners make quarters. Dragging a snapped window away gives it back its old size.")
            }

            Section {
                Picker("Hold to move a window", selection: Binding(get: { config.moveModifier }, set: { v in store.updateConfig { $0.moveModifier = v } })) {
                    ForEach(KeyModifiers.choices, id: \.bits) { Text($0.bits == 0 ? "Off" : $0.title).tag($0.bits) }
                }
                Picker("Hold to resize a window", selection: Binding(get: { config.resizeModifier }, set: { v in store.updateConfig { $0.resizeModifier = v } })) {
                    ForEach(KeyModifiers.choices, id: \.bits) { Text($0.bits == 0 ? "Off" : $0.title).tag($0.bits) }
                }
                if (config.moveModifier != 0 || config.resizeModifier != 0), !permissions.isGranted(.inputMonitoring) {
                    HStack {
                        Label("This needs Input Monitoring.", systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.warn)
                        Spacer()
                        Button("Allow…") { permissions.request(.inputMonitoring) }.controlSize(.small)
                    }
                    .transition(.opacity)
                }
            } header: { Text("Drag from anywhere in a window") } footer: {
                Text("Hold the keys and drag anywhere in a window to move it, or to resize it from the nearest corner. The click does not reach the app. Choose keys other apps do not use for clicks.")
            }

            Section {
                SliderRow(title: "Visible edge", value: Binding(get: { config.stashSliver }, set: { v in store.updateConfig { $0.stashSliver = v } }),
                          range: 6...60, format: { "\(Int($0)) pt" }, help: "How much of a stashed window stays on screen.")
            } header: { Text("Stash") } footer: {
                Text("A stashed window slides to the nearer side of the screen. Point at the visible edge to bring it out; move away and it tucks back. Use the shortcut again to put it back for good.")
            }

            Section {
                SliderRow(title: "Almost maximize margin", value: Binding(get: { config.almostMaximizeMargin }, set: { v in store.updateConfig { $0.almostMaximizeMargin = v } }),
                          range: 0...200, format: { "\(Int($0)) pt" }, help: "Left at every edge.")
                SliderRow(title: "Grow and shrink by", value: Binding(get: { config.resizeStep }, set: { v in store.updateConfig { $0.resizeStep = v } }),
                          range: 10...400, format: { "\(Int($0)) pt" })
                Toggle("Keep the window's shape when growing or shrinking", isOn: Binding(get: { config.keepAspect }, set: { v in store.updateConfig { $0.keepAspect = v } }))
                SliderRow(title: "Widest on an ultrawide display", value: Binding(get: { config.ultrawideMaxWidth }, set: { v in store.updateConfig { $0.ultrawideMaxWidth = v < 400 ? 0 : v } }),
                          range: 0...6000, format: { $0 < 400 ? "Off" : "\(Int($0)) pt" }, help: "A maximized window stays this wide, centred.")
                ColorPicker("Radial menu colour", selection: Binding(get: { Color.fromHex(config.radialColor) }, set: { v in store.updateConfig { $0.radialColor = v.hexString } }), supportsOpacity: false)
                SliderRow(title: "Radial menu size", value: Binding(get: { config.radialSize }, set: { v in store.updateConfig { $0.radialSize = v } }),
                          range: 70...220, format: { "\(Int($0)) pt" })
                Toggle("Place an app's windows by its rule every time it comes to the front", isOn: Binding(get: { config.applyRulesOnActivate }, set: { v in store.updateConfig { $0.applyRulesOnActivate = v } }))
                Toggle("Bring a window to the front when I rest the pointer on it", isOn: Binding(get: { config.focusFollowsMouse }, set: { v in store.updateConfig { $0.focusFollowsMouse = v } }))
                if config.focusFollowsMouse {
                    SliderRow(title: "Rest for", value: Binding(get: { Double(config.focusDelayMs) }, set: { v in store.updateConfig { $0.focusDelayMs = UInt32(v) } }),
                              range: 150...2000, format: { "\(Int($0)) ms" }, help: "How long the pointer stays before the window comes forward.")
                }
                Picker("Switcher looks like", selection: $switcherStyle) {
                    Text("Window cards (like AltTab)").tag(SwitcherStyle.cards.rawValue)
                    Text("Searchable list").tag(SwitcherStyle.list.rawValue)
                }
                SliderRow(title: "Switcher card size", value: Binding(get: { config.switcherScale }, set: { v in store.updateConfig { $0.switcherScale = v } }),
                          range: 0.7...1.5, format: { "\(Int($0 * 100))%" })
                Toggle("Open the switcher on the display the pointer is on", isOn: Binding(get: { config.switcherFollowPointer }, set: { v in store.updateConfig { $0.switcherFollowPointer = v } }))
                Toggle("Hold and release, like ⌘Tab", isOn: Binding(get: { config.switcherHoldRelease }, set: { v in store.updateConfig { $0.switcherHoldRelease = v } }))
                Toggle("Show a picture of each window in the switcher", isOn: Binding(get: { config.switcherThumbnails }, set: { v in
                    store.updateConfig { $0.switcherThumbnails = v }
                    if v, !permissions.isGranted(.screenRecording) { permissions.request(.screenRecording) }
                }))
                Toggle("Act on the window under the pointer", isOn: Binding(get: { config.actOnPointerWindow }, set: { v in store.updateConfig { $0.actOnPointerWindow = v } }))
            } header: { Text("Resizing") } footer: {
                Text("These apply to the shortcuts for almost maximize, maximize width or height, bigger, smaller, wider, narrower, taller and shorter. Under the pointer lets a shortcut move a window you have not clicked.")
            }

            Section {
                Stepper("Columns: \(Int(config.gridColumns))", value: Binding(get: { Int(config.gridColumns) }, set: { v in store.updateConfig { $0.gridColumns = UInt32(v) } }), in: 2...12)
                Stepper("Rows: \(Int(config.gridRows))", value: Binding(get: { Int(config.gridRows) }, set: { v in store.updateConfig { $0.gridRows = UInt32(v) } }), in: 2...12)
            } header: { Text("Keyboard grid") } footer: {
                Text("Press the grid shortcut, move the cursor with the arrow keys, hold Shift to cover more cells, then Return to place the window. Escape leaves it where it was.")
            }

            Section {
                LabeledContent("Todo app") {
                    HStack(spacing: 8) {
                        Text(todoName).foregroundStyle(.secondary)
                        if config.todoAppId != nil {
                            Button("Clear") { store.updateConfig { $0.todoAppId = nil } }.controlSize(.small)
                        }
                    }
                }
                SliderRow(title: "Column width", value: Binding(get: { config.todoFraction }, set: { v in store.updateConfig { $0.todoFraction = v } }),
                          range: 0.10...0.50, format: { "\(Int($0 * 100))%" })
                Picker("Side", selection: Binding(get: { config.todoOnRight }, set: { v in store.updateConfig { $0.todoOnRight = v } })) {
                    Text("Right").tag(true)
                    Text("Left").tag(false)
                }
                .pickerStyle(.segmented)
            } header: { Text("Todo mode") } footer: {
                Text("Bring the app you want in the column to the front and use the todo shortcut. Every layout then uses the space that is left. Use it again from that app to turn todo mode off.")
            }

            Section {
                Picker("Hold to show drop zones", selection: Binding(get: { config.dropZoneModifier }, set: { v in store.updateConfig { $0.dropZoneModifier = v } })) {
                    ForEach(KeyModifiers.choices, id: \.bits) { Text($0.bits == 0 ? "Off" : $0.title).tag($0.bits) }
                }
                Picker("Layout", selection: Binding(get: { config.dropZoneLayoutId ?? "" }, set: { v in store.updateConfig { $0.dropZoneLayoutId = v.isEmpty ? nil : v } })) {
                    Text("Most recent saved layout").tag("")
                    ForEach(store.layouts.filter { !$0.isAuto && !$0.isGroup }) { Text($0.name).tag($0.id) }
                }
            } header: { Text("Drop zones") } footer: {
                Text("Drag a window and hold the keys: the places in a saved layout appear. Drop the window on one to put it there. Save a layout under Layouts first.")
            }

            Section {
                HStack {
                    Text("Hot corners")
                    Spacer()
                    Button("Set Up in Automation") { navigator.pane = .automation }
                }
            } header: { Text("Hot corners") } footer: {
                Text("A hot corner is a trigger in Automation: pick a corner and how long to rest the pointer, then any window command.")
            }

            Section("Displays and apps") {
                Toggle("Bring windows back when displays change", isOn: Binding(get: { config.restoreOnReconnect }, set: { v in store.updateConfig { $0.restoreOnReconnect = v } }))
                Toggle("Place new app windows by their rules", isOn: Binding(get: { config.applyRulesOnLaunch }, set: { v in store.updateConfig { $0.applyRulesOnLaunch = v } }))
            }
        }
        .formStyle(.grouped)
        .animation(.smooth(duration: 0.25), value: config.snapOnDrag)
        .animation(.smooth(duration: 0.25), value: permissions.status(.inputMonitoring))
    }
}

// MARK: - Sizes

private struct SizesTab: View {
    @EnvironmentObject private var store: WindowStore
    @State private var editing: CustomSize?

    var body: some View {
        Form {
            Section {
                if store.sizes.isEmpty {
                    Text("No custom sizes. Add one for a window shape you use often, such as a 60% wide reading window.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(store.sizes) { size in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(size.name).font(.headline)
                            Text(describe(size)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Edit") { editing = size }.controlSize(.small)
                        Button(role: .destructive) { store.deleteSize(size.id) } label: { Image(systemName: "trash") }.accessibilityLabel("Delete").buttonStyle(.borderless)
                    }
                }
            } header: {
                HStack {
                    Text("Custom sizes")
                    Spacer()
                    Button { editing = CustomSize(id: UUID().uuidString, name: "", width: 0.6, height: 0.8, asFraction: true, centered: true, x: 0.5, y: 0.5) } label: {
                        Label("New Size", systemImage: "plus")
                    }.controlSize(.small)
                }
            } footer: {
                Text("A custom size is a window shape. Give it a shortcut under Shortcuts, or use it in a placement rule.")
            }
        }
        .formStyle(.grouped)
        .animation(.smooth(duration: 0.25), value: store.sizes)
        .sheet(item: $editing) { SizeEditor(size: $0) }
    }

    private func describe(_ size: CustomSize) -> String {
        size.asFraction ? "\(Int(size.width * 100))% × \(Int(size.height * 100))% of the display, centered" : "\(Int(size.width)) × \(Int(size.height)) points, centered"
    }
}

private struct SizeEditor: View {
    @State var size: CustomSize
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: WindowStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Custom Size").font(.title3.bold())
            Form {
                TextField("Name", text: $size.name)
                Toggle("As a share of the display", isOn: Binding(
                    get: { size.asFraction },
                    set: { on in
                        size.asFraction = on
                        size.width = on ? 0.6 : 900
                        size.height = on ? 0.8 : 700
                    }
                ))
                if size.asFraction {
                    SliderRow(title: "Width", value: $size.width, range: 0.2...1, format: { "\(Int($0 * 100))%" })
                    SliderRow(title: "Height", value: $size.height, range: 0.2...1, format: { "\(Int($0 * 100))%" })
                } else {
                    LabeledContent("Width") { TextField("", value: $size.width, format: .number).frame(width: 90) }
                    LabeledContent("Height") { TextField("", value: $size.height, format: .number).frame(width: 90) }
                }
                Toggle("Center on the display", isOn: $size.centered)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { store.saveSize(size); if store.lastError == nil { dismiss() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(size.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20).frame(width: 460)
    }
}

// MARK: - Layouts

private struct LayoutsTab: View {
    @EnvironmentObject private var store: WindowStore
    @EnvironmentObject private var controller: WindowController
    @EnvironmentObject private var displays: DisplayManager

    @State private var naming = false
    @State private var name = ""
    @State private var restoring: String?
    @State private var bindingTick = 0
    private let bindings = DisplaySetupBindings()
    @State private var message: String?
    @State private var designing: DesignerTarget?
    @State private var showingReport = false
    @State private var makingGroup = false

    private struct DesignerTarget: Identifiable {
        let id = UUID()
        let layout: SavedLayout?
    }

    private var thisSetup: [SavedLayout] { store.layouts.filter { !$0.isGroup && $0.displayKey == displays.setKey } }
    private var otherSetups: [SavedLayout] { store.layouts.filter { !$0.isGroup && $0.displayKey != displays.setKey } }
    private var groups: [SavedLayout] { store.layouts.filter(\.isGroup) }

    var body: some View {
        Form {
            Section {
                HStack {
                    Button { name = ""; naming = true } label: { Label("Save Current Windows…", systemImage: "square.and.arrow.down") }
                    Button { designing = DesignerTarget(layout: nil) } label: { Label("Draw a Layout…", systemImage: "rectangle.dashed") }
                    Spacer()
                    Text("\(displays.displays.count) display\(displays.displays.count == 1 ? "" : "s") connected")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if let message { Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(Theme.ok).transition(.opacity) }
                if let report = controller.lastReport {
                    HStack(spacing: 8) {
                        Image(systemName: report.isClean ? "checkmark.seal" : "exclamationmark.triangle")
                            .foregroundStyle(report.isClean ? Theme.ok : Theme.warn)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Last restore: “\(report.layoutName)”").font(.callout)
                            Text(report.summary).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Details…") { showingReport = true }.controlSize(.small)
                    }
                    .transition(.opacity)
                }
            } footer: {
                Text("A layout remembers where windows go, on which display. Save the windows you have open, or draw boxes and give each an app. A layout can also minimize, hide or close the windows it does not place, and open apps that are not running. Restore it in one click or with a shortcut. Kriya also keeps its own snapshot for each set of displays and brings it back when that set is connected again.")
            }

            Section("For the displays connected now") {
                if thisSetup.isEmpty { Text("None saved.").font(.callout).foregroundStyle(.secondary) }
                ForEach(thisSetup) { row($0) }
            }
            if !otherSetups.isEmpty {
                Section {
                    ForEach(otherSetups) { row($0) }
                } header: { Text("For other display setups") } footer: {
                    Text("Windows go to the same display if it is connected, or to the main display.")
                }
            }

            Section {
                if groups.isEmpty { Text("None saved.").font(.callout).foregroundStyle(.secondary) }
                ForEach(groups) { groupRow($0) }
            } header: {
                HStack {
                    Text("Window groups")
                    Spacer()
                    Button { makingGroup = true } label: { Label("New Group…", systemImage: "plus") }.controlSize(.small)
                }
            } footer: {
                Text("A group is a few related windows you pick, such as your editor, terminal and browser. Restore brings all of them forward where they were saved, opening apps that are closed. Move To fits the whole group, keeping its shape, into a display or half of one. Like a layout, a group can have a shortcut: look for “Group: …” in the Shortcuts tab.")
            }
        }
        .formStyle(.grouped)
        .animation(.smooth(duration: 0.25), value: store.layouts)
        .animation(.smooth(duration: 0.25), value: message)
        .sheet(item: $designing) { target in
            LayoutDesignerView(existing: target.layout, displays: displays.displays, displayKey: displays.setKey, onSave: { layout in
                store.saveLayout(layout)
                designing = nil
                message = store.lastError == nil ? "Saved “\(layout.name)”." : nil
            }, onCancel: { designing = nil })
        }
        .sheet(isPresented: $showingReport) {
            RestoreReportSheet(onClose: { showingReport = false }, onRetry: { retryLast() })
        }
        .sheet(isPresented: $makingGroup) {
            NewGroupSheet(onSave: { name, windows in
                makingGroup = false
                if controller.saveGroup(named: name, windows: windows) { message = "Saved group “\(name)”." }
            }, onCancel: { makingGroup = false })
        }
        .alert("Save layout", isPresented: $naming) {
            TextField("Name", text: $name)
            Button("Save") { save() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Name this arrangement of windows.") }
    }

    private func row(_ layout: SavedLayout) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "rectangle.3.group").foregroundStyle(.secondary).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(layout.name).font(.headline)
                Text(detail(of: layout)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let shortcut = store.shortcuts.first(where: { $0.command == store.layoutCommand(layout) }) {
                Text(KeyNames.describe(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers))
                    .font(.system(.caption, design: .rounded)).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .help("The shortcut that restores this layout")
            }
            if restoring == layout.id { ProgressView().controlSize(.small) }
            Button { bindings.toggle(layout: layout.id, setup: layout.displayKey); bindingTick += 1 } label: {
                Image(systemName: bindings.isBound(layout: layout.id, to: layout.displayKey) ? "display.2" : "display")
                    .foregroundStyle(bindings.isBound(layout: layout.id, to: layout.displayKey) ? Color.accentColor : .secondary)
            }
            .buttonStyle(.borderless).id(bindingTick)
            .help(bindings.isBound(layout: layout.id, to: layout.displayKey) ? "Comes back by itself whenever the displays it was made for are connected. Click to stop." : "Bring this layout back by itself whenever the displays it was made for are connected")
            Button("Edit") { designing = DesignerTarget(layout: layout) }.controlSize(.small)
            Button("Restore") { restore(layout) }.controlSize(.small)
            Button(role: .destructive) { store.deleteLayout(layout.id) } label: { Image(systemName: "trash") }.accessibilityLabel("Delete").buttonStyle(.borderless)
        }
    }

    private func groupRow(_ group: SavedLayout) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "square.stack.3d.up").foregroundStyle(.secondary).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(group.name).font(.headline)
                Text(groupDetail(group)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            if let shortcut = store.shortcuts.first(where: { $0.command == store.layoutCommand(group) }) {
                Text(KeyNames.describe(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers))
                    .font(.system(.caption, design: .rounded)).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            if restoring == group.id { ProgressView().controlSize(.small) }
            Button("Restore") { restore(group) }.controlSize(.small)
            Menu("Move To") {
                ForEach(displays.displays) { display in
                    Menu(display.name) {
                        ForEach(GroupRegion.allCases) { region in
                            Button(region.title) { controller.moveGroup(group, to: display, region: region) }
                        }
                    }
                }
            }
            .menuStyle(.button).controlSize(.small).fixedSize()
            Button(role: .destructive) { store.deleteLayout(group.id) } label: { Image(systemName: "trash") }.accessibilityLabel("Delete").buttonStyle(.borderless)
        }
    }

    private func groupDetail(_ group: SavedLayout) -> String {
        let names = group.entries.map { AppChoice.name(for: $0.appId) }
        var seen = Set<String>()
        let unique = names.filter { seen.insert($0).inserted }
        return "\(group.entries.count) window\(group.entries.count == 1 ? "" : "s"): " + unique.joined(separator: ", ")
    }

    private func retryLast() {
        guard let layout = controller.lastLayout else { return }
        controller.restore(layout)
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        controller.saveCurrentLayout(named: trimmed)
        message = store.lastError == nil ? "Saved “\(trimmed)”." : nil
    }

    private func detail(of layout: SavedLayout) -> String {
        var parts = ["\(layout.entries.count) window\(layout.entries.count == 1 ? "" : "s")", Date(timeIntervalSince1970: TimeInterval(layout.createdAt)).shortDescription]
        switch layout.unplaced {
        case .leave: break
        case .minimize: parts.append("minimizes the rest")
        case .hide: parts.append("hides other apps")
        case .close: parts.append("closes the rest")
        }
        if layout.launchMissing { parts.append("opens missing apps") }
        return parts.joined(separator: " · ")
    }

    private func restore(_ layout: SavedLayout) {
        if layout.unplaced == .close {
            let alert = NSAlert()
            alert.messageText = "Close the other windows?"
            alert.informativeText = "“\(layout.name)” closes every open window it does not place. Apps with unsaved work will ask to save first."
            alert.addButton(withTitle: "Restore and Close")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        restoring = layout.id
        controller.restore(layout) { outcome in
            restoring = nil
            var text = "Restored “\(layout.name)”: \(outcome.placed) window\(outcome.placed == 1 ? "" : "s") placed"
            if outcome.tidied > 0 { text += ", \(outcome.tidied) other\(outcome.tidied == 1 ? "" : "s") tidied" }
            if outcome.opened > 0 { text += ", \(outcome.opened) app\(outcome.opened == 1 ? "" : "s") opening" }
            message = text + (outcome.missing > outcome.opened ? ", \(outcome.missing - outcome.opened) not open." : ".")
            // When something did not go where it should, the details open by themselves.
            if let report = outcome.report, !report.isClean { showingReport = true }
        }
    }
}

// MARK: - Restore report

/// What a restore did, window by window, with the reason for anything that did not go where it should and a way to point at
/// the window that was meant.
private struct RestoreReportSheet: View {
    @EnvironmentObject private var controller: WindowController
    let onClose: () -> Void
    let onRetry: () -> Void
    @State private var choices: [WindowChoice] = []
    @State private var loaded = false
    @State private var failure: String?

    var body: some View {
        VStack(spacing: 0) {
            if let report = controller.lastReport {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("“\(report.layoutName)”").font(.headline)
                        Text(report.summary).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(16)
                Divider()
                List {
                    if !report.needAttention.isEmpty {
                        Section("Needs a look") { ForEach(report.needAttention) { row($0, report: report) } }
                    }
                    let elsewhere = report.onMainDisplay + report.onOtherDisplay
                    if !elsewhere.isEmpty {
                        Section("On a different display") { ForEach(elsewhere) { row($0, report: report) } }
                    }
                    let opening = report.results.filter { $0.status == .opening }
                    if !opening.isEmpty {
                        Section("Opening") { ForEach(opening) { row($0, report: report) } }
                    }
                    let fine = report.placed.filter { r in !elsewhere.contains(where: { $0.id == r.id }) }
                    if !fine.isEmpty {
                        Section("Restored") { ForEach(fine) { row($0, report: report) } }
                    }
                }
                if let failure { Text(failure).font(.callout).foregroundStyle(Theme.danger).padding(.horizontal, 16).padding(.bottom, 6) }
            } else {
                Text("Nothing has been restored yet.").foregroundStyle(.secondary).frame(maxHeight: .infinity)
            }
            Divider()
            HStack {
                Text("Choosing a window places it now and remembers it for this layout.").font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Button("Try Again") { failure = nil; onRetry() }.disabled(controller.lastLayout == nil)
                Button("Done") { onClose() }.keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 600, height: 520)
        .onAppear { reload() }
        .animation(.smooth(duration: 0.25), value: controller.lastReport)
    }

    private func reload() {
        controller.loadWindowChoices { choices = $0; loaded = true }
    }

    private func row(_ result: RestoreEntryResult, report: RestoreReport) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon(result)).foregroundStyle(tint(result)).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(result.label).lineLimit(1)
                Text(result.explanation).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if result.canChooseReplacement {
                Menu("Choose Window…") {
                    let same = choices.filter { $0.appID == result.appID }
                    let others = choices.filter { $0.appID != result.appID }
                    if choices.isEmpty { Text(loaded ? "No windows are open" : "Looking…") }
                    ForEach(same) { choice in Button(choice.title.isEmpty ? choice.appName : choice.title) { use(choice, for: result) } }
                    if !same.isEmpty && !others.isEmpty { Divider() }
                    ForEach(others) { choice in Button("\(choice.appName) · \(choice.title)") { use(choice, for: result) } }
                    Divider()
                    Button("Refresh the List") { reload() }
                }
                .menuStyle(.button).controlSize(.small).fixedSize()
            }
        }
        .padding(.vertical, 2)
    }

    private func use(_ choice: WindowChoice, for result: RestoreEntryResult) {
        guard let layout = controller.lastLayout else { return }
        if !controller.place(choice, forEntry: result.id, of: layout, remember: true) {
            failure = "That window could not be moved. Some windows have a fixed size, or are full screen."
        } else {
            failure = nil
        }
    }

    private func icon(_ result: RestoreEntryResult) -> String {
        switch result.status {
        case .placed: return "checkmark.circle.fill"
        case .placedOnOtherDisplay, .movedToMainDisplay: return "display.2"
        case .opening: return "arrow.up.forward.app"
        default: return "exclamationmark.triangle.fill"
        }
    }

    private func tint(_ result: RestoreEntryResult) -> Color {
        switch result.status {
        case .placed: return Theme.ok
        case .placedOnOtherDisplay, .movedToMainDisplay, .opening: return Theme.accent
        default: return Theme.warn
        }
    }
}

// MARK: - New group

private struct NewGroupSheet: View {
    @EnvironmentObject private var controller: WindowController
    let onSave: (String, [WindowChoice]) -> Void
    let onCancel: () -> Void
    @State private var name = ""
    @State private var choices: [WindowChoice] = []
    @State private var picked = Set<UUID>()
    @State private var loaded = false

    private var chosen: [WindowChoice] { choices.filter { picked.contains($0.id) } }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("New window group").font(.headline)
                TextField("Name, such as “Development setup”", text: $name)
                Text("Tick the windows that belong together. Their places on screen are saved with the group.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .padding(16)
            Divider()
            if choices.isEmpty {
                Text(loaded ? "No windows are open." : "Looking for open windows…").foregroundStyle(.secondary).frame(maxHeight: .infinity)
            } else {
                List(choices) { choice in
                    Toggle(isOn: Binding(get: { picked.contains(choice.id) }, set: { on in if on { picked.insert(choice.id) } else { picked.remove(choice.id) } })) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(choice.appName)
                            if !choice.title.isEmpty { Text(choice.title).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                        }
                    }
                }
            }
            Divider()
            HStack {
                Button("Select All") { picked = Set(choices.map(\.id)) }.disabled(choices.isEmpty)
                Button("None") { picked = [] }.disabled(picked.isEmpty)
                Spacer()
                Text("\(picked.count) chosen").font(.callout).foregroundStyle(.secondary)
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Save Group") { onSave(name.trimmingCharacters(in: .whitespaces), chosen) }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || picked.isEmpty)
            }
            .padding(14)
        }
        .frame(width: 520, height: 520)
        .onAppear { controller.loadWindowChoices { choices = $0; loaded = true } }
        .animation(.smooth(duration: 0.2), value: choices.count)
    }
}

// MARK: - Apps

private struct AppsTab: View {
    @EnvironmentObject private var store: WindowStore
    @EnvironmentObject private var displays: DisplayManager

    var body: some View {
        Form {
            Section {
                if store.rules.isEmpty { Text("No placement rules.").font(.callout).foregroundStyle(.secondary) }
                ForEach(store.rules) { rule in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Toggle("", isOn: Binding(get: { rule.enabled }, set: { var r = rule; r.enabled = $0; store.saveRule(r) }))
                                .labelsHidden().toggleStyle(.switch).controlSize(.small)
                            Text(AppChoice.name(for: rule.appId)).font(.headline)
                            Spacer()
                            Button(role: .destructive) { store.deleteRule(rule.id) } label: { Image(systemName: "trash") }.accessibilityLabel("Delete").buttonStyle(.borderless)
                        }
                        HStack(spacing: 12) {
                            Picker("Place", selection: Binding(get: { placementTag(rule) }, set: { setPlacement(rule, $0) })) {
                                Section("Layouts") { ForEach(windowLayouts()) { Text($0.title).tag("layout:\($0.command)") } }
                                if !store.sizes.isEmpty {
                                    Section("Custom sizes") { ForEach(store.sizes) { Text($0.name).tag("size:\($0.id)") } }
                                }
                            }
                            .frame(maxWidth: 260)
                            Picker("On", selection: Binding(get: { rule.displayId ?? "" }, set: { var r = rule; r.displayId = $0.isEmpty ? nil : $0; store.saveRule(r) })) {
                                Text("Where it opens").tag("")
                                ForEach(displays.displays) { Text($0.name).tag($0.id) }
                            }
                            .frame(maxWidth: 240)
                        }
                    }
                    .padding(.vertical, 3)
                }
            } header: {
                HStack {
                    Text("Placement rules")
                    Spacer()
                    Button { addRule() } label: { Label("Add App", systemImage: "plus") }.controlSize(.small)
                }
            } footer: {
                Text("When one of these apps opens a window, it is placed as the rule says. “Apply placement rules to open windows” in Shortcuts does the same for windows already open.")
            }

            Section {
                if store.config.excludedAppIds.isEmpty { Text("No excluded apps.").font(.callout).foregroundStyle(.secondary) }
                ForEach(store.config.excludedAppIds, id: \.self) { id in
                    HStack {
                        Text(AppChoice.name(for: id))
                        Spacer()
                        Button(role: .destructive) { store.updateConfig { $0.excludedAppIds.removeAll { $0 == id } } } label: { Image(systemName: "trash") }.accessibilityLabel("Delete")
                            .buttonStyle(.borderless)
                    }
                }
            } header: {
                HStack {
                    Text("Never move windows of")
                    Spacer()
                    Button { addExcluded() } label: { Label("Add App", systemImage: "plus") }.controlSize(.small)
                }
            } footer: {
                Text("Kriya will not move, snap or list windows of these apps. Good for apps that manage their own windows.")
            }
        }
        .formStyle(.grouped)
        .animation(.smooth(duration: 0.25), value: store.rules)
        .animation(.smooth(duration: 0.25), value: store.config.excludedAppIds)
    }

    private func placementTag(_ rule: PlacementRule) -> String {
        if let layout = rule.layout { return "layout:\(layout.command)" }
        if let id = rule.customSizeId { return "size:\(id)" }
        return "layout:\(WindowLayout.leftHalf.command)"
    }

    private func setPlacement(_ rule: PlacementRule, _ tag: String) {
        var r = rule
        if tag.hasPrefix("layout:") {
            r.layout = windowLayoutFromCommand(command: String(tag.dropFirst(7)))
            r.customSizeId = nil
        } else {
            r.layout = nil
            r.customSizeId = String(tag.dropFirst(5))
        }
        store.saveRule(r)
    }

    private func addRule() {
        guard let id = AppChoice.choose(prompt: "Add") else { return }
        store.saveRule(PlacementRule(id: UUID().uuidString, appId: id, enabled: true, layout: .maximize, customSizeId: nil, displayId: nil))
    }

    private func addExcluded() {
        guard let id = AppChoice.choose(prompt: "Exclude"), !store.config.excludedAppIds.contains(id) else { return }
        store.updateConfig { $0.excludedAppIds.append(id) }
    }
}
