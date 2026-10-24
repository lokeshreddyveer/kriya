import AppKit
import SwiftUI

/// The window list: a search box, windows with their pictures, favorites at the top, and what to do with each.
struct WindowListView: View {
    @ObservedObject var model: WindowListModel
    var onClose: () -> Void = {}
    var showsClose = true
    @FocusState private var searchFocused: Bool
    @State private var selected: String?
    @State private var explaining: String?

    private var rank: [String: Int] {
        Dictionary(uniqueKeysWithValues: model.rows.sorted { $0.lastUsed > $1.lastUsed }.enumerated().map { ($1.id, $0) })
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search windows", text: $model.query)
                    .textFieldStyle(.plain).font(.title3)
                    .focused($searchFocused)
                    .onSubmit { if let id = selected ?? model.flat.first?.id { go(id) } }
                Picker("", selection: $model.grouping) { ForEach(WindowGrouping.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless).accessibilityLabel("Refresh")
                    .disabled(model.isGathering)
            }
            .padding(14)
            Divider()
            if !AXIsProcessTrusted() {
                ContentUnavailableView("Accessibility is needed", systemImage: "lock.shield", description: Text("Allow Kriya under System Settings › Privacy & Security › Accessibility so it can list windows."))
            } else if model.sections.isEmpty {
                ContentUnavailableView(model.query.isEmpty ? "No windows" : "Nothing matches", systemImage: "macwindow", description: Text(model.query.isEmpty ? "Open a window and it appears here." : "Try fewer words."))
            } else {
                ScrollViewReader { proxy in
                    List(selection: $selected) {
                        ForEach(model.sections) { section in
                            Section(section.title) { ForEach(section.rows) { row in rowView(row).tag(row.id) } }
                        }
                    }
                    .listStyle(.inset)
                    .onChange(of: selected) { _, id in if let id { proxy.scrollTo(id) } }
                }
            }
        }
        .frame(minWidth: 520, minHeight: 360)
        .onAppear { searchFocused = true; if model.rows.isEmpty { model.refresh() } }
        .onKeyPress(.escape) { if model.query.isEmpty { if showsClose { onClose() }; return .handled }; model.query = ""; return .handled }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .animation(.smooth(duration: 0.2), value: model.sections)
    }

    private func move(_ delta: Int) {
        let ids = model.flat.map(\.id)
        guard !ids.isEmpty else { return }
        let current = selected.flatMap { ids.firstIndex(of: $0) } ?? -1
        selected = ids[min(max(current + delta, 0), ids.count - 1)]
    }

    private func go(_ id: String) {
        model.go(id)
        if showsClose { onClose() }
    }

    @ViewBuilder
    private func rowView(_ row: WindowRow) -> some View {
        HStack(spacing: 12) {
            thumbnail(row)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.title.isEmpty ? row.appName : row.title).font(.headline).lineLimit(1)
                    if row.isFront { badge("In front", .green) }
                    if row.isMinimized { badge("Minimized", .orange) }
                    if row.isAppHidden { badge("Hidden", .gray) }
                }
                Text("\(row.appName) · \(row.display)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if explaining == row.id {
                    Text(WindowListOrder.why(row, query: model.query, rank: rank[row.id] ?? 99, clock: row.lastUsed)).font(.caption).foregroundStyle(Theme.accent)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            Button { model.toggleFavorite(row.id) } label: { Image(systemName: row.isFavorite ? "star.fill" : "star").foregroundStyle(row.isFavorite ? Theme.warn : .secondary) }
                .buttonStyle(.borderless).accessibilityLabel(row.isFavorite ? "Remove favorite" : "Make favorite")
            Button("Go") { go(row.id) }.controlSize(.small)
            Menu {
                Button(row.isMinimized ? "Bring Back" : "Minimize") { model.toggleMinimized(row.id) }
                Button("Close Window", role: .destructive) { model.close(row.id) }
                Divider()
                Button("Hide \(row.appName)") { model.hideApp(of: row.id) }
                Button("Quit \(row.appName)", role: .destructive) { model.quitApp(of: row.id) }
                Divider()
                Button(explaining == row.id ? "Hide the Reason" : "Why Is This Shown?") { explaining = explaining == row.id ? nil : row.id }
            } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("More").menuStyle(.borderlessButton).frame(width: 28)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { go(row.id) }
    }

    @ViewBuilder
    private func thumbnail(_ row: WindowRow) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.07))
            if let image = model.thumbnails[row.id] {
                Image(nsImage: image).resizable().scaledToFill().clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: row.appID) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().scaledToFit().padding(8).opacity(row.isMinimized ? 0.5 : 1)
            }
        }
        .frame(width: 88, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text).font(.caption2.weight(.medium)).padding(.horizontal, 6).padding(.vertical, 1)
            .background(color.opacity(0.18), in: Capsule()).foregroundStyle(color)
    }
}
