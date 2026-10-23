import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Finding out why something is not working: how things stand, what Kriya just did, and how the input watching is doing.
struct DiagnosticsPane: View {
    @State private var tab: Tab = .overview

    enum Tab: String, CaseIterable, Identifiable {
        case overview = "Overview", health = "Health", trace = "Trace", timeline = "Timeline", audit = "Audit"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) { ForEach(Tab.allCases) { Text($0.rawValue).tag($0) } }
                .paneTabBar(maxWidth: 440)
                .paneHeader()
            Group {
                switch tab {
                case .overview: DiagnosticsOverviewTab()
                case .health: HealthTab()
                case .trace: TraceTab()
                case .timeline: TimelineTab()
                case .audit: AuditTab()
                }
            }
            .id(tab)
            .transition(.opacity)
        }
        .animation(.smooth(duration: 0.22), value: tab)
        .tabHint($tab)
    }
}

// MARK: - Health

/// Whether Kriya has what it needs, and what could be getting in the way.
private struct HealthTab: View {
    @EnvironmentObject private var permissions: PermissionManager
    @EnvironmentObject private var services: ServiceManager
    @EnvironmentObject private var config: ConfigStore
    @EnvironmentObject private var registry: ShortcutRegistry
    @EnvironmentObject private var navigator: SettingsNavigator
    @State private var secure = SecureInput.current()
    @State private var released = false
    @State private var competing: [CompetingUtility] = []

    private let ticker = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private func refreshCompeting() {
        let running = NSWorkspace.shared.runningApplications.map { RunningProgram(bundleID: $0.bundleIdentifier, name: $0.localizedName) }
        competing = CompetingUtilities.detect(in: running)
    }

