import SwiftUI

/// A picture of where the room went: every item in a folder as a tile as big as the item, folders you can open to look inside.
struct DiskMapPane: View {
    @StateObject private var scanner = DiskMapScanner()
    @State private var hovered: DiskEntry?
    @State private var started = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Button { scanner.up() } label: { Image(systemName: "chevron.left") }.disabled(scanner.path.count < 2 || scanner.scanning)
                ForEach(Array(scanner.path.enumerated()), id: \.offset) { index, url in
                    if index > 0 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                    Button(index == 0 ? (url == FileManager.default.homeDirectoryForCurrentUser ? "Home" : url.lastPathComponent) : url.lastPathComponent) { scanner.go(toIndex: index) }.buttonStyle(.link)
                }
                Spacer()
                Menu("Look At") {
                    Button("Home") { scanner.reset(to: FileManager.default.homeDirectoryForCurrentUser) }
                    Button("Applications") { scanner.reset(to: URL(fileURLWithPath: "/Applications")) }
                    Button("Choose Folder…") { choose() }
                }.fixedSize()
                Button { scanner.scan() } label: { Image(systemName: "arrow.clockwise") }.disabled(scanner.scanning)
            }
            .controlSize(.small)

            ZStack {
                if scanner.scanning { VStack(spacing: 8) { ProgressView(); Text("Measuring \(scanner.current.lastPathComponent)…").foregroundStyle(.secondary) } }
                else if scanner.entries.isEmpty { Text("Nothing here, or macOS did not allow Kriya to look.").foregroundStyle(.secondary) }
                else { MapCanvas(entries: scanner.entries, hovered: $hovered, open: { scanner.open($0.url) }, trash: { scanner.trash($0) }) }
            }
            .frame(maxWidth: .infinity, minHeight: 380)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            HStack {
                if let h = hovered { Text("\(h.name) · \(ByteFormat.size(Double(h.size))) · \(Int((Double(h.size) / Double(max(scanner.total, 1)) * 100).rounded()))% of this folder").lineLimit(1) }
                else { Text("\(ByteFormat.size(Double(scanner.total))) in this folder").foregroundStyle(.secondary) }
                Spacer()
                if scanner.skipped > 0 { Text("\(scanner.skipped) item\(scanner.skipped == 1 ? "" : "s") macOS did not let Kriya read").font(.caption).foregroundStyle(.secondary) }
            }
            .font(.callout)
            Text("Click a folder to look inside it. Right-click a tile to show it in Finder or move it to the Trash. Nothing is removed unless you choose that.").font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .onAppear { if !started { started = true; scanner.scan() } }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.prompt = "Look Here"
        if panel.runModal() == .OK, let url = panel.url { scanner.reset(to: url) }
    }
}

private struct MapCanvas: View {
    let entries: [DiskEntry]
    @Binding var hovered: DiskEntry?
    let open: (DiskEntry) -> Void
    let trash: (DiskEntry) -> Void

    var body: some View {
        GeometryReader { geo in
            let items = Treemap.grouped(entries.map { Treemap.Item(id: $0.id, size: Double($0.size)) })
            let tiles = Treemap.layout(items, in: CGRect(origin: .zero, size: geo.size).insetBy(dx: 4, dy: 4))
            ZStack(alignment: .topLeading) {
                ForEach(tiles, id: \.id) { tile in
                    let entry = entries.first { $0.id == tile.id }
                    tileView(tile, entry: entry)
                }
            }
        }
        .padding(0)
    }

    @ViewBuilder
    private func tileView(_ tile: Treemap.Tile, entry: DiskEntry?) -> some View {
        let r = tile.rect.insetBy(dx: 1, dy: 1)
        let color = entry.map(Self.color) ?? Color.gray
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 5, style: .continuous).fill(color.opacity(hovered?.id == tile.id ? 0.95 : 0.78))
            if r.width > 70, r.height > 34 {
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry?.name ?? "Smaller items").font(.system(size: 11, weight: .semibold)).lineLimit(1)
                    if let entry { Text(ByteFormat.size(Double(entry.size))).font(.system(size: 10)).opacity(0.85) }
                }.foregroundStyle(.white).padding(6)
            }
        }
        .frame(width: max(r.width, 0), height: max(r.height, 0))
        .position(x: r.midX, y: r.midY)
        .onHover { inside in if inside { hovered = entry } else if hovered?.id == tile.id { hovered = nil } }
        .onTapGesture { if let entry, entry.isFolder { open(entry) } }
        .contextMenu {
            if let entry {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
                if entry.isFolder { Button("Look Inside") { open(entry) } }
                Divider()
                Button("Move to Trash", role: .destructive) { trash(entry) }
            }
        }
    }

    /// Folders get a colour of their own from their name; files by what they are.
    static func color(for entry: DiskEntry) -> Color {
        if entry.isFolder {
            let h = Double(abs(entry.name.hashValue % 360)) / 360
            return Color(hue: h, saturation: 0.55, brightness: 0.62)
        }
        switch entry.url.pathExtension.lowercased() {
        case "mov", "mp4", "m4v", "mkv", "avi": return Color(hue: 0.0, saturation: 0.6, brightness: 0.7)
        case "jpg", "jpeg", "png", "heic", "gif", "raw", "tiff": return Color(hue: 0.33, saturation: 0.5, brightness: 0.6)
        case "mp3", "m4a", "wav", "flac", "aiff": return Color(hue: 0.78, saturation: 0.5, brightness: 0.65)
        case "zip", "dmg", "pkg", "tar", "gz", "iso": return Color(hue: 0.1, saturation: 0.65, brightness: 0.72)
        case "pdf", "doc", "docx", "pages", "txt", "md": return Color(hue: 0.58, saturation: 0.5, brightness: 0.68)
        default: return Color(white: 0.45)
        }
    }
}
