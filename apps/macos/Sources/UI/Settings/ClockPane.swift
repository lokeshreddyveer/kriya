import SwiftUI

struct ClockPane: View {
    @EnvironmentObject private var clock: WorldClockModel
    @State private var text = ""
    @State private var problem: String?

    var body: some View {
        Form {
            Section {
                Toggle("Show the times in the menu bar", isOn: $clock.showInMenuBar)
                Toggle("24-hour clock", isOn: $clock.twentyFourHour)
            } footer: { Text("A second menu-bar item with the places below. Click it to see each place with its difference from here, and what is left on your calendar today (once you allow Calendars in the launcher settings).") }

            Section {
                ForEach($clock.places) { $place in
                    HStack {
                        TextField("Label", text: $place.label).frame(width: 70)
                        Text(place.zoneID.replacingOccurrences(of: "_", with: " ")).foregroundStyle(.secondary)
                        Spacer()
                        Button(role: .destructive) { clock.places.removeAll { $0.id == place.id } } label: { Image(systemName: "trash") }.accessibilityLabel("Delete").buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("Add a place", text: $text, prompt: Text("tokyo, london, new york, kolkata…")).onSubmit(add)
                    Button("Add", action: add).disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let problem { Text(problem).font(.caption).foregroundStyle(Theme.warn) }
            } header: { Text("Places") }
        }
        .formStyle(.grouped)
    }

    private func add() {
        if clock.add(named: text) { text = ""; problem = nil } else { problem = "That is not a place Kriya knows, or it is already there. Try a city or a zone name." }
    }
}
