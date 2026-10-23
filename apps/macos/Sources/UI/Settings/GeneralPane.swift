import AppKit
import SwiftUI

struct GeneralPane: View {
    @AppStorage("ui.textSize") private var textSizeRaw = TextSize.standard.rawValue
    @EnvironmentObject private var config: ConfigStore
    @EnvironmentObject private var updates: UpdateManager
    @EnvironmentObject private var menuBar: MenuBarHider
    @State private var cliInstalled = CommandLineTool.isInstalled()
    @State private var cliMessage: String?

    @State private var loginStatus = LaunchAtLogin.status
    @State private var loginError: String?
    @State private var localOnly = LocalOnly.isOn

    private var loginBinding: Binding<Bool> {
        Binding(
            get: { loginStatus != .disabled },
            set: { on in
                do {
                    try LaunchAtLogin.setEnabled(on)
                    loginError = nil
                } catch {
                    loginError = "Could not change this: \(error.localizedDescription)"
                }
                withAnimation(.smooth) { loginStatus = LaunchAtLogin.status }
            }
        )
    }

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Open Kriya when I log in", isOn: loginBinding)
                if loginStatus == .requiresApproval {
                    HStack {
                        Text("Approve Kriya in Login Items to finish turning this on.")
                            .font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Login Items") { LaunchAtLogin.openLoginItemsSettings() }
                    }
                    .transition(.opacity)
                }
                if let loginError {
                    Text(loginError).font(.callout).foregroundStyle(Theme.danger).transition(.opacity)
                }
                Toggle("Show Kriya in the Dock", isOn: $config.settings.showAppIcon)
            }

            Section("Appearance") {
                Picker("Text size in settings", selection: $textSizeRaw) {
                    ForEach(TextSize.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Text("Makes the text and controls in this window larger. The window already grows them when it is made very wide. Colours follow System Settings › Accessibility › Display › Increase contrast.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Appearance", selection: $config.settings.appearance) {
                    ForEach([AppearanceMode.system, .light, .dark], id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section {
                Toggle("Local only: keep Kriya off the network", isOn: Binding(get: { localOnly }, set: { LocalOnly.isOn = $0; localOnly = $0 }))
            } header: { Text("Privacy") } footer: {
                Text("While this is on, Kriya makes no network requests of its own. It stops: " + LocalOnly.stopped.joined(separator: "; ") + ". Web searches and quicklinks still open in your browser when you choose them, and Homebrew is only run when you ask. See Diagnostics › Audit for everything Kriya did that reached outside itself.")
            }

            Section {
                Toggle("Look for updates automatically", isOn: $config.settings.automaticallyCheckForUpdates)
                    .disabled(!updates.isConfigured)
                Toggle("Install them automatically", isOn: $updates.installAutomatically)
                    .disabled(!updates.isConfigured || !config.settings.automaticallyCheckForUpdates)
                if !updates.isConfigured {
                    Text("Updates are not set up in this build.").font(.callout).foregroundStyle(.secondary)
                } else if let last = updates.lastChecked {
                    Text("Last looked \(RelativeDateTimeFormatter().localizedString(for: last, relativeTo: Date())).")
                        .font(.callout).foregroundStyle(.secondary)
                }
            } header: {
                Text("Updates")
            } footer: {
                Text("Kriya looks when it starts and then about every hour, and installs what it finds. Each update is signed. One that is not signed with Kriya's key is refused. Only the app's version is sent.")
            }

            Section {
                Toggle("Hide menu bar icons behind an arrow", isOn: Binding(get: { menuBar.isEnabled }, set: { menuBar.setEnabled($0) }))
                if menuBar.isEnabled {
                    Picker("Hide them again", selection: $menuBar.autoHideSeconds) { ForEach(MenuBarHider.autoHideChoices, id: \.seconds) { Text($0.title).tag($0.seconds) } }
                    Button(menuBar.isCollapsed ? "Show Hidden Icons" : "Hide Icons Now") { menuBar.toggle() }
                }
                if let problem = menuBar.problem { Label(problem, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(Theme.warn) }
            } header: { Text("Menu bar") } footer: {
                Text("Two items appear in the menu bar: a thin divider and an arrow. Hold ⌘ and drag icons to the left of the divider, then click the arrow to hide them or show them again. Turn this off and every icon is back.")
            }

            Section {
                HStack {
                    StateBadge(text: cliInstalled ? "Installed" : "Not installed", color: cliInstalled ? Theme.ok : Theme.warn)
                    Spacer()
                    if cliInstalled {
                        Button("Remove") { CommandLineTool.uninstall(); cliInstalled = CommandLineTool.isInstalled(); cliMessage = nil }
                    } else {
                        Button("Install “kriya”") {
                            cliMessage = CommandLineTool.install()
                            cliInstalled = CommandLineTool.isInstalled()
                            if cliMessage == nil, !CommandLineTool.isOnPath(CommandLineTool.installFolder) {
                                cliMessage = "Installed in ~/.local/bin. Add it to your PATH to type just “kriya”: export PATH=\"$HOME/.local/bin:$PATH\""
                            }
                        }
                    }
                }
                if let cliMessage { Text(cliMessage).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            } header: { Text("Command line and Shortcuts") } footer: {
                Text("“kriya run window.left_half”, “kriya action <id>”, “kriya workflow <id>” and “kriya launcher some text” run Kriya from a terminal or a script. The Shortcuts app has the same: search for Kriya under Apps. Both use a secret only your account can read; nothing goes over the network.")
            }

            Section {
                Toggle("Turn off a feature that crashes while starting", isOn: $config.settings.autoDisableCrashingFeature)
            } header: {
                Text("Safety")
            } footer: {
                Text("If Kriya quits unexpectedly three times in half an hour it starts in safe mode, with every feature off, so you can always get back in. Hold Option while opening Kriya to start in safe mode yourself.")
            }
        }
        .formStyle(.grouped)
        .onAppear { updates.refreshLastChecked() }
        .animation(.smooth(duration: 0.25), value: loginStatus)
        .animation(.smooth(duration: 0.25), value: loginError)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginStatus = LaunchAtLogin.status
        }
    }
}
