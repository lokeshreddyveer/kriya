import AppKit
import SwiftUI

/// The notes window's state: which note is open and what is typed. Saves as you type, a moment after you stop.
final class NotesModel: ObservableObject {
    static let folderKey = "notes.folder"
    @Published var notes: [NoteFile] = []
    @Published var current: URL?
    @Published var text = "" { didSet { if !loading { scheduleSave() } } }
    @Published var query = "" { didSet { reload() } }
    /// Something the person needs to know about the last thing they did, shown under the note.
    @Published var notice: String?
    private var loading = false
    private var saveWork: DispatchWorkItem?

    var store: NoteStore {
        let path = UserDefaults.standard.string(forKey: Self.folderKey)
        return NoteStore(folder: path.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? NoteStore.defaultFolder)
    }

    var pinned: Set<String> { NotePins.stored }
    func isPinned(_ url: URL) -> Bool { pinned.contains(NotePins.key(url)) }

    func reload() { notes = NotePins.apply(store.search(query), pinned: NotePins.stored) }

    func togglePin() {
        guard let url = current else { return }
        NotePins.stored = NotePins.toggled(NotePins.stored, url)
        reload()
    }

    /// Locks or unlocks the open note. The text on screen is saved first.
    func toggleLock() {
        guard let url = current else { return }
        flush()
        let unlocking = url.pathExtension == NoteStore.lockedExtension
        let next = unlocking ? store.unlock(url) : store.lock(url)
        guard let next else {
            notice = unlocking ? "This note could not be unlocked. Its key is not in your Keychain, or the Keychain would not give it up." : "This note could not be locked. Kriya could not save a key in your Keychain."
            return
        }
        notice = nil
        loading = true; current = next; text = store.read(next); loading = false
        reload()
    }

    var isLocked: Bool { current?.pathExtension == NoteStore.lockedExtension }

    /// Copies a chosen file next to the note and puts a link to it at the end of the text.
    func attach(_ file: URL) {
        if current == nil { flush() }
        guard let url = current, let link = store.attach(file, to: url) else { return }
        text += (text.hasSuffix("\n") || text.isEmpty ? "" : "\n") + link + "\n"
    }

    var attachments: [URL] { current.map { store.attachments(of: $0) } ?? [] }

    func newNote(from template: NoteTemplate) {
        flush()
        let rendered = template.render(title: "", date: Date(), clipboard: NSPasteboard.general.string(forType: .string) ?? "")
        loading = true; current = nil; text = rendered.text; loading = false
        flush()
    }

    var tagCounts: [(tag: String, notes: Int)] {
        NoteTags.counts(store.list().filter { !$0.locked }.map { store.read($0.url) })
    }

    func open(_ url: URL) {
        notice = nil
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

    /// Brings back an earlier version of the open note. What was there is kept as a version too.
    func restore(_ version: NoteStore.Version) {
        guard let url = current else { return }
        flush()
        if store.restore(version, to: url) {
            loading = true; text = store.read(url); loading = false
        }
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
                TextField("Search notes, or tag:work", text: $model.query).textFieldStyle(.roundedBorder).padding(8)
                let tags = model.tagCounts
                if !tags.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(tags.prefix(12), id: \.tag) { item in
                                Button("#\(item.tag) \(item.notes)") { model.query = "tag:\(item.tag)" }
                                    .buttonStyle(.plain).font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Color.primary.opacity(0.08), in: Capsule())
                            }
                        }.padding(.horizontal, 8)
                    }.padding(.bottom, 4)
                }
                List(model.notes, selection: Binding(get: { model.current }, set: { if let u = $0 { model.open(u) } })) { note in
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            if model.isPinned(note.url) { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary) }
                            if note.locked { Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary) }
                            Text(note.title).lineLimit(1)
                        }
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
                if let notice = model.notice { Text(notice).font(.caption).foregroundStyle(Theme.warn).padding(.horizontal, 10).padding(.top, 6).frame(maxWidth: .infinity, alignment: .leading) }
                HStack(spacing: 14) {
                    Button { model.newNote(); editing = true } label: { Label("New", systemImage: "square.and.pencil") }.keyboardShortcut("n")
                    Menu {
                        ForEach(model.store.templates()) { template in Button(template.name) { model.newNote(from: template); editing = true } }
                        Divider()
                        Button("Save This Note as a Template…") { saveTemplate() }.disabled(model.text.isEmpty)
                    } label: { Label("From Template", systemImage: "doc.badge.plus") }.menuIndicator(.hidden).fixedSize()
                    Button { model.togglePin() } label: { Label(model.current.map(model.isPinned) == true ? "Unpin" : "Pin", systemImage: model.current.map(model.isPinned) == true ? "pin.slash" : "pin") }.disabled(model.current == nil)
                    Button { model.toggleLock() } label: { Label(model.isLocked ? "Unlock" : "Lock", systemImage: model.isLocked ? "lock.open" : "lock") }.disabled(model.current == nil)
                        .help(model.isLocked ? "Turn this note back into a plain Markdown file" : "Encrypt this note with a key kept in your Keychain. Without that key it cannot be read.")
                    Menu {
                        Button("Attach a File…") { attachFile() }.disabled(model.current == nil && model.text.isEmpty)
                        let files = model.attachments
                        if !files.isEmpty { Divider() }
                        ForEach(files, id: \.self) { file in
                            Menu(file.lastPathComponent) {
                                Button("Open") { NSWorkspace.shared.open(file) }
                                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                                Button("Move to Trash", role: .destructive) { model.store.removeAttachment(file) }
                            }
                        }
                    } label: { Label("Attachments", systemImage: "paperclip") }.menuIndicator(.hidden).fixedSize()
                    Button { summarize(model.text) } label: { Label("Summarize", systemImage: "text.append") }.disabled(model.text.count < 40)
                    Menu {
                        Button("Suggest Tags") { NotesAI.suggestTags(model) }
                        Button("Pull Out Tasks") { NotesAI.extractTasks(model) }
                        Button("Tidy Up…") { NotesAI.cleanUp(model) }
                        Divider()
                        Button("Find Related or Duplicate Notes") { NotesAI.related(model) }
                        Button("Turn Into a Workflow Draft") { NotesAI.toWorkflow(model) }
                    } label: { Label("AI", systemImage: "sparkles") }.menuIndicator(.hidden).fixedSize().disabled(!AIGateway.shared.isAvailable(for: .notes) || model.text.count < 20)
                    Menu {
                        let versions = model.current.map { model.store.versions(of: $0) } ?? []
                        if versions.isEmpty { Text("No earlier versions yet") }
                        ForEach(versions.prefix(10)) { version in
                            Button(version.date.formatted(date: .abbreviated, time: .shortened)) { model.restore(version) }
                        }
                    } label: { Label("History", systemImage: "clock.arrow.circlepath") }.menuIndicator(.hidden).fixedSize().disabled(model.current == nil)
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

    private func attachFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { model.attach(url) }
    }

    private func saveTemplate() {
        let alert = NSAlert()
        alert.messageText = "Name this template"
        alert.informativeText = "The text is saved as it is now. {title}, {date}, {time}, {weekday}, {clipboard} and {cursor} are filled in when you use it."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn, !field.stringValue.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        model.store.saveTemplate(named: field.stringValue, body: model.text)
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
