import AppKit
import SwiftUI

/// Draw a window layout: drag boxes on a picture of a display, give each box an app, and choose what happens to every other
/// window when the layout is used.
struct LayoutDesignerView: View {
    let existing: SavedLayout?
    let displays: [DisplayInfo]
    let displayKey: String
    let onSave: (SavedLayout) -> Void
    let onCancel: () -> Void

    @State private var name: String
    @State private var displayID: String
    @State private var regions: [DesignRegion]
    /// Boxes on displays other than the one being drawn, kept as they are.
    private let otherEntries: [LayoutEntry]
    @State private var selected: UUID?
    @State private var grid = 12
    @State private var unplaced: UnplacedPolicy
    @State private var launchMissing: Bool
    @State private var drawing: CGRect?
    @State private var starts: [UUID: CGRect] = [:]

    init(existing: SavedLayout?, displays: [DisplayInfo], displayKey: String, onSave: @escaping (SavedLayout) -> Void, onCancel: @escaping () -> Void) {
        self.existing = existing
        self.displays = displays
        self.displayKey = displayKey
        self.onSave = onSave
        self.onCancel = onCancel
        let firstShown = existing?.entries.first.flatMap { entry in displays.first { $0.id == entry.displayId }?.id }
        let start = firstShown ?? displays.first { $0.isMain }?.id ?? displays.first?.id ?? ""
        _name = State(initialValue: existing?.name ?? "")
        _displayID = State(initialValue: start)
        _regions = State(initialValue: LayoutDesign.regions(from: existing?.entries ?? [], displayID: start))
        otherEntries = (existing?.entries ?? []).filter { $0.displayId != start }
        _unplaced = State(initialValue: existing?.unplaced ?? .leave)
        _launchMissing = State(initialValue: existing?.launchMissing ?? false)
    }

