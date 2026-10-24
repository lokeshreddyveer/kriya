import SwiftUI

/// What the menu-bar icon opens: a search box, one-tap actions, window places, switches for every feature and a pause
/// button. What it shows, and how it looks, is chosen in Settings › Menu Bar Window.
struct PopoverView: View {
    @EnvironmentObject private var config: ConfigStore
    @EnvironmentObject private var crashGuard: CrashGuard
    @EnvironmentObject private var services: ServiceManager
    @EnvironmentObject private var remap: RemapStore
    @EnvironmentObject private var screen: ScreenToolsStore
    @EnvironmentObject private var prefs: PopoverPrefs
    @EnvironmentObject private var library: ActionLibrary
    @EnvironmentObject private var commands: QuickCommands
    @EnvironmentObject private var windowController: WindowController
    @ObservedObject private var pause = FeaturePause.shared
    @State private var contentHeight: CGFloat = 480
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    let openSettings: (SettingsPane?) -> Void
    var close: () -> Void = {}

    private var tint: Color { PopoverCatalog.tint(prefs.tint) }

    private var attentionCount: Int {
        FeatureId.all.filter { if case .needsPermission = services.state($0) { return true } else { return false } }.count
    }

    private var runningCount: Int { FeatureId.all.filter { services.state($0) == .running }.count }

    private var summary: (text: String, color: Color?) {
        if crashGuard.isSafeMode { return ("Safe mode", Theme.warn) }
        if attentionCount > 0 { return (attentionCount == 1 ? "1 needs permission" : "\(attentionCount) need permission", Theme.warn) }
        switch runningCount {
        case 0: return ("Nothing running", nil)
        case FeatureId.all.count: return ("All running", nil)
        default: return ("\(runningCount) running", nil)
        }
    }

    /// Turns every feature off at once and brings back exactly the ones that were on.
    private func togglePause() {
        withAnimation(.smooth) {
            if pause.isPaused {
                for key in pause.features { if let f = FeatureId.all.first(where: { $0.key == key }) { services.setFeature(f, enabled: true) } }
                if pause.remapWasOn { remap.update { $0.enabled = true } }
                if pause.cornersWereOn { screen.update { $0.hotCornersEnabled = true } }
                pause.clear()
            } else {
                let on = FeatureId.all.filter { config.isEnabled($0) }
                pause.remember(features: on.map(\.key), remap: remap.config.enabled, corners: screen.config.hotCornersEnabled)
                for f in on { services.setFeature(f, enabled: false) }
                if remap.config.enabled { remap.update { $0.enabled = false } }
                if screen.config.hotCornersEnabled { screen.update { $0.hotCornersEnabled = false } }
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if prefs.showSearch { searchField }
            Divider()
            Group {
                if query.trimmingCharacters(in: .whitespaces).isEmpty { sections } else { results }
            }
            Divider()
            footer
        }
        .frame(width: 380)
        .tint(tint)
        .environment(\.popoverTint, tint)
        .preferredColorScheme(prefs.colorScheme)
        .animation(.smooth(duration: 0.2), value: prefs.sectionOrder)
        .animation(.smooth(duration: 0.2), value: prefs.hiddenSections)
    }

    // MARK: Parts

    private var header: some View {
        HStack(spacing: 10) {
            // The app's mark, then its name over one line that says how things are.
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(LinearGradient(colors: [tint, tint.opacity(0.65)], startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "bolt.fill").font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
            }
            .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("Kriya").font(.system(size: 14, weight: .semibold))
                HStack(spacing: 5) {
                    if let color = pause.isPaused ? Theme.warn : summary.color { StatusDot(color: color) }
                    Text(pause.isPaused ? "Paused" : summary.text).font(.system(size: 11.5))
                        .foregroundStyle(pause.isPaused || summary.color != nil ? Theme.warn : Color.secondary)
                }
                .smoothly(summary.text + (pause.isPaused ? "p" : ""))
            }
            Spacer()
            headerButton(pause.isPaused ? "play.fill" : "pause.fill", help: pause.isPaused ? "Resume everything" : "Pause every feature") { togglePause() }
            headerButton("slider.horizontal.3", help: "Customize this window") { openSettings(.menuBar) }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12).padding(.bottom, 10)
    }

