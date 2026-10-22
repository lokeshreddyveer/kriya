import AppKit
import SwiftUI

/// The quick paste panel: a search box, a few type filters and the history grouped by day. The row you are on opens up to
/// show everything it holds, so there is no separate preview to look at. Click a row, or press Return, to paste it.
struct QuickAccessView: View {
    @ObservedObject var model: QuickClipModel
    @ObservedObject var store: ClipboardStore
    let onChoose: (ClipItem, Bool) -> Void
    let onClose: () -> Void
    @FocusState private var searchFocused: Bool
    @State private var hovered: String?

    /// The filters shown here. Pinned items have no place in this panel, so that filter is left out.
    private static let chips: [ClipChip] = [.all, .text, .links, .images, .files, .snippets]

    var body: some View {
        VStack(spacing: 0) {
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

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search your clipboard", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($searchFocused)
                .onSubmit { if let item = model.current { onChoose(item, false) } }
            if store.currentConfig.paused {
                Label("Paused", systemImage: "pause.circle.fill").font(.caption).foregroundStyle(Theme.warn)
            }
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
                                .onHover { inside in hovered = inside ? entry.item.id : (hovered == entry.item.id ? nil : hovered) }
                                .onTapGesture { onChoose(entry.item, NSEvent.modifierFlags.contains(.command)) }
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

    // MARK: Footer and keys

    private var footer: some View {
        HStack(spacing: 12) {
            hint("↩", "Paste")
            hint("⌘↩", "Plain text")
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
            Text(item.title ?? item.preview)
                .font(looksLikeCode ? .system(size: 12, design: .monospaced) : .system(size: 13))
                .lineLimit(isSelected ? 1 : 2)
        }
    }

    private var detail: some View {
        HStack(spacing: 5) {
            if let app = item.sourceApp, let icon = AppIcons.icon(for: app) {
                Image(nsImage: icon).resizable().frame(width: 12, height: 12)
            }
            Text(detailText)
            if item.favorite { Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(Theme.warn) }
            ForEach(item.tags.prefix(2), id: \.self) { Text("#\($0)").foregroundStyle(Theme.accent) }
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
