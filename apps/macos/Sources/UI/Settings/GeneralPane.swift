import AppKit
import SwiftUI

struct GeneralPane: View {
    @EnvironmentObject private var config: ConfigStore
    @EnvironmentObject private var updates: UpdateManager

    @State private var loginStatus = LaunchAtLogin.status
    @State private var loginError: String?

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
                Picker("Appearance", selection: $config.settings.appearance) {
                    ForEach([AppearanceMode.system, .light, .dark], id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
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
