import AppKit
import SwiftUI

/// The sidebar sections. The order here is the order on screen.
enum SettingsPaneGroup: CaseIterable, Identifiable {
    case overview, input, windows, filesAndText, automate, system

    var id: Self { self }

    var title: String {
        switch self {
        case .overview: return ""
        case .input: return "Input"
        case .windows: return "Windows"
        case .filesAndText: return "Files & Text"
        case .automate: return "Automate"
        case .system: return "System"
        }
    }
}

/// Declared in sidebar order, so "next pane" and the Cmd-number shortcuts follow what the person sees.
enum SettingsPane: String, CaseIterable, Identifiable {
    case features, mouse, pointer, keyboard, devices, windows, workspaces, buttons, displays, finder, clipboard, selection, links, shelf, apps, automation, actions, profiles
    case power, general, permissions, backup, diagnostics, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .features: return "Overview"
        case .general: return "General"
        case .displays: return "Displays & Corners"
        case .shelf: return "File Shelf"
        case .apps: return "Apps"
        case .power: return "Sleep & Power"
        case .permissions: return "Permissions"
        case .mouse: return "Mouse & Trackpad"
        case .pointer: return "Pointer Effects"
        case .windows: return "Windows"
        case .workspaces: return "Workspaces"
        case .buttons: return "Window Buttons"
        case .finder: return "Finder Actions"
        case .clipboard: return "Clipboard"
        case .selection: return "Selection Bar"
        case .links: return "Link Routing"
        case .keyboard: return "Keyboard"
        case .automation: return "Automation"
        case .devices: return "Devices"
        case .profiles: return "App Profiles"
        case .actions: return "Actions"
        case .backup: return "Backup & Restore"
        case .diagnostics: return "Diagnostics"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .features: return "square.grid.2x2"
        case .general: return "gearshape"
        case .displays: return "display"
        case .shelf: return "tray"
        case .apps: return "square.grid.3x3.square"
        case .power: return "bolt.circle"
        case .permissions: return "lock.shield"
        case .mouse: return "computermouse.fill"
        case .pointer: return "cursorarrow.rays"
        case .windows: return "rectangle.split.2x2"
        case .workspaces: return "square.stack.3d.up"
        case .buttons: return "macwindow"
        case .finder: return "contextualmenu.and.cursorarrow"
        case .clipboard: return "doc.on.clipboard"
        case .selection: return "text.cursor"
        case .links: return "arrow.triangle.branch"
        case .keyboard: return "keyboard"
        case .automation: return "gearshape.2"
        case .devices: return "computermouse"
        case .profiles: return "square.stack"
        case .actions: return "bolt"
        case .backup: return "externaldrive"
        case .diagnostics: return "stethoscope"
        case .about: return "info.circle"
        }
    }

    var group: SettingsPaneGroup {
        switch self {
        case .features: return .overview
        case .mouse, .pointer, .keyboard, .devices: return .input
        case .windows, .workspaces, .buttons: return .windows
        case .finder, .clipboard, .selection, .links: return .filesAndText
        case .automation, .actions, .profiles: return .automate
        case .displays: return .windows
        case .shelf, .apps: return .filesAndText
        case .power, .general, .permissions, .backup, .diagnostics, .about: return .system
        }
    }

    /// The feature this pane configures, so the sidebar can show whether it is running.
    var feature: FeatureId? {
        switch self {
        case .mouse: return .mouse
        case .windows: return .windowManagement
        case .buttons: return .trafficLights
        case .finder: return .contextMenu
        case .clipboard: return .clipboard
        case .selection: return .selectionBar
        case .keyboard: return .keyboard
        case .automation: return .automation
        default: return nil
        }
    }

    /// Words other than the title that should find this pane in the sidebar search.
    private var keywords: String {
        switch self {
        case .features: return "home features turn on off setup guide"
        case .mouse: return "scroll speed acceleration trackpad gestures buttons natural reverse"
        case .keyboard: return "shortcuts hotkeys text expansion snippets launcher palette"
        case .devices: return "wired wireless bluetooth usb"
        case .pointer: return "cursor highlight halo click ring locate find magnifier zoom hide idle presentation screen sharing position"
        case .windows: return "snap tile resize move layout screen edge display half quarter maximize grid todo stash radial cascade ultrawide hot corners drop zones margin grow shrink"
        case .buttons: return "traffic lights close minimize zoom red yellow green"
        case .workspaces: return "workspace focus mode quit all hide apps relaunch favorite previous app launch set of apps"
        case .finder: return "right click context menu new file folder convert rename terminal"
        case .clipboard: return "copy paste history snippets"
        case .selection: return "popclip text toolbar bar highlight"
        case .links: return "browser link url default velja openin route profile work personal tracking redirect"
        case .automation: return "workflow trigger script schedule"
        case .actions: return "commands library"
        case .profiles: return "per app rules"
        case .displays: return "resolution refresh rate hidpi scaling dim brightness profile arrangement hot corners corner"
        case .shelf: return "drag drop files temporary tray dropover stage hold"
        case .apps: return "uninstall remove leftovers cleaner orphan update installed applications trash"
        case .power: return "sleep wake awake caffeinate keep awake prevent display lid battery"
        case .general: return "appearance dark light dock menu bar login startup updates"
        case .permissions: return "accessibility input monitoring screen recording privacy"
        case .backup: return "export import restore"
        case .diagnostics: return "log crash safe mode problem"
        case .about: return "version"
        }
    }

    func matches(_ query: String) -> Bool {
        let words = query.lowercased().split(separator: " ")
        guard !words.isEmpty else { return true }
        let haystack = title.lowercased() + " " + keywords
        return words.allSatisfy { haystack.contains($0) }
    }
}