    private var display: DisplayInfo? { displays.first { $0.id == displayID } }
    private var aspect: CGFloat {
        guard let area = display?.area, area.width > 0, area.height > 0 else { return 16.0 / 10.0 }
        return CGFloat(area.width / area.height)
    }
    private var problem: String? { LayoutDesign.problem(name: name, regions: regions) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            canvas
            regionList
            policy
            footer
        }
        .padding(20)
        .frame(minWidth: 720, minHeight: 640)
    }

    // MARK: Pieces

    private var header: some View {
        HStack(spacing: 10) {
            TextField("Layout name", text: $name).textFieldStyle(.roundedBorder).frame(maxWidth: 240)
            if displays.count > 1 {
                Picker("Display", selection: $displayID) { ForEach(displays) { Text($0.name).tag($0.id) } }.frame(maxWidth: 220)
                    .onChange(of: displayID) { _, _ in selected = nil }
            }
            Picker("Snap", selection: $grid) {
                Text("Off").tag(0); Text("Coarse").tag(8); Text("Medium").tag(12); Text("Fine").tag(24)
            }
            .frame(maxWidth: 170)
            Menu {
                ForEach(LayoutDesign.Template.allCases) { template in
                    Button(template.rawValue) { apply(template) }
                }
            } label: { Label("Start From…", systemImage: "square.grid.2x2") }
            .menuStyle(.borderlessButton).fixedSize()
            Spacer()
        }
    }

    private var canvas: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.25), lineWidth: 1))
                    .contentShape(Rectangle())
                    .gesture(drawGesture(size: size))
                if regions.isEmpty && drawing == nil {
                    Text("Drag on the display to draw a box. Each box holds one app's window.")
                        .font(.callout).foregroundStyle(.secondary).frame(width: size.width, height: size.height)
                }
                ForEach(regions) { region in box(region, size: size) }
                if let drawing {
                    Rectangle().fill(Theme.accent.opacity(0.2))
                        .overlay(Rectangle().strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3])))
                        .frame(width: drawing.width * size.width, height: drawing.height * size.height)
                        .offset(x: drawing.minX * size.width, y: drawing.minY * size.height)
                        .allowsHitTesting(false)
                }
            }
            .coordinateSpace(name: "canvas")
        }
        .aspectRatio(aspect, contentMode: .fit)
        .frame(maxHeight: 320)
        .frame(maxWidth: .infinity)
    }

    private func drawGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named("canvas"))
            .onChanged { value in
                drawing = LayoutDesign.rect(from: value.startLocation, to: value.location, in: size, grid: grid)
            }
            .onEnded { value in
                let made = LayoutDesign.rect(from: value.startLocation, to: value.location, in: size, grid: grid)
                drawing = nil
                guard made.width >= LayoutDesign.minimumSize, made.height >= LayoutDesign.minimumSize else { return }
                let region = DesignRegion(rect: made)
                withAnimation(.smooth(duration: 0.18)) {
                    regions.append(region)
                    selected = region.id
                }
            }
    }

    private func box(_ region: DesignRegion, size: CGSize) -> some View {
        let on = selected == region.id
        let rect = CGRect(x: region.rect.minX * size.width, y: region.rect.minY * size.height, width: region.rect.width * size.width, height: region.rect.height * size.height)
        return ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.accent.opacity(on ? 0.34 : 0.2))
            RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.accent.opacity(on ? 0.95 : 0.6), lineWidth: on ? 2 : 1)
            VStack(spacing: 3) {
                if !region.appID.isEmpty, let icon = Self.icon(for: region.appID) { Image(nsImage: icon).resizable().frame(width: 26, height: 26) }
                Text(region.appID.isEmpty ? "Choose an app" : AppChoice.name(for: region.appID))
                    .font(.system(size: 11, weight: .medium)).lineLimit(1).minimumScaleFactor(0.7)
                    .foregroundStyle(region.appID.isEmpty ? Color.secondary : Color.primary)
            }
            .padding(4)
            if on { handles(region, size: size) }
        }
        .frame(width: rect.width, height: rect.height)
        .contentShape(Rectangle())
        .offset(x: rect.minX, y: rect.minY)
        .gesture(
            DragGesture(minimumDistance: 2, coordinateSpace: .named("canvas"))
                .onChanged { value in
                    if starts[region.id] == nil { starts[region.id] = region.rect; selected = region.id }
                    guard let start = starts[region.id], let index = regions.firstIndex(where: { $0.id == region.id }) else { return }
                    let delta = CGSize(width: value.translation.width / size.width, height: value.translation.height / size.height)
                    regions[index].rect = LayoutDesign.moved(start, by: delta, grid: grid)
                }
                .onEnded { _ in starts[region.id] = nil }
        )
        .onTapGesture { selected = region.id }
    }

    private func handles(_ region: DesignRegion, size: CGSize) -> some View {
        let corners: [(LayoutDesign.Corner, Alignment)] = [(.topLeft, .topLeading), (.topRight, .topTrailing), (.bottomLeft, .bottomLeading), (.bottomRight, .bottomTrailing)]
        return ZStack {
            ForEach(corners.indices, id: \.self) { index in
                let (corner, alignment) = corners[index]
                Circle().fill(Theme.accent).frame(width: 11, height: 11)
                    .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1.5))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
                    .offset(x: alignment == .topLeading || alignment == .bottomLeading ? -5 : 5, y: alignment == .topLeading || alignment == .topTrailing ? -5 : 5)
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .named("canvas"))
                            .onChanged { value in
                                if starts[region.id] == nil { starts[region.id] = region.rect }
                                guard let start = starts[region.id], let at = regions.firstIndex(where: { $0.id == region.id }) else { return }
                                let point = CGPoint(x: value.location.x / size.width, y: value.location.y / size.height)
                                regions[at].rect = LayoutDesign.resized(start, corner: corner, to: point, grid: grid)
                            }
                            .onEnded { _ in starts[region.id] = nil }
                    )
            }
        }
    }

    private var regionList: some View {
        VStack(alignment: .leading, spacing: 6) {
            if regions.isEmpty {
                Text("No boxes yet.").font(.callout).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(regions) { region in row(region) }
                }
            }
            .frame(maxHeight: 130)
            let overlapping = LayoutDesign.overlaps(regions)
            if !overlapping.isEmpty {
                Label("\(overlapping.count) pair\(overlapping.count == 1 ? "" : "s") of boxes overlap. That is allowed: the later window sits on top.", systemImage: "square.on.square")
                    .font(.caption).foregroundStyle(Theme.warn)
            }
        }
    }

    private func row(_ region: DesignRegion) -> some View {
        let on = selected == region.id
        return HStack(spacing: 8) {
            Menu {
                ForEach(Self.runningApps(), id: \.id) { app in Button(app.name) { setApp(app.id, for: region.id) } }
                Divider()
                Button("Other App…") { if let id = AppChoice.choose(prompt: "Use") { setApp(id, for: region.id) } }
            } label: {
                HStack(spacing: 6) {
                    if !region.appID.isEmpty, let icon = Self.icon(for: region.appID) { Image(nsImage: icon).resizable().frame(width: 18, height: 18) }
                    Text(region.appID.isEmpty ? "Choose an app…" : AppChoice.name(for: region.appID)).lineLimit(1)
                }
                .frame(minWidth: 170, alignment: .leading)
            }
            .menuStyle(.borderlessButton).fixedSize()
            TextField("Window title (optional)", text: Binding(
                get: { regions.first { $0.id == region.id }?.title ?? "" },
                set: { new in if let index = regions.firstIndex(where: { $0.id == region.id }) { regions[index].title = new } }
            ))
            .textFieldStyle(.roundedBorder)
            Text("\(Int((region.rect.width * 100).rounded()))% × \(Int((region.rect.height * 100).rounded()))%").font(.caption).foregroundStyle(.secondary)
            Button(role: .destructive) { remove(region.id) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(on ? Theme.accent.opacity(0.14) : Color.primary.opacity(0.04)))
        .contentShape(Rectangle())
        .onTapGesture { selected = region.id }
    }

    private var policy: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Other windows", selection: $unplaced) {
                Text("Leave them").tag(UnplacedPolicy.leave)
                Text("Minimize them").tag(UnplacedPolicy.minimize)
                Text("Hide their apps").tag(UnplacedPolicy.hide)
                Text("Close them").tag(UnplacedPolicy.close)
            }
            .frame(maxWidth: 360)
            if unplaced == .close {
                Label("Closing asks each window to close like its own close button, so an app with unsaved work will ask first. You are asked to confirm each time the layout is used.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(Theme.warn)
            } else if unplaced == .hide {
                Text("An app is hidden only if none of its windows are in the layout.").font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Open apps in the layout that are not running, and place them when their window appears", isOn: $launchMissing)
        }
    }

    private var footer: some View {
        HStack {
            if let problem { Text(problem).font(.callout).foregroundStyle(.secondary) }
            Spacer()
            Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
            Button("Save Layout", action: save).keyboardShortcut(.defaultAction).disabled(problem != nil)
        }
    }

    // MARK: Actions

    private func apply(_ template: LayoutDesign.Template) {
        withAnimation(.smooth(duration: 0.2)) {
            regions = template.rects.map { DesignRegion(rect: $0) }
            selected = regions.first?.id
        }
    }

    private func setApp(_ id: String, for region: UUID) {
        guard let index = regions.firstIndex(where: { $0.id == region }) else { return }
        regions[index].appID = id
    }

    private func remove(_ id: UUID) {
        withAnimation(.smooth(duration: 0.18)) { regions.removeAll { $0.id == id } }
        if selected == id { selected = nil }
    }

    private func save() {
        guard problem == nil else { return }
        let entries = LayoutDesign.entries(from: regions, displayID: displayID) + otherEntries
        onSave(SavedLayout(
            id: existing?.id ?? UUID().uuidString, name: name.trimmingCharacters(in: .whitespaces),
            displayKey: existing?.displayKey ?? displayKey, isAuto: false, createdAt: SystemInfo.nowSeconds,
            entries: entries, unplaced: unplaced, launchMissing: launchMissing
        ))
    }

    // MARK: Apps

    private static func runningApps() -> [(id: String, name: String)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .compactMap { app in app.bundleIdentifier.map { ($0, app.localizedName ?? $0) } }
            .sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
    }

    private static func icon(for bundleID: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}
