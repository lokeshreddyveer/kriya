import SwiftUI

/// Keeping the Mac awake: for a while, until turned off, or while chosen apps run.
struct PowerPane: View {
    @EnvironmentObject private var awake: KeepAwake
    @State private var assertions: [PowerAssertions.Assertion] = []
    @ObservedObject private var saving = PowerSavingState.shared
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
                        Button(role: .destructive) { awake.watchedAppIDs.removeAll { $0 == id } } label: { Image(systemName: "trash") }.accessibilityLabel("Stop watching \(AppChoice.name(for: id))").buttonStyle(.borderless)
                    }
                }
                Button {
                    if let id = AppChoice.choose(prompt: "Keep awake while this runs"), !awake.watchedAppIDs.contains(id) { awake.watchedAppIDs.append(id) }
                } label: { Label("Add an App", systemImage: "plus") }
            } header: { Text("While these apps are running") } footer: {
                Text("The Mac stays awake for as long as any of these apps is open, then goes back to normal.")
            }

            Section {
                LabeledContent("Low Power Mode", value: saving.lowPowerMode ? "On" : "Off")
                Picker("Make Kriya use less power", selection: Binding(get: { saving.mode }, set: { saving.mode = $0 })) {
                    ForEach(PowerSaving.Mode.allCases) { Text($0.title).tag($0) }
                }
                if saving.isActive { Label("Kriya is saving power now.", systemImage: "leaf").font(.callout).foregroundStyle(Theme.ok) }
                ForEach(PowerSaving.whatItDoes, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                Button("Open Battery Settings") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension")!) }.controlSize(.small)
            } header: { Text("Low Power Mode") } footer: {
                Text("macOS does not let an app switch Low Power Mode on or off, so Kriya shows its state and opens the Battery settings where you can. Saving power here only changes what Kriya itself does.")
            }

            Section {
                Text(PowerAssertions.summary(assertions)).font(.callout)
                ForEach(PowerAssertions.awakeHolders(assertions)) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.process)
                            Text("\(item.effect) · \(item.name)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Text(item.heldFor).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Button("Refresh", action: refresh).controlSize(.small)
                    Button("Reset Kriya's Rules") { awake.stop(); awake.watchedAppIDs.removeAll(); refresh() }.controlSize(.small)
                        .help("Stops keep-awake and forgets the apps chosen above. Other apps' holds are not touched.")
                }
            } header: { Text("What is keeping this Mac awake") } footer: {
                Text("From the system's own list. Closing the lid still sleeps a laptop; macOS does not let an app report or change that.")
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refresh)
        .animation(.smooth(duration: 0.25), value: awake.isOn)
    }

    private func refresh() {
        DispatchQueue.global(qos: .userInitiated).async {
            let output = (try? ToolRunner.run("/usr/bin/pmset", ["-g", "assertions"], timeout: 4)) ?? ""
            let parsed = PowerAssertions.parse(output)
            DispatchQueue.main.async { assertions = parsed }
        }
    }
}
