import SwiftUI

/// What the person has set aside to look at together before moving it to the Trash. Nothing leaves the disk by being added here.
final class DiskCollector: ObservableObject {
    @Published private(set) var items: [DiskEntry] = []
    var total: Int64 { items.reduce(0) { $0 + $1.size } }

    func add(_ list: [DiskEntry]) {
        let known = Set(items.map(\.id))
        items += list.filter { !known.contains($0.id) }
    }
    func remove(_ id: String) { items.removeAll { $0.id == id } }
    func clear() { items = [] }
}

/// A Trash request waiting for a yes. Every move to the Trash, from any tab, goes through one of these.
struct PendingTrash: Identifiable {
    let id = UUID()
    let items: [DiskEntry]
    var bytes: Int64 { items.reduce(0) { $0 + $1.size } }
    var title: String { items.count == 1 ? "Move “\(items[0].name)” to the Trash?" : "Move \(items.count) items to the Trash?" }
}

enum DiskMapTab: String, CaseIterable, Identifiable {
    case map = "Map", largest = "Largest", cleanup = "Cleanup", advanced = "Advanced"
    var id: String { rawValue }
}

/// A picture of where the room went, in four parts: the Map of one folder, the Largest files under it, Cleanup suggestions, and
/// Advanced reports about the disk itself.
struct DiskMapPane: View {
    @StateObject private var scanner = DiskMapScanner()
    @StateObject private var deep = DiskDeepScanner()
    @StateObject private var collector = DiskCollector()
    @State private var tab: DiskMapTab = .map
    @State private var pending: PendingTrash?

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab.animation(.easeInOut(duration: 0.2))) { ForEach(DiskMapTab.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden().fixedSize().padding(.top, 14)
            if !scanner.lastTrashed.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "trash").foregroundStyle(.secondary)
                    Text("Moved \(scanner.lastTrashed.count) item\(scanner.lastTrashed.count == 1 ? "" : "s") to the Trash.")
                    Button("Undo") { withAnimation(.easeInOut(duration: 0.2)) { scanner.undo() } }.controlSize(.small)
                    Spacer()
                    Button { withAnimation(.easeInOut(duration: 0.2)) { scanner.dismissUndo() } } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Dismiss")
                }
                .padding(10)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(.horizontal, 20).padding(.top, 10)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            Group {
                switch tab {
                case .map: DiskMapTab_Map(scanner: scanner, collector: collector, request: { pending = PendingTrash(items: $0) })
                case .largest: DiskLargestTab(scanner: scanner, deep: deep, collector: collector, request: { pending = PendingTrash(items: $0) })
                case .cleanup: DiskCleanupTab(scanner: scanner, deep: deep, collector: collector, request: { pending = PendingTrash(items: $0) })
                case .advanced: DiskAdvancedTab(scanner: scanner)
                }
            }
            .transition(.opacity)
        }
        .animation(.easeInOut(duration: 0.2), value: scanner.lastTrashed.count)
        .confirmationDialog(pending?.title ?? "", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible, presenting: pending) { request in
            Button("Move to Trash", role: .destructive) {
                scanner.trash(request.items)
                deep.forget(Set(request.items.map(\.id)))
                collector.clear(for: request.items)
            }
            Button("Cancel", role: .cancel) {}
        } message: { request in
            Text("About \(ByteFormat.size(Double(request.bytes))) will come back once the Trash is emptied. You can put it back from the Trash, or choose Undo right after.")
        }
    }
}

extension DiskCollector {
    func clear(for removed: [DiskEntry]) { let ids = Set(removed.map(\.id)); for id in ids { remove(id) } }
}

// MARK: Map

enum DiskColorMode: String, CaseIterable, Identifiable {
    case kind = "Kind", age = "Age", risk = "Risk", folder = "Folder"
    var id: String { rawValue }
}

