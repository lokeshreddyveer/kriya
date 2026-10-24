import AppKit
import SwiftUI

/// One more thing a right-click can do with an item. Those with the same `submenu` share a sub-menu.
struct QuickMenuAction: Identifiable {
    let id = UUID()
    let title: String
    let symbol: String
    var submenu: String?
    let run: () -> Void
}

/// Where the quick paste window opens.
enum QuickPanelPlacement: String, CaseIterable, Identifiable {
    case atPointer, remembered
    var id: String { rawValue }
    var title: String { self == .atPointer ? "At the pointer" : "Where I left it" }

    private static let key = "quickPastePlacement"
    static var current: QuickPanelPlacement {
        get { UserDefaults.standard.string(forKey: key).flatMap(QuickPanelPlacement.init(rawValue:)) ?? .atPointer }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
}

/// Keeping the window where the person put it.
enum QuickPanelPosition {
    private static let key = "quickPasteOrigin"

    static var saved: NSPoint? {
        guard let text = UserDefaults.standard.string(forKey: key) else { return nil }
        let parts = text.split(separator: ",").compactMap { Double($0) }
        return parts.count == 2 ? NSPoint(x: parts[0], y: parts[1]) : nil
    }

    static func save(_ origin: NSPoint) { UserDefaults.standard.set("\(origin.x),\(origin.y)", forKey: key) }

    /// The saved place, if most of the window would still be on a screen (a display may have been unplugged), moved fully
    /// inside the screen it mostly overlaps. Nil when it would be mostly off every screen.
    static func usable(_ saved: NSPoint?, size: NSSize, screens: [CGRect]) -> NSPoint? {
        guard let saved, size.width > 0, size.height > 0 else { return nil }
        let frame = CGRect(origin: saved, size: size)
        let best = screens.max { overlap(frame, $0) < overlap(frame, $1) }
        guard let screen = best, overlap(frame, screen) >= size.width * size.height * 0.5 else { return nil }
        let x = min(max(saved.x, screen.minX + 4), max(screen.maxX - size.width - 4, screen.minX + 4))
        let y = min(max(saved.y, screen.minY + 4), max(screen.maxY - size.height - 4, screen.minY + 4))
        return NSPoint(x: x, y: y)
    }

    private static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let both = a.intersection(b)
        return both.isNull ? 0 : both.width * both.height
    }
}

/// A strip that moves the window when it is dragged.
private struct WindowGrip: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { GripView() }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class GripView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
    }
}

/// The quick paste panel: a search box, a few type filters and the history grouped by day. The row you are on opens up to
/// show everything it holds, so there is no separate preview to look at. Click a row, or press Return, to paste it.
struct QuickAccessView: View {
    @ObservedObject var model: QuickClipModel
    @ObservedObject var store: ClipboardStore
    let onChoose: (ClipItem, Bool) -> Void
    let onClose: () -> Void
    var onCopy: (ClipItem) -> Void = { _ in }
    var menuActions: (ClipItem) -> [QuickMenuAction] = { _ in [] }
    @FocusState private var searchFocused: Bool
    @State private var hovered: String?

    /// The filters shown here. Pinned items have no place in this panel, so that filter is left out.
    private static let chips: [ClipChip] = [.all, .pinned, .text, .links, .images, .files, .snippets, .secrets, .frequent]

