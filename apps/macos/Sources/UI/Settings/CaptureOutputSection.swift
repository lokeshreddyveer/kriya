import AppKit
import SwiftUI

/// The newer capture options: the quick card, the saved format, a backdrop for every picture, apps never captured, and uploading to
/// the person's own bucket.
struct CaptureOutputSection: View {
    @AppStorage(CaptureOverlay.hideWhenSharingKey) private var hideWhenSharing = true
    @State private var format = CaptureExtraSettings.format
    @State private var keepOriginal = CaptureExtraSettings.keepOriginal
    @State private var style = CaptureExtraSettings.beautify
    @State private var excluded = CaptureExtraSettings.excludedApps

    var body: some View {
        Group {
            QuickAccessSection()
            Section {
                Toggle("Hide the cards and the editor from screen sharing and recordings", isOn: $hideWhenSharing)
                Picker("Save pictures as", selection: $format) { ForEach(CaptureFormat.allCases) { Text($0.title).tag($0) } }
                    .onChange(of: format) { _, value in CaptureExtraSettings.format = value }
                Toggle("Keep the untouched picture too when I edit one", isOn: $keepOriginal)
                    .onChange(of: keepOriginal) { _, value in CaptureExtraSettings.keepOriginal = value }
            } header: { Text("Formats and privacy") } footer: {
                Text("WebP is not offered because macOS cannot write it. Hiding from screen sharing asks macOS to leave Kriya's windows out of what other apps can capture or record; a phone pointed at the screen still sees them.")
            }

            Section {
                Picker("Backdrop", selection: $style.background) { ForEach(CaptureBeautify.Background.allCases) { Text($0.id == "none" ? "None (plain screenshot)" : $0.title).tag($0) } }
                if style.isOn {
                    Picker("Space around", selection: $style.padding) { Text("Small").tag(0.04); Text("Medium").tag(0.08); Text("Large").tag(0.14) }
                    Picker("Corners", selection: $style.corners) { Text("Square").tag(0.0); Text("Round").tag(0.02); Text("Rounder").tag(0.05) }
                    Picker("Shape", selection: $style.aspect) { ForEach(CaptureBeautify.Aspect.allCases) { Text($0.title).tag($0) } }
                    Toggle("Shadow", isOn: $style.shadow)
                }
            } header: { Text("Make every screenshot presentable") } footer: {
                Text("A backdrop, space, round corners and a shadow around each picture that is not edited. In the editor, Style does the same for one picture.")
            }
            .onChange(of: style) { _, value in CaptureExtraSettings.beautify = value }

            Section {
                ForEach(excluded, id: \.self) { id in
                    HStack {
                        Text(AppChoice.name(for: id))
                        Spacer()
                        Button(role: .destructive) { excluded.removeAll { $0 == id }; CaptureExtraSettings.excludedApps = excluded } label: { Image(systemName: "trash") }.buttonStyle(.borderless).accessibilityLabel("Allow capturing \(AppChoice.name(for: id))")
                    }
                }
                Button { if let id = AppChoice.choose(prompt: "Never Capture"), !excluded.contains(id) { excluded.append(id); CaptureExtraSettings.excludedApps = excluded } } label: { Label("Add an App", systemImage: "plus") }.controlSize(.small)
            } header: { Text("Apps Kriya never captures") } footer: {
                Text("When one of these is in front, a capture, text reading or recording is refused with a message, so a password or account number is not photographed by accident. Password managers are listed to start with.")
            }
        }
    }
}

/// The cards that appear after a capture: for what, where, how big, how long, and the menu-bar icon.
struct QuickAccessSection: View {
    @State private var s = QuickAccessStore.settings

