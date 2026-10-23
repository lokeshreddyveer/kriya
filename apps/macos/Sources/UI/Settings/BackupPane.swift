import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct BackupPane: View {
    @EnvironmentObject private var backup: BackupManager
    @Environment(\.paths) private var paths

    @State private var message: String?
    @State private var messageIsError = false
    @State private var phrase = ""
    @State private var again = ""

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
                if backup.isProtected {
                    Label("Backups are protected with your passphrase.", systemImage: "lock.shield.fill").foregroundStyle(Theme.ok)
                    Button("Stop Protecting Backups…", role: .destructive) { confirmStopProtecting() }.controlSize(.small)
                } else {
                    SecureField("Passphrase (at least 8 characters)", text: $phrase)
                    SecureField("Type it again", text: $again)
                    Button("Protect Backups") { protect() }
                        .disabled(phrase.count < BackupCrypto.minimumLength || phrase != again)
                }
            } header: { Text("Protection") } footer: {
                Text(backup.isProtected
                     ? "Every backup, including the automatic ones and the iCloud Drive copy, is sealed so it cannot be read without the passphrase. The passphrase is kept in your Keychain on this Mac. To restore on another Mac you type it. If you lose it, protected backups cannot be opened by anyone, including Kriya."
                     : "A backup holds your saved actions, scripts, shortcuts and rules in plain text. A passphrase seals it, so a copy in iCloud Drive or on a drive cannot be read by anyone who finds it.")
            }

            Section {
                if let newer = backup.newerFromOtherMac {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.triangle.2.circlepath.icloud").foregroundStyle(Theme.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Newer settings from \(newer.name.replacingOccurrences(of: "Kriya – ", with: "").replacingOccurrences(of: ".\(BackupManager.fileExtension)", with: ""))").font(.headline)
                            Text("Saved \(newer.date.shortDescription). Restoring replaces this Mac's settings; this Mac's current ones are saved first so you can undo it.").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Not Now") { withAnimation(.smooth) { backup.dismissNewerFromOtherMac() } }.controlSize(.small)
                        Button("Review…") { confirmRestore(newer.url) }.controlSize(.small).buttonStyle(.borderedProminent)
                    }
                    .padding(.vertical, 4).transition(.opacity)
                }
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
                     ? "Keeps one copy of your settings per Mac in iCloud Drive, updated every hour. To move to another Mac, turn this on in both and restore the other Mac's copy here. Clipboard history is never included. Unless backups are protected with a passphrase (above), the copy is not encrypted and includes your saved actions, scripts and shortcuts, so turn this on only if you are comfortable with that in your iCloud Drive."
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

    private func protect() {
        do {
            try backup.protect(with: phrase)
            phrase = ""; again = ""
            show("Backups are protected.", error: false)
        } catch {
            show(error.userMessage, error: true)
        }
    }

    private func confirmStopProtecting() {
        let alert = NSAlert()
        alert.messageText = "Stop protecting backups?"
        alert.informativeText = "New backups will be saved in plain text again. Backups already protected still need the passphrase to open."
        alert.addButton(withTitle: "Stop Protecting")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { backup.stopProtecting() }
    }

    /// Asks for the passphrase of a protected backup.
    private func askPassphrase(again retry: Bool) -> String? {
        let alert = NSAlert()
        alert.messageText = retry ? "That passphrase did not work" : "This backup is protected"
        alert.informativeText = "Type the passphrase it was protected with."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty else { return nil }
        return field.stringValue
    }

    private func confirmRestore(_ url: URL, passphrase: String? = nil) {
        let summary: BackupSummary
        do {
            summary = try backup.inspect(url, passphrase: passphrase)
        } catch let error as BackupCryptoError where error == .needsPassphrase || error == .wrongPassphrase {
            if let typed = askPassphrase(again: error == .wrongPassphrase) { confirmRestore(url, passphrase: typed) }
            return
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
            try backup.restore(from: url, passphrase: passphrase)
            show("Settings restored.", error: false)
        } catch {
            show(error.userMessage, error: true)
        }
    }
}