    private func headerButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 26, height: 22)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search apps, actions, settings and more", text: $query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onSubmit { hits.first?.run() }
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }.buttonStyle(.plain).accessibilityLabel("Clear the search")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
        .padding(.horizontal, 12).padding(.bottom, 10)
    }

    private var sections: some View {
        ScrollView {
            VStack(spacing: prefs.compact ? 10 : 14) {
                StatusBanners()
                ForEach(prefs.sectionOrder, id: \.self) { id in
                    if !prefs.hiddenSections.contains(id) { section(id) }
                }
            }
            .padding(prefs.compact ? 10 : 12)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .scrollIndicators(.hidden)
        // A scroll view has no height of its own, so it is given its content's height, up to the chosen limit.
        .frame(height: min(contentHeight, CGFloat(prefs.maxHeight)))
    }

    @ViewBuilder
    private func section(_ id: String) -> some View {
        switch id {
        case "quick": QuickActions(close: close)
        case "window": if services.state(.windowManagement) == .running { WindowGrid() }
        case "features": FeaturesSection(openSettings: openSettings)
        case "more": ExtrasSection()
        default: EmptyView()
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            footerButton("gearshape", "Settings") { openSettings(nil) }.keyboardShortcut(",")
            footerButton("square.grid.2x2", "Overview") { openSettings(.features) }
            Spacer()
            Text("v\(SystemInfo.appVersion)").font(.caption2).foregroundStyle(.tertiary)
            footerButton("power", "Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
    }

    private func footerButton(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 11, weight: .medium))
                Text(title).font(.system(size: 12))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(TileStyle())
    }

    // MARK: Search

    private struct Hit: Identifiable {
        let id: String
        let symbol: String
        let title: String
        let detail: String
        let run: () -> Void
    }

    private var hits: [Hit] {
        let text = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !text.isEmpty else { return [] }
        var list: [Hit] = []
        // The quick-action tiles keep their own behaviour (some close this window), so they are matched here.
        for tile in PopoverCatalog.tiles where tile.title.lowercased().contains(text) {
            list.append(Hit(id: "tile-\(tile.id)", symbol: tile.symbol, title: tile.title, detail: "Action") {
                commands.run(tile.command)
                if tile.closes { close() }
            })
        }
        // Everything else comes from the same search as the launcher: apps, settings, saved actions, window layouts, a
        // calculator and more, ranked by how well they match and how often you use them.
        for entry in commands.search(text) where !list.contains(where: { $0.title == entry.title }) {
            list.append(Hit(id: "found-\(entry.id)", symbol: entry.symbol, title: entry.title, detail: entry.category.label) {
                commands.choose(entry)
                close()
            })
        }
        return Array(list.prefix(9))
    }

    private var results: some View {
        let found = hits
        return VStack(spacing: 2) {
            if found.isEmpty {
                Text("Nothing matches “\(query)”").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 90)
            }
            ForEach(Array(found.enumerated()), id: \.element.id) { index, hit in
                Button { hit.run() } label: {
                    HStack(spacing: 10) {
                        Image(systemName: hit.symbol).frame(width: 22).foregroundStyle(tint)
                        Text(hit.title)
                        Spacer(minLength: 4)
                        Text(hit.detail).font(.caption).foregroundStyle(.tertiary)
                        if index == 0 { Image(systemName: "return").font(.caption2).foregroundStyle(.tertiary) }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(index == 0 ? tint.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(TileStyle())
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .top)
    }
}

/// A titled group, drawn as a soft card.
private struct PopoverSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
            content
                .padding(6)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        }
    }
}

