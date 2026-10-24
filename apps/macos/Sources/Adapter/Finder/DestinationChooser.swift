import AppKit
import SwiftUI

/// Asks where to move or copy items to: starred folders and recent ones first, a search, and "Choose Another Folder…"
/// for anywhere else. Return picks the highlighted folder, ⌘1 to ⌘9 pick one by number, Escape cancels.
final class DestinationChooser {
    private let destinations: FolderDestinations

    init(destinations: FolderDestinations) { self.destinations = destinations }

    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    /// Runs on the main thread and returns the folder chosen, or nil when the person cancelled.
    func choose(count: Int, move: Bool) -> URL? {
        var chosen: URL?
        let panel = Panel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 420), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.applyPopupPrivacy()
        panel.hidesOnDeactivate = false
        let finish: (URL?) -> Void = { url in
            chosen = url
            NSApp.stopModal()
            panel.orderOut(nil)
        }
        panel.contentView = NSHostingView(rootView: DestinationChooserView(
            destinations: destinations, count: count, move: move,
            onPick: { finish(URL(fileURLWithPath: $0, isDirectory: true)) },
            onBrowse: { [weak panel] in
                if let url = Self.browse(move: move, over: panel) { finish(url) }
            },
            onCancel: { finish(nil) }
        ))
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        NSApp.runModal(for: panel)
        panel.orderOut(nil)
        return chosen
    }

    private static func browse(move: Bool, over panel: NSWindow?) -> URL? {
        let open = NSOpenPanel()
        open.canChooseFiles = false
        open.canChooseDirectories = true
        open.canCreateDirectories = true
        open.allowsMultipleSelection = false
        open.prompt = move ? "Move Here" : "Copy Here"
        open.message = move ? "Choose where to move the items." : "Choose where to copy the items."
        return open.runModal() == .OK ? open.url : nil
    }
}

private struct DestinationChooserView: View {
    @ObservedObject var destinations: FolderDestinations
    let count: Int
    let move: Bool
    let onPick: (String) -> Void
    let onBrowse: () -> Void
    let onCancel: () -> Void

    @State private var query = ""
    @State private var selected: String?
    @FocusState private var searching: Bool

    private var choices: [DestinationChoice] { destinations.choices(matching: query) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(move ? "Move" : "Copy") \(count) item\(count == 1 ? "" : "s") to…").font(.headline)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search folders", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searching)
                    .onSubmit { pickSelected() }
                    .onKeyPress(.downArrow) { step(1); return .handled }
                    .onKeyPress(.upArrow) { step(-1); return .handled }
                    .onKeyPress(.escape) { onCancel(); return .handled }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            if choices.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "folder.badge.questionmark").font(.title2).foregroundStyle(.tertiary)
                    Text(query.isEmpty ? "Folders you move or copy to will be listed here. Star one to keep it at the top." : "No folder matches.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(choices.enumerated()), id: \.element.id) { index, choice in
                                row(choice, number: index < 9 ? index + 1 : nil).id(choice.id)
                            }
                        }
                    }
                    .onChange(of: selected) { _, id in if let id { withAnimation(.smooth(duration: 0.15)) { proxy.scrollTo(id) } } }
                }
            }

            HStack {
                Button("Choose Another Folder…") { onBrowse() }
                Spacer()
                Button("Cancel") { onCancel() }.keyboardShortcut(.cancelAction)
            }
            // ⌘1 to ⌘9, with nothing visible of their own.
            ZStack {
                ForEach(0..<9, id: \.self) { index in
                    Button("") { pick(index) }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                        .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
                }
            }
            .frame(width: 0, height: 0)
        }
        .padding(16)
        .frame(width: 440, height: 420)
        .onAppear { searching = true; selected = choices.first?.id }
        .onChange(of: query) { _, _ in selected = choices.first?.id }
        .animation(.smooth(duration: 0.2), value: choices)
    }

    private func row(_ choice: DestinationChoice, number: Int?) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.fill").foregroundStyle(Theme.accent).frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(choice.name).lineLimit(1)
                Text(choice.shortPath).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }
            Spacer()
            if let number { Text("⌘\(number)").font(.caption).foregroundStyle(.tertiary) }
            Button { destinations.toggleFavorite(choice.path) } label: {
                Image(systemName: choice.isFavorite ? "star.fill" : "star").foregroundStyle(choice.isFavorite ? Theme.warn : Color.secondary)
            }
            .buttonStyle(.borderless).help(choice.isFavorite ? "Remove from favorites" : "Keep at the top")
            .accessibilityLabel(choice.isFavorite ? "Remove \(choice.name) from favorites" : "Keep \(choice.name) at the top")
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(selected == choice.id ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { onPick(choice.path) }
        .contextMenu {
            Button(choice.isFavorite ? "Remove from Favorites" : "Add to Favorites") { destinations.toggleFavorite(choice.path) }
            if !choice.isFavorite { Button("Remove from Recents") { destinations.forget(choice.path) } }
        }
    }

    private func step(_ delta: Int) {
        let list = choices
        guard !list.isEmpty else { return }
        let current = list.firstIndex { $0.id == selected } ?? (delta > 0 ? -1 : list.count)
        selected = list[min(max(current + delta, 0), list.count - 1)].id
    }

    private func pickSelected() {
        if let selected, choices.contains(where: { $0.id == selected }) { onPick(selected) }
    }

    private func pick(_ index: Int) {
        let list = choices
        if index < list.count { onPick(list[index].path) }
    }
}