    var body: some View {
        Section {
            Picker("Show a card after", selection: $s.scope) { ForEach(QuickAccessScope.allCases) { Text($0.title).tag($0) } }
            if s.scope != .off {
                Picker("Position", selection: $s.position) { ForEach(QuickAccessPosition.allCases) { Text($0.title).tag($0) } }
                Picker("On", selection: $s.display) { ForEach(QuickAccessDisplay.allCases) { Text($0.title).tag($0) } }
                Picker("Size", selection: $s.size) { ForEach(QuickAccessSize.allCases) { Text($0.title).tag($0) } }
                LabeledContent("Distance from the edge") {
                    HStack { Slider(value: $s.margin, in: 0...120, step: 2).frame(width: 160); Text("\(Int(s.margin)) pt").monospacedDigit().foregroundStyle(.secondary).frame(width: 52, alignment: .trailing) }
                }
                Picker("Close by itself after", selection: $s.autoCloseSeconds) {
                    Text("Stay until I close it").tag(0); Text("5 seconds").tag(5); Text("9 seconds").tag(9); Text("15 seconds").tag(15); Text("30 seconds").tag(30); Text("1 minute").tag(60)
                }
                Stepper("Cards stacked at once: \(s.stackLimit)", value: $s.stackLimit, in: 1...6)
                Toggle("Wait while a recording is running", isOn: $s.holdWhileRecording)
            }
            Picker("Menu-bar icon", selection: $s.icon) { ForEach(QuickAccessIcon.allCases) { Text($0.title).tag($0) } }
        } header: { Text("Quick access cards") } footer: {
            Text("A card shows the capture to drag into Finder, Mail, Slack or Messages, with its size, format and time, and buttons to copy, save, annotate, copy the text in it, pin, send to the shelf, share, move to the Trash and open the history. Keys while the pointer is over a card: \(QuickAccessKey.allCases.map { "\($0.key.uppercased()) \($0.title.lowercased())" }.joined(separator: ", ")). Swipe a card sideways to dismiss it. Closed cards come back from the menu-bar icon (or the command capture.restore). The icon is one optional menu, never a window: with “only while there is something to show” it appears after a capture and goes away again.")
        }
        .onChange(of: s) { _, value in QuickAccessStore.settings = value; CaptureOverlay.shared.settingsChanged() }
    }
}

/// Setting up uploads to a bucket the person owns. Off until filled in; the secret key goes to the Keychain.
struct CaptureUploadSection: View {
    @ObservedObject private var store = CaptureUploadStore.shared
    @State private var secret = ""
    @State private var hasSecret = false
    @State private var testResult: String?
    @State private var testing = false

    var body: some View {
        Section {
            Toggle("Allow uploading captures to my bucket", isOn: $store.config.enabled)
            if store.config.enabled {
                TextField("Endpoint", text: $store.config.endpoint, prompt: Text("ACCOUNT.r2.cloudflarestorage.com or s3.amazonaws.com"))
                TextField("Region", text: $store.config.region, prompt: Text("auto (R2), us-east-1…"))
                TextField("Bucket", text: $store.config.bucket)
                TextField("Access key ID", text: $store.config.accessKey)
                HStack {
                    SecureField(hasSecret ? "Secret key (saved in the Keychain)" : "Secret access key", text: $secret)
                    Button("Save Key") { if CaptureUploadKeychain.setSecret(secret.trimmingCharacters(in: .whitespacesAndNewlines), for: store.config.accessKey) { secret = ""; hasSecret = true } }
                        .disabled(secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.config.accessKey.isEmpty).controlSize(.small)
                    if hasSecret { Button("Forget Key", role: .destructive) { CaptureUploadKeychain.deleteSecret(for: store.config.accessKey); hasSecret = false }.controlSize(.small) }
                }
                TextField("Folder in the bucket", text: $store.config.prefix, prompt: Text("captures/"))
                TextField("Public address (optional)", text: $store.config.publicBase, prompt: Text("https://files.example.com"))
                if store.config.publicBase.trimmingCharacters(in: .whitespaces).isEmpty {
                    Picker("Links expire after", selection: $store.config.linkMinutes) {
                        Text("15 minutes").tag(15); Text("1 hour").tag(60); Text("1 day").tag(1440); Text("7 days").tag(10_080)
                    }
                }
                Toggle("Address style: endpoint/bucket/file (turn off for bucket.endpoint)", isOn: $store.config.usePathStyle)
                Toggle("Move the local file to the Trash after a successful upload", isOn: $store.config.deleteLocalAfterUpload)
                HStack {
                    Button(testing ? "Sending…" : "Send a Test File") { test() }.disabled(!store.config.isComplete || !hasSecret || testing).controlSize(.small)
                    if let testResult { Text(testResult).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                }
            }
        } header: { Text("Upload to my own bucket") } footer: {
            Text("Works with Amazon S3, Cloudflare R2, Backblaze B2, MinIO and anything else that speaks the S3 protocol. Kriya signs each request itself and sends it straight to your bucket; there is no Kriya server, and nothing is sent unless you press Upload on the card. With a public address the link is that address; without one it is a link that stops working after the time you choose (the bucket can stay private). Local-only mode blocks uploads.")
        }
        .onAppear { hasSecret = !store.config.accessKey.isEmpty && CaptureUploadKeychain.secret(for: store.config.accessKey) != nil }
        .animation(.smooth(duration: 0.2), value: store.config.enabled)
    }

    private func test() {
        testing = true; testResult = nil
        let data = Data("Kriya upload test \(Date())\n".utf8)
        CaptureUploader.upload(data, fileName: "kriya-test.txt", contentType: "text/plain") { result in
            DispatchQueue.main.async {
                testing = false
                switch result {
                case .success(let done): testResult = "Worked. Link: " + String(done.link.prefix(70)) + "…"
                case .failure(let error): testResult = error.localizedDescription
                }
            }
        }
    }
}
