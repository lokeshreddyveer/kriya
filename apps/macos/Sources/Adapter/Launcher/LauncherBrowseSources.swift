import AppKit

/// Bookmarks from the browsers on this Mac, read from their files and kept only in memory.
final class BookmarkIndex {
    private(set) var all: [Bookmark] = []
    private var loadedAt: Date?
    private var loading = false

    private static let chromiumFolders: [(name: String, path: String)] = [
        ("Chrome", "Google/Chrome"), ("Brave", "BraveSoftware/Brave-Browser"), ("Edge", "Microsoft Edge"), ("Arc", "Arc/User Data"), ("Vivaldi", "Vivaldi")
    ]

    /// Loads in the background if the list is old. Safari's file is protected, so it is read only if Kriya was allowed Full Disk Access.
    func refreshIfNeeded() {
        if let loadedAt, Date().timeIntervalSince(loadedAt) < 120 { return }
        guard !loading else { return }
        loading = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var found: [Bookmark] = []
            let fm = FileManager.default
            let support = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
            for (name, path) in Self.chromiumFolders {
                let base = support.appendingPathComponent(path)
                for profile in (try? fm.contentsOfDirectory(atPath: base.path)) ?? [] where profile == "Default" || profile.hasPrefix("Profile ") {
                    if let data = fm.contents(atPath: base.appendingPathComponent(profile).appendingPathComponent("Bookmarks").path) { found += BookmarkParser.chromium(data, source: name) }
                }
            }
            if let data = fm.contents(atPath: fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Safari/Bookmarks.plist").path) { found += BookmarkParser.safari(data) }
            var seen = Set<String>()
            found = found.filter { seen.insert($0.url).inserted }
            DispatchQueue.main.async {
                self?.all = found
                self?.loadedAt = Date()
                self?.loading = false
            }
        }
    }
}

extension LauncherSources {
    /// Saved pages from your browsers, found by name or address.
    func bookmarkEntries(_ text: String) -> [PaletteEntry] {
        bookmarks.refreshIfNeeded()
        let query = text.trimmingCharacters(in: .whitespaces)
        return BookmarkParser.search(query, in: bookmarks.all).compactMap { b in
            guard let url = URL(string: b.url) else { return nil }
            var e = PaletteEntry(id: "bookmark:\(b.url)", title: b.title, subtitle: "\(b.source) bookmark · \(url.host ?? b.url)", symbol: "bookmark", rememberable: true) { NSWorkspace.shared.open(url) }
            e.category = .web
            return e
        }
    }

    /// "> ls -la" runs in Terminal; "large type Hello" shows big text across the screen.
    func terminalEntries(_ text: String) -> [PaletteEntry] {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        var found: [PaletteEntry] = []
        if trimmed.hasPrefix(">"), trimmed.count > 1 {
            let command = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
            var e = PaletteEntry(id: "terminal:run", title: "Run in Terminal: \(command)", subtitle: "Opens Terminal and runs it", symbol: "terminal", rememberable: false) { TerminalRunner.run(command) }
            e.queryScore = 900
            found.append(e)
        }
        let lower = trimmed.lowercased()
        for prefix in ["large type ", "big ", "lt "] where lower.hasPrefix(prefix) && trimmed.count > prefix.count {
            let body = String(trimmed.dropFirst(prefix.count))
            var e = PaletteEntry(id: "largetype", title: "Show in Large Type", subtitle: String(body.prefix(60)), symbol: "textformat.size", rememberable: false) { DispatchQueue.main.async { LargeType.show(body) } }
            e.queryScore = 850
            found.append(e)
            break
        }
        return found
    }
}

/// Runs a command in a new Terminal window, through a throwaway script file so no automation permission is needed.
enum TerminalRunner {
    static func run(_ command: String) {
        let dir = FileManager.default.temporaryDirectory
        let file = dir.appendingPathComponent("kriya-\(UUID().uuidString).command")
        let script = "#!/bin/zsh\nrm -f \"$0\"\n\(command)\n"
        do {
            try script.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
            NSWorkspace.shared.open([file], withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"), configuration: NSWorkspace.OpenConfiguration())
        } catch {
            Toast().show("Terminal could not be opened.", isError: true)
        }
    }
}

/// Text shown huge on the screen, for reading from across a room or reading out a code. Any key or click closes it.
enum LargeType {
    private static var window: NSWindow?

    static func show(_ text: String) {
        close()
        guard let screen = NSScreen.main else { return }
        let size = NSSize(width: screen.visibleFrame.width * 0.92, height: screen.visibleFrame.height * 0.7)
        let w = KeyWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        w.isOpaque = false; w.backgroundColor = .clear; w.level = .screenSaver; w.hasShadow = true
        w.isReleasedWhenClosed = false
        let box = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        box.material = .hudWindow; box.state = .active; box.blendingMode = .behindWindow
        box.wantsLayer = true; box.layer?.cornerRadius = 28; box.layer?.masksToBounds = true
        let label = NSTextField(wrappingLabelWithString: text)
        label.alignment = .center
        label.textColor = .labelColor
        label.font = .systemFont(ofSize: fontSize(for: text, in: size), weight: .semibold)
        label.frame = box.bounds.insetBy(dx: 40, dy: 30)
        label.autoresizingMask = [.width, .height]
        label.maximumNumberOfLines = 0
        box.addSubview(label)
        w.contentView = box
        w.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.midY - size.height / 2))
        w.alphaValue = 0
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; w.animator().alphaValue = 1 }
    }

    /// Big for a few words, smaller as the text grows, so all of it fits.
    static func fontSize(for text: String, in size: NSSize) -> CGFloat {
        let count = max(text.count, 1)
        let area = size.width * size.height * 0.55
        let estimate = (area / CGFloat(count) / 0.62).squareRoot()
        return min(max(estimate, 28), 260)
    }

    static func close() {
        guard let w = window else { return }
        window = nil
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.12; w.animator().alphaValue = 0 }, completionHandler: { w.orderOut(nil) })
    }

    private final class KeyWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override func keyDown(with event: NSEvent) { LargeType.close() }
        override func mouseDown(with event: NSEvent) { LargeType.close() }
        override func resignKey() { super.resignKey(); LargeType.close() }
    }
}
