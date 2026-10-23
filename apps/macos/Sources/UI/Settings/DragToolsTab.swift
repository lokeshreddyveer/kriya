import SwiftUI

/// Dragging with the mouse: scroll by dragging the page, glide on after letting go, and windows that follow the pointer.
struct DragToolsTab: View {
    @EnvironmentObject private var store: DragToolsStore
    @EnvironmentObject private var permissions: PermissionManager
    @EnvironmentObject private var library: ActionLibrary

    private var config: DragToolsConfig { store.config }

    private static let extraButtons: [(number: UInt32, title: String)] = [(2, "Middle button"), (3, "Side button 1"), (4, "Side button 2"), (5, "Button 6")]

    private static let buttons: [(number: UInt32, title: String)] = [
        (2, "Middle button"), (3, "Side button 1"), (4, "Side button 2"), (0, "Left button, with keys"), (1, "Right button, with keys"),
    ]

    var body: some View {
        Form {
            Section {
                Toggle("Drag to scroll", isOn: Binding(get: { config.scrollEnabled }, set: { v in store.update { $0.scrollEnabled = v } }))
                if config.scrollEnabled {
                    Picker("Button", selection: Binding(get: { config.scrollButton }, set: { v in store.update { $0.scrollButton = v } })) {
                        ForEach(Self.buttons, id: \.number) { Text($0.title).tag($0.number) }
                    }
                    Picker("Also hold", selection: Binding(get: { config.scrollModifier }, set: { v in store.update { $0.scrollModifier = v } })) {
                        ForEach(KeyModifiers.choices, id: \.bits) { Text($0.bits == 0 ? "No key" : $0.title).tag($0.bits) }
                    }
                    Toggle("Reverse direction", isOn: Binding(get: { config.scrollInvert }, set: { v in store.update { $0.scrollInvert = v } }))
                    SliderRow(title: "Speed", value: Binding(get: { config.scrollSpeed }, set: { v in store.update { $0.scrollSpeed = v } }),
                              range: 0.2...5, format: { String(format: "%.1f×", $0) }, help: "How far the page moves for each point the pointer moves.")
                    Toggle("Keep gliding after letting go", isOn: Binding(get: { config.momentum }, set: { v in store.update { $0.momentum = v } }))
                    if config.momentum {
                        SliderRow(title: "Glide length", value: Binding(get: { config.momentumKeep }, set: { v in store.update { $0.momentumKeep = v } }),
                                  range: 0.8...0.99, format: { $0 < 0.92 ? "Short" : $0 < 0.96 ? "Medium" : "Long" })
                    }
                    if !permissions.isGranted(.inputMonitoring) { inputMonitoringNote }
                }
            } header: { Text("Drag to scroll") } footer: {
                Text("Hold the button and drag, and the page moves with your hand. A button press without moving still clicks, so the middle button keeps opening links in new tabs. The left and right buttons need a key held so normal clicking is not affected.")
            }

            Section {
                Toggle("Auto-scroll", isOn: Binding(get: { config.autoScrollEnabled }, set: { v in store.update { $0.autoScrollEnabled = v } }))
                if config.autoScrollEnabled {
                    Picker("Click this button", selection: Binding(get: { config.autoScrollButton }, set: { v in store.update { $0.autoScrollButton = v } })) {
                        ForEach(Self.buttons, id: \.number) { Text($0.title).tag($0.number) }
                    }
                    Picker("Also hold", selection: Binding(get: { config.autoScrollModifier }, set: { v in store.update { $0.autoScrollModifier = v } })) {
                        ForEach(KeyModifiers.choices, id: \.bits) { Text($0.bits == 0 ? "No key" : $0.title).tag($0.bits) }
                    }
                    SliderRow(title: "Speed", value: Binding(get: { config.autoScrollSpeed }, set: { v in store.update { $0.autoScrollSpeed = v } }),
                              range: 0.2...5, format: { String(format: "%.1f×", $0) }, help: "How fast the page moves for a given distance from where you clicked.")
                    if config.scrollEnabled, config.scrollButton == config.autoScrollButton, config.scrollModifier == config.autoScrollModifier {
                        Label("Drag to scroll uses this button and these keys too, so it wins and auto-scroll will not start. Pick another button or add a key.", systemImage: "exclamationmark.triangle.fill")
                            .font(.callout).foregroundStyle(Theme.warn)
                    }
                    if !permissions.isGranted(.inputMonitoring) { inputMonitoringNote }
                }
            } header: { Text("Auto-scroll") } footer: {
                Text("Click the button and the page scrolls by itself: move the pointer down to read on, up to go back, sideways for sideways, and further away to go faster. A small mark shows where you clicked. Click again, press Escape or turn the wheel to stop. The click that starts or stops it is not given to the app. The left and right buttons need a key held.")
            }

            Section {
                Picker("Hold to move a window", selection: Binding(get: { config.followModifier }, set: { v in store.update { $0.followModifier = v } })) {
                    ForEach(KeyModifiers.choices, id: \.bits) { Text($0.bits == 0 ? "Off" : $0.title).tag($0.bits) }
                }
                if config.followModifier != 0, !permissions.isGranted(.inputMonitoring) { inputMonitoringNote }
            } header: { Text("Window follows the pointer") } footer: {
                Text("Hold only these keys and the window under the pointer follows it, with no click. Let go of the keys to leave it there. Needs window management on and Accessibility allowed.")
            }

            Section {
                ForEach(Array(config.doubleClicks.enumerated()), id: \.offset) { index, binding in
                    HStack {
                        Picker("", selection: Binding(get: { binding.button }, set: { v in store.update { $0.doubleClicks[index].button = v } })) {
                            ForEach(Self.extraButtons, id: \.number) { Text($0.title).tag($0.number) }
                        }.labelsHidden().frame(maxWidth: 150)
                        Picker("", selection: Binding(get: { binding.actionId }, set: { v in store.update { $0.doubleClicks[index].actionId = v } })) {
                            ForEach(library.actions, id: \.id) { Text($0.name).tag($0.id) }
                        }.labelsHidden()
                        Button(role: .destructive) { store.update { $0.doubleClicks.remove(at: index) } } label: { Image(systemName: "trash") }.accessibilityLabel("Delete").buttonStyle(.borderless)
                    }
                }
                Button {
                    if let first = library.actions.first { store.update { $0.doubleClicks.append(DoubleClickBinding(button: 2, modifiers: 0, actionId: first.id)) } }
                } label: { Label("Add a Double Click", systemImage: "plus") }.disabled(library.actions.isEmpty)
                if !config.doubleClicks.isEmpty, !permissions.isGranted(.inputMonitoring) { inputMonitoringNote }
            } header: { Text("Double click a button") } footer: {
                Text("A second click within a moment runs a saved action. The first click is still an ordinary click. The left and right buttons are left out so normal clicking is never affected.")
            }

            Section {
                ForEach(Array(config.buttonScrolls.enumerated()), id: \.offset) { index, binding in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Picker("Hold", selection: Binding(get: { binding.button }, set: { v in store.update { $0.buttonScrolls[index].button = v } })) {
                                ForEach(Self.extraButtons, id: \.number) { Text($0.title).tag($0.number) }
                            }
                            Button(role: .destructive) { store.update { $0.buttonScrolls.remove(at: index) } } label: { Image(systemName: "trash") }.accessibilityLabel("Delete").buttonStyle(.borderless)
                        }
                        Picker("Wheel up", selection: Binding(get: { binding.upActionId ?? "" }, set: { v in store.update { $0.buttonScrolls[index].upActionId = v.isEmpty ? nil : v } })) {
                            Text("Nothing").tag("")
                            ForEach(library.actions, id: \.id) { Text($0.name).tag($0.id) }
                        }
                        Picker("Wheel down", selection: Binding(get: { binding.downActionId ?? "" }, set: { v in store.update { $0.buttonScrolls[index].downActionId = v.isEmpty ? nil : v } })) {
                            Text("Nothing").tag("")
                            ForEach(library.actions, id: \.id) { Text($0.name).tag($0.id) }
                        }
                    }
                    .padding(.vertical, 2)
                }
                Button {
                    store.update { $0.buttonScrolls.append(ButtonScrollBinding(button: 2, upActionId: library.actions.first?.id, downActionId: nil)) }
                } label: { Label("Add a Button + Wheel", systemImage: "plus") }
                if !config.buttonScrolls.isEmpty, !permissions.isGranted(.inputMonitoring) { inputMonitoringNote }
            } header: { Text("Hold a button and turn the wheel") } footer: {
                Text("While the button is held, each notch of the wheel runs the action for that direction, for example switching tabs or changing the volume. Pressing the button without turning the wheel still clicks.")
            }

            if let error = store.lastError {
                Section { Text(error).font(.callout).foregroundStyle(Theme.danger) }
            }
        }
        .formStyle(.grouped)
        .animation(.smooth(duration: 0.25), value: config)
    }

    private var inputMonitoringNote: some View {
        HStack {
            Label("This needs Input Monitoring.", systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.warn)
            Spacer()
            Button("Allow…") { permissions.request(.inputMonitoring) }.controlSize(.small)
        }
        .transition(.opacity)
    }
}
