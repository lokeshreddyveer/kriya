import AppKit
import SwiftUI

/// A small panel beside the screen's edge that shows what is selected in Finder, and keeps a short list of files to drag from. It is
/// Kriya's own window, not part of Finder: it asks Finder for its selection while it is open (macOS asks once to allow that), and
/// keeps file paths only.
final class FinderDrawer: ObservableObject {
    static let shared = FinderDrawer()

    @Published private(set) var selection: [String] = []
    @Published private(set) var folder: String?
    @Published var kept = FinderDrawerList()
    @Published private(set) var problem: String?

    private var panel: NSPanel?
    private var closeObserver: NSObjectProtocol?
    private var timer: Timer?
    private let queue = DispatchQueue(label: "app.kriya.finder-drawer", qos: .utility)
    private var reading = false

    func toggle() {
        if panel?.isVisible == true { hide() } else { show() }
    }

    func show() {
        FeatureActivity.shared.used("finderDrawer")
        let panel = self.panel ?? makePanel()
        self.panel = panel
        place(panel)
        panel.orderFrontRegardless()
        poll()
        timer?.invalidate()
        let t = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func hide() {
        timer?.invalidate(); timer = nil
        panel?.orderOut(nil)
    }

    private func poll() {
        guard !reading, NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == "com.apple.finder" }) else { return }
        // Only look while Finder is in front, so using another app does not empty the list.
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder" || selection.isEmpty else { return }
        reading = true
        queue.async { [weak self] in
            let result = Result { try FinderSelectionReader.read() }
            DispatchQueue.main.async {
                guard let self else { return }
                self.reading = false
                switch result {
                case .success(let read):
                    self.problem = nil
                    if self.selection != read.paths { self.selection = read.paths }
                    self.folder = read.folder
                case .failure:
                    self.problem = "Kriya could not ask Finder for its selection. Allow it in System Settings › Privacy & Security › Automation."
                }
            }
        }
    }

    func keepSelection() { kept.add(selection) }

    private func place(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let size = panel.frame.size
        let frame = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: frame.maxX - size.width - 8, y: frame.midY - size.height / 2))
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 420), styleMask: [.nonactivatingPanel, .titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        panel.title = "Finder Drawer"
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.applyPopupPrivacy()
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: FinderDrawerView(drawer: self))
        // The window's own close button must stop the polling too, or Finder keeps being asked while nothing is shown.
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: panel, queue: .main) { [weak self] _ in
            self?.timer?.invalidate(); self?.timer = nil
        }
        return panel
    }
}

private struct FinderDrawerView: View {
    @ObservedObject var drawer: FinderDrawer

    var body: some View {
        VStack(spacing: 0) {
            if let problem = drawer.problem { Text(problem).font(.caption).foregroundStyle(Theme.warn).padding(8) }
            section("Selected in Finder", trailing: {
                Button("Keep") { drawer.keepSelection() }.controlSize(.small).disabled(drawer.selection.isEmpty)
            }) {
                if drawer.selection.isEmpty { empty(drawer.folder == nil ? "Nothing is selected." : "Nothing is selected in \((drawer.folder! as NSString).lastPathComponent).") }
                else { ForEach(drawer.selection, id: \.self) { row($0) } }
            }
            Divider()
            section("Kept", trailing: {
                Button("Clear") { drawer.kept.clear() }.controlSize(.small).disabled(drawer.kept.paths.isEmpty)
            }) {
                if drawer.kept.paths.isEmpty { empty("Press Keep to hold files here, drag them to reorder, then drag them out into any app.") }
                else {
                    List {
                        ForEach(drawer.kept.paths, id: \.self) { path in
                            row(path, removable: true)
                        }
                        .onMove { drawer.kept.move(from: $0, to: $1) }
                    }
                    .listStyle(.plain)
                }
            }
        }
        .frame(minWidth: 260, minHeight: 300)
        .onAppear { drawer.kept.prune() }
    }

    private func section<T: View, C: View>(_ title: String, @ViewBuilder trailing: () -> T, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack { Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary); Spacer(); trailing() }
                .padding(.horizontal, 10).padding(.top, 8)
            ScrollView { VStack(alignment: .leading, spacing: 2) { content() }.padding(.horizontal, 6) }.frame(maxHeight: .infinity)
        }
    }

    private func empty(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary).padding(8)
    }

    private func row(_ path: String, removable: Bool = false) -> some View {
        let url = URL(fileURLWithPath: path)
        return HStack(spacing: 6) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 20, height: 20)
            Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
            Spacer()
            Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Image(systemName: "magnifyingglass") }.buttonStyle(.borderless).help("Show in Finder").accessibilityLabel("Show \(url.lastPathComponent) in Finder")
            if removable { Button { drawer.kept.remove(path) } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).help("Remove from the drawer").accessibilityLabel("Remove \(url.lastPathComponent) from the drawer") }
        }
        .padding(.vertical, 2).padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
        .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Double-click to open. Drag to move or copy it.")
    }
}