    var body: some View {
        Form {
            EvidenceSection()
            Section {
                ForEach(Permission.allCases) { permission in
                    let needed = FeatureId.all.filter { $0.requiredPermissions.contains(permission) }
                    HStack(spacing: 10) {
                        Image(systemName: icon(permissions.status(permission))).foregroundStyle(tint(permissions.status(permission)))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(permission.title)
                            Text(permission == .screenRecording ? "Used by Screen Capture and window previews" : (needed.isEmpty ? "Not needed by a feature" : "Used by " + needed.map(\.title).joined(separator: ", ")))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(label(permissions.status(permission))).font(.callout).foregroundStyle(.secondary)
                        if permissions.status(permission) == .denied || permissions.status(permission) == .notDetermined {
                            Button("Allow…") { permissions.request(permission) }.controlSize(.small)
                        }
                    }
                }
            } header: { Text("Permissions") } footer: {
                Text("macOS keeps these. A feature that needs one it does not have cannot work, and says so in its own pane.")
            }

            Section {
                ForEach(FeatureId.all) { feature in
                    let missing = feature.requiredPermissions.filter { !permissions.isGranted($0) && permissions.status($0) != .onDemand }
                    HStack {
                        Image(systemName: feature.symbol).frame(width: 22).foregroundStyle(.secondary)
                        Text(feature.title)
                        Spacer()
                        if config.isEnabled(feature), !missing.isEmpty {
                            StateBadge(text: "Needs " + missing.map(\.title).joined(separator: ", "), color: Theme.danger)
                        } else {
                            StateBadge(text: config.isEnabled(feature) ? services.state(feature).label : "Off", color: config.isEnabled(feature) && services.state(feature) == .running ? Theme.ok : .secondary)
                        }
                    }
                }
            } header: { Text("Features") }

            Section {
                if competing.isEmpty { Label("No overlapping utility is running.", systemImage: "checkmark.circle").foregroundStyle(Theme.ok) }
                ForEach(competing) { utility in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warn)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(utility.name)
                            Text(utility.overlaps).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            } header: { Text("Other utilities running") } footer: {
                Text("Two programs that remap keys, watch the mouse or move windows can undo each other. If something in Kriya does not behave, turn off the same feature in the program listed here, or in Kriya.")
            }
            .onAppear { refreshCompeting() }

            Section {
                HStack(spacing: 10) {
                    Image(systemName: secure.enabled ? "lock.fill" : "lock.open").foregroundStyle(secure.enabled ? Theme.warn : Theme.ok)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(secure.enabled ? "Secure input is on" : "Secure input is off")
                        if secure.enabled {
                            Text(secure.appName.map { "Held by \($0). " } ?? "Held by an app the system does not name. ").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
                if secure.enabled {
                    Text("While it is on, key remapping, shortcuts that read the keyboard and text expansion cannot see what you type. It usually turns off when you leave a password field or close the app that asked for it. Terminals can leave it on: look for “Secure Keyboard Entry” in the Terminal menu.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Release Stuck Modifier Keys") {
                        ModifierReset.run()
                        released = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { released = false }
                    }
                    if released { Label("Sent", systemImage: "checkmark").foregroundStyle(Theme.ok).transition(.opacity) }
                    Spacer()
                }
            } header: { Text("Keyboard") } footer: {
                Text("If ⌘, ⌥, ⌃ or ⇧ feels stuck, this lets go of all of them at once.")
            }

            Section {
                LabeledContent("Shortcuts that clash", value: "\(registry.conflicts.count)")
                Button("Open the Shortcut Map") { navigator.pane = .shortcutMap }.controlSize(.small)
            } header: { Text("Conflicts") }
        }
        .formStyle(.grouped)
        .animation(.smooth(duration: 0.2), value: secure)
        .animation(.smooth(duration: 0.2), value: released)
        .onReceive(ticker) { _ in secure = SecureInput.current() }
    }

    private func icon(_ status: PermissionStatus) -> String {
        switch status {
        case .granted: return "checkmark.circle.fill"
        case .denied: return "xmark.circle.fill"
        case .notDetermined: return "questionmark.circle"
        case .onDemand: return "circle.dashed"
        }
    }

    private func tint(_ status: PermissionStatus) -> Color {
        switch status {
        case .granted: return Theme.ok
        case .denied: return Theme.danger
        case .notDetermined: return Theme.warn
        case .onDemand: return .secondary
        }
    }

    private func label(_ status: PermissionStatus) -> String {
        switch status {
        case .granted: return "Allowed"
        case .denied: return "Not allowed"
        case .notDetermined: return "Not asked yet"
        case .onDemand: return "Asked when needed"
        }
    }
}

// MARK: - Trace

private struct TraceTab: View {
    @ObservedObject private var trace = InteractionTrace.shared
    @State private var now = Date()

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                HStack {
                    if trace.isOn {
                        Button("Stop Tracing") { trace.stop() }
                        if let end = trace.offAt { Text("Stops itself in \(max(0, Int(end.timeIntervalSince(now))))s").font(.callout).foregroundStyle(.secondary) }
                    } else {
                        Button("Start Tracing for 5 Minutes") { trace.start() }
                    }
                    Spacer()
                    Button("Clear") { trace.clear() }.disabled(trace.entries.isEmpty)
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(SupportScrubber.scrub(trace.text()), forType: .string)
                    }.disabled(trace.entries.isEmpty)
                }
            } header: { Text("What Kriya just did") } footer: {
                Text("Trace shows which shortcut or command Kriya acted on, as it happens, so you can see why something did or did not run. It records only the name of the shortcut or command, never what you typed, selected or copied. It is off until you start it, and stops itself after five minutes.")
            }

            Section {
                if trace.entries.isEmpty {
                    Text(trace.isOn ? "Waiting. Press a shortcut or use a command." : "Nothing traced.").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(trace.entries.reversed()) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(entry.time, format: .dateTime.hour().minute().second()).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                        Text(entry.source).font(.caption).padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Color.primary.opacity(0.07), in: Capsule())
                        Text(entry.text).font(.callout)
                        Spacer(minLength: 0)
                    }
                }
            } header: { Text("Newest first") }
        }
        .formStyle(.grouped)
        .animation(.smooth(duration: 0.2), value: trace.isOn)
        .onReceive(ticker) { now = $0 }
    }
}

// MARK: - Timeline

private struct TimelineTab: View {
    @EnvironmentObject private var timeline: PerformanceTimeline
    @EnvironmentObject private var events: EventMonitor

