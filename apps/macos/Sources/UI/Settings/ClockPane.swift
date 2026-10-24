import SwiftUI

struct ClockPane: View {
    @EnvironmentObject private var clock: WorldClockModel
    @State private var text = ""
    @State private var problem: String?
    @AppStorage("worldClock.hoursStart") private var hoursStart = 9
    @AppStorage("worldClock.hoursEnd") private var hoursEnd = 18
    @State private var convertText = ""
    @State private var convertFrom = ""

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
                        Button(role: .destructive) { clock.places.removeAll { $0.id == place.id } } label: { Image(systemName: "trash") }.accessibilityLabel("Delete \(place.label)").buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("Add a place", text: $text, prompt: Text("tokyo, london, new york, kolkata…")).onSubmit(add)
                    Button("Add", action: add).disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let problem { Text(problem).font(.caption).foregroundStyle(Theme.warn) }
            } header: { Text("Places") }

            if clock.places.count >= 2 {
                Section {
                    Stepper("Work starts at \(hoursStart):00", value: $hoursStart, in: 0...max(0, hoursEnd - 1))
                    Stepper("Work ends at \(hoursEnd):00", value: $hoursEnd, in: min(24, hoursStart + 1)...24)
                    let slots = MeetingOverlap.merged(MeetingOverlap.slots(places: clock.places, hours: BusinessHours(start: hoursStart, end: min(hoursEnd, 24)), from: Date()))
                    if slots.isEmpty {
                        Text("No hour in the next two days is inside everyone's working hours.").font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(Array(slots.prefix(5).enumerated()), id: \.offset) { _, slot in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(clock.places.compactMap { place in place.zone.map { "\(place.label) \(WorldClockFormat.time(slot.start, in: $0, twentyFourHour: clock.twentyFourHour))–\(WorldClockFormat.time(slot.end, in: $0, twentyFourHour: clock.twentyFourHour))" } }.joined(separator: "   "))
                                .font(.callout)
                        }
                    }
                } header: { Text("When everyone is at work") } footer: { Text("Hours when every place above is inside its working hours, over the next two days.") }
            }

            if !clock.places.isEmpty {
                Section {
                    HStack {
                        TextField("Time", text: $convertText, prompt: Text("3pm, 15:30"))
                        Picker("in", selection: $convertFrom) {
                            ForEach(clock.places) { Text($0.label).tag($0.id) }
                        }.frame(maxWidth: 160)
                    }
                    let source = clock.places.first { $0.id == convertFrom } ?? clock.places[0]
                    let lines = TimeConversion.lines(time: convertText, from: source, to: clock.places, on: Date(), twentyFourHour: clock.twentyFourHour)
                    ForEach(lines, id: \.self) { Text($0).font(.callout) }
                    HStack {
                        Button("Copy These") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string) }.disabled(lines.isEmpty)
                        Button("Copy the Times Now") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(WorldClockFormat.barText(clock.places, date: Date(), twentyFourHour: clock.twentyFourHour), forType: .string)
                        }
                    }.controlSize(.small)
                } header: { Text("Convert a time") }
                let changes = DaylightWarnings.upcoming(places: clock.places, from: Date())
                if !changes.isEmpty {
                    Section {
                        ForEach(changes, id: \.date) { Label(DaylightWarnings.sentence($0), systemImage: "sun.max.trianglebadge.exclamationmark").font(.callout) }
                    } header: { Text("Clocks changing soon") }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func add() {
        if clock.add(named: text) { text = ""; problem = nil } else { problem = "That is not a place Kriya knows, or it is already there. Try a city or a zone name." }
    }
}
