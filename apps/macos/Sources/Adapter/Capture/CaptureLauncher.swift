import AppKit
import SwiftUI

/// What the capture icon opens on a click: every way of capturing in groups, with its shortcut beside it, the recording in progress with
/// its controls, the last few captures to open again, and the settings. The long menu stays on a right-click.
struct CaptureLauncherView: View {
    let actions: CaptureOverlayActions
    let recents: [CaptureHistory.Entry]
    let canRestore: Bool
    let run: (String) -> Void
    let showRecent: (CaptureHistory.Entry) -> Void
    let restore: () -> Void

    private struct Item: Identifiable {
        let id: String
        let title: String
        let symbol: String
        let command: String
        var needsIdleRecorder = false
    }

    private let screenshots: [Item] = [
        Item(id: "area", title: "Area", symbol: "viewfinder", command: "capture.region"),
        Item(id: "window", title: "Window", symbol: "macwindow", command: "capture.window"),
        Item(id: "screen", title: "Display", symbol: "display", command: "capture.screen"),
        Item(id: "again", title: "Previous Area", symbol: "arrow.counterclockwise", command: "capture.again"),
        Item(id: "scroll", title: "Scrolling", symbol: "arrow.up.and.down.text.horizontal", command: "capture.scroll"),
        Item(id: "menu", title: "Menu", symbol: "filemenu.and.cursorarrow", command: "capture.menu"),
    ]
    private let recordings: [Item] = [
        Item(id: "rscreen", title: "Screen", symbol: "record.circle", command: "capture.rec.screen", needsIdleRecorder: true),
        Item(id: "rwindow", title: "Window", symbol: "macwindow.badge.plus", command: "capture.rec.window", needsIdleRecorder: true),
        Item(id: "rarea", title: "Area", symbol: "rectangle.dashed.badge.record", command: "capture.record", needsIdleRecorder: true),
        Item(id: "gif", title: "GIF", symbol: "photo.on.rectangle", command: "capture.gif", needsIdleRecorder: true),
    ]
    private let tools: [Item] = [
        Item(id: "ocr", title: "Copy Text", symbol: "text.viewfinder", command: "capture.text"),
        Item(id: "qr", title: "QR Code", symbol: "qrcode.viewfinder", command: "capture.qr"),
        Item(id: "redact", title: "Hide Private", symbol: "eye.slash", command: "capture.redacted"),
        Item(id: "cutout", title: "Cut Out", symbol: "person.crop.rectangle", command: "capture.cutout"),
        Item(id: "ruler", title: "Pixel Ruler", symbol: "ruler", command: "capture.ruler"),
        Item(id: "pin", title: "Pin", symbol: "pin", command: "capture.pin"),
    ]

    private var recording: OverlayRecordingKind { actions.recordingKind() }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if recording != .none { recordingStrip }
            group("Screenshot", screenshots)
            group("Record", recordings)
            group("Text and tools", tools)
            let areas = actions.savedAreas()
            if !areas.isEmpty { savedAreas(areas) }
            if !recents.isEmpty { recentRow }
            footer
        }
        .padding(16)
        .frame(width: 372)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "camera.viewfinder").font(.system(size: 18, weight: .medium)).foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text("Capture").font(.system(size: 15, weight: .semibold))
                Text("Choose what to capture").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Button { run("capture.all") } label: { Label("All-in-One", systemImage: "square.grid.3x3") }
                .controlSize(.small).help("One panel with every kind of capture; press 1 to 9 to choose")
        }
    }

    private var recordingStrip: some View {
        HStack(spacing: 8) {
            Circle().fill(Color.red).frame(width: 8, height: 8)
            Text(recording == .kriya ? "Recording with Kriya" : "Recording with macOS's recorder").font(.system(size: 12, weight: .medium))
            Spacer()
            if recording == .kriya { Button("Pause") { run("capture.rec.pause") }.controlSize(.small) }
            Button("Stop") { run("capture.rec.stop") }.controlSize(.small).buttonStyle(.borderedProminent)
        }
        .padding(10)
        .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func group(_ title: String, _ items: [Item]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(items) { item in
                    let disabled = item.needsIdleRecorder && recording != .none
                    Button { run(item.command) } label: {
                        VStack(spacing: 4) {
                            Image(systemName: item.symbol).font(.system(size: 17)).frame(height: 22)
                            Text(item.title).font(.system(size: 11)).lineLimit(1).minimumScaleFactor(0.8)
                            Text(actions.shortcutText(item.command) ?? " ").font(.system(size: 9, design: .rounded)).foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 62)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .opacity(disabled ? 0.4 : 1)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(disabled)
                    .help(disabled ? "Stop the recording that is running first" : item.title)
                    .accessibilityLabel("\(title): \(item.title)")
                }
            }
        }
    }

    private func savedAreas(_ areas: [(name: String, command: String)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Saved areas").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(areas.enumerated()), id: \.offset) { _, area in
                        Button { run(area.command) } label: {
                            Label(area.name, systemImage: "viewfinder").font(.system(size: 11)).padding(.horizontal, 10).padding(.vertical, 5)
                                .background(Color.primary.opacity(0.06), in: Capsule())
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var recentRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Recent").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                if canRestore { Button("Bring Back Closed") { restore() }.controlSize(.mini) }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(recents) { entry in
                        Button { showRecent(entry) } label: {
                            Group {
                                if entry.isMovie { ZStack { Color.black.opacity(0.7); Image(systemName: "play.fill").foregroundStyle(.white) } }
                                else if let image = NSImage(contentsOfFile: entry.path) { Image(nsImage: image).resizable().scaledToFill() }
                                else { Color.gray.opacity(0.25) }
                            }
                            .frame(width: 76, height: 50).clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
                        }
                        .buttonStyle(.plain)
                        .help(entry.date.formatted(date: .abbreviated, time: .shortened))
                        .accessibilityLabel("Open the capture from \(entry.date.formatted(date: .abbreviated, time: .shortened))")
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Button { actions.openHistory() } label: { Label("History", systemImage: "clock.arrow.circlepath") }
            Button { NSWorkspace.shared.open(actions.captureFolder()) } label: { Label("Folder", systemImage: "folder") }
            Spacer()
            Button { actions.openSettings() } label: { Label("Settings", systemImage: "gearshape") }
        }
        .buttonStyle(.plain).font(.system(size: 11.5)).foregroundStyle(.secondary)
    }
}
