import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct BackupPane: View {
    @EnvironmentObject private var backup: BackupManager
    @Environment(\.paths) private var paths

    @State private var message: String?
    @State private var messageIsError = false

    private var fileType: UTType {
        UTType(filenameExtension: BackupManager.fileExtension) ?? .json
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    Button("Back Up Settings…") { exportBackup() }
                    Button("Restore from File…") { chooseRestore() }
                }
            } header: {
                Text("Your settings")
            } footer: {
                Text("A backup holds your settings, app profiles, saved actions, rules and device names. It does not include permissions, which stay with macOS. Restoring saves your current settings first, so you can undo it below.")
            }

            Section {
                Toggle("Back up to iCloud Drive", isOn: $backup.iCloudEnabled.animation())
                    .disabled(!backup.iCloudAvailable)
                if backup.iCloudEnabled {
                    HStack {
                        Text(backup.lastICloudBackup.map { "Last backup \($0.shortDescription)" } ?? "Not backed up yet")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Back Up Now") { backUpToICloud() }.controlSize(.small)
                    }
                }
                ForEach(backup.iCloudBackups) { file in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(file.name.replacingOccurrences(of: ".\(BackupManager.fileExtension)", with: ""))
                            Text(file.date.shortDescription).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Restore") { confirmRestore(file.url) }.controlSize(.small)
                    }
                }
            } header: {
                Text("iCloud Drive")
            } footer: {
                Text(backup.iCloudAvailable
                     ? "Keeps one copy of your settings per Mac in iCloud Drive, updated every hour. To move to another Mac, turn this on in both and restore the other Mac's copy here. Clipboard history is never included. The copy is not encrypted and includes your saved actions, scripts and shortcuts, so turn this on only if you are comfortable with that in your iCloud Drive."
                     : "Turn on iCloud Drive in System Settings to use this.")
            }

            if let message {
                Section {
                    Label(message, systemImage: messageIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(messageIsError ? Theme.danger : Theme.ok)
                        .transition(.opacity)
                }
            }

            Section {
                if backup.automaticBackups.isEmpty {
                    Text("None yet. One is saved automatically before each restore.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(backup.automaticBackups) { file in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(file.date.shortDescription)
                            Text(file.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Button("Restore") { confirmRestore(file.url) }.controlSize(.small)
                    }
                }
            } header: {
                HStack {
                    Text("Automatic backups")
                    Spacer()
                    Button("Show in Finder") { NSWorkspace.shared.open(paths.backups) }
                        .controlSize(.small)
                }
            }
        }
        .formStyle(.grouped)
        .animation(.smooth(duration: 0.25), value: message)
        .animation(.smooth(duration: 0.3), value: backup.automaticBackups)
        .onAppear { backup.refreshList(); backup.refreshICloudList() }
    }

    private func backUpToICloud() {
        do {
            try backup.backUpToICloud()
            show("Backed up to iCloud Drive.", error: false)
        } catch {
            show(error.userMessage, error: true)
        }
    }

    private func show(_ text: String, error: Bool) {
        messageIsError = error
        message = text
    }

    private func exportBackup() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [fileType]
        panel.nameFieldStringValue = "Kriya \(Date().formatted(.iso8601.year().month().day())).\(BackupManager.fileExtension)"
        panel.message = "Save a copy of your Kriya settings."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try backup.export(to: url)
            show("Saved \(url.lastPathComponent).", error: false)
        } catch {
            show(error.userMessage, error: true)
        }
    }

    private func chooseRestore() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [fileType, .json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a Kriya backup to restore."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        confirmRestore(url)
    }

    private func confirmRestore(_ url: URL) {
        let summary: BackupSummary
        do {
            summary = try backup.inspect(url)
        } catch {
            show(error.userMessage, error: true)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Restore these settings?"
        alert.informativeText = """
            Made \(Date(timeIntervalSince1970: TimeInterval(summary.createdAt)).shortDescription) with Kriya \(summary.appVersion).
            It holds \(summary.profiles) profile\(summary.profiles == 1 ? "" : "s"), \(summary.actions) saved action\(summary.actions == 1 ? "" : "s") \(summary.rules) rule\(summary.rules == 1 ? "" : "s") and \(summary.mousePresets) mouse preset\(summary.mousePresets == 1 ? "" : "s").

            Your current settings will be replaced. They are saved first, so you can undo this.
            """
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try backup.restore(from: url)
            show("Settings restored.", error: false)
        } catch {
            show(error.userMessage, error: true)
        }
    }
}
