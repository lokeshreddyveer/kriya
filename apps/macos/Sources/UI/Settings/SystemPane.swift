import SwiftUI

/// Everything the Mac reports about itself, live: processor, memory, disks, network, battery, devices and programs.
struct SystemPane: View {
    @EnvironmentObject private var monitor: SystemMonitor

    var body: some View {
        Form {
            Section {
                Toggle("Show readings in the menu bar", isOn: $monitor.showInMenuBar)
                if monitor.showInMenuBar {
                    ForEach(MonitorMetric.allCases) { metric in
                        Toggle(metric.title, isOn: Binding(get: { monitor.metrics.contains(metric) }, set: { on in
                            monitor.metrics = MonitorMetric.allCases.filter { $0 == metric ? on : monitor.metrics.contains($0) }
                        }))
                    }
                }
            } header: { Text("In the menu bar") } footer: {
                Text("A second item beside the Kriya icon. Click it for the full picture. Nothing is read when this is off and this page is closed.")
            }
            Section {
                Toggle("Warn when a mouse, keyboard or trackpad is nearly flat", isOn: $monitor.lowBatteryAlerts)
            } footer: { Text("Checked every few minutes at 15% and below, once per device until it has been charged.") }
            SystemDetails(snapshot: monitor.snapshot, info: monitor.info)
            StorageSection()
            CleanupSection()
        }
        .formStyle(.grouped)
        .onAppear { monitor.viewerAppeared() }
        .onDisappear { monitor.viewerGone() }
    }
}

/// The readings themselves, shared by the settings page and the menu-bar window.
struct SystemDetails: View {
    let snapshot: MonitorSnapshot
    let info: MacInfo

    var body: some View {
        Section("This Mac") {
            row("Model", info.model)
            row("Chip", info.chip)
            row("System", info.system)
            row("Memory", info.memory)
            row("Processor", info.cores)
            row("On for", ByteFormat.duration(snapshot.uptime))
            row("Temperature", MonitorSnapshot.thermalText(snapshot.thermal), warn: snapshot.thermal != .nominal && snapshot.thermal != .fair)
        }
        Section("Processor") {
            bar("In use", snapshot.cpu, MonitorSnapshot.percent(snapshot.cpu))
            if !snapshot.cores.isEmpty {
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(Array(snapshot.cores.enumerated()), id: \.offset) { _, use in
                        RoundedRectangle(cornerRadius: 2).fill(Color.accentColor.opacity(0.85)).frame(height: max(3, 34 * use)).frame(maxWidth: .infinity)
                    }
                }
                .frame(height: 36, alignment: .bottom).animation(.easeOut(duration: 0.4), value: snapshot.cores)
            }
            ForEach(snapshot.topByCPU) { p in row(p.name, String(format: "%.1f%%", p.cpu)) }
        }
        Section("Memory") {
            bar("In use", snapshot.memory.share, "\(ByteFormat.size(snapshot.memory.used)) of \(ByteFormat.size(snapshot.memory.total))")
            row("Apps", ByteFormat.size(snapshot.memory.app))
            row("Held by the system", ByteFormat.size(snapshot.memory.wired))
            row("Squeezed", ByteFormat.size(snapshot.memory.compressed))
            row("Cached files", ByteFormat.size(snapshot.memory.cached))
            row("Swap", ByteFormat.size(snapshot.memory.swapUsed))
            ForEach(snapshot.topByMemory) { p in row(p.name, ByteFormat.size(p.memory)) }
        }
        Section("Disks") {
            ForEach(snapshot.disks) { disk in
                bar(disk.name, disk.usedShare, "\(ByteFormat.size(Double(disk.free))) free of \(ByteFormat.size(Double(disk.total)))")
            }
        }
        Section("Network") {
            row("Download", ByteFormat.rate(snapshot.down))
            row("Upload", ByteFormat.rate(snapshot.up))
            row("Received since start-up", ByteFormat.size(Double(snapshot.totalDown)))
            row("Sent since start-up", ByteFormat.size(Double(snapshot.totalUp)))
            if let address = NetworkAddress.local() { row("Address", address) }
        }
        if let b = snapshot.battery {
            Section("Battery") {
                bar("Charge", Double(b.percent) / 100, "\(b.percent)%\(b.charging ? ", charging" : b.onAC ? ", plugged in" : "")")
                if let left = b.minutesLeft, !b.onAC { row("Time left", ByteFormat.duration(Double(left) * 60)) }
                if let cycles = b.cycles { row("Charge cycles", "\(cycles)") }
                if let health = b.healthPercent { row("Health", "\(health)% of new") }
            }
        }
        if !snapshot.devices.isEmpty {
            Section("Connected devices") {
                ForEach(snapshot.devices, id: \.name) { d in row(d.name, "\(d.percent)%\(d.charging ? ", charging" : "")", warn: d.percent <= 15 && !d.charging) }
            }
        }
    }

    private func row(_ title: String, _ value: String, warn: Bool = false) -> some View {
        LabeledContent(title) { Text(value).monospacedDigit().foregroundStyle(warn ? Theme.warn : .secondary).lineLimit(1) }
    }

    private func bar(_ title: String, _ share: Double, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack { Text(title); Spacer(); Text(value).foregroundStyle(.secondary).monospacedDigit() }
            ProgressView(value: min(max(share, 0), 1)).tint(share > 0.9 ? Theme.warn : .accentColor).animation(.easeOut(duration: 0.4), value: share)
        }
    }
}

