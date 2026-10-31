import AppKit
import SwiftUI

/// Where a Quick Access card's Save puts a picture: a place, or a question each time, or a folder chosen here.
struct SaveDestinationPicker: View {
    let title: String
    @Binding var destination: SaveDestination

    var body: some View {
        Picker(title, selection: Binding(get: { destination.kind }, set: { kind in
            if kind == .custom, destination.path.isEmpty, !choose() { return }
            destination.kind = kind
        })) {
            ForEach(SaveDestination.Kind.allCases) { Text($0.title).tag($0) }
        }
        if destination.kind == .custom {
            LabeledContent("Folder") {
                HStack(spacing: 8) {
                    Text(destination.path.isEmpty ? "None chosen" : (destination.path as NSString).abbreviatingWithTildeInPath)
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Button("Choose…") { _ = choose() }.controlSize(.small)
                }
            }
        }
    }

    /// Asks for a folder. False if the person cancelled.
    private func choose() -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        destination.path = url.path
        return true
    }
}