    var body: some View {
        Form {
            Section {
                if timeline.samples.count < 2 {
                    Text("Collecting. A point is added every \(Int(PerformanceTimeline.interval)) seconds.").font(.callout).foregroundStyle(.secondary)
                } else {
                    chart("How long handling an event takes (95th percentile)", values: timeline.samples.map { Double($0.p95Microseconds) }, unit: "µs", color: Theme.accent)
                    chart("Events handled in each interval", values: timeline.samples.map { Double($0.events) }, unit: "events", color: Theme.ok)
                    let slow = timeline.samples.reduce(0) { $0 + $1.slowHandlers }
                    let recoveries = timeline.samples.reduce(0) { $0 + $1.recoveries }
                    LabeledContent("Slow handlers in this time", value: "\(slow)")
                    LabeledContent("Times the system switched the tap off", value: "\(recoveries)")
                }
            } header: { Text("The last \(Int(Double(PerformanceTimeline.capacity) * PerformanceTimeline.interval / 60)) minutes") } footer: {
                Text("A steady low line is healthy. A spike means a handler was slow at that moment. The numbers stay flat while no feature that watches input is running.")
            }
        }
        .formStyle(.grouped)
    }

    private func chart(_ title: String, values: [Double], unit: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.callout)
                Spacer()
                Text("latest \(Int(values.last ?? 0)) \(unit), highest \(Int(values.max() ?? 0))").font(.caption).foregroundStyle(.secondary)
            }
            Sparkline(values: values).stroke(color, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round)).frame(height: 48)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }
}

/// A line through a list of numbers, scaled to fit.
struct Sparkline: Shape {
    let values: [Double]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard values.count > 1 else { return path }
        let top = max(values.max() ?? 1, 1)
        for (index, value) in values.enumerated() {
            let point = CGPoint(x: rect.minX + rect.width * CGFloat(index) / CGFloat(values.count - 1), y: rect.maxY - rect.height * CGFloat(value / top))
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }
}

// MARK: - Overview

private struct DiagnosticsOverviewTab: View {
    @EnvironmentObject private var intelligence: AppleIntelligence
    @EnvironmentObject private var permissions: PermissionManager
    @EnvironmentObject private var config: ConfigStore
    @EnvironmentObject private var crashGuard: CrashGuard
    @EnvironmentObject private var events: EventMonitor
    @EnvironmentObject private var devices: DeviceRegistry
    @EnvironmentObject private var services: ServiceManager
    @EnvironmentObject private var windowController: WindowController
    @Environment(\.paths) private var paths

    @State private var lines: [String] = []
    @State private var stats = EventMonitor.Stats()
    @State private var autoRefresh = true
    @State private var message: String?
    @State private var resetting: ResettableArea?
    @State private var explaining = false
    @ObservedObject private var timings = FeatureTimings.shared

    private let ticker = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    private var eventTapText: String {
        switch events.state {
        case .stopped: return events.subscriberCount == 0 ? "Idle (no feature needs it)" : "Stopped"
        case .running: return "Running"
        case .failed(let reason): return reason
        }
    }

