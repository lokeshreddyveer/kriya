import SwiftUI

struct TrafficPane: View {
    @EnvironmentObject private var traffic: TrafficStore
    @EnvironmentObject private var config: ConfigStore
    @EnvironmentObject private var services: ServiceManager
    @EnvironmentObject private var permissions: PermissionManager

    @State private var tab: Tab = .buttons
    @State private var confirmReset = false

    enum Tab: String, CaseIterable, Identifiable {
        case buttons = "Buttons", titleBar = "Title Bar", apps = "Apps", hover = "Hover", activity = "Activity"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            banners.padding(.horizontal, 20).padding(.top, hasBanner ? 10 : 0)
            HStack {
                Picker("", selection: $tab) { ForEach(Tab.allCases) { Text($0.rawValue).tag($0) } }
                    .paneTabBar(maxWidth: 360)
                Menu {
                    Button("Use Suggested Settings") { traffic.update { $0.bindings = suggestedTrafficBindings(); $0.hoverSets = suggestedTrafficHoverSets() } }
                    Divider()
                    Button("Restore Normal Button Behavior") { traffic.restoreNative(everything: false) }
                    Button("Restore Everything…") { confirmReset = true }
                } label: { MoreMenuLabel() }
                    .menuStyle(.button).menuIndicator(.hidden).fixedSize()
            }
            .paneHeader()