private struct DiskMapTab_Map: View {
    @ObservedObject var scanner: DiskMapScanner
    @ObservedObject var collector: DiskCollector
    let request: ([DiskEntry]) -> Void
    @State private var hovered: DiskEntry?
    @State private var selected: String?
    @State private var started = false
    @State private var sunburst = false
    @State private var mode: DiskColorMode = .kind
    @FocusState private var focused: Bool

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Button { scanner.up() } label: { Image(systemName: "chevron.left") }.disabled(scanner.path.count < 2 || scanner.scanning).accessibilityLabel("Up one folder")
                ForEach(Array(scanner.path.enumerated()), id: \.offset) { index, url in
                    if index > 0 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                    Button(index == 0 ? (url == FileManager.default.homeDirectoryForCurrentUser ? "Home" : (url.path == "/" ? "Whole disk" : url.lastPathComponent)) : url.lastPathComponent) { scanner.go(toIndex: index) }.buttonStyle(.link)
                }
                Spacer()
                Menu("Look At") {
                    Button("Home") { scanner.reset(to: FileManager.default.homeDirectoryForCurrentUser) }
                    Button("Whole Startup Disk") { scanner.reset(to: URL(fileURLWithPath: "/")) }
                    Button("Applications") { scanner.reset(to: URL(fileURLWithPath: "/Applications")) }
                    let others = DiskTools.mountedVolumes().filter { $0.path != "/" }
                    if !others.isEmpty { Divider(); ForEach(others, id: \.path) { v in Button(v.lastPathComponent) { scanner.reset(to: v) } } }
                    Divider()
                    Button("Choose Folder…") { choose() }
                }.fixedSize()
                Button { scanner.scan() } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("Refresh").disabled(scanner.scanning)
            }
            .controlSize(.small)

            HStack(spacing: 10) {
                Picker("Shape", selection: $sunburst.animation(.easeInOut(duration: 0.25))) { Text("Treemap").tag(false); Text("Sunburst").tag(true) }.pickerStyle(.segmented).fixedSize().labelsHidden()
                Picker("Colour by", selection: $mode.animation(.easeInOut(duration: 0.25))) { ForEach(DiskColorMode.allCases) { Text($0.rawValue).tag($0) } }.fixedSize()
                Spacer()
                if let at = scanner.scannedAt, !scanner.scanning { Text("Measured \(at.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.secondary) }
            }
            .controlSize(.small)

            if ScanFreshness.isStale(scannedAt: scanner.scannedAt), !scanner.scanning {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text("This map is more than 10 minutes old. Things may have moved or changed since.").font(.callout)
                    Spacer()
                    Button("Measure Again") { scanner.scan() }.controlSize(.small)
                }
                .padding(8).background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .transition(.opacity)
            }

            ZStack {
                if scanner.scanning, scanner.entries.isEmpty, scanner.issue == nil { VStack(spacing: 8) { ProgressView(); Text(scanner.measuring.isEmpty ? "Measuring \(scanner.current.lastPathComponent)…" : "Measuring \(scanner.current.lastPathComponent)… \(scanner.measuring)").foregroundStyle(.secondary) } }
                else if scanner.entries.isEmpty { issueView }
                else if sunburst { SunburstCanvas(entries: scanner.entries, mode: mode, hovered: $hovered, selected: $selected, open: { scanner.open($0.url) }) }
                else { MapCanvas(entries: scanner.entries, mode: mode, hovered: $hovered, selected: selected, open: { scanner.open($0.url) }, actions: tileActions) }
            }
            .frame(maxWidth: .infinity, minHeight: 380)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(.downArrow) { step(1); return .handled }
            .onKeyPress(.rightArrow) { step(1); return .handled }
            .onKeyPress(.upArrow) { step(-1); return .handled }
            .onKeyPress(.leftArrow) { if selected == nil { scanner.up() } else { step(-1) }; return .handled }
            .onKeyPress(.return) { if let e = chosen, e.isFolder { scanner.open(e.url) }; return .handled }
            .onKeyPress(.escape) { if selected != nil { selected = nil } else { scanner.up() }; return .handled }
            .onKeyPress(.space) { if let e = chosen { DiskTools.quickLook([e.url]) }; return .handled }
            .onTapGesture { focused = true }

            if scanner.scanning {
                HStack(spacing: 10) {
                    ProgressView(value: Double(scanner.measured), total: Double(max(scanner.itemCount, 1))).frame(maxWidth: 200)
                    Text("Measured \(scanner.measured) of \(scanner.itemCount)\(scanner.measuring.isEmpty ? "" : " · now \(scanner.measuring)")").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Button("Stop") { scanner.stop() }.controlSize(.small)
                }
                .transition(.opacity)
            }
            HStack {
                if let h = hovered ?? chosen { Text("\(h.name) · \(ByteFormat.size(Double(h.size))) on disk · \(Int((Double(h.size) / Double(max(scanner.total, 1)) * 100).rounded()))% of this folder · \(DiskRisk.classify(h.url.path).level.title)").lineLimit(1).help(DiskRisk.classify(h.url.path).reason) }
                else { Text("\(ByteFormat.size(Double(scanner.total))) in this folder").foregroundStyle(.secondary) }
                Spacer()
                if scanner.skipped > 0 { Text("\(scanner.skipped) item\(scanner.skipped == 1 ? "" : "s") could not be read or took too long").font(.caption).foregroundStyle(.secondary) }
                if scanner.notMeasured > 0 { Text("\(scanner.notMeasured) cloud or network place\(scanner.notMeasured == 1 ? "" : "s") not measured").font(.caption).foregroundStyle(.secondary) }
            }
            .font(.callout)
            legend
            Text("Click a folder to look inside it, or use the arrow keys, Return to open, Space to preview. Right-click for Finder, preview, collect or Trash. Nothing is removed unless you choose that, and every removal asks first.").font(.caption).foregroundStyle(.secondary)
            Text(DiskText.usageNote).font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        }
        .onAppear { if !started { started = true; scanner.scan() } }
    }

    private var chosen: DiskEntry? { scanner.entries.first { $0.id == selected } }

    private func step(_ delta: Int) {
        let list = scanner.entries
        guard !list.isEmpty else { return }
        let index = list.firstIndex { $0.id == selected }
        let next = index.map { min(max($0 + delta, 0), list.count - 1) } ?? 0
        withAnimation(.easeInOut(duration: 0.12)) { selected = list[next].id }
    }

    private var tileActions: TileActions {
        TileActions(trash: { request([$0]) }, collect: { collector.add([$0]) }, preview: { DiskTools.quickLook([$0.url]) })
    }

    /// The real reason there is nothing to draw, with the way out where there is one.
    @ViewBuilder
    private var issueView: some View {
        VStack(spacing: 8) {
            switch scanner.issue {
            case .permissionDenied:
                Image(systemName: "lock").font(.title2).foregroundStyle(.secondary)
                Text("macOS did not let Kriya read this folder.").font(.headline)
                Text(DiskTools.hasFullDiskAccess ? "Try measuring it as administrator in Advanced." : "Full Disk Access is needed for protected places like this. Give it to Kriya, then Measure Again.").foregroundStyle(.secondary).multilineTextAlignment(.center)
                HStack { if !DiskTools.hasFullDiskAccess { Button("Open Full Disk Access") { DiskTools.openFullDiskAccessSettings() } }; Button("Measure Again") { scanner.scan() } }
            case .disappeared:
                Image(systemName: "questionmark.folder").font(.title2).foregroundStyle(.secondary)
                Text("This folder is gone.").font(.headline)
                Text("It was moved, renamed or removed since it was last shown.").foregroundStyle(.secondary)
                Button("Go Up") { scanner.up() }.disabled(scanner.path.count < 2)
            case .timedOut(let count):
                Image(systemName: "clock.badge.exclamationmark").font(.title2).foregroundStyle(.secondary)
                Text("Measuring took too long.").font(.headline)
                Text("\(count) item\(count == 1 ? "" : "s") did not finish in time. Try a smaller folder, or measure again when the disk is quieter.").foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Measure Again") { scanner.scan() }
            case .cloudOnly:
                Image(systemName: "icloud").font(.title2).foregroundStyle(.secondary)
                Text("Everything here lives in the cloud or on the network.").font(.headline)
                Text("Kriya skips those so they are not downloaded or slowed down. Turn on “Include cloud folders” in Advanced to measure what is on this Mac.").foregroundStyle(.secondary).multilineTextAlignment(.center)
            case .empty, nil:
                Image(systemName: "folder").font(.title2).foregroundStyle(.secondary)
                Text("Nothing here.").font(.headline)
                Text("This folder is empty, or everything in it is zero size.").foregroundStyle(.secondary)
            }
        }
        .padding(20)
    }

    @ViewBuilder
    private var legend: some View {
        switch mode {
        case .kind:
            legendRow([("Video", DiskPalette.kind("mov")), ("Images", DiskPalette.kind("png")), ("Audio", DiskPalette.kind("mp3")), ("Archives", DiskPalette.kind("zip")), ("Documents", DiskPalette.kind("pdf")), ("Other", DiskPalette.kind("")), ("Folder", DiskPalette.folder("Folder"))])
        case .age:
            legendRow(DiskPaths.Age.allCases.map { ($0.title, DiskPalette.age($0)) })
        case .risk:
            legendRow([("Likely rebuildable", DiskPalette.risk(.safe)), ("Look first", DiskPalette.risk(.review)), ("Keep", DiskPalette.risk(.keep))])
        case .folder: EmptyView()
        }
    }

    private func legendRow(_ items: [(String, Color)]) -> some View {
        HStack(spacing: 12) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 4) { Circle().fill(item.1).frame(width: 8, height: 8); Text(item.0).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.prompt = "Look Here"
        if panel.runModal() == .OK, let url = panel.url { scanner.reset(to: url) }
    }
}