/// The folders taking the most room, measured when asked.
struct StorageSection: View {
    @StateObject private var scanner = StorageScanner()

    var body: some View {
        Section {
            if scanner.items.isEmpty {
                HStack {
                    Text(scanner.scanning ? "Measuring your folders…" : "See which folders take the room.").foregroundStyle(.secondary)
                    Spacer()
                    if scanner.scanning { ProgressView().controlSize(.small) }
                }
            }
            ForEach(scanner.items) { item in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.name)
                        if let note = item.note { Text(note).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    Text(ByteFormat.size(Double(item.bytes))).monospacedDigit().foregroundStyle(.secondary)
                    Button { NSWorkspace.shared.activateFileViewerSelecting([item.url]) } label: { Image(systemName: "magnifyingglass") }.buttonStyle(.borderless).help("Show in Finder")
                    if item.name == "Trash" { Button("Empty") { scanner.emptyTrash() }.controlSize(.small) }
                }
            }
            Button(scanner.items.isEmpty ? "Measure Folders" : "Measure Again") { scanner.scan() }.disabled(scanner.scanning)
        } header: { Text("Storage") } footer: {
            Text("Sizes only. Nothing is deleted except the Trash, and only when you press Empty. macOS may ask before Kriya can read some folders.")
        }
    }
}

/// Big files and exact copies, in a folder you choose. Nothing is removed unless you press the button on that file.
struct CleanupSection: View {
    @StateObject private var scanner = FileCleanupScanner()

    var body: some View {
        Section {
            HStack {
                Text(scanner.folder.path).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                Spacer()
                Button("Choose…") { scanner.chooseFolder() }.controlSize(.small).disabled(scanner.scanning)
            }
            HStack {
                Button("Find Large Files") { scanner.scan(duplicates: false) }.disabled(scanner.scanning)
                Button("Find Copies") { scanner.scan(duplicates: true) }.disabled(scanner.scanning)
                if scanner.scanning { Button("Stop") { scanner.cancel() }; ProgressView().controlSize(.small) }
                Spacer()
                Text(scanner.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if !scanner.duplicateSets.isEmpty {
                Text("Copies would free \(ByteFormat.size(Double(scanner.reclaimable))) if you kept one of each.").font(.callout).foregroundStyle(.secondary)
                ForEach(Array(scanner.duplicateSets.prefix(30).enumerated()), id: \.offset) { _, set in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(set.count) copies · \(ByteFormat.size(Double(set[0].size))) each").font(.caption).foregroundStyle(.secondary)
                        ForEach(set) { file in fileRow(file) }
                    }.padding(.vertical, 2)
                }
            }
            if !scanner.large.isEmpty {
                Text("Largest files").font(.callout.weight(.medium)).padding(.top, 4)
                ForEach(scanner.large) { file in fileRow(file) }
            }
        } header: { Text("Large files and copies") } footer: {
            Text("Copies are files with exactly the same contents, found by comparing them. Move to Trash puts a file in the Trash, where you can still get it back. Your Library folder is skipped.")
        }
    }

    private func fileRow(_ file: FoundFile) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 0) {
                Text(file.name).lineLimit(1)
                Text(file.folder).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(ByteFormat.size(Double(file.size))).monospacedDigit().foregroundStyle(.secondary)
            Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.path)]) } label: { Image(systemName: "magnifyingglass") }.buttonStyle(.borderless).help("Show in Finder")
            Button { scanner.trash(file) } label: { Image(systemName: "trash") }.buttonStyle(.borderless).help("Move to Trash")
        }
    }
}