            Group {
                switch tab {
                case .buttons: ButtonsTab()
                case .titleBar: TitleBarTab()
                case .apps: TrafficAppsTab()
                case .hover: HoverTab()
                case .activity: ActivityTab()
                }
            }
            .id(tab)
            .transition(.opacity)
        }
        .animation(.smooth(duration: 0.22), value: tab)
        .animation(.smooth(duration: 0.25), value: services.state(.trafficLights))
        .animation(.smooth(duration: 0.25), value: traffic.interceptionIssue)
        .overlay(alignment: .bottom) {
            if let error = traffic.lastError {
                Text(error).font(.callout).padding(10)
                    .background(Theme.danger.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                    .padding().transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .confirmationDialog("Restore window buttons?", isPresented: $confirmReset) {
            Button("Reset Everything", role: .destructive) { traffic.restoreNative(everything: true) }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Removes every button setting, app profile, hover menu and exclusion. Every button goes back to its normal behavior.") }
    }

    /// Whether any notice shows above the tabs, so an empty one does not push the tab strip down.
    private var hasBanner: Bool {
        let state = services.state(.trafficLights)
        return !config.isEnabled(.trafficLights) || state != .running || traffic.interceptionIssue != nil
    }

    @ViewBuilder
    private var banners: some View {
        let state = services.state(.trafficLights)
        VStack(spacing: 8) {
            if !config.isEnabled(.trafficLights) || state != .running {
                Banner(
                    symbol: "macwindow", tint: state == .running ? Theme.ok : Theme.warn,
                    title: "Window buttons are \(config.isEnabled(.trafficLights) ? state.label.lowercased() : "off")",
                    message: "Your settings are saved, but the buttons keep their normal behavior until the feature is on and allowed."
                ) {
                    if !config.isEnabled(.trafficLights) {
                        Button("Turn On") { services.setFeature(.trafficLights, enabled: true) }.controlSize(.small)
                    } else if case .needsPermission(let missing) = state, let first = missing.first {
                        Button("Allow \(first.title)…") { permissions.request(first) }.controlSize(.small)
                    }
                }
            }
            if let issue = traffic.interceptionIssue {
                Banner(symbol: "exclamationmark.triangle.fill", tint: Theme.warn, title: "Falling back to normal buttons", message: issue) { EmptyView() }
            }
        }
    }
}

// MARK: - Choosing an action

/// A menu of everything a button can do.
struct TrafficActionMenu: View {
    @Binding var action: TrafficAction
    var allowNative = true
    var allowNothing = true

    @EnvironmentObject private var library: ActionLibrary

    private func set(_ new: TrafficAction) -> some View {
        Button { action = new } label: { Label(new.title, systemImage: new.symbol) }
    }

    var body: some View {
        Menu {
            if allowNative { set(.native) }
            if allowNothing { set(.doNothing) }
            if allowNative || allowNothing { Divider() }
            Section("Window") {
                set(.closeWindow); set(.closeOrQuit); set(.minimizeWindow); set(.minimizeAllWindows); set(.restoreMinimized)
                set(.maximize); set(.restoreSize); set(.toggleFullScreen); set(.center); set(.layoutPalette)
            }
            Section("App") {
                set(.quitApp); set(.hideApp); set(.hideOtherApps)
            }
            Menu("Snap to…") {
                ForEach(windowLayouts()) { layout in
                    if layout != .center { set(.snap(layout: layout)) }
                }
            }
            if !library.actions.isEmpty {
                Menu("Saved action…") {
                    ForEach(library.actions) { saved in
                        Button { action = .run(actionId: saved.id) } label: { Label(saved.name, systemImage: saved.action.symbol) }
                    }
                }
            }
        } label: {
            Label(title, systemImage: action.symbol)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var title: String {
        if case .run(let id) = action { return library.actions.first { $0.id == id }?.name ?? "Saved action" }
        return action.title
    }
}

// MARK: - Bindings

/// The rules for the three buttons, as three sections. Used for the general rules and for each app's own.
struct TrafficBindingsEditor: View {
    @Binding var bindings: [TrafficBinding]
    var allowNative: Bool

    var body: some View {
        ForEach(TrafficButton.all) { button in
            Section {
                let mine = bindings.indices.filter { bindings[$0].button == button }
                if mine.isEmpty {
                    Text("Normal behavior for every click.").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(mine, id: \.self) { index in
                    if index < bindings.count { row(index) }
                }
            } header: {
                HStack(spacing: 8) {
                    Circle().fill(color(button)).frame(width: 11, height: 11)
                    Text("\(button.colorName) · \(button.title)")
                    Spacer()
                    Button { add(button) } label: { Label("Add Rule", systemImage: "plus") }.controlSize(.small)
                }
            }
        }
    }

    private func row(_ index: Int) -> some View {
        HStack(spacing: 12) {
            Picker("Keys", selection: Binding(get: { bindings[index].modifiers }, set: { bindings[index].modifiers = $0 })) {
                Text("Plain click").tag(UInt64(0))
                ForEach(KeyModifiers.choices.filter { $0.bits != 0 }, id: \.bits) { Text(trafficModifierTitle(modifiers: $0.bits)).tag($0.bits) }
            }
            .labelsHidden().pickerStyle(.menu).frame(width: 200, alignment: .leading)
            Image(systemName: "arrow.right").foregroundStyle(.secondary)
            TrafficActionMenu(action: Binding(get: { bindings[index].action }, set: { bindings[index].action = $0 }), allowNative: allowNative)
            Spacer()
            Button(role: .destructive) { withAnimation(.smooth) { _ = bindings.remove(at: index) } } label: { Image(systemName: "trash") }.accessibilityLabel("Delete")
                .buttonStyle(.borderless)
        }
    }

    private func add(_ button: TrafficButton) {
        let used = Set(bindings.filter { $0.button == button }.map(\.modifiers))
        let free = ([UInt64(0)] + KeyModifiers.choices.map(\.bits)).first { !used.contains($0) } ?? 0
        withAnimation(.smooth) {
            bindings.append(TrafficBinding(button: button, modifiers: free, action: button.suggestedAction))
        }
    }

    private func color(_ button: TrafficButton) -> Color {
        switch button {
        case .close: return Theme.danger
        case .minimize: return Theme.warn
        case .zoom: return Theme.ok
        }
    }
}

private struct ButtonsTab: View {
    @EnvironmentObject private var traffic: TrafficStore

    var body: some View {
        Form {
            TrafficBindingsEditor(
                bindings: Binding(get: { traffic.config.bindings }, set: { new in traffic.update { $0.bindings = new } }),
                allowNative: false
            )
            let notes = TrafficInsight.notes(for: traffic.config.bindings)
            let dupes = TrafficInsight.duplicates(traffic.config.bindings)
            if !notes.isEmpty || !dupes.isEmpty {
                Section {
                    ForEach(notes) { Text($0.text).font(.callout) }
                    ForEach(dupes, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(Theme.warn) }
                    if let title = TrafficInsight.titleBarNote(traffic.config.titleDoubleClick) { Text(title).font(.callout) }
                } header: { Text("What this changes") } footer: { Text("Compared with what macOS does on its own.") }
            }
            Section {
                Text("A rule changes a button only for the exact keys shown. Every other click behaves normally, and so does any app Kriya cannot read. “Do nothing” disables a click. The red button closes through the app, so unsaved-changes prompts still appear.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Apps

private struct TrafficAppsTab: View {
    @EnvironmentObject private var traffic: TrafficStore

    var body: some View {
        Form {
            Section {
                if traffic.profiles.isEmpty { Text("No app profiles.").font(.callout).foregroundStyle(.secondary) }
            } header: {
                HStack {
                    Text("Different buttons in certain apps")
                    Spacer()
                    Button { if let id = AppChoice.choose(prompt: "Add") { traffic.addProfile(appID: id) } } label: { Label("Add App", systemImage: "plus") }
                        .controlSize(.small)
                }
            } footer: {
                Text("An app's profile wins over the general rules for the same button and keys. Choose “Normal behavior” in a profile to switch a general rule off for that app.")
            }
            ForEach(traffic.profiles) { profile in
                Section {
                    HStack {
                        Toggle("Use this profile", isOn: Binding(get: { profile.enabled }, set: { var p = profile; p.enabled = $0; traffic.saveProfile(p) }))
                        Spacer()
                        Button("Remove", role: .destructive) { traffic.deleteProfile(profile.id) }.controlSize(.small)
                    }
                    TrafficBindingsEditor(
                        bindings: Binding(get: { profile.bindings }, set: { var p = profile; p.bindings = $0; traffic.saveProfile(p) }),
                        allowNative: true
                    )
                } header: {
                    Text(AppChoice.name(for: profile.appId)).font(.headline)
                }
            }

            Section {
                if traffic.config.excludedAppIds.isEmpty { Text("None added.").font(.callout).foregroundStyle(.secondary) }
                ForEach(traffic.config.excludedAppIds, id: \.self) { id in
                    HStack {
                        Text(AppChoice.name(for: id))
                        Spacer()
                        Button(role: .destructive) { traffic.update { $0.excludedAppIds.removeAll { $0 == id } } } label: { Image(systemName: "trash") }.accessibilityLabel("Delete")
                            .buttonStyle(.borderless)
                    }
                }
            } header: {
                HStack {
                    Text("Leave these apps alone")
                    Spacer()
                    Button {
                        if let id = AppChoice.choose(prompt: "Exclude"), !traffic.config.excludedAppIds.contains(id) { traffic.update { $0.excludedAppIds.append(id) } }
                    } label: { Label("Add App", systemImage: "plus") }.controlSize(.small)
                }
            } footer: {
                Text("Kriya never touches the window buttons of these apps, nor of system surfaces such as the login window and the Dock. Useful for apps that draw their own buttons.")
            }
        }
        .formStyle(.grouped)
        .animation(.smooth(duration: 0.25), value: traffic.profiles)
        .animation(.smooth(duration: 0.25), value: traffic.config.excludedAppIds)
    }
}

// MARK: - Hover

private struct HoverTab: View {
    @EnvironmentObject private var traffic: TrafficStore

    var body: some View {
        Form {
            Section {
                Text("1. Turn this on.  2. Choose what each button's menu holds below, or tap “Add Window Snapping Menu”.  3. Rest the pointer on that window button (red, yellow or green) without clicking. After the wait below, a small menu appears next to it.  4. Click an action in the menu, or move away to dismiss it.")
                    .font(.callout).foregroundStyle(.secondary)
                if traffic.config.hoverEnabled, TrafficButton.all.allSatisfy({ traffic.config.hoverActions(for: $0).isEmpty }) {
                    Label("Hover is on, but no button has a menu yet, so nothing will appear.", systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                }
                Button("Add Window Snapping Menu to the Green Button") { traffic.update { $0.hoverEnabled = true; $0.hoverSets = suggestedTrafficHoverSets() } }
                    .help("Halves, quarters, thirds, maximize, center and full screen")
            } header: { Text("How hover works") }
            Section {
                Toggle("Show a menu when the pointer rests on a button", isOn: Binding(get: { traffic.config.hoverEnabled }, set: { v in traffic.update { $0.hoverEnabled = v } }))
                if traffic.config.hoverEnabled {
                    SliderRow(title: "Wait before showing", value: Binding(get: { Double(traffic.config.hoverDelayMs) }, set: { v in traffic.update { $0.hoverDelayMs = UInt32(v) } }),
                              range: 300...2500, format: { "\(Int($0)) ms" })
                        .transition(.opacity)
                }
            } footer: {
                Text("The menu lists the actions you choose for that button. Move away or click elsewhere to dismiss it. It shows only where the button can be read.")
            }
            if traffic.config.hoverEnabled {
                ForEach(TrafficButton.all) { button in
                    Section {
                        let actions = traffic.config.hoverActions(for: button)
                        if actions.isEmpty { Text("No menu for this button.").font(.callout).foregroundStyle(.secondary) }
                        ForEach(Array(actions.enumerated()), id: \.offset) { index, action in
                            HStack {
                                Label(action.title, systemImage: action.symbol)
                                Spacer()
                                Button(role: .destructive) { edit(button) { $0.remove(at: index) } } label: { Image(systemName: "trash") }.accessibilityLabel("Delete").buttonStyle(.borderless)
                            }
                        }
                    } header: {
                        HStack {
                            Text("\(button.colorName) · \(button.title)")
                            Spacer()
                            AddHoverAction { new in edit(button) { if !$0.contains(new) && $0.count < 8 { $0.append(new) } } }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .animation(.smooth(duration: 0.25), value: traffic.config.hoverEnabled)
        .animation(.smooth(duration: 0.25), value: traffic.config.hoverSets)
    }

    private func edit(_ button: TrafficButton, _ change: (inout [TrafficAction]) -> Void) {
        traffic.update { config in
            var actions = config.hoverActions(for: button)
            change(&actions)
            config.hoverSets.removeAll { $0.button == button }
            if !actions.isEmpty { config.hoverSets.append(HoverSet(button: button, actions: actions)) }
        }
    }
}

private struct AddHoverAction: View {
    let onAdd: (TrafficAction) -> Void
    @State private var chosen: TrafficAction = .center

    var body: some View {
        HStack(spacing: 6) {
            TrafficActionMenu(action: $chosen, allowNative: false, allowNothing: false)
            Button("Add") { onAdd(chosen) }.controlSize(.small)
        }
    }
}

// MARK: - Activity

private struct ActivityTab: View {
    @EnvironmentObject private var traffic: TrafficStore
    @State private var stats = TrafficStats()
    private let ticker = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                LabeledContent("Clicks Kriya handled", value: "\(stats.handled)")
                LabeledContent("Clicks left alone", value: "\(stats.leftNative)")
                LabeledContent("Handed back to the app", value: "\(stats.replayedAsNormal)")
                LabeledContent("Repeat presses ignored", value: "\(stats.duplicatesSuppressed)")
                Button("Reset Numbers") { traffic.resetStats(); stats = traffic.currentStats() }.controlSize(.small)
            } footer: {
                Text("“Handed back” counts actions Kriya could not carry out, so the button's normal click was performed instead. “Repeat presses ignored” counts a second press of the same button within a third of a second, which would otherwise run an action twice.")
            }
        }
        .formStyle(.grouped)
        .onAppear { stats = traffic.currentStats() }
        .onReceive(ticker) { _ in stats = traffic.currentStats() }
    }
}

// MARK: - Title bar

/// What clicking the empty part of a window's title bar does, and whether quitting from a button asks first.
private struct TitleBarTab: View {
    @EnvironmentObject private var traffic: TrafficStore

    var body: some View {
        Form {
            Section {
                LabeledContent("Double-click") {
                    TrafficActionMenu(action: Binding(get: { traffic.config.titleDoubleClick }, set: { v in traffic.update { $0.titleDoubleClick = v } }), allowNothing: true)
                }
                LabeledContent("Middle-click") {
                    TrafficActionMenu(action: Binding(get: { traffic.config.titleMiddleClick }, set: { v in traffic.update { $0.titleMiddleClick = v } }), allowNothing: true)
                }
            } header: { Text("Title bar clicks") } footer: {
                Text("Applies to the empty part of a window's title bar, not to its buttons, tabs or search fields. “Normal behavior” leaves what macOS does. Needs Input Monitoring.")
            }

            Section {
                Toggle("Ask before a window button quits an app", isOn: Binding(get: { traffic.config.confirmQuit }, set: { v in traffic.update { $0.confirmQuit = v } }))
            } header: { Text("Quitting") } footer: {
                Text("Applies to the actions “Quit app” and “Close, or quit if it is the last window”.")
            }

            Section {
                Text("Hold keys and drag anywhere in a window to move or resize it: Windows › Options › Drag from anywhere in a window. Rest the pointer on a window button for a menu of actions: the Hover tab.")
                    .font(.callout).foregroundStyle(.secondary)
            } header: { Text("Also in the title bar") }
        }
        .formStyle(.grouped)
    }
}