    var body: some View {
        VStack(spacing: 0) {
            grip
            searchBar
            chipRow
            Divider().opacity(0.6)
            content
            Divider().opacity(0.6)
            footer
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.22), lineWidth: 1))
        .onAppear { searchFocused = true }
        .onKeyPress(phases: [.down, .repeat]) { press in handle(press) }
    }

    // MARK: Search and filters

    /// A small bar to take hold of, to move the window.
    private var grip: some View {
        ZStack {
            WindowGrip()
            Capsule().fill(Color.primary.opacity(0.22)).frame(width: 38, height: 4)
        }
        .frame(height: 14)
        .padding(.top, 2)
        .help("Drag to move this window")
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search your clipboard", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($searchFocused)
                .onSubmit { if let item = model.current { onChoose(item, false) } }
            if store.currentConfig.paused {
                Label(ClipPause.label(until: ClipPauseController.until), systemImage: "pause.circle.fill").font(.caption).foregroundStyle(Theme.warn)
            }
            pauseMenu
            if !model.query.isEmpty {
                Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                    .buttonStyle(.plain)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
        .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 8)
        .animation(.smooth(duration: 0.15), value: model.query.isEmpty)
    }

    /// Stops recording for a while (or until turned back on), and turns it back on.
    private var pauseMenu: some View {
        Menu {
            if store.currentConfig.paused {
                Button("Resume Recording") { ClipPauseController.resume(store: store) }
            } else {
                Button("Pause for 5 Minutes") { ClipPauseController.pause(store: store, minutes: 5) }
                Button("Pause for 30 Minutes") { ClipPauseController.pause(store: store, minutes: 30) }
                Button("Pause Until I Resume") { ClipPauseController.pause(store: store, minutes: 0) }
            }
        } label: { Image(systemName: store.currentConfig.paused ? "play.circle" : "pause.circle").foregroundStyle(.secondary) }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help(store.currentConfig.paused ? "Resume recording" : "Pause recording")
    }

    /// Narrow the list by the app it was copied in and by when.
    private var filterMenu: some View {
        Menu {
            Picker("When", selection: $model.view.range) { ForEach(ClipDateRange.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.inline)
            if !model.sources.isEmpty {
                Divider()
                Button("Any App") { model.view.sourceApp = nil }
                ForEach(model.sources.prefix(12), id: \.self) { app in
                    Button { model.view.sourceApp = app } label: { Text(AppChoice.name(for: app)) }
                }
            }
        } label: {
            Label(model.view.isActive ? "Filtered" : "Filter", systemImage: model.view.isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                .font(.system(size: 11))
        }
        .menuStyle(.borderlessButton).fixedSize()
    }

    private var chipRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Self.chips) { chip in
                    let on = model.chip == chip
                    Button { withAnimation(.smooth(duration: 0.15)) { model.chip = chip } } label: {
                        Text(chip.rawValue)
                            .font(.system(size: 11, weight: on ? .semibold : .regular))
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(on ? Theme.accent.opacity(0.22) : Color.primary.opacity(0.05), in: Capsule())
                            .overlay(Capsule().strokeBorder(on ? Theme.accent.opacity(0.7) : Color.primary.opacity(0.10), lineWidth: 1))
                            .foregroundStyle(on ? Color.primary : Color.secondary)
                    }
                    .buttonStyle(.plain)
                }
                filterMenu
                if !store.collections.isEmpty {
                    Menu {
                        Button("All collections") { model.collection = nil }
                        Divider()
                        ForEach(store.collections) { c in Button(c.name) { model.collection = c.id } }
                    } label: {
                        Label(store.collections.first { $0.id == model.collection }?.name ?? "Collections", systemImage: "folder")
                            .font(.system(size: 11))
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                }
            }
            .padding(.horizontal, 12).padding(.bottom, 9)
        }
    }

    // MARK: The list

    /// One day's worth of items, each with its place in the list so arrow keys and clicks agree.
    private struct Day: Identifiable {
        let title: String
        let items: [(index: Int, item: ClipItem)]
        var id: String { title }
    }

    private var days: [Day] {
        let calendar = Calendar.current
        let now = Date()
        func title(for item: ClipItem) -> String {
            let date = Date(timeIntervalSince1970: TimeInterval(item.lastUsedAt))
            if calendar.isDateInToday(date) { return "Today" }
            if calendar.isDateInYesterday(date) { return "Yesterday" }
            if let days = calendar.dateComponents([.day], from: date, to: now).day, days < 7 { return "This week" }
            return "Earlier"
        }
        var order: [String] = []
        var grouped: [String: [(Int, ClipItem)]] = [:]
        for (index, item) in model.results.enumerated() {
            let name = title(for: item)
            if grouped[name] == nil { order.append(name) }
            grouped[name, default: []].append((index, item))
        }
        return order.map { name in Day(title: name, items: (grouped[name] ?? []).map { (index: $0.0, item: $0.1) }) }
    }

    @ViewBuilder
    private var content: some View {
        if model.results.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: store.isEmpty ? "doc.on.clipboard" : "magnifyingglass")
                    .font(.system(size: 28, weight: .light)).foregroundStyle(.tertiary)
                Text(store.isEmpty ? "Nothing copied yet" : "Nothing matches")
                    .font(.callout).foregroundStyle(.secondary)
                if store.isEmpty { Text("Copy something and it shows up here.").font(.caption).foregroundStyle(.tertiary) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2, pinnedViews: []) {
                        ForEach(days) { day in
                            Text(day.title.uppercased())
                                .font(.system(size: 10, weight: .semibold)).tracking(0.5)
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 2)
                            ForEach(day.items, id: \.item.id) { entry in
                                QuickRow(
                                    item: entry.item, number: entry.index < 9 ? entry.index + 1 : nil,
                                    isSelected: entry.index == model.selected, isHovered: hovered == entry.item.id, blob: entry.index == model.selected ? model.blob : nil
                                )
                                .id(entry.item.id)
                                .contextMenu { menu(for: entry.item) }
                                .onHover { inside in hovered = inside ? entry.item.id : (hovered == entry.item.id ? nil : hovered) }
                                .onTapGesture { onChoose(entry.item, NSEvent.modifierFlags.contains(.command)) }
                                // Drag it straight into another app, a message or a folder.
                                .onDrag { ClipDrag.provider(for: entry.item, blob: store.blob(entry.item.id)) ?? NSItemProvider() }
                            }
                        }
                    }
                    .padding(.horizontal, 6).padding(.bottom, 6)
                }
                .scrollIndicators(.hidden)
                .onChange(of: model.selected) { _, new in
                    if model.results.indices.contains(new) { withAnimation(.smooth(duration: 0.14)) { proxy.scrollTo(model.results[new].id) } }
                }
            }
            .animation(.smooth(duration: 0.18), value: model.selected)
        }
    }

    // MARK: Right-click menu

    @ViewBuilder
    private func menu(for item: ClipItem) -> some View {
        let isText = item.kind == .text || item.kind == .richText || item.kind == .url
        Button { onChoose(item, false) } label: { Label("Paste", systemImage: "arrow.turn.down.left") }
        if isText { Button { onChoose(item, true) } label: { Label("Paste as Plain Text", systemImage: "textformat") } }
        Button { onCopy(item) } label: { Label("Copy", systemImage: "doc.on.doc") }
        Divider()
        Button { model.togglePin(item) } label: { Label(item.pinned ? "Unpin" : "Pin to the Top", systemImage: item.pinned ? "pin.slash" : "pin") }
        Button { model.toggleSnippet(item) } label: { Label(item.favorite ? "Remove from Snippets" : "Save as Snippet", systemImage: item.favorite ? "star.slash" : "star") }
        let extras = menuActions(item)
        if !extras.isEmpty {
            Divider()
            ForEach(extras.filter { $0.submenu == nil }) { action in
                Button { action.run() } label: { Label(action.title, systemImage: action.symbol) }
            }
            let groups = extras.compactMap(\.submenu).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            ForEach(groups, id: \.self) { group in
                Menu {
                    ForEach(extras.filter { $0.submenu == group }) { action in
                        Button { action.run() } label: { Label(action.title, systemImage: action.symbol) }
                    }
                } label: { Label(group, systemImage: "sparkles") }
            }
        }
        Divider()
        Button(role: .destructive) { model.remove(item) } label: { Label("Delete", systemImage: "trash") }
    }

    // MARK: Footer and keys

    private var footer: some View {
        HStack(spacing: 12) {
            hint("↩", "Paste")
            hint("⌘1–9", "Quick")
            hint("⌘↩", "Plain")
            hint("⌘P", "Pin")
            hint("⌘⌫", "Delete")
            hint("⎋", "Close")
            Spacer(minLength: 4)
            Text("\(model.results.count) item\(model.results.count == 1 ? "" : "s")").font(.caption2).foregroundStyle(.tertiary)
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(.horizontal, 12).padding(.vertical, 7)
    }

    private func hint(_ key: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Text(key).font(.system(size: 10, design: .rounded)).padding(.horizontal, 4).padding(.vertical, 1)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            Text(text)
        }
    }

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        let command = press.modifiers.contains(.command)
        switch press.key {
        case .downArrow: model.move(1); return .handled
        case .upArrow: model.move(-1); return .handled
        case .escape: onClose(); return .handled
        case .return:
            if command, let item = model.current { onChoose(item, true); return .handled }
            return .ignored
        case .delete where command: model.deleteCurrent(); return .handled
        default:
            if command, press.characters.lowercased() == "p" { model.togglePin(); return .handled }
            if command, let digit = Int(press.characters), (1...9).contains(digit), model.results.indices.contains(digit - 1) {
                onChoose(model.results[digit - 1], false)
                return .handled
            }
            return .ignored
        }
    }
}

