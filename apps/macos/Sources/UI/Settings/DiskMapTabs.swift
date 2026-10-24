import SwiftUI
import UniformTypeIdentifiers

private extension DiskFile {
    var sortDate: Date { modified ?? .distantPast }
    var kindText: String { ext.isEmpty ? "—" : ext }
    var asEntry: DiskEntry { DiskEntry(url: URL(fileURLWithPath: path), name: name, size: allocated, isFolder: false, modified: modified) }
}

private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 8) { content() }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
}

private func bytes(_ n: Int64) -> String { ByteFormat.size(Double(n)) }

// MARK: Largest

/// Every big file under the folder in a table: sort, search, filter, pick several, preview, export, or move to the Trash.
struct DiskLargestTab: View {
    @ObservedObject var scanner: DiskMapScanner
    @ObservedObject var deep: DiskDeepScanner
    @ObservedObject var collector: DiskCollector
    let request: ([DiskEntry]) -> Void

    @State private var query = ""
    @State private var ext = ""
    @State private var minimum: Int64 = 0
    @State private var olderThan = 0
    @State private var selection = Set<DiskFile.ID>()
    @State private var order = [KeyPathComparator(\DiskFile.allocated, order: .reverse)]

    private var base: [DiskFile] { deep.candidates.isEmpty ? deep.largest : deep.candidates }
    private var rows: [DiskFile] {
        Array(DiskFilter.apply(base, query: query, ext: ext, minBytes: minimum, olderThanDays: olderThan == 0 ? nil : olderThan).sorted(using: order).prefix(1000))
    }
    private var chosen: [DiskFile] { rows.filter { selection.contains($0.id) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TextField("Search names and folders", text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                TextField("Kind (pdf)", text: $ext).textFieldStyle(.roundedBorder).frame(width: 90)
                Picker("At least", selection: $minimum) { Text("Any size").tag(Int64(0)); Text("10 MB").tag(Int64(10_000_000)); Text("100 MB").tag(Int64(100_000_000)); Text("1 GB").tag(Int64(1_000_000_000)) }.fixedSize()
                Picker("Not changed for", selection: $olderThan) { Text("Any age").tag(0); Text("30 days").tag(30); Text("6 months").tag(180); Text("1 year").tag(365) }.fixedSize()
                Spacer()
                Button { deep.scan(scanner.current, includeCloud: scanner.includeCloud) } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("Look at files again").disabled(deep.scanning)
            }
            .controlSize(.small)

            if deep.scanning {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Looked at \(deep.visited.formatted()) files in \(deep.root?.lastPathComponent ?? "")…").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Stop") { deep.stop() }.controlSize(.small)
                }
            } else if let at = deep.scannedAt, ScanFreshness.isStale(scannedAt: at) {
                Label("This list is more than 10 minutes old.", systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
            }

            Table(rows, selection: $selection, sortOrder: $order) {
                TableColumn("Name", value: \.name) { f in
                    HStack(spacing: 6) { Image(nsImage: NSWorkspace.shared.icon(forFile: f.path)).resizable().frame(width: 16, height: 16); Text(f.name).lineLimit(1) }
                }
                TableColumn("Disk usage", value: \.allocated) { Text(bytes($0.allocated)).monospacedDigit() }.width(min: 70, ideal: 80)
                TableColumn("Length", value: \.logical) { Text(bytes($0.logical)).monospacedDigit().foregroundStyle(.secondary) }.width(min: 70, ideal: 80)
                TableColumn("Modified", value: \.sortDate) { f in Text(f.modified.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "—").foregroundStyle(.secondary) }.width(min: 80, ideal: 100)
                TableColumn("Kind", value: \.kindText) { Text($0.kindText).foregroundStyle(.secondary) }.width(min: 40, ideal: 60)
                TableColumn("Risk") { f in
                    let v = DiskRisk.classify(f.path)
                    Text(v.level.title).foregroundStyle(DiskPalette.risk(v.level)).help(v.reason)
                }.width(min: 90, ideal: 110)
                TableColumn("Folder") { f in Text(((f.path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head) }
            }
            .frame(minHeight: 360)
            .contextMenu(forSelectionType: DiskFile.ID.self) { ids in
                let files = rows.filter { ids.contains($0.id) }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(files.map { URL(fileURLWithPath: $0.path) }) }
                Button("Preview") { DiskTools.quickLook(files.map { URL(fileURLWithPath: $0.path) }) }
                Button("Add to Collector") { collector.add(files.map(\.asEntry)) }
                Divider()
                Button("Move to Trash…", role: .destructive) { request(files.map(\.asEntry)) }
            } primaryAction: { ids in
                NSWorkspace.shared.activateFileViewerSelecting(rows.filter { ids.contains($0.id) }.map { URL(fileURLWithPath: $0.path) })
            }

            HStack(spacing: 8) {
                Text(selection.isEmpty ? "\(rows.count.formatted()) files · \(bytes(rows.reduce(0) { $0 + $1.allocated })) on disk" : "\(chosen.count) selected · \(bytes(chosen.reduce(0) { $0 + $1.allocated })) on disk").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Preview") { DiskTools.quickLook(chosen.map { URL(fileURLWithPath: $0.path) }) }.disabled(chosen.isEmpty)
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(chosen.map { URL(fileURLWithPath: $0.path) }) }.disabled(chosen.isEmpty)
                Button("Add to Collector") { collector.add(chosen.map(\.asEntry)) }.disabled(chosen.isEmpty)
                Button("Move to Trash…") { request(chosen.map(\.asEntry)) }.disabled(chosen.isEmpty)
                Menu("Export") {
                    Button("CSV…") { export(csv: true) }
                    Button("JSON…") { export(csv: false) }
                }.fixedSize().disabled(rows.isEmpty)
            }
            .controlSize(.small)
            if deep.unreadable > 0 { Text("\(deep.unreadable) place\(deep.unreadable == 1 ? "" : "s") could not be read. Full Disk Access in Advanced lets Kriya see more.").font(.caption).foregroundStyle(.secondary) }
            Text("Disk usage is what a file takes on the disk; Length is how long the file is. \(DiskText.usageNote)").font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .onAppear { if deep.root != scanner.current, !deep.scanning { deep.scan(scanner.current, includeCloud: scanner.includeCloud) } }
    }