struct TileActions {
    let trash: (DiskEntry) -> Void
    let collect: (DiskEntry) -> Void
    let preview: (DiskEntry) -> Void
}

/// The colours the map can paint with. Folder and kind keep their look from before; age and risk are new.
enum DiskPalette {
    static func folder(_ name: String) -> Color { Color(hue: Double(abs(name.hashValue % 360)) / 360, saturation: 0.55, brightness: 0.62) }

    static func kind(_ ext: String) -> Color {
        switch ext.lowercased() {
        case "mov", "mp4", "m4v", "mkv", "avi": return Color(hue: 0.0, saturation: 0.6, brightness: 0.7)
        case "jpg", "jpeg", "png", "heic", "gif", "raw", "tiff": return Color(hue: 0.33, saturation: 0.5, brightness: 0.6)
        case "mp3", "m4a", "wav", "flac", "aiff": return Color(hue: 0.78, saturation: 0.5, brightness: 0.65)
        case "zip", "dmg", "pkg", "tar", "gz", "iso": return Color(hue: 0.1, saturation: 0.65, brightness: 0.72)
        case "pdf", "doc", "docx", "pages", "txt", "md": return Color(hue: 0.58, saturation: 0.5, brightness: 0.68)
        default: return Color(white: 0.45)
        }
    }

