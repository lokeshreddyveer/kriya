import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct DiagnosticsPane: View {
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
                    Toggle("Update automatically", isOn: $autoRefresh)
                    Spacer()
                    Button("Refresh") { refresh() }
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

    private func saveReport() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "Kriya diagnostic report.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let report = DiagnosticReport.make(config: config, devices: devices, services: services, events: events)
        do {
            try report.write(to: url, atomically: true, encoding: .utf8)
            message = "Saved \(url.lastPathComponent)."
        } catch {
            message = "Could not save the report: \(error.localizedDescription)"
        }
    }
}

/// The text of a diagnostic report: versions, what is on, and the log. No file names, typed text or account details.
enum DiagnosticReport {
    static func make(config: ConfigStore, devices: DeviceRegistry, services: ServiceManager, events: EventMonitor) -> String {
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
        out.append("")
        out.append("Devices:")
        for device in devices.devices {
            out.append("  \(device.record.name) — \(device.record.kind.title), \(device.connection.title), \(device.record.transport), \(device.isConnected ? "connected" : "not connected")")
        }
        let stats = events.currentStats()
        out.append("")
        out.append("Event tap: \(events.state), \(events.subscriberCount) subscribers, \(stats.eventsHandled) events, avg \(stats.averageMicroseconds) µs, p95 \(stats.p95Microseconds) µs, p99 \(stats.p99Microseconds) µs, worst \(stats.worstHandlerMicroseconds) µs, \(stats.slowHandlers) slow, \(stats.tapRecoveries) recoveries")
        out.append("")
        out.append("Log:")
        for file in Log.shared.allLogFiles() {
            if let text = try? String(contentsOf: file, encoding: .utf8) {
                out.append("--- \(file.lastPathComponent) ---")
                out.append(String(text.suffix(200_000)))
            }
        }
        return out.joined(separator: "\n")
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
