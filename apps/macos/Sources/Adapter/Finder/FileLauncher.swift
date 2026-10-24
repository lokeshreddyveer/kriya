import AppKit
import SwiftUI

/// What is selected in Finder right now.
struct FinderSelection: Equatable {
    var paths: [String]
    /// The folder of the front Finder window, for acting when nothing is selected.
    var folder: String?
}

enum FinderSelectionReader {
    /// Asks Finder. macOS asks the person once to let Kriya control Finder.
    static func read() throws -> FinderSelection {
        let script = """
        tell application "Finder"
          set out to ""
          try
            set out to POSIX path of (target of front Finder window as alias)
          end try
          repeat with f in (selection as alias list)
            set out to out & linefeed & POSIX path of f
          end repeat
          return out
        end tell
        """
        let output = try ToolRunner.run("/usr/bin/osascript", ["-e", script], timeout: 4)
        let lines = output.components(separatedBy: "\n")
        let folder = lines.first.flatMap { $0.isEmpty ? nil : $0 }
        let paths = lines.dropFirst().filter { !$0.isEmpty }.map { $0.count > 1 && $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
        return FinderSelection(paths: paths, folder: folder)
    }
}

struct LauncherRow: Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let symbol: String
    let itemID: String
    let child: String?
}

final class LauncherModel: ObservableObject {
    @Published var query = "" { didSet { rank() } }
    @Published private(set) var results: [LauncherRow] = []
    @Published var selected = 0
    @Published var headline = ""

    private var all: [LauncherRow] = []
    private let usage: UserDefaults

    init(usage: UserDefaults = .standard) { self.usage = usage }

    func load(_ rows: [LauncherRow], headline: String) {
        all = rows
        self.headline = headline
        query = ""
        rank()
    }

    private func rank() {
        let items = all.map { SwitcherItem(id: $0.id, appName: "", title: $0.title, lastUsed: Int64(usage.integer(forKey: "launcherUse.\($0.id)"))) }
        let order = windowRankSwitcher(items: items, query: query)
        let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        results = order.compactMap { byID[$0] }
        selected = 0
    }

    func remember(_ row: LauncherRow) {
        usage.set(Int(Date().timeIntervalSince1970), forKey: "launcherUse.\(row.id)")
    }

    func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        selected = (selected + delta + results.count) % results.count
    }

    var current: LauncherRow? { results.indices.contains(selected) ? results[selected] : nil }
}

/// A search box over every file action that applies to what is selected in Finder. Reached by a shortcut or from the
/// Services menu. Actions limited to certain apps show only while one of those apps is in front.
final class FileLauncher: NSObject, NSWindowDelegate {
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    private let store: FinderStore
    private let runner: FileActionRunner
    private let model = LauncherModel()
    private var panel: Panel?
    private var context: (selection: FinderSelection, front: String?) = (FinderSelection(paths: [], folder: nil), nil)

    var onProblem: (String) -> Void = { _ in }

    init(store: FinderStore, runner: FileActionRunner) {
        self.store = store
        self.runner = runner
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    /// Reads Finder's selection, then opens the launcher. With `selection` given (from Services), Finder is not asked.
    func show(selection: FinderSelection? = nil) {
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if let selection {
            present(selection, front: front)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let read = try FinderSelectionReader.read()
                DispatchQueue.main.async { self?.present(read, front: front) }
            } catch {
                DispatchQueue.main.async {
                    self?.onProblem("Kriya could not read Finder's selection. Allow Kriya to control Finder in System Settings › Privacy & Security › Automation.")
                }
            }
        }
    }

    func close() { panel?.orderOut(nil) }