    var body: some View {
        Form {
            Section("This Mac") {
                LabeledContent("Kriya", value: "\(SystemInfo.appVersion) (\(SystemInfo.build))")
                LabeledContent("Core", value: coreVersion())
                LabeledContent("macOS", value: SystemInfo.osVersion)
                LabeledContent("Processor", value: SystemInfo.architecture)
                LabeledContent("Safe mode", value: crashGuard.isSafeMode ? "On" : "Off")
                LabeledContent("Devices connected", value: "\(devices.devices.filter(\.isConnected).count)")
                LabeledContent("Features running", value: "\(FeatureId.all.filter { services.state($0) == .running }.count)")
            }

            Section {
                LabeledContent("Event tap", value: eventTapText)
                LabeledContent("Events handled", value: stats.eventsHandled.formatted())
                LabeledContent("Average (last 512 events)", value: latencyText(stats.averageMicroseconds))
                LabeledContent("95th percentile", value: latencyText(stats.p95Microseconds))
                LabeledContent("99th percentile", value: latencyText(stats.p99Microseconds))
                LabeledContent("Slowest handler", value: latencyText(stats.worstHandlerMicroseconds))
                LabeledContent("Slow handlers (over 20 ms)", value: stats.slowHandlers.formatted())
                LabeledContent("Times the system switched it off", value: stats.tapRecoveries.formatted())
            } header: {
                Text("Input latency")
            } footer: {
                Text("How long Kriya takes to handle each mouse or key event. It should stay well under a millisecond. The numbers stay at zero until a feature that watches input is running.")
                Button("Reset Numbers") { events.resetStats(); refresh() }.controlSize(.small)
            }

            WindowDiagnosticsSection(diagnostics: windowController.diagnostics, displays: windowController.displays)

            Section {
                Picker("Detail", selection: $config.settings.logLevel) {
                    ForEach(LogLevel.all, id: \.self) { Text($0.title).tag($0) }
                }
                HStack {
                    Button("Show Log Folder") { NSWorkspace.shared.open(paths.logs) }
                    Button("Save Diagnostic Report…") { saveReport() }
                    Button("Explain with AI") { explain() }.disabled(explaining || !AIGateway.shared.isAvailable(for: .diagnostics))
                        .help("Sends the report, with names, paths, addresses and keys removed, to the provider you chose for Diagnostics")
                    Spacer()
                }
                if let message {
                    Text(message).font(.callout).foregroundStyle(.secondary).transition(.opacity)
                }
            } header: {
                Text("Log")
            } footer: {
                Text("The log stays on this Mac. It records what Kriya did, never what you typed or selected. A report is a text file you can choose to share.")
            }

            Section {
                Toggle("Measure how long Kriya's own work takes", isOn: $timings.enabled)
                if let bytes = ProcessMemory.residentBytes() {
                    LabeledContent("Memory held by Kriya", value: ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory))
                }
                if timings.enabled {
                    ForEach(timings.table.ranked, id: \.name) { entry in
                        LabeledContent(entry.name) {
                            Text("\(entry.stat.count)× · avg \(entry.stat.averageMicroseconds) µs · worst \(entry.stat.worstMicroseconds) µs · total \(entry.stat.totalMicroseconds / 1000) ms")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    if timings.table.stats.isEmpty { Text("Nothing has been measured yet.").font(.callout).foregroundStyle(.secondary) }
                    Button("Clear") { timings.reset() }.controlSize(.small)
                }
            } header: { Text("Activity and memory (approximate)") } footer: {
                Text("Off by default. These are Kriya's own clock readings for a few of its recurring jobs, kept in memory only and never written down or sent. They leave out time the system spends for Kriya, and they are not a substitute for Activity Monitor.")
            }

            Section {
                ForEach(FeatureReset.areas) { area in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(area.title)
                            Text(area.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Reset…", role: .destructive) { resetting = area }.controlSize(.small)
                    }
                }
                if let last = resetUndo.load() {
                    HStack {
                        Text("\(last.area.title) was reset \(last.at.formatted(.relative(presentation: .named))).").font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button("Undo and Restart") {
                            FeatureReset.restore(last.values, to: last.area)
                            resetUndo.clear()
                            UserDefaults.standard.synchronize()
                            SystemInfo.relaunch(arguments: [])
                        }.controlSize(.small)
                    }
                }
            } header: { Text("Reset one part") } footer: {
                Text("Puts one part of Kriya back to how it was on first launch and leaves everything else as it is. Kriya restarts to finish. It cannot be undone, so make a backup first if the settings matter.")
            }
            .confirmationDialog("Reset \(resetting?.title ?? "")?", isPresented: Binding(get: { resetting != nil }, set: { if !$0 { resetting = nil } }), titleVisibility: .visible) {
                Button("Reset and Restart", role: .destructive) {
                    if let area = resetting { performReset(area) }
                    resetting = nil
                }
            } message: {
                Text(resetting.map { "\($0.detail) will be cleared." } ?? "")
            }

            Section {
                if crashGuard.isSafeMode {
                    Button("Leave Safe Mode") { withAnimation(.smooth) { crashGuard.leaveSafeMode() } }
                } else {
                    Button("Restart in Safe Mode") { crashGuard.restartInSafeMode() }
                }
            } header: {
                Text("Recovery")
            } footer: {
                Text("Safe mode starts Kriya with every feature off. Use it if a feature is causing trouble.")
            }

            Section {
                ScrollView {
                    Text(lines.isEmpty ? "The log is empty." : lines.joined(separator: "\n"))
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 220)
                HStack {
                    Toggle("Keep this log up to date", isOn: $autoRefresh)
                    Spacer()
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
                    }
                }
            } header: {
                Text("Recent log")
            }
        }
        .formStyle(.grouped)
        .animation(.smooth(duration: 0.25), value: message)
        .animation(.smooth(duration: 0.25), value: crashGuard.isSafeMode)
        .onAppear(perform: refresh)
        .onReceive(ticker) { _ in if autoRefresh { refresh() } }
    }