/// What the pause switch remembers, so resuming brings back exactly what was on.
final class FeaturePause: ObservableObject {
    static let shared = FeaturePause()
    /// Kept on disk, so quitting Kriya while paused does not lose which features to bring back.
    static let key = "featurePause.v1"
    @Published private(set) var features: [String] = []
    @Published private(set) var remapWasOn = false
    @Published private(set) var cornersWereOn = false
    @Published private(set) var isPaused = false

    private struct Saved: Codable { var features: [String]; var remap: Bool; var corners: Bool }

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            features = saved.features
            remapWasOn = saved.remap
            cornersWereOn = saved.corners
            isPaused = true
        }
    }

    func remember(features: [String], remap: Bool, corners: Bool) {
        self.features = features
        remapWasOn = remap
        cornersWereOn = corners
        isPaused = true
        if let data = try? JSONEncoder().encode(Saved(features: features, remap: remap, corners: corners)) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    func clear() {
        features = []
        remapWasOn = false
        cornersWereOn = false
        isPaused = false
        UserDefaults.standard.removeObject(forKey: Self.key)
    }
}

/// Lets the menu-bar window run any command by name, and search everything the launcher can find.
final class QuickCommands: ObservableObject {
    let run: (String) -> Void
    var search: (String) -> [PaletteEntry] = { _ in [] }
    var choose: (PaletteEntry) -> Void = { $0.run() }
    init(run: @escaping (String) -> Void) { self.run = run }
}

/// One-tap actions: tiles that run a command, and show whether it is on when it is a switch.
private struct QuickActions: View {
    @EnvironmentObject private var commands: QuickCommands
    @EnvironmentObject private var awake: KeepAwake
    @EnvironmentObject private var stack: PasteStack
    @EnvironmentObject private var prefs: PopoverPrefs
    @Environment(\.popoverTint) private var tint
    let close: () -> Void

    private func isOn(_ tile: PopoverTile) -> Bool {
        switch tile.id {
        case "awake": return awake.isOn
        case "stack": return stack.active
        default: return false
        }
    }

    var body: some View {
        PopoverSection(title: "Quick actions") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: max(3, min(6, prefs.columns))), spacing: 6) {
                ForEach(prefs.tiles.compactMap(PopoverCatalog.tile)) { tile in
                    let on = isOn(tile)
                    Button {
                        commands.run(tile.command)
                        if tile.closes { close() }
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: tile.symbol)
                                .font(.system(size: prefs.compact ? 15 : 17))
                                .foregroundStyle(on ? tint : Color.primary.opacity(0.8))
                                .frame(height: prefs.compact ? 18 : 22)
                            if prefs.showLabels {
                                Text(tile.title).font(.system(size: 10)).lineLimit(1).minimumScaleFactor(0.8)
                                    .foregroundStyle(on ? Color.primary : Color.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: prefs.compact ? 40 : (prefs.showLabels ? 54 : 40))
                        .background(on ? tint.opacity(0.2) : Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(TileStyle())
                    .help(tile.title)
                    .accessibilityLabel(tile.title)
                    .accessibilityValue(on ? "on" : "")
                }
            }
        }
        .animation(.smooth(duration: 0.18), value: awake.isOn)
        .animation(.smooth(duration: 0.18), value: stack.active)
    }
}

private struct TileStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Hover(configuration: configuration)
    }

    private struct Hover: View {
        let configuration: ButtonStyle.Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .background(Color.primary.opacity(configuration.isPressed ? 0.14 : hovering ? 0.07 : 0), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .scaleEffect(configuration.isPressed ? 0.96 : 1)
                .onHover { hovering = $0 }
                .animation(.smooth(duration: 0.12), value: hovering)
        }
    }
}

/// Window places drawn as little screens, one click each, for the window that was in front when the menu was opened.
private struct WindowGrid: View {
    @EnvironmentObject private var windowController: WindowController
    @EnvironmentObject private var prefs: PopoverPrefs