    private func present(_ selection: FinderSelection, front: String?) {
        context = (selection, front)
        let facts = FinderMenuFile.Selection(
            count: selection.paths.isEmpty ? 1 : selection.paths.count,
            folders: selection.paths.isEmpty ? 1 : selection.paths.filter(isDirectory).count,
            extensions: selection.paths.map { isDirectory($0) ? "" : (($0 as NSString).pathExtension).lowercased() },
            isBackground: selection.paths.isEmpty
        )
        if selection.paths.isEmpty && selection.folder == nil {
            onProblem("Nothing is selected in Finder.")
            return
        }
        let menu = store.menuFileContents(forceActive: true)
        var rows: [LauncherRow] = []
        for item in store.items where item.enabled {
            if !item.appIds.isEmpty, let front, !item.appIds.contains(front) { continue }
            guard let visible = menu.items.first(where: { $0.id == item.id }), menu.visibleItems(for: facts).contains(visible) else { continue }
            if let children = menu.children(of: visible, for: facts) {
                for child in children {
                    rows.append(LauncherRow(id: "\(item.id)/\(child.id)", title: "\(item.title) › \(child.title)", subtitle: nil, symbol: item.kind.symbol, itemID: item.id, child: child.id))
                }
            } else {
                rows.append(LauncherRow(id: item.id, title: item.title, subtitle: item.kind.summary, symbol: item.kind.symbol, itemID: item.id, child: nil))
            }
        }
        let headline = selection.paths.isEmpty ? (selection.folder.map { ($0 as NSString).lastPathComponent } ?? "") : (selection.paths.count == 1 ? (selection.paths[0] as NSString).lastPathComponent : "\(selection.paths.count) items")
        model.load(rows, headline: headline)

        let panel = self.panel ?? makePanel()
        self.panel = panel
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.midY + frame.height * 0.12))
        }
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; panel.animator().alphaValue = 1 }
    }

    private func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    private func choose(_ row: LauncherRow) {
        model.remember(row)
        close()
        guard let item = store.item(row.itemID) else { return }
        let selection = context.selection
        runner.run(item, paths: selection.paths, target: selection.paths.isEmpty ? selection.folder : nil, child: row.child)
    }

    private func makePanel() -> Panel {
        let panel = Panel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 420), styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.applyPopupPrivacy()
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: LauncherView(model: model, onChoose: { [weak self] in self?.choose($0) }, onClose: { [weak self] in self?.close() }))
        return panel
    }

    func windowDidResignKey(_ notification: Notification) { close() }
}

private struct LauncherView: View {
    @ObservedObject var model: LauncherModel
    let onChoose: (LauncherRow) -> Void
    let onClose: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "bolt.fill").foregroundStyle(Theme.accent)
                TextField("Action for \(model.headline)", text: $model.query)
                    .textFieldStyle(.plain).font(.title3).focused($focused)
                    .onSubmit { if let current = model.current { onChoose(current) } }
            }
            .padding(14)
            Divider()
            ScrollViewReader { proxy in
                List(Array(model.results.enumerated()), id: \.element.id) { index, row in
                    HStack(spacing: 12) {
                        Image(systemName: row.symbol).frame(width: 22).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.title).lineLimit(1)
                            if let subtitle = row.subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                        }
                        Spacer()
                    }
                    .padding(.vertical, 2)
                    .id(row.id)
                    .listRowSeparator(.hidden)
                    .listRowBackground(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(index == model.selected ? Theme.accent.opacity(0.25) : .clear).padding(.horizontal, 6))
                    .contentShape(Rectangle())
                    .onTapGesture { onChoose(row) }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .onChange(of: model.selected) { _, new in
                    if model.results.indices.contains(new) { withAnimation(.smooth(duration: 0.15)) { proxy.scrollTo(model.results[new].id) } }
                }
                .overlay { if model.results.isEmpty { Text("No matching actions").foregroundStyle(.secondary) } }
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator))
        .onAppear { focused = true }
        .onKeyPress(.downArrow) { model.move(1); return .handled }
        .onKeyPress(.upArrow) { model.move(-1); return .handled }
        .onKeyPress(.escape) { onClose(); return .handled }
    }
}
