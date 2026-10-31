import SwiftUI

/// Backdrops put behind captures automatically: one for screenshots, one for the thumbnails of recordings, when it goes on, and how to
/// leave it off for one capture. A profile can choose its own.
struct BackgroundsSection: View {
    @State private var policy = CaptureExtraSettings.delivery.background

    private var presets: [BackgroundPreset] { policy.presets.filter { !$0.id.hasPrefix(BackgroundPolicy.profilePrefix) } }

    private func picker(_ title: String, selection: Binding<String?>) -> some View {
        Picker(title, selection: selection) {
            Text("As before").tag(String?.none)
            Text("No backdrop").tag(String?.some(BackgroundPolicy.noneID))
            ForEach(presets) { Text($0.name).tag(String?.some($0.id)) }
        }
    }

    var body: some View {
        Section {
            picker("Screenshots", selection: $policy.screenshotPreset)
            picker("Recording thumbnails", selection: $policy.recordingPreset)
            Picker("Put it on", selection: $policy.timing) { ForEach(BackgroundPolicy.Timing.allCases) { Text($0.title).tag($0) } }
            Toggle("Only on what leaves Kriya", isOn: $policy.exportOnly)
            Toggle("Hold ⇧ when capturing to leave it off", isOn: $policy.skipWithShift)
        } header: { Text("Backgrounds") } footer: {
            Text("“As before” keeps the single backdrop set under Style, if there is one. A backdrop for recordings goes only on the thumbnail on the card: the recording itself is never changed. “Only on what leaves Kriya” puts it on the saved file, the copy and the upload, and keeps the card, the pin and the editor plain. “Before the editor opens” shows it in the editor so it can be adjusted there, with the picture itself untouched underneath. A capture profile can choose its own backdrop.")
        }
        .onChange(of: policy) { _, value in
            var all = CaptureExtraSettings.delivery
            all.background = value.sanitized()
            CaptureExtraSettings.delivery = all
        }
    }
}