    private func refresh() {
        stats = events.currentStats()
        lines = Log.shared.recentLines(limit: 200)
    }

    private func latencyText(_ micros: Int) -> String {
        micros < 1000 ? "\(micros) µs" : String(format: "%.1f ms", Double(micros) / 1000)
    }

    private var resetUndo: FeatureResetUndo { FeatureResetService.undoStore }

    /// Keeps what the area held, clears it, and restarts. If Kriya is still running a few seconds later the restart did not
    /// happen, so what was held is put back and the person is told.
    private func performReset(_ area: ResettableArea) {
        if let problem = FeatureResetService.reset(area, onRollback: { message = $0 }) { message = problem }
    }

    private func explain() {
        explaining = true
        let report = DiagnosticReport.make(config: config, devices: devices, services: services, events: events, permissions: permissions, intelligence: intelligence)
        Task {
            do {
                let text = try await AIDiagnosticsExplainer.explain(report: report, question: "")
                await MainActor.run { explaining = false; ScriptOutputWindow.show(title: "What the report suggests", text: text) }
            } catch {
                await MainActor.run { explaining = false; message = (error as? AIError)?.errorDescription ?? error.localizedDescription }
            }
        }
    }

    private func saveReport() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "Kriya diagnostic report.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let report = DiagnosticReport.make(config: config, devices: devices, services: services, events: events, permissions: permissions, intelligence: intelligence)
        do {
            try report.write(to: url, atomically: true, encoding: .utf8)
            message = "Saved \(url.lastPathComponent)."
        } catch {
            message = "Could not save the report: \(error.localizedDescription)"
        }
    }
}

/// The text of a diagnostic report: versions, what is on, and the log. Names, file paths, addresses and keys are removed.
enum DiagnosticReport {
    static func make(config: ConfigStore, devices: DeviceRegistry, services: ServiceManager, events: EventMonitor, permissions: PermissionManager? = nil, intelligence: AppleIntelligence? = nil) -> String {
        var out: [String] = []
        out.append("Kriya diagnostic report")
        out.append("Created: \(Date().formatted(date: .complete, time: .standard))")
        out.append("Kriya: \(SystemInfo.appVersion) (\(SystemInfo.build)), core \(coreVersion())")
        out.append("macOS: \(SystemInfo.osVersion)")
        out.append("Processor: \(SystemInfo.architecture)")
        out.append("")
        out.append("Features:")
        for feature in FeatureId.all {
            out.append("  \(feature.title): \(config.isEnabled(feature) ? "on" : "off"), \(services.state(feature).label)")
        }
        if let permissions {
            out.append("")
            out.append("Permissions:")
            for permission in Permission.allCases { out.append("  \(permission.title): \(permissions.status(permission))") }
        }
        if let intelligence { out.append("Apple Intelligence: \(intelligence.availability.title)") }
        let secure = SecureInput.current()
        out.append("Secure input: \(secure.enabled ? "on" + (secure.appName.map { " (\($0))" } ?? "") : "off")")
        out.append("")
        out.append("Devices:")
        for device in devices.devices {
            out.append("  \(device.record.name) — \(device.record.kind.title), \(device.connection.title), \(device.record.transport), \(device.isConnected ? "connected" : "not connected")")
        }
        let stats = events.currentStats()
        out.append("")
        out.append("Event tap: \(events.state), \(events.subscriberCount) subscribers, \(stats.eventsHandled) events, avg \(stats.averageMicroseconds) µs, p95 \(stats.p95Microseconds) µs, p99 \(stats.p99Microseconds) µs, worst \(stats.worstHandlerMicroseconds) µs, \(stats.slowHandlers) slow, \(stats.tapRecoveries) recoveries")
        out.append("")
        out.append("Recent activity (what Kriya did, newest first):")
        out.append(AuditLog.shared.text())
        out.append("")
        out.append("Log:")
        for file in Log.shared.allLogFiles() {
            if let text = try? String(contentsOf: file, encoding: .utf8) {
                out.append("--- \(file.lastPathComponent) ---")
                out.append(String(text.suffix(200_000)))
            }
        }
        // A report is made to be shared, so what identifies the person is taken out of all of it.
        return SupportScrubber.scrub(out.joined(separator: "\n"))
    }
}