    var body: some View {
        PopoverSection(title: "Window") {
            VStack(spacing: 6) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 6), spacing: 6) {
                    ForEach(prefs.layouts, id: \.self) { command in
                        if let layout = windowLayoutFromCommand(command: command) {
                            Button { windowController.run(command: command) } label: { MiniScreen(layout: layout) }
                                .buttonStyle(TileStyle())
                                .help(layout.title)
                                .accessibilityLabel("Place the window: \(layout.title)")
                        }
                    }
                }
                HStack(spacing: 6) {
                    row("arrow.uturn.backward", "Undo", "window.restore")
                    row("rectangle.2.swap", "Next display", "window.next_display")
                    row("square.grid.3x3", "Grid", "window.grid")
                }
            }
        }
    }

    private func row(_ symbol: String, _ title: String, _ command: String) -> some View {
        Button { windowController.run(command: command) } label: {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 11))
                Text(title).font(.system(size: 11))
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 26)
        }
        .buttonStyle(TileStyle())
    }
}

/// A tiny screen with the part a layout fills shaded in. Drawn from a full-size screen, so the layout's own minimum window
/// sizes do not stretch it.
struct MiniScreen: View {
    let layout: WindowLayout
    @Environment(\.popoverTint) private var tint

    var body: some View {
        let width: Double = 1600, height: Double = 1000
        let frame = windowLayoutFrame(layout: layout, area: Rect(x: 0, y: 0, width: width, height: height), current: Rect(x: 400, y: 250, width: 800, height: 500), gap: 0)
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.primary.opacity(0.07))
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(tint.opacity(0.75))
                .frame(width: max(4, 40 * frame.width / width), height: max(4, 26 * frame.height / height))
                .offset(x: 40 * frame.x / width, y: 26 * frame.y / height)
        }
        .frame(width: 40, height: 26)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.primary.opacity(0.28), lineWidth: 1))
        .frame(maxWidth: .infinity, minHeight: 34)
    }
}

/// The switch for each feature, as a list or as two columns.
private struct FeaturesSection: View {
    let openSettings: (SettingsPane?) -> Void
    @EnvironmentObject private var prefs: PopoverPrefs
    @EnvironmentObject private var config: ConfigStore
    @EnvironmentObject private var services: ServiceManager

    var body: some View {
        PopoverSection(title: "Features") {
            if prefs.featuresAsGrid {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 4) {
                    ForEach(FeatureId.all) { feature in
                        let state = services.state(feature)
                        HStack(spacing: 6) {
                            Image(systemName: feature.symbol).font(.system(size: 13)).frame(width: 20)
                                .foregroundStyle(state == .running ? Color.primary : Color.secondary)
                            Text(PopoverCatalog.shortTitle(feature)).font(.callout).lineLimit(1)
                                .foregroundStyle(state == .off ? Color.secondary : Color.primary)
                            Spacer(minLength: 0)
                            if case .needsPermission = state { StatusDot(color: Theme.warn) }
                            Toggle(PopoverCatalog.shortTitle(feature), isOn: Binding(get: { config.isEnabled(feature) }, set: { on in withAnimation(.smooth) { services.setFeature(feature, enabled: on) } }))
                                .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .contextMenu { Button("Open \(feature.title) settings") { openSettings(feature.pane) } }
                        .help(feature.title)
                    }
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(FeatureId.all) { feature in PopoverFeatureRow(feature: feature, openSettings: openSettings) }
                }
            }
        }
    }
}

private struct PopoverFeatureRow: View {
    let feature: FeatureId
    let openSettings: (SettingsPane?) -> Void
    @EnvironmentObject private var config: ConfigStore
    @EnvironmentObject private var services: ServiceManager
    @EnvironmentObject private var permissions: PermissionManager
    @State private var hovering = false

    /// One short line under the name, so the list says what each feature is doing and not only whether its switch is on.
    static func caption(_ state: FeatureState) -> String {
        switch state {
        case .running: return "Running"
        case .off: return "Off"
        case .safeMode: return "Held back by safe mode"
        case .needsPermission(let missing): return missing.isEmpty ? "Needs a permission" : "Needs " + missing.map(\.title).joined(separator: " and ")
        case .failed: return "Could not start"
        }
    }

