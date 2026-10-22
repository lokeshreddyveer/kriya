import SwiftUI

/// Keeping the Mac awake: for a while, until turned off, or while chosen apps run.
struct PowerPane: View {
    @EnvironmentObject private var awake: KeepAwake
    @State private var untilTime = Calendar.current.date(bySettingHour: 18, minute: 0, second: 0, of: Date()) ?? Date()

    private static let durations: [(title: String, minutes: Int?)] = [
        ("15 minutes", 15), ("30 minutes", 30), ("1 hour", 60), ("2 hours", 120), ("4 hours", 240), ("Until I turn it off", nil),
    ]

    var body: some View {
        Form {
            Section {
                HStack {
                    Label(awake.isOn ? "Keeping your Mac awake" : "Your Mac sleeps as usual", systemImage: awake.isOn ? "cup.and.saucer.fill" : "moon.zzz")
                        .foregroundStyle(awake.isOn ? Theme.ok : Color.secondary)
                    Spacer()
                    if awake.isOn { Button("Stop") { awake.stop() }.controlSize(.small) }
                }
                if awake.isOn {
                    if let end = awake.endsAt {
                        Text("Ends \(end.formatted(date: .omitted, time: .shortened))").font(.callout).foregroundStyle(.secondary)
                    }
                    if !awake.heldBy.isEmpty { Text(awake.heldBy).font(.callout).foregroundStyle(.secondary) }
                }
            } header: { Text("Status") }

            Section {
                ForEach(Self.durations, id: \.title) { option in
                    Button(option.title) { awake.start(minutes: option.minutes) }
                }
                HStack {
                    DatePicker("Until", selection: $untilTime, displayedComponents: .hourAndMinute)
                    Button("Keep Awake") {
                        let parts = Calendar.current.dateComponents([.hour, .minute], from: untilTime)
                        awake.start(untilHour: parts.hour ?? 0, minute: parts.minute ?? 0)
                    }
                }
                Toggle("Keep the display on too", isOn: $awake.keepDisplayOn)
                SliderRow(title: "Stop on battery at", value: Binding(get: { Double(awake.stopBelowBattery) }, set: { awake.stopBelowBattery = Int($0) }),
                          range: 0...50, format: { $0 < 1 ? "Never" : "\(Int($0))%" }, help: "Lets the Mac sleep when it runs on battery and the charge gets this low.")
            } header: { Text("Keep awake") } footer: {
                Text("Stops the Mac sleeping on its own. Closing the lid still puts a laptop to sleep. If Kriya quits, the Mac goes back to normal. Give the actions “Keep the Mac awake” or “Let the Mac sleep again” (Actions › Add Common Actions) a shortcut for a quick switch.")
            }

            Section {
                if awake.watchedAppIDs.isEmpty { Text("No apps chosen.").font(.callout).foregroundStyle(.secondary) }
                ForEach(awake.watchedAppIDs, id: \.self) { id in
                    HStack {
                        Text(AppChoice.name(for: id))
                        Spacer()
                        Button(role: .destructive) { awake.watchedAppIDs.removeAll { $0 == id } } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                    }
                }
                Button {
                    if let id = AppChoice.choose(prompt: "Keep awake while this runs"), !awake.watchedAppIDs.contains(id) { awake.watchedAppIDs.append(id) }
                } label: { Label("Add an App", systemImage: "plus") }
            } header: { Text("While these apps are running") } footer: {
                Text("The Mac stays awake for as long as any of these apps is open, then goes back to normal.")
            }
        }
        .formStyle(.grouped)
        .animation(.smooth(duration: 0.25), value: awake.isOn)
    }
}
