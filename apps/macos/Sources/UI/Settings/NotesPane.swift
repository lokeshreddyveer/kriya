import SwiftUI

struct NotesPane: View {
    @EnvironmentObject private var controller: NotesController
    @State private var folder = ""

    var body: some View {
        Form {
            Section {
                LabeledContent("Notes folder") { Text(folder).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary) }
                HStack {
                    Button("Choose Folder…") { choose() }
                    Button("Show in Finder") { try? FileManager.default.createDirectory(at: controller.folder, withIntermediateDirectories: true); NSWorkspace.shared.open(controller.folder) }
                    Button("Open Notes") { controller.show() }
                }
            } header: { Text("Where notes live") } footer: {
                Text("Each note is a plain Markdown file named by its date and first line, so any app can open it. Set a shortcut for “Open Notes” in the Keyboard pane, or type “note” and your text in the launcher to save one at once.")
            }
        }
        .formStyle(.grouped)
        .onAppear { folder = controller.folder.path }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = "Use This Folder"
        if panel.runModal() == .OK, let url = panel.url {
            UserDefaults.standard.set(url.path, forKey: NotesModel.folderKey)
            folder = url.path
            controller.model.reload()
        }
    }
}
