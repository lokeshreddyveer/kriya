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
                    if let state = focus.state {
                        Button(state.isPaused ? "Resume" : "Pause") { state.isPaused ? focus.resume() : focus.pause() }.controlSize(.small)
                    }
                    Button(focus.isActive ? "End Now" : "Start") { focus.toggle() }.buttonStyle(.borderedProminent).controlSize(.small)
                }
            } header: { Text("Status") }

            Section {
                Stepper("Lasts \(focus.config.minutes) minutes", value: $focus.config.minutes, in: 1...480, step: 5)
                Toggle("Hide the Dock", isOn: $focus.config.hideDock)
                Toggle("Hide the desktop icons", isOn: $focus.config.hideDesktopIcons)
                Toggle("Remind me to take a break", isOn: Binding(get: { focus.config.breakEveryMinutes != nil }, set: { focus.config.breakEveryMinutes = $0 ? 25 : nil }))
                if let every = focus.config.breakEveryMinutes {
                    Stepper("Every \(every) minutes of focus", value: Binding(get: { every }, set: { focus.config.breakEveryMinutes = $0 }), in: 5...240, step: 5)
                }
            } header: { Text("While it lasts") } footer: {
                Text("A setting that is already the way you want it is left alone, so ending the session never changes something you set yourself. If Kriya quits in the middle, the next time it opens it puts everything back.")
            }

            Section {
                ForEach(focus.config.quitAppIDs, id: \.self) { id in
                    HStack { Text(AppChoice.name(for: id)); Spacer(); Button { focus.config.quitAppIDs.removeAll { $0 == id } } label: { Image(systemName: "minus.circle") }.accessibilityLabel("Remove").buttonStyle(.borderless) }
                }
                Button("Add an App…") { if let id = AppChoice.choose(), !focus.config.quitAppIDs.contains(id) { focus.config.quitAppIDs.append(id) } }
            } header: { Text("Ask these apps to quit when it starts") }

            Section {
                TextField("Shortcut to run when it starts", text: $focus.config.startShortcut, prompt: Text("For example, Turn On Do Not Disturb"))
                TextField("Shortcut to run when it ends", text: $focus.config.endShortcut, prompt: Text("For example, Turn Off Do Not Disturb"))
            } header: { Text("Shortcuts") } footer: {
                Text("macOS has no way for an app to switch Do Not Disturb or a Focus by itself. Make a Shortcut that does it (the “Set Focus” action) and name it here. In the launcher, type “focus 45” to start a 45-minute session and “focus off” to end it.")
            }

            Section {
                let week = focus.history.week(now: Date())
                if focus.history.entries.isEmpty {
                    Text("Finished sessions show up here.").foregroundStyle(.secondary)
                } else {
                    Text("Last 7 days: \(week.minutes) minutes in \(week.sessions) session\(week.sessions == 1 ? "" : "s")").font(.callout)
                    ForEach(focus.history.entries.prefix(8)) { entry in
                        HStack {
                            Text(entry.startedAt.formatted(date: .abbreviated, time: .shortened))
                            Spacer()
                            Text("\(entry.focusedMinutes) of \(entry.plannedMinutes) min · \(entry.completed ? "finished" : "ended early")").foregroundStyle(.secondary)
                        }.font(.callout)
                    }
                    Button("Clear History") { focus.clearHistory() }.controlSize(.small)
                }
            } header: { Text("History") }
        }
        .formStyle(.grouped)
    }
}