// MARK: - One row

/// The colour and picture that stand for each kind of item. Muted, so a long list stays calm.
private enum KindStyle {
    static func color(_ kind: ClipKind) -> Color {
        switch kind {
        case .text, .richText: return Color(.sRGB, red: 0.45, green: 0.58, blue: 0.72)
        case .url: return Color(.sRGB, red: 0.52, green: 0.66, blue: 0.54)
        case .image: return Color(.sRGB, red: 0.76, green: 0.63, blue: 0.40)
        case .files: return Color(.sRGB, red: 0.62, green: 0.55, blue: 0.72)
        }
    }
}

private enum AppIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(for bundleID: String) -> NSImage? {
        if let hit = cache[bundleID] { return hit }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 12, height: 12)
        cache[bundleID] = icon
        return icon
    }
}

private struct QuickRow: View {
    let item: ClipItem
    let number: Int?
    let isSelected: Bool
    let isHovered: Bool
    let blob: ClipBlob?

    private var tint: Color { KindStyle.color(item.kind) }

    /// What kind of secret it is, when it was labelled one (kept as a tag, never as the secret's text).
    private var secretKind: ClipSecretKind? { item.tags.lazy.compactMap(ClipSecretKind.from(tag:)).first }
    private var hidden: Bool { item.sensitive || secretKind != nil }

