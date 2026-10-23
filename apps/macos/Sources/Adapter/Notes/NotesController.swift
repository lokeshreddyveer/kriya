import AppKit
import SwiftUI

/// The notes window's state: which note is open and what is typed. Saves as you type, a moment after you stop.
final class NotesModel: ObservableObject {
    static let folderKey = "notes.folder"
    @Published var notes: [NoteFile] = []
    @Published var current: URL?
    @Published var text = "" { didSet { if !loading { scheduleSave() } } }
    @Published var query = "" { didSet { reload() } }
    private var loading = false
    private var saveWork: DispatchWorkItem?

    var store: NoteStore {
        let path = UserDefaults.standard.string(forKey: Self.folderKey)
        return NoteStore(folder: path.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? NoteStore.defaultFolder)
    }

    func reload() { notes = store.search(query) }

    func open(_ url: URL) {
        flush()
        loading = true; current = url; text = store.read(url); loading = false
    }

    func newNote() {
        flush()
        loading = true; current = nil; text = ""; loading = false
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flush() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    /// Writes what is typed now. A note nobody has typed in is not created.
    func flush() {
        saveWork?.cancel()
        let s = store
        if let url = current { s.save(text, to: url) }
        else if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { current = s.create(text) }
        reload()
    }

    func deleteCurrent() {
        guard let url = current else { newNote(); return }
        saveWork?.cancel()
        store.trash(url)
        newNote(); reload()
    }
}

private struct NotesView: View {
    @ObservedObject var model: NotesModel
    let summarize: (String) -> Void
    let close: () -> Void
    @FocusState private var editing: Bool

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                TextField("Search notes", text: $model.query).textFieldStyle(.roundedBorder).padding(8)
                List(model.notes, selection: Binding(get: { model.current }, set: { if let u = $0 { model.open(u) } })) { note in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(note.title).lineLimit(1)
                        Text(note.modified, style: .relative).font(.caption).foregroundStyle(.secondary)
                    }.tag(note.url)
                }
                .listStyle(.sidebar)
            }
            .frame(width: 190)
            Divider()
            VStack(spacing: 0) {
                TextEditor(text: $model.text)
                    .font(.system(size: 14, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .focused($editing)
                Divider()
                HStack(spacing: 14) {
                    Button { model.newNote(); editing = true } label: { Label("New", systemImage: "square.and.pencil") }.keyboardShortcut("n")
                    Button { summarize(model.text) } label: { Label("Summarize", systemImage: "text.append") }.disabled(model.text.count < 40)
                    Menu {
                        Button("Suggest Tags") { NotesAI.suggestTags(model) }
                        Button("Pull Out Tasks") { NotesAI.extractTasks(model) }
                        Button("Tidy Up…") { NotesAI.cleanUp(model) }
                        Divider()
                        Button("Find Related or Duplicate Notes") { NotesAI.related(model) }
                        Button("Turn Into a Workflow Draft") { NotesAI.toWorkflow(model) }
                    } label: { Label("AI", systemImage: "sparkles") }.menuIndicator(.hidden).fixedSize().disabled(!AIGateway.shared.isAvailable(for: .notes) || model.text.count < 20)
                    Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(model.text, forType: .string) } label: { Label("Copy", systemImage: "doc.on.doc") }
                    Button { if let u = model.current { NSWorkspace.shared.activateFileViewerSelecting([u]) } } label: { Label("Show in Finder", systemImage: "folder") }.disabled(model.current == nil)
                    Spacer()
                    Button(role: .destructive) { model.deleteCurrent() } label: { Label("Delete", systemImage: "trash") }.disabled(model.current == nil)
                }
                .labelStyle(.iconOnly).buttonStyle(.borderless).padding(8)
            }
        }
        .frame(minWidth: 620, minHeight: 380)
        .onAppear { model.reload(); editing = true }
        .onExitCommand { close() }
    }
}

/// A floating notes window on a shortcut: type, and it is a Markdown file in your Notes folder.
final class NotesController: NSObject, NSWindowDelegate, ObservableObject {
    private final class Panel: NSPanel { override var canBecomeKey: Bool { true } }

    let model = NotesModel()
    var summarize: (String) -> Void = { _ in }
    private var panel: Panel?

    var folder: URL { model.store.folder }

    func toggle() { panel?.isVisible == true ? close() : show() }

    func show(opening url: URL? = nil, newNote: Bool = true) {
        if panel == nil {
            let p = Panel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 460), styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
            p.title = "Notes"
            p.titlebarAppearsTransparent = true
            p.isFloatingPanel = true
            p.level = .floating
            p.hidesOnDeactivate = false
            p.isReleasedWhenClosed = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.delegate = self
            p.contentView = NSHostingView(rootView: NotesView(model: model, summarize: { [weak self] in self?.summarize($0) }, close: { [weak self] in self?.close() }))
            p.setFrameAutosaveName("KriyaNotes")
            p.center()
            panel = p
        }
        model.reload()
        if let url { model.open(url) } else if newNote, model.current == nil || !model.text.isEmpty { model.newNote() }
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() { model.flush(); panel?.orderOut(nil) }
    func windowWillClose(_ notification: Notification) { model.flush() }

    /// Saves some text as a new note without opening the window.
    @discardableResult
    func quickSave(_ text: String) -> URL? {
        let url = model.store.create(text)
        model.reload()
        return url
    }
}
