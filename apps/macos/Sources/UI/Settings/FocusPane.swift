import SwiftUI

struct FocusPane: View {
    @EnvironmentObject private var focus: FocusSessionController

    var body: some View {
        Form {
            Section {
                HStack {
                    Label(focus.isActive ? focus.remainingText : "No session running", systemImage: focus.isActive ? "scope" : "moon.zzz")
                        .foregroundStyle(focus.isActive ? Theme.ok : Color.secondary).monospacedDigit()
                    Spacer()
                    Button(focus.isActive ? "End Now" : "Start") { focus.toggle() }.buttonStyle(.borderedProminent).controlSize(.small)
                }
            } header: { Text("Status") }

            Section {
                Stepper("Lasts \(focus.config.minutes) minutes", value: $focus.config.minutes, in: 1...480, step: 5)
                Toggle("Hide the Dock", isOn: $focus.config.hideDock)
                Toggle("Hide the desktop icons", isOn: $focus.config.hideDesktopIcons)
            } header: { Text("While it lasts") } footer: {
                Text("A setting that is already the way you want it is left alone, so ending the session never changes something you set yourself. If Kriya quits in the middle, the next time it opens it puts everything back.")
            }

            Section {
                ForEach(focus.config.quitAppIDs, id: \.self) { id in
                    HStack { Text(AppChoice.name(for: id)); Spacer(); Button { focus.config.quitAppIDs.removeAll { $0 == id } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless) }
                }
                Button("Add an App…") { if let id = AppChoice.choose(), !focus.config.quitAppIDs.contains(id) { focus.config.quitAppIDs.append(id) } }
            } header: { Text("Ask these apps to quit when it starts") }

            Section {
                TextField("Shortcut to run when it starts", text: $focus.config.startShortcut, prompt: Text("For example, Turn On Do Not Disturb"))
                TextField("Shortcut to run when it ends", text: $focus.config.endShortcut, prompt: Text("For example, Turn Off Do Not Disturb"))
            } header: { Text("Shortcuts") } footer: {
                Text("macOS has no way for an app to switch Do Not Disturb or a Focus by itself. Make a Shortcut that does it (the “Set Focus” action) and name it here. In the launcher, type “focus 45” to start a 45-minute session and “focus off” to end it.")
            }
        }
        .formStyle(.grouped)
    }
}
