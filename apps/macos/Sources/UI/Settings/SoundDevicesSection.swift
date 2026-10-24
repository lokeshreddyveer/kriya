import SwiftUI
import UniformTypeIdentifiers

/// Which device the sound uses, and what Kriya knows about each: the order of preference, the menu-bar icons, a device's details,
/// and headphone correction.
struct SoundDevicesSection: View {
    @EnvironmentObject private var mixer: SoundMixerModel
    @ObservedObject private var runner = DevicePriorityRunner.shared
    @ObservedObject private var correction = AutoEQRunner.shared
    @ObservedObject private var names = DeviceNames.shared
    @AppStorage(DeviceStatusItems.key) private var pinnedData = Data()
    @State private var inspected: AudioDevice?
    @State private var message: String?

    /// Every connected device, hidden ones included, so a hidden device can be shown again.
    private var allDevices: [AudioDevice] {
        let all = AudioControl.shared.devices()
        return all.filter(\.isOutput) + all.filter { $0.isInput && !$0.isOutput }
    }

    private var pinned: [PinnedDevice] { (try? JSONDecoder().decode([PinnedDevice].self, from: pinnedData)) ?? [] }

    var body: some View {
        Toggle("Keep the sound on my best device", isOn: $runner.enabled)
        if runner.enabled {
            Toggle("Move back to a better device when it reconnects", isOn: $runner.switchBack)
            if let last = runner.lastAction { Text(last).font(.caption).foregroundStyle(.secondary) }
        }
        priority(title: "Outputs, best first", list: runner.outputPriority, devices: mixer.outputs, input: false)
        priority(title: "Inputs, best first", list: runner.inputPriority, devices: mixer.inputs, input: true)
        ForEach(allDevices) { device in row(device) }
        if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
    }

    // MARK: The order

    @ViewBuilder
    private func priority(title: String, list: [String], devices: [AudioDevice], input: Bool) -> some View {
        if runner.enabled || !list.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title).font(.callout.weight(.medium))
                    Spacer()
                    Menu("Add a Device") {
                        let missing = devices.filter { !list.contains($0.uid) }
                        if missing.isEmpty { Text("Every connected device is in the list") }
                        ForEach(missing) { device in Button(names.name(for: device)) { runner.add(device.uid, input: input) } }
                    }.fixedSize()
                }
                ForEach(Array(list.enumerated()), id: \.element) { index, uid in
                    HStack(spacing: 8) {
                        Text("\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 18)
                        let live = devices.first { $0.uid == uid }
                        Text(live.map { names.name(for: $0) } ?? Self.savedName(uid)).foregroundStyle(live == nil ? .secondary : .primary)
                        if live == nil { Text("not connected").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Button { withAnimation(.smooth(duration: 0.2)) { runner.move(uid, by: -1, input: input) } } label: { Image(systemName: "chevron.up") }.disabled(index == 0)
                        Button { withAnimation(.smooth(duration: 0.2)) { runner.move(uid, by: 1, input: input) } } label: { Image(systemName: "chevron.down") }.disabled(index == list.count - 1)
                        Button { withAnimation(.smooth(duration: 0.2)) { runner.remove(uid, input: input) } } label: { Image(systemName: "minus.circle") }
                    }.buttonStyle(.borderless)
                }
                if list.isEmpty { Text("Nothing is ranked yet. Add the devices you use, best first.").font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    private static func savedName(_ uid: String) -> String { DeviceNames.shared.labels[uid]?.nickname ?? uid }

    // MARK: One device

    private func row(_ device: AudioDevice) -> some View {
        let pins = [device.isOutput ? PinnedDevice(uid: device.uid, name: names.name(for: device), input: false) : nil,
                    device.isInput ? PinnedDevice(uid: device.uid, name: names.name(for: device), input: true) : nil].compactMap { $0 }
        return HStack(spacing: 10) {
            Image(systemName: device.isInput && !device.isOutput ? "mic" : "speaker.wave.2").foregroundStyle(.secondary).frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(names.name(for: device))
                Text([device.isOutput ? "Output" : nil, device.isInput ? "Input" : nil].compactMap { $0 }.joined(separator: " and ")).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            ForEach(pins) { pin in
                Toggle(pin.input && device.isOutput ? "Mic icon" : "Menu bar", isOn: Binding(
                    get: { pinned.contains { $0.id == pin.id } },
                    set: { DeviceStatusItems.setPinned(pin, $0) })).toggleStyle(.checkbox).controlSize(.small)
            }
            Toggle("Hide", isOn: Binding(get: { names.labels[device.uid]?.hidden == true }, set: { hide in
                var label = names.labels[device.uid] ?? DeviceLabel()
                label.hidden = hide ? true : nil
                names.set(label, for: device.uid)
            })).toggleStyle(.checkbox).controlSize(.small).help("Leave this device out of the mixer's lists and menus. The one in use is always shown.")
            if device.isOutput { correctionMenu(device) }
            Button("Details…") { inspected = device }.controlSize(.small)
        }
        .sheet(item: Binding(get: { inspected?.id == device.id ? inspected : nil }, set: { inspected = $0 })) { DeviceDetailsSheet(device: $0) }
    }

    private func correctionMenu(_ device: AudioDevice) -> some View {
        Menu {
            Button("Import AutoEq File…") { importFile(for: device) }
            if let stored = correction.stored[device.uid] {
                Text("\(stored.name): off by \(String(format: "%.1f", stored.correction.errorDB)) dB on average").font(.caption)
                Button("Remove Correction", role: .destructive) { correction.remove(device.uid) }
            }
        } label: {
            Label(correction.stored[device.uid] == nil ? "Correction" : "Corrected", systemImage: correction.stored[device.uid] == nil ? "waveform.badge.plus" : "waveform.badge.checkmark")
        }
        .controlSize(.small).fixedSize()
        .help("Headphone correction from an AutoEq ParametricEQ or GraphicEQ file. It goes on when this device is the output and comes off when another is.")
    }

    private func importFile(for device: AudioDevice) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .text]
        panel.message = "Choose the AutoEq ParametricEQ.txt (or GraphicEQ.txt) for \(names.name(for: device))."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { message = AutoEQRunner.Failure.unreadable.localizedDescription; return }
        do {
            let fitted = try AutoEQRunner.correction(fromFileText: text)
            AutoEQRunner.shared.start()
            correction.set(fitted, name: names.name(for: device), for: device.uid)
            message = fitted.errorDB > 2 ? "Fitted, but ten bands only follow this curve to within \(String(format: "%.1f", fitted.errorDB)) dB." : "Correction saved for \(names.name(for: device))."
        } catch { message = error.localizedDescription }
    }
}

