import SwiftUI

/// How the annotate editor behaves: its window, the pen, arrows, colour names and what it remembers. These are your preferences for the
/// editor; they are not stored in any project file.
struct EditorPreferencesSection: View {
    @State private var prefs = EditorPreferencesStore().preferences

    var body: some View {
        Section {
            Toggle("Keep the editor above other windows", isOn: $prefs.window.alwaysOnTop)
            Toggle("Show a Dock icon while the editor is open", isOn: $prefs.window.showDockIcon)
            Toggle("Smooth the pen", isOn: $prefs.smoothPen)
            Toggle("Hold ⌥ to point an arrow the other way", isOn: $prefs.reverseArrowWithOption)
            Toggle("Show the name of the colour", isOn: $prefs.showColourNames)
            Toggle("Open with the backdrop panel as I left it", isOn: $prefs.remembersBackdropPanel)
            Toggle("Grow the picture when a mark goes past its edge", isOn: $prefs.autoExpandCanvas)
            if prefs.autoExpandCanvas {
                Stepper("Room around the marks: \(Int(prefs.expandPadding)) pixels", value: $prefs.expandPadding, in: 0...200, step: 4)
            }
            HStack {
                Button("Restore Editor Shortcut Defaults") { prefs.shortcutOverrides = [:] }.controlSize(.small).disabled(prefs.shortcutOverrides.isEmpty)
                Spacer()
            }
        } header: { Text("Annotate editor") } footer: {
            Text("The Dock icon appears only while the editor is open, and Kriya goes back to how it was when you close it. Smoothing takes the jitter out of a freehand stroke when you lift the pen; it starts and ends where your hand did. These are kept for every picture you edit and are not saved inside project files.")
        }
        .onChange(of: prefs) { _, value in EditorPreferencesStore().preferences = value }
    }
}