    private func export(csv: Bool) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = csv ? "disk-usage.csv" : "disk-usage.json"
        panel.allowedContentTypes = [csv ? .commaSeparatedText : .json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let data = csv ? Data(DiskExport.csv(rows).utf8) : (DiskExport.json(rows) ?? Data())
        do { try data.write(to: url, options: .atomic) } catch { Toast().show("Could not save the file.", isError: true) }
    }
}

// MARK: Cleanup

/// Things worth a look to get room back: caches, developer files, copies, old big files, and a list to gather them in. Nothing is
/// chosen for you; every move goes to the Trash after a question.
struct DiskCleanupTab: View {
    @ObservedObject var scanner: DiskMapScanner
    @ObservedObject var deep: DiskDeepScanner
    @ObservedObject var collector: DiskCollector
    let request: ([DiskEntry]) -> Void

    @State private var devSizes: [String: Int64] = [:]
    @State private var devMeasuring = false
    @State private var groups: [[DiskFile]] = []
    @State private var finding = false
    @State private var foundDuplicates = false
    @State private var cancelFind = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                rebuildable
                developer
                duplicates
                oldAndLarge
                recent
                collectorCard
                Button("Save Cleanup Report…") { saveReport() }.controlSize(.small)
                Text("Kriya never cleans up by itself. \(DiskText.trashNote)").font(.caption).foregroundStyle(.secondary)
            }
            .padding(20)
        }
        .onAppear {
            if deep.root != scanner.current, !deep.scanning { deep.scan(scanner.current, includeCloud: scanner.includeCloud) }
            measureDeveloperPlaces()
        }
    }

    // Likely rebuildable, from this folder's map.
    @ViewBuilder
    private var rebuildable: some View {
        let picks = DiskRisk.cleanupSuggestions(scanner.entries.map { ($0.url.path, $0.size) })
        card {
            HStack {
                Text("Likely rebuildable").font(.headline)
                Spacer()
                if !picks.items.isEmpty {
                    Text("\(bytes(picks.total)) in \(picks.items.count) item\(picks.items.count == 1 ? "" : "s")").font(.callout).foregroundStyle(.secondary)
                    Button("Review & Move to Trash…") { request(picks.items.compactMap { p in scanner.entries.first { $0.url.path == p.path } }) }.controlSize(.small)
                }
            }
            if picks.items.isEmpty {
                Text("Nothing in \(scanner.current.lastPathComponent) looks like a cache or build folder.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(picks.items, id: \.path) { item in
                HStack {
                    Text((item.path as NSString).lastPathComponent).lineLimit(1)
                    Text(DiskRisk.classify(item.path).reason).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Text(bytes(item.size)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            Text("Apps and tools make these again when needed, but check first: an app may be mid-task, and rebuilding can take time.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var developer: some View {
        card {
            HStack {
                Text("Developer files").font(.headline)
                if devMeasuring { ProgressView().controlSize(.small) }
                Spacer()
                Button("Measure Again") { measureDeveloperPlaces(force: true) }.controlSize(.small).disabled(devMeasuring)
            }
            let present = DeveloperPlaces.list.filter { (devSizes[$0.path] ?? 0) > 0 }.sorted { (devSizes[$0.path] ?? 0) > (devSizes[$1.path] ?? 0) }
            if present.isEmpty { Text(devMeasuring ? "Measuring…" : "No developer caches found.").font(.callout).foregroundStyle(.secondary) }
            ForEach(present, id: \.path) { place in
                let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(place.path)
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 1) { Text(place.name); Text(place.note).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Text(bytes(devSizes[place.path] ?? 0)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Image(systemName: "magnifyingglass") }.buttonStyle(.borderless).help("Show in Finder")
                    Button("Move to Trash…") { request([DiskEntry(url: url, name: place.name, size: devSizes[place.path] ?? 0, isFolder: true)]) }.controlSize(.small)
                }
            }
        }
    }

    private var duplicates: some View {
        card {
            HStack {
                Text("Duplicate files").font(.headline)
                Spacer()
                if finding { Button("Stop") { cancelFind = true }.controlSize(.small) }
                else { Button(foundDuplicates ? "Look Again" : "Find Duplicates") { findDuplicates() }.controlSize(.small).disabled(deep.scanning || deep.candidates.isEmpty) }
            }
            if finding { HStack { ProgressView().controlSize(.small); Text("Comparing files with the same size…").font(.caption).foregroundStyle(.secondary) } }
            else if !foundDuplicates { Text(deep.scanning ? "Waiting for the file scan…" : "Compares the contents of files over 1 MB that share a size. Nothing is changed.").font(.callout).foregroundStyle(.secondary) }
            else if groups.isEmpty { Text("No duplicates found in \(deep.root?.lastPathComponent ?? "this folder").").font(.callout).foregroundStyle(.secondary) }
            else {
                Text("\(bytes(DiskDuplicates.reclaimable(groups))) would come back by keeping one copy of each.").font(.callout).foregroundStyle(.secondary)
                ForEach(Array(groups.prefix(12).enumerated()), id: \.offset) { _, group in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("\(group.count) copies · \(bytes(group[0].allocated)) each").font(.callout.weight(.medium))
                            Spacer()
                            Button("Keep First, Trash the Rest…") { request(group.dropFirst().map(\.asEntry)) }.controlSize(.small)
                        }
                        ForEach(group, id: \.path) { f in Text((f.path as NSString).abbreviatingWithTildeInPath).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head) }
                    }
                    Divider()
                }
            }
        }
    }

    private var oldAndLarge: some View {
        let old = Array(DiskFilter.sorted(DiskFilter.apply(deep.candidates, minBytes: 100_000_000, olderThanDays: 365), by: .size).prefix(12))
        return card {
            Text("Large and not changed for a year").font(.headline)
            if old.isEmpty { Text(deep.scanning ? "Looking…" : "No files over 100 MB that have sat untouched for a year.").font(.callout).foregroundStyle(.secondary) }
            ForEach(old) { f in fileRow(f) }
            Text("Age is when a file last changed. A file you open often can still be old.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var recent: some View {
        let cutoff = Date().addingTimeInterval(-7 * 86_400)
        let list = Array(DiskFilter.sorted(deep.candidates.filter { ($0.modified ?? .distantPast) > cutoff && $0.allocated >= 50_000_000 }, by: .size).prefix(8))
        return card {
            Text("Large files from this week").font(.headline)
            if list.isEmpty { Text(deep.scanning ? "Looking…" : "No big files changed in the past week.").font(.callout).foregroundStyle(.secondary) }
            ForEach(list) { f in fileRow(f) }
        }
    }

    private func fileRow(_ f: DiskFile) -> some View {
        HStack {
            Image(nsImage: NSWorkspace.shared.icon(forFile: f.path)).resizable().frame(width: 16, height: 16)
            Text(f.name).lineLimit(1)
            Text(((f.path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            Spacer()
            Text(bytes(f.allocated)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            Button { collector.add([f.asEntry]) } label: { Image(systemName: "tray.and.arrow.down") }.buttonStyle(.borderless).help("Add to Collector")
            Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: f.path)]) } label: { Image(systemName: "magnifyingglass") }.buttonStyle(.borderless).help("Show in Finder")
        }
    }

    private var collectorCard: some View {
        card {
            HStack {
                Text("Collector").font(.headline)
                Spacer()
                if !collector.items.isEmpty {
                    Text("\(collector.items.count) item\(collector.items.count == 1 ? "" : "s") · \(bytes(collector.total))").font(.callout).foregroundStyle(.secondary)
                    Button("Clear") { collector.clear() }.controlSize(.small)
                    Button("Move to Trash…") { request(collector.items) }.controlSize(.small)
                }
            }
            if collector.items.isEmpty { Text("Right-click anything on the Map or in Largest and choose Add to Collector to gather items here, then review them together.").font(.callout).foregroundStyle(.secondary) }
            ForEach(collector.items) { item in
                HStack {
                    Text(item.name).lineLimit(1)
                    Text((item.url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                    Spacer()
                    Text(bytes(item.size)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    Button { collector.remove(item.id) } label: { Image(systemName: "xmark.circle") }.buttonStyle(.borderless).accessibilityLabel("Remove from Collector")
                }
            }
        }
    }

    private func measureDeveloperPlaces(force: Bool = false) {
        guard !devMeasuring, force || devSizes.isEmpty else { return }
        devMeasuring = true
        let home = FileManager.default.homeDirectoryForCurrentUser
        DispatchQueue.global(qos: .utility).async {
            let group = DispatchGroup(), lock = NSLock()
            var found: [String: Int64] = [:]
            for place in DeveloperPlaces.list {
                let url = home.appendingPathComponent(place.path)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    if let n = StorageScanner.size(of: url) { lock.lock(); found[place.path] = n; lock.unlock() }
                    group.leave()
                }
            }
            group.wait()
            DispatchQueue.main.async { withAnimation(.easeInOut(duration: 0.2)) { devSizes = found; devMeasuring = false } }
        }
    }

    private func findDuplicates() {
        finding = true; cancelFind = false
        let candidates = deep.candidates
        DispatchQueue.global(qos: .utility).async {
            let sized = Array(DiskDuplicates.sizeGroups(candidates).prefix(300))
            let result = DiskDuplicates.confirm(sized) { DiskTools.sha256(of: $0.path, cancelled: { cancelFind }) }
            DispatchQueue.main.async { withAnimation(.easeInOut(duration: 0.2)) { groups = result; foundDuplicates = !cancelFind; finding = false } }
        }
    }

    private func saveReport() {
        var text = "# Kriya cleanup report\n\n\(Date().formatted(date: .long, time: .shortened)) · \(scanner.current.path)\n\n"
        let picks = DiskRisk.cleanupSuggestions(scanner.entries.map { ($0.url.path, $0.size) })
        text += "## Likely rebuildable (\(bytes(picks.total)))\n" + picks.items.map { "- \($0.path) — \(bytes($0.size))" }.joined(separator: "\n") + "\n\n"
        text += "## Developer files\n" + DeveloperPlaces.list.compactMap { p in devSizes[p.path].map { "- \(p.name): \(bytes($0))" } }.joined(separator: "\n") + "\n\n"
        text += "## Duplicates (\(bytes(DiskDuplicates.reclaimable(groups))) reclaimable)\n" + groups.prefix(30).map { "- " + $0.map(\.path).joined(separator: " = ") }.joined(separator: "\n") + "\n\n"
        text += "## Collector (\(bytes(collector.total)))\n" + collector.items.map { "- \($0.url.path) — \(bytes($0.size))" }.joined(separator: "\n") + "\n\n"
        text += "_\(DiskText.usageNote)_\n"
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "kriya-cleanup-report.md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try Data(text.utf8).write(to: url, options: .atomic) } catch { Toast().show("Could not save the report.", isError: true) }
    }
}

// MARK: Advanced

/// The disk itself: how full it is, what macOS can give back, snapshots, permissions, scan options and how things changed.
struct DiskAdvancedTab: View {
    @ObservedObject var scanner: DiskMapScanner
    @State private var report: VolumeReport?
    @State private var snapshots: [String] = []
    @State private var loadingSnapshots = false
    @State private var fullDiskAccess = DiskTools.hasFullDiskAccess
    @State private var history: [ScanRecord] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                volumeCard
                snapshotCard
                permissionCard
                optionsCard
                historyCard
            }
            .padding(20)
        }
        .onAppear { refresh() }
    }

    private func refresh() {
        report = DiskTools.volumeReport()
        fullDiskAccess = DiskTools.hasFullDiskAccess
        history = DiskTools.history().filter { $0.path == scanner.current.path }.sorted { $0.date > $1.date }
        loadingSnapshots = true
        DispatchQueue.global(qos: .utility).async {
            let list = DiskTools.localSnapshots()
            DispatchQueue.main.async { withAnimation(.easeInOut(duration: 0.2)) { snapshots = list; loadingSnapshots = false } }
        }
    }

    private var volumeCard: some View {
        card {
            HStack { Text("Startup disk").font(.headline); Spacer(); Button { refresh() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless).accessibilityLabel("Refresh") }
            if let r = report {
                ProgressView(value: r.usedFraction).tint(r.usedFraction > 0.9 ? .red : .accentColor)
                row("Used", bytes(r.used))
                row("Free now", bytes(r.available))
                row("Free if purgeable space is given back", bytes(r.availableForImportant))
                row("Purgeable", bytes(r.purgeable), note: "Room macOS gives back by itself when it is needed (local snapshots, caches). Kriya cannot measure it item by item, and macOS decides when it is released.")
                row("Total", bytes(r.total))
                if scanner.current.path == "/", scanner.total > 0 {
                    row("Not shown in the map", bytes(r.unaccounted(measured: scanner.total)), note: "Hidden space: system data, snapshots, and anything macOS did not let Kriya read. Full Disk Access or an administrator measurement reveals more.")
                }
            } else { Text("The disk could not be read.").foregroundStyle(.secondary) }
        }
    }

    private var snapshotCard: some View {
        card {
            HStack { Text("Local snapshots").font(.headline); if loadingSnapshots { ProgressView().controlSize(.small) } }
            if snapshots.isEmpty { Text(loadingSnapshots ? "Looking…" : "No Time Machine local snapshots on this disk.").font(.callout).foregroundStyle(.secondary) }
            ForEach(snapshots, id: \.self) { name in
                HStack { Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary); Text(SnapshotList.date(of: name).map { $0.formatted(date: .abbreviated, time: .shortened) } ?? name); Spacer() }
            }
            Text("Snapshots keep only what changed, share data with each other, and macOS removes them when room is needed, so their size cannot be added up exactly. To thin them yourself, Terminal's “tmutil thinlocalsnapshots” does it. Kriya only lists them.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var permissionCard: some View {
        card {
            Text("Access").font(.headline)
            HStack {
                Image(systemName: fullDiskAccess ? "checkmark.circle.fill" : "exclamationmark.circle").foregroundStyle(fullDiskAccess ? .green : .orange)
                Text(fullDiskAccess ? "Full Disk Access is on. Kriya can look inside protected folders." : "Full Disk Access is off. Mail, Messages, Safari and some system folders are left out.")
                Spacer()
                if !fullDiskAccess { Button("Open Settings") { DiskTools.openFullDiskAccessSettings() }.controlSize(.small) }
                Button("Check Again") { fullDiskAccess = DiskTools.hasFullDiskAccess }.controlSize(.small)
            }
            Text("Kriya reads sizes only. Turn it on in System Settings ▸ Privacy & Security ▸ Full Disk Access, then measure again.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var optionsCard: some View {
        card {
            Text("Measuring options").font(.headline)
            Toggle("Include cloud folders (iCloud Drive, other providers)", isOn: $scanner.includeCloud)
            Text("Off by default: measuring a cloud folder can download files and take minutes. When on, only the folders that are on this Mac are measured, and files that are just names in the cloud count for nothing.").font(.caption).foregroundStyle(.secondary)
            Toggle("Measure as administrator", isOn: $scanner.asAdministrator)
            Text("Asks for your password once and measures folders Kriya cannot read as itself, such as system folders. It only reads sizes. Use it with Look At ▸ Whole Startup Disk.").font(.caption).foregroundStyle(.secondary)
            Button("Measure \(scanner.current.lastPathComponent.isEmpty ? "Disk" : scanner.current.lastPathComponent) Again") { scanner.scan() }.controlSize(.small).disabled(scanner.scanning)
        }
    }

    private var historyCard: some View {
        card {
            Text("Changes since last time").font(.headline)
            if history.count < 2 {
                Text("Kriya remembers each reading of a folder. Measure \(scanner.current.lastPathComponent) again later and what grew or shrank shows here.").font(.callout).foregroundStyle(.secondary)
            } else {
                let latest = history[0], previous = history[1]
                Text("\(previous.date.formatted(date: .abbreviated, time: .shortened)) → \(latest.date.formatted(date: .abbreviated, time: .shortened)) · \(deltaText(latest.total - previous.total)) overall").font(.callout).foregroundStyle(.secondary)
                let changes = latest.changes(since: previous)
                if changes.isEmpty { Text("Nothing changed by more than 1 MB.").font(.callout).foregroundStyle(.secondary) }
                ForEach(changes.prefix(10), id: \.name) { c in
                    HStack { Text(c.name).lineLimit(1); Spacer(); Text(deltaText(c.delta)).font(.callout.monospacedDigit()).foregroundStyle(c.delta > 0 ? Color.orange : Color.green) }
                }
            }
            if !history.isEmpty { Button("Forget Readings of This Folder") { forget() }.controlSize(.small) }
        }
    }

    private func forget() {
        // The history is only ever the saved size readings, never file lists.
        history = []
        DiskTools.forgetHistory(for: scanner.current.path)
    }

    private func deltaText(_ n: Int64) -> String { (n >= 0 ? "+" : "−") + bytes(abs(n)) }

    private func row(_ title: String, _ value: String, note: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack { Text(title); Spacer(); Text(value).monospacedDigit().foregroundStyle(.secondary) }
            if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
        }
    }
}