/// Everything Core Audio reports about a device, with what it means for latency and volume.
struct DeviceDetailsSheet: View {
    let device: AudioDevice
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let details = AudioControl.shared.details(of: device)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: details.transport.symbol).font(.title2)
                VStack(alignment: .leading) {
                    Text(DeviceNames.shared.name(for: device)).font(.headline)
                    Text(details.transport.title).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            Divider()
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                ForEach(Array(details.rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        Text(row.label).foregroundStyle(.secondary)
                        Text(row.value).textSelection(.enabled)
                    }
                }
            }
            if details.isOutput {
                Divider()
                Label(details.latencyAdvice, systemImage: "timer").font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(20).frame(width: 460)
    }
}

/// How the sound is doing: the delay each output adds, what Kriya's own processing adds for each app, and anything that failed.
struct SoundHealthSection: View {
    @EnvironmentObject private var mixer: SoundMixerModel
    @EnvironmentObject private var engine: AppAudioEngine
    @State private var devices: [(name: String, details: DeviceDetails)] = []
    @State private var delays: [String: Double] = [:]

    var body: some View {
        let slowest = devices.max { $0.details.latencyMilliseconds < $1.details.latencyMilliseconds }
        let report = SoundHealth.report(problems: engine.problems.count, slowestMilliseconds: slowest?.details.latencyMilliseconds ?? 0, slowestName: slowest?.name)
        Label(report.headline, systemImage: report.level == .good ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            .foregroundStyle(report.level == .good ? Color.green : (report.level == .noticeable ? Color.orange : Color.red))
        ForEach(devices, id: \.details.uid) { entry in
            HStack {
                Text(entry.name)
                Spacer()
                Text(String(format: "%.0f ms", entry.details.latencyMilliseconds)).monospacedDigit().foregroundStyle(.secondary)
                Text(entry.details.transport.title).font(.caption).foregroundStyle(.secondary)
            }
        }
        ForEach(delays.sorted { $0.key < $1.key }, id: \.key) { key, ms in
            HStack {
                Text(key == AppAudioEngine.systemKey ? "All sound" : AudioProcessList.name(for: key))
                Spacer()
                Text(String(format: "+%.0f ms from Kriya", ms)).monospacedDigit().foregroundStyle(.secondary)
            }
        }
        ForEach(engine.problems.sorted { $0.key < $1.key }, id: \.key) { key, text in
            Label("\(AudioProcessList.name(for: key)): \(text)", systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.secondary)
        }
        if let slowest, slowest.details.latencyMilliseconds >= SoundHealth.noticeableMilliseconds {
            Text(slowest.details.latencyAdvice).font(.caption).foregroundStyle(.secondary)
        }
        Button("Check Again") { load() }.controlSize(.small)
            .onAppear { load() }
    }

    private func load() {
        devices = mixer.outputs.map { (DeviceNames.shared.name(for: $0), AudioControl.shared.details(of: $0)) }
        delays = engine.processingDelays()
    }
}