    private var looksLikeCode: Bool {
        item.kind == .text && (item.preview.contains("{") || item.preview.contains("=>") || item.preview.contains("();") || item.preview.contains("</"))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                tile
                VStack(alignment: .leading, spacing: 2) {
                    headline
                    detail
                }
                Spacer(minLength: 4)
                if let number {
                    Text("⌘\(number)")
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(isSelected || isHovered ? Color.secondary : Color.secondary.opacity(0.45))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.primary.opacity(isSelected ? 0.10 : 0.05), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
            }
            if isSelected { expanded.transition(.opacity.combined(with: .move(edge: .top))) }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(isSelected ? Theme.accent.opacity(0.18) : (isHovered ? Color.primary.opacity(0.06) : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(isSelected ? Theme.accent.opacity(0.55) : Color.clear, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .animation(.smooth(duration: 0.16), value: isSelected)
        .animation(.smooth(duration: 0.12), value: isHovered)
    }

    // The left-hand picture: the file's own icon for files, a coloured symbol for everything else.
    @ViewBuilder
    private var tile: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous).fill(tint.opacity(0.16))
            if item.kind == .files, let first = item.files.first {
                Image(nsImage: NSWorkspace.shared.icon(forFile: first)).resizable().scaledToFit().padding(5)
            } else if hidden {
                Image(systemName: "lock.fill").font(.system(size: 14, weight: .medium)).foregroundStyle(tint)
            } else {
                Image(systemName: item.kind.symbol).font(.system(size: 14, weight: .medium)).foregroundStyle(tint)
            }
        }
        .frame(width: 34, height: 34)
    }