    static func age(_ age: DiskPaths.Age) -> Color {
        [Color(hue: 0.38, saturation: 0.6, brightness: 0.62), Color(hue: 0.52, saturation: 0.55, brightness: 0.68), Color(hue: 0.12, saturation: 0.65, brightness: 0.74), Color(hue: 0.02, saturation: 0.6, brightness: 0.66)][age.rawValue]
    }

    static func risk(_ level: DiskRisk.Level) -> Color {
        switch level {
        case .safe: return Color(hue: 0.38, saturation: 0.6, brightness: 0.62)
        case .review: return Color(hue: 0.12, saturation: 0.65, brightness: 0.74)
        case .keep: return Color(hue: 0.58, saturation: 0.5, brightness: 0.68)
        }
    }

    static func color(for entry: DiskEntry, mode: DiskColorMode) -> Color {
        switch mode {
        case .folder: return entry.isFolder ? folder(entry.name) : kind(entry.url.pathExtension)
        case .age: return age(DiskPaths.Age.of(entry.modified))
        case .risk: return risk(DiskRisk.classify(entry.url.path).level)
        case .kind: return entry.isFolder ? folder("Folder") : kind(entry.url.pathExtension)
        }
    }
}

private struct MapCanvas: View {
    let entries: [DiskEntry]
    let mode: DiskColorMode
    @Binding var hovered: DiskEntry?
    let selected: String?
    let open: (DiskEntry) -> Void
    let actions: TileActions

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
        let color = entry.map { DiskPalette.color(for: $0, mode: mode) } ?? Color.gray
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 5, style: .continuous).fill(color.opacity(hovered?.id == tile.id ? 0.95 : 0.78))
            if selected == tile.id { RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.white, lineWidth: 2) }
            if r.width > 70, r.height > 34 {
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry?.name ?? "Smaller items").font(.system(size: 11, weight: .semibold)).lineLimit(1)
                    if let entry { Text(ByteFormat.size(Double(entry.size))).font(.system(size: 10)).opacity(0.85) }
                }.foregroundStyle(.white).padding(6)
            }
        }
        .frame(width: max(r.width, 0), height: max(r.height, 0))
        .position(x: r.midX, y: r.midY)
        .animation(.easeInOut(duration: 0.15), value: hovered?.id)
        .onHover { inside in if inside { hovered = entry } else if hovered?.id == tile.id { hovered = nil } }
        .onTapGesture { if let entry, entry.isFolder, !entry.isLink { open(entry) } }
        .contextMenu {
            if let entry {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
                Button("Preview") { actions.preview(entry) }
                if entry.isFolder, !entry.isLink { Button("Look Inside") { open(entry) } }
                Button("Add to Collector") { actions.collect(entry) }
                Divider()
                Button("Move to Trash…", role: .destructive) { actions.trash(entry) }
            }
        }
    }
}