/// How window management has been doing: timings, apps that would not comply, shortcut problems and the displays.
struct WindowDiagnosticsSection: View {
    @ObservedObject var diagnostics: WindowDiagnostics
    @ObservedObject var displays: DisplayManager

    var body: some View {
        Section {
            LabeledContent("Window moves", value: "\(diagnostics.operations)")
            LabeledContent("Failed", value: "\(diagnostics.failures)")
            LabeledContent("Last move", value: String(format: "%.0f ms", diagnostics.lastMilliseconds))
            LabeledContent("Average", value: String(format: "%.0f ms", diagnostics.averageMilliseconds))
            LabeledContent("Slowest", value: String(format: "%.0f ms", diagnostics.worstMilliseconds))
            ForEach(displays.displays) { display in
                LabeledContent(display.name + (display.isMain ? " (main)" : "")) {
                    Text("\(Int(display.area.width)) × \(Int(display.area.height)) at \(Int(display.full.x)), \(Int(display.full.y))")
                        .font(.system(.caption, design: .monospaced))
                }
            }
            if !diagnostics.resistedApps.isEmpty {
                LabeledContent("Apps that did not fit") {
                    Text(diagnostics.resistedApps.sorted { $0.value > $1.value }.map { "\($0.key) ×\($0.value)" }.joined(separator: ", "))
                        .font(.caption).multilineTextAlignment(.trailing)
                }
            }
            if !diagnostics.hotkeyFailures.isEmpty {
                LabeledContent("Shortcuts another app uses") {
                    Text(diagnostics.hotkeyFailures.joined(separator: ", ")).font(.caption).multilineTextAlignment(.trailing)
                }
            }
            if !diagnostics.recent.isEmpty {
                DisclosureGroup("Recent window actions") {
                    Text(diagnostics.recent.reversed().joined(separator: "\n"))
                        .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Button("Reset Window Numbers") { diagnostics.reset() }.controlSize(.small)
        } header: {
            Text("Window management")
        } footer: {
            Text("“Did not fit” means the app ended up more than a few points from where it was told, usually because of a minimum or fixed window size.")
        }
    }
}


// MARK: - Audit

/// What Kriya did that reached outside itself, newest first. It holds where and what, never the words or contents involved.
private struct AuditTab: View {
    @ObservedObject private var audit = AuditLog.shared
    @State private var filter: AuditLog.Kind?

    private var shown: [AuditLog.Entry] { audit.entries.filter { filter == nil || $0.kind == filter } }

    var body: some View {
        Form {
            UnifiedActivitySection()
            Section {
                if LocalOnly.isOn { Label("Local-only mode is on: no network requests are being made.", systemImage: "lock.shield").foregroundStyle(Theme.ok) }
                Picker("Show", selection: $filter) {
                    Text("Everything").tag(AuditLog.Kind?.none)
                    ForEach(AuditLog.Kind.allCases) { Text($0.title).tag(AuditLog.Kind?.some($0)) }
                }
                if shown.isEmpty { Text("Nothing yet.").font(.callout).foregroundStyle(.secondary) }
                ForEach(shown.prefix(200)) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: entry.kind.symbol).foregroundStyle(.secondary).frame(width: 18)
                        Text(entry.summary).lineLimit(2)
                        Spacer()
                        Text(entry.at.formatted(date: .abbreviated, time: .standard)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: { Text("Audit") } footer: {
                Text("A record of network requests Kriya made (the site, not what was sent), scripts and commands it ran, installs, backups, files changed by rules and changes to local-only mode. The last \(AuditLog.capacity) are kept on this Mac.")
            }
            Section {
                HStack {
                    Button("Copy as Text") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(audit.text(kinds: filter.map { [$0] } ?? []), forType: .string)
                    }
                    Button("Clear", role: .destructive) { audit.clear() }
                }
            }
        }
        .formStyle(.grouped)
    }
}