    static func captionIsWarning(_ state: FeatureState) -> Bool {
        switch state {
        case .needsPermission, .failed, .safeMode: return true
        default: return false
        }
    }

    private var binding: Binding<Bool> {
        Binding(
            get: { config.isEnabled(feature) },
            set: { on in withAnimation(.smooth) { services.setFeature(feature, enabled: on) } }
        )
    }

    var body: some View {
        let state = services.state(feature)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Button { openSettings(feature.pane) } label: {
                    HStack(spacing: 10) {
                        RowIcon(symbol: feature.symbol, active: state == .running)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(feature.title)
                                .foregroundStyle(state == .off ? Color.secondary : Color.primary)
                            Text(Self.caption(state)).font(.system(size: 10.5))
                                .foregroundStyle(Self.captionIsWarning(state) ? Theme.warn : Color.secondary.opacity(0.8))
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .opacity(hovering ? 1 : 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open \(feature.title) settings")
                Toggle(feature.title, isOn: binding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
            }
            if case .needsPermission(let missing) = state, !missing.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(missing) { permission in
                        HStack(spacing: 8) {
                            StateBadge(text: "Needs \(permission.title)", color: Theme.warn)
                            Button("Allow") { permissions.request(permission) }.controlSize(.small)
                        }
                    }
                }
                .padding(.leading, 34)
                .transition(.opacity.combined(with: .move(edge: .top)))
            } else if case .failed = state {
                StateBadge(text: "Could not start", color: Theme.danger).padding(.leading, 34)
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(Color.primary.opacity(hovering ? 0.06 : 0), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .onHover { hovering = $0 }
        .animation(.smooth(duration: 0.15), value: hovering)
        .smoothly(state)
    }
}

/// Switches for the newer features, so they can be turned on and off without opening Settings.
private struct ExtrasSection: View {
    @EnvironmentObject private var remap: RemapStore
    @EnvironmentObject private var screen: ScreenToolsStore
    @EnvironmentObject private var pointer: PointerEffectsStore
    @EnvironmentObject private var links: LinkRoutingStore
    @EnvironmentObject private var drag: DragToolsStore
    @EnvironmentObject private var prefs: PopoverPrefs
    @Environment(\.popoverTint) private var tint

    private func isOn(_ id: String) -> Bool {
        switch id {
        case "remap": return remap.config.enabled
        case "pointer": return pointer.config.enabled
        case "corners": return screen.config.hotCornersEnabled
        case "shelf": return screen.config.shelfEnabled
        case "links": return links.config.enabled
        case "dragscroll": return drag.config.scrollEnabled
        default: return false
        }
    }

    private func set(_ id: String, _ on: Bool) {
        switch id {
        case "remap": remap.update { $0.enabled = on }
        case "pointer": pointer.update { $0.enabled = on }
        case "corners": screen.update { $0.hotCornersEnabled = on }
        case "shelf": screen.update { $0.shelfEnabled = on }
        case "links": links.update { $0.enabled = on }
        case "dragscroll": drag.update { $0.scrollEnabled = on }
        default: break
        }
    }

    var body: some View {
        let shown = PopoverCatalog.extras.filter { prefs.extras.contains($0.id) }
        if !shown.isEmpty {
            PopoverSection(title: "More") {
                VStack(spacing: 0) {
                    ForEach(shown, id: \.id) { extra in
                        let on = isOn(extra.id)
                        HStack(spacing: 10) {
                            Image(systemName: extra.symbol).font(.system(size: 14)).frame(width: 24).foregroundStyle(on ? tint : Color.secondary)
                            Text(extra.title).foregroundStyle(on ? Color.primary : Color.secondary)
                            Spacer(minLength: 0)
                            Toggle(extra.title, isOn: Binding(get: { on }, set: { v in withAnimation(.smooth) { set(extra.id, v) } })).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                        }
                        .padding(.vertical, 5)
                        .padding(.horizontal, 8)
                    }
                }
            }
        }
    }
}