extension FeatureId {
    /// The settings pane for this feature.
    var pane: SettingsPane {
        switch self {
        case .mouse: return .mouse
        case .windowManagement: return .windows
        case .trafficLights: return .buttons
        case .contextMenu: return .finder
        case .selectionBar: return .selection
        case .clipboard: return .clipboard
        case .keyboard: return .keyboard
        case .automation: return .automation
        }
    }
}

/// Which pane the settings window shows. Shared so the menu bar can open the window on a particular pane.
final class SettingsNavigator: ObservableObject {
    @Published var pane: SettingsPane = .features
    /// Opens the guided setup. Set by the app delegate.
    var openSetupGuide: () -> Void = {}
}

struct SettingsRootView: View {
    @EnvironmentObject private var navigator: SettingsNavigator
    @EnvironmentObject private var shelf: FileShelf
    @State private var query = ""
    /// How wide the window is, so text and controls can grow when it does (full screen).
    @State private var windowWidth: CGFloat = 900

    /// Larger controls and text in a wide window. Only the environment changes; the layout is left to the window.
    private var scale: (control: ControlSize, font: Font?) {
        switch windowWidth {
        case ..<1300: return (.regular, nil)
        case ..<1800: return (.large, .system(size: 15))
        default: return (.extraLarge, .system(size: 17))
        }
    }

    private var selection: Binding<SettingsPane?> {
        Binding(
            get: { navigator.pane },
            set: { if let pane = $0 { navigator.pane = pane } }
        )
    }

