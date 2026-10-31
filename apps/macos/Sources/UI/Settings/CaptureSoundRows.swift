import AppKit
import SwiftUI

/// Which sound a capture makes, a file for a custom one, and a button to hear it. Goes under the "play a sound" switch.
struct CaptureSoundRows: View {
    /// Whether capture sounds are on. The sound can still be previewed when they are off.
    let enabled: Bool
    @State private var policy = CaptureExtraSettings.delivery.sound
    @State private var note: String?

    var body: some View {
        Picker("Sound", selection: $policy.choice) {
            ForEach(CaptureSound.allCases) { Text($0.title).tag($0) }
        }
        .onChange(of: policy) { _, value in
            var all = CaptureExtraSettings.delivery
            all.sound = value
            CaptureExtraSettings.delivery = all
            note = nil
        }
        if policy.choice == .custom {
            LabeledContent("Sound file") {
                HStack(spacing: 8) {
                    Text(policy.customURL?.lastPathComponent ?? "None chosen").foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Button("Choose…") { chooseFile() }.controlSize(.small)
                }
            }
        }
        HStack {
            Button("Preview") { hear() }.controlSize(.small).disabled(policy.choice == .none)
            if let note { Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            else if !enabled && policy.choice != .none { Text("Capture sounds are off; this only lets you hear it.").font(.caption).foregroundStyle(.secondary) }
            Spacer()
        }
    }

    private func hear() {
        let outcome = CaptureSoundPlayer.shared.preview(policy: policy)
        switch outcome.result {
        case .silent: note = "“None” is chosen, so there is nothing to hear."
        case .failed: note = outcome.message
        case .played: note = outcome.message
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.title = "Choose a sound for captures"
        panel.allowedContentTypes = [.audio]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard CaptureSoundFile.url(for: url.path) != nil else {
            note = "That kind of file cannot be used. Choose an AIFF, WAV, CAF, MP3 or M4A file."
            return
        }
        policy.customPath = url.path
    }
}