    @ViewBuilder
    private var headline: some View {
        switch item.kind {
        case .url:
            let url = URL(string: item.preview)
            Text(url?.host ?? item.preview).font(.system(size: 13, weight: .medium)).lineLimit(1)
        case .files:
            Text(item.files.count == 1 ? ((item.files[0] as NSString).lastPathComponent) : "\(item.files.count) files")
                .font(.system(size: 13, weight: .medium)).lineLimit(1)
        case .image:
            Text(item.title ?? "Image").font(.system(size: 13, weight: .medium)).lineLimit(1)
        default:
            if hidden {
                Text("•••••••• \(secretKind?.title ?? "Sensitive")").font(.system(size: 13, weight: .medium)).lineLimit(1)
            } else {
                Text(item.title ?? item.preview)
                    .font(looksLikeCode ? .system(size: 12, design: .monospaced) : .system(size: 13))
                    .lineLimit(isSelected ? 1 : 2)
            }
        }
    }

    private var detail: some View {
        HStack(spacing: 5) {
            if let app = item.sourceApp, let icon = AppIcons.icon(for: app) {
                Image(nsImage: icon).resizable().frame(width: 12, height: 12)
            }
            Text(detailText)
            if item.pinned { Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(Theme.warn) }
            if item.favorite { Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(Theme.warn) }
            ForEach(item.tags.filter { ClipSecretKind.from(tag: $0) == nil }.prefix(2), id: \.self) { Text("#\($0)").foregroundStyle(Theme.accent) }
            if ClipLifetimes.shared.remaining(item.id) != nil { Image(systemName: "timer").font(.system(size: 9)).foregroundStyle(Theme.warn) }
        }
        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
    }

    private var detailText: String {
        var parts: [String] = []
        if let app = item.sourceApp { parts.append(AppChoice.name(for: app)) }
        parts.append(Self.age(of: item))
        if item.kind == .image, let w = item.imageWidth, let h = item.imageHeight { parts.append("\(w)×\(h)") }
        else if item.kind != .files { parts.append(ByteCountFormatter.string(fromByteCount: Int64(item.byteSize), countStyle: .file)) }
        return parts.joined(separator: " · ")
    }

    /// "just now" for the first few seconds, then "5 min. ago" and so on.
    static func age(of item: ClipItem, now: Date = Date()) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(item.lastUsedAt))
        if now.timeIntervalSince(date) < 10 { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: now)
    }

    // What the selected row opens up to show: all of the text, the picture, or the file names.
    @ViewBuilder
    private var expanded: some View {
        switch item.kind {
        case .image:
            if let data = blob?.image, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 170)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
            }
        case .files:
            VStack(alignment: .leading, spacing: 3) {
                ForEach(item.files.prefix(5), id: \.self) { path in
                    HStack(spacing: 6) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 14, height: 14)
                        Text((path as NSString).lastPathComponent).lineLimit(1)
                    }
                }
                if item.files.count > 5 { Text("and \(item.files.count - 5) more").foregroundStyle(.tertiary) }
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
        default:
            if hidden {
                Label("Hidden\(secretKind.map { " (\($0.title))" } ?? ""). Press Return to paste it.", systemImage: "eye.slash")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                let full = String((blob?.plain ?? item.preview).prefix(1500))
                Text(full)
                    .font(looksLikeCode ? .system(size: 11, design: .monospaced) : .system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }
}
