import SwiftUI

struct NotesPane: View {
    @EnvironmentObject private var controller: NotesController
    @State private var folder = ""
    @State private var saved: [URL] = []
    @State private var lockedCount = 0
    @State private var pinnedCount = 0

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

            Section {
                LabeledContent("Locked notes", value: "\(lockedCount)")
                Text("A locked note is encrypted with a key kept in your Keychain. Its title and text are never searched or shown in lists. If that Keychain key is lost, for example after erasing this Mac without a backup of the Keychain, the note cannot be read again and Kriya cannot recover it. Unlock a note first if you want a plain copy that any app can open.")
                    .font(.callout).foregroundStyle(.secondary)
            } header: { Text("Locked notes") }

            Section {
                if saved.isEmpty { Text("No saved templates. Use “Save This Note as a Template…” in the notes window.").font(.callout).foregroundStyle(.secondary) }
                ForEach(saved, id: \.self) { url in
                    HStack {
                        Text(url.deletingPathExtension().lastPathComponent)
                        Spacer()
                        Button("Edit") { NSWorkspace.shared.open(url) }.controlSize(.small)
                        Button(role: .destructive) { delete(url) } label: { Image(systemName: "trash") }.accessibilityLabel("Delete").buttonStyle(.borderless)
                    }
                }
            } header: { Text("Templates") } footer: {
                Text("Ready-made templates (Meeting, Daily log, Checklist) are always there. Yours are Markdown files in the .templates folder inside the notes folder. A template can use {title} {date} {time} {weekday} {clipboard} and {cursor}. Deleting one moves it to the Trash.")
            }

            Section {
                LabeledContent("Pinned notes", value: "\(pinnedCount)")
                Text("Attachments are stored next to the notes, in a hidden .attachments folder, one folder per note. They go to the Trash together with their note. Each file can be up to 100 MB.")
                    .font(.callout).foregroundStyle(.secondary)
            } header: { Text("Pins and attachments") }
        }
        .formStyle(.grouped)
        .onAppear { folder = controller.folder.path; refresh() }
    }

    private func refresh() {
        let store = controller.model.store
        saved = ((try? FileManager.default.contentsOfDirectory(at: store.templatesFolder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
            .filter { $0.pathExtension == "md" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        lockedCount = store.list().filter(\.locked).count
        pinnedCount = controller.model.pinned.count
    }

    private func delete(_ url: URL) {
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        withAnimation(.smooth(duration: 0.2)) { refresh() }
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