    private var results: [SettingsPane] { SettingsPane.allCases.filter { $0.matches(query) } }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 215, max: 250)
        } detail: {
            VStack(spacing: 0) {
                StatusBanners()
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                paneContent
            }
            .navigationTitle(navigator.pane.title)
        }
        .frame(minWidth: 800, minHeight: 540)
        .scrollIndicators(.hidden)
        .environment(\.controlSize, scale.control)
        .font(scale.font)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { windowWidth = $0 }
    }

    private var sidebar: some View {
        List(selection: selection) {
            if query.isEmpty {
                ForEach(SettingsPaneGroup.allCases) { group in
                    Section {
                        ForEach(SettingsPane.allCases.filter { $0.group == group }) { pane in
                            SidebarRow(pane: pane).tag(pane)
                        }
                    } header: {
                        if !group.title.isEmpty { Text(group.title) }
                    }
                }
            } else if results.isEmpty {
                Text("No settings match “\(query)”")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(results) { pane in SidebarRow(pane: pane).tag(pane) }
            }
        }
        .tint(Theme.accent)
        .searchable(text: $query, placement: .sidebar, prompt: "Search")
        .animation(.smooth(duration: 0.2), value: query)
    }

    @ViewBuilder
    private var paneContent: some View {
        switch navigator.pane {
        case .general: GeneralPane()
        case .power: PowerPane()
        case .displays: DisplaysPane()
        case .shelf: ShelfPane(shelf: shelf)
        case .apps: AppsPane()
        case .features: FeaturesPane()
        case .permissions: PermissionsPane()
        case .mouse: MousePane()
        case .pointer: PointerPane()
        case .windows: WindowsPane()
        case .buttons: TrafficPane()
        case .workspaces: WorkspacesPane()
        case .finder: FinderPane()
        case .clipboard: ClipboardPane()
        case .selection: SelectionPane()
        case .links: LinksPane()
        case .keyboard: KeyboardPane()
        case .automation: AutomationPane()
        case .devices: DevicesPane()
        case .profiles: ProfilesPane()
        case .actions: ActionsPane()
        case .backup: BackupPane()
        case .diagnostics: DiagnosticsPane()
        case .about: AboutPane()
        }
    }
}

/// A sidebar entry. A feature that is working shows nothing; one that needs attention gets a dot. The list is the
/// system's own, so selection, keyboard use and scrolling behave as in any Mac app.
private struct SidebarRow: View {
    let pane: SettingsPane
    @EnvironmentObject private var services: ServiceManager
    @EnvironmentObject private var navigator: SettingsNavigator

    var body: some View {
        let color = pane.feature.flatMap { dotColor(services.state($0)) }
        let selected = navigator.pane == pane
        HStack {
            Label {
                Text(pane.title)
            } icon: {
                // A fixed box so every icon lines up, muted blue at rest and white on the selected row.
                Image(systemName: pane.symbol)
                    .symbolRenderingMode(.monochrome)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 20, height: 20)
                    .foregroundStyle(selected ? Color.white : Theme.accent)
                    .animation(.smooth(duration: 0.15), value: selected)
            }
            Spacer(minLength: 4)
            if let color { StatusDot(color: color).transition(.opacity) }
        }
        .animation(.smooth(duration: 0.25), value: color)
    }

    private func dotColor(_ state: FeatureState) -> Color? {
        switch state {
        case .off, .running: return nil
        case .safeMode, .needsPermission: return Theme.warn
        case .failed: return Theme.danger
        }
    }
}

/// Owns the settings window. While it is open the app gets a Dock icon so the window can be found with Cmd-Tab.
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let env: AppEnvironment
    private(set) var window: NSWindow?

    init(env: AppEnvironment) {
        self.env = env
    }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        env.config.applyActivationPolicy(forWindowOpen: true)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Kriya"
        window.isReleasedWhenClosed = false
        window.animationBehavior = .documentWindow
        window.contentViewController = NSHostingController(rootView: SettingsRootView().injecting(env))
        // A new name, so a window saved at the old, shorter size does not keep hiding the end of the sidebar.
        window.setFrameAutosaveName("KriyaSettingsWindow2")
        if !window.setFrameUsingName("KriyaSettingsWindow2") { window.center() }
        window.delegate = self
        return window
    }

    func windowWillClose(_ notification: Notification) {
        env.config.applyActivationPolicy()
    }
}