/// The round alternative to the treemap: one ring, each arc as wide as the item is big. Click an arc to look inside a folder.
private struct SunburstCanvas: View {
    let entries: [DiskEntry]
    let mode: DiskColorMode
    @Binding var hovered: DiskEntry?
    @Binding var selected: String?
    let open: (DiskEntry) -> Void

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height) - 16
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let outer = side / 2, inner = outer * 0.38
            let arcs = Sunburst.arcs(entries.map { ($0.id, Double($0.size)) })
            ZStack {
                Canvas { context, _ in
                    for arc in arcs {
                        guard let entry = entries.first(where: { $0.id == arc.id }) else { continue }
                        var path = Path()
                        // Arcs start at the top and run clockwise; SwiftUI's angles start at the right.
                        let a0 = Angle(radians: arc.start - .pi / 2), a1 = Angle(radians: arc.end - .pi / 2)
                        path.addArc(center: center, radius: outer, startAngle: a0, endAngle: a1, clockwise: false)
                        path.addArc(center: center, radius: inner, startAngle: a1, endAngle: a0, clockwise: true)
                        path.closeSubpath()
                        let lit = hovered?.id == arc.id || selected == arc.id
                        context.fill(path, with: .color(DiskPalette.color(for: entry, mode: mode).opacity(lit ? 0.98 : 0.78)))
                        context.stroke(path, with: .color(Color(nsColor: .windowBackgroundColor)), lineWidth: 1.5)
                    }
                }
                VStack(spacing: 2) {
                    if let h = hovered {
                        Text(h.name).font(.headline).lineLimit(2).multilineTextAlignment(.center)
                        Text(ByteFormat.size(Double(h.size))).font(.callout).foregroundStyle(.secondary)
                    } else {
                        Text(ByteFormat.size(Double(entries.reduce(0) { $0 + $1.size }))).font(.title3.weight(.semibold))
                        Text("in this folder").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(width: inner * 1.6)
                .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p):
                    let id = Sunburst.hit(p, center: center, inner: inner, outer: outer, in: arcs)?.id
                    hovered = entries.first { $0.id == id }
                case .ended: hovered = nil
                }
            }
            .onTapGesture { if let e = hovered { selected = e.id; if e.isFolder, !e.isLink { open(e) } } }
        }
        .padding(8)
    }
}
