#if DEBUG
import AppKit
import SwiftUI

/// Debug builds only. With `KRIYA_SHOT_DIR` set, Kriya renders the menu-bar popover and every settings pane to PNG
/// files, in light and dark, then quits. Used to review the interface without touching the screen.
enum DesignShots {
    static func runIfRequested(env: AppEnvironment, settings: SettingsWindowController?, show: @escaping (SettingsPane?) -> Void) {
        guard let path = ProcessInfo.processInfo.environment["KRIYA_SHOT_DIR"] else { return }
        let root = URL(fileURLWithPath: path)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            Task { @MainActor in
                for (name, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", NSAppearance.Name.aqua)] {
                    NSApp.appearance = NSAppearance(named: appearance)
                    let dir = root.appendingPathComponent(name)
                    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    capturePopover(env: env, to: dir.appendingPathComponent("popover.png"))
                    captureSoundPopover(env: env, to: dir.appendingPathComponent("soundpopover.png"))
                    captureClipboardPanel(env: env, to: dir.appendingPathComponent("quickpaste.png"))
                    captureSwitcher(to: dir.appendingPathComponent("switcher.png"))
                    await captureLauncher(env: env, into: dir)
                    let only = ProcessInfo.processInfo.environment["KRIYA_SHOT_PANES"]?.split(separator: ",").map(String.init)
                    for pane in SettingsPane.allCases where only == nil || only!.contains(pane.rawValue) {
                        show(pane)
                        try? await Task.sleep(nanoseconds: 900_000_000)
                        guard let window = settings?.window else { continue }
                        snap(window, to: dir.appendingPathComponent("\(pane.rawValue).png"))
                        await snapScrolled(window, to: dir.appendingPathComponent("\(pane.rawValue)-bottom.png"))
                        // Visit every tab of a pane that has them, and every tab inside those tabs (tabs inside tabs are found by
                        // looking again after each choice), and each screen scrolled to its end.
                        if let control = segmentedControls(in: window.contentView).first {
                            for index in 0..<control.segmentCount {
                                if index > 0 { await choose(index, in: control) }
                                if index > 0 { snap(window, to: dir.appendingPathComponent("\(pane.rawValue)-\(index).png")) }
                                await snapScrolled(window, to: dir.appendingPathComponent("\(pane.rawValue)-\(index)-bottom.png"))
                                // Controls other than the pane's own tab bar are nested tab bars.
                                let nested = segmentedControls(in: window.contentView).filter { $0 !== control && $0.segmentCount > 1 }
                                for (n, inner) in nested.enumerated() {
                                    for j in 0..<inner.segmentCount where j != inner.selectedSegment || j > 0 {
                                        await choose(j, in: inner)
                                        snap(window, to: dir.appendingPathComponent("\(pane.rawValue)-\(index)-nested\(n)-\(j).png"))
                                    }
                                }
                            }
                        }
                    }
                }
                NSApp.terminate(nil)
            }
        }
    }

    /// Every segmented control in the window, in the order they are met (the pane's own tab bar first).
    private static func segmentedControls(in view: NSView?) -> [NSSegmentedControl] {
        guard let view else { return [] }
        var found: [NSSegmentedControl] = []
        if let control = view as? NSSegmentedControl { found.append(control) }
        for sub in view.subviews { found += segmentedControls(in: sub) }
        return found
    }

    private static func choose(_ index: Int, in control: NSSegmentedControl) async {
        control.selectedSegment = index
        if let action = control.action { NSApp.sendAction(action, to: control.target, from: control) }
        try? await Task.sleep(nanoseconds: 600_000_000)
    }

    /// The window with its longest scrolling area moved to the end, so content below the fold is looked at too. Skipped when nothing scrolls.
    private static func snapScrolled(_ window: NSWindow, to url: URL) async {
        func scrollViews(_ view: NSView?) -> [NSScrollView] {
            guard let view else { return [] }
            return (view as? NSScrollView).map { [$0] + view.subviews.flatMap { scrollViews($0) } } ?? view.subviews.flatMap { scrollViews($0) }
        }
        guard let scroll = scrollViews(window.contentView).max(by: { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }),
              let document = scroll.documentView, document.frame.height > scroll.contentView.bounds.height + 40 else { return }
        let top = scroll.contentView.bounds.origin
        scroll.contentView.scroll(to: NSPoint(x: top.x, y: document.isFlipped ? document.frame.height - scroll.contentView.bounds.height : 0))
        scroll.reflectScrolledClipView(scroll.contentView)
        try? await Task.sleep(nanoseconds: 400_000_000)
        snap(window, to: url)
        scroll.contentView.scroll(to: top)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private static func capturePopover(env: AppEnvironment, to url: URL) {
        let host = NSHostingController(rootView: PopoverView(openSettings: { _ in }).injecting(env))
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.borderless]
        window.appearance = NSApp.appearance
        window.backgroundColor = .windowBackgroundColor
        window.setFrameOrigin(NSPoint(x: 200, y: 200))
        window.orderFrontRegardless()
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        snap(window, to: url)
        window.orderOut(nil)
    }

    private static func captureSoundPopover(env: AppEnvironment, to url: URL) {
        env.soundMixer.refresh()
        // Sample apps in a throwaway preference suite, so the picture shows favorites, a boost and a mute without touching real settings.
        let suite = UserDefaults(suiteName: "kriya-shot-\(UUID().uuidString)")!
        let engine = AppAudioEngine(defaults: suite)
        engine.setFavorite("com.apple.Safari", true)
        engine.setFavorite("com.apple.Music", true)
        engine.setFavorite("com.spotify.client", true)
        engine.update("com.apple.Safari") { $0.volume = 0.7 }
        engine.update("com.apple.Music") { $0.volume = 1 }
        engine.update("com.spotify.client") { $0.muted = true; $0.volume = 0.5 }
        engine.refresh()
        // Closed, and with an app's effects open, at the popover's real fixed size.
        for (suffix, open) in [("", nil), ("-effects", "com.apple.Safari")] as [(String, String?)] {
            let host = NSHostingController(rootView: SoundPopoverView(startWithEffects: open).environmentObject(engine).environmentObject(env.soundMixer).environmentObject(QuickConfigStore(engine: engine, defaults: suite)))
            host.sizingOptions = []
            let window = NSWindow(contentViewController: host)
            window.styleMask = [.borderless]
            window.setContentSize(NSSize(width: SoundPopoverView.width, height: SoundPopoverView.height))
            window.appearance = NSAppearance(named: .darkAqua)
            window.backgroundColor = .black
            window.setFrameOrigin(NSPoint(x: 200, y: 100))
            window.orderFrontRegardless()
            RunLoop.current.run(until: Date().addingTimeInterval(1.0))
            snap(window, to: URL(fileURLWithPath: url.path.replacingOccurrences(of: ".png", with: suffix + ".png")))
            window.orderOut(nil)
        }
    }

    /// The quick paste panel with sample clips. Only ever with a throwaway data folder, so real history is never touched.
    private static func captureClipboardPanel(env: AppEnvironment, to url: URL) {
        guard ProcessInfo.processInfo.environment["KRIYA_DATA_DIR"] != nil else { return }
        func clip(_ text: String, app: String) -> NewClip {
            NewClip(text: text, rich: nil, richFormat: nil, image: nil, imageFormat: nil, imageWidth: nil, imageHeight: nil, files: [], sourceApp: app, concealed: false)
        }
        let image = NSImage(size: NSSize(width: 320, height: 180), flipped: false) { rect in
            NSGradient(colors: [NSColor(srgbRed: 0.35, green: 0.5, blue: 0.7, alpha: 1), NSColor(srgbRed: 0.8, green: 0.6, blue: 0.4, alpha: 1)])?.draw(in: rect, angle: 35)
            return true
        }
        var png: Data?
        if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) { png = rep.representation(using: .png, properties: [:]) }
        let clips: [NewClip] = [
            clip("Meeting notes: ship the menu bar window redesign this week, then look at the clipboard panel.", app: "com.apple.Notes"),
            clip("func greet(name: String) -> String {\n    return \"Hello, \\(name)!\"\n}", app: "com.apple.dt.Xcode"),
            clip("https://developer.apple.com/documentation/swiftui/menubarextra", app: "com.apple.Safari"),
            NewClip(text: nil, rich: nil, richFormat: nil, image: png, imageFormat: "png", imageWidth: 320, imageHeight: 180, files: [], sourceApp: "com.apple.finder", concealed: false),
            NewClip(text: nil, rich: nil, richFormat: nil, image: nil, imageFormat: nil, imageWidth: nil, imageHeight: nil, files: ["/System/Applications/Notes.app", "/System/Applications/Calendar.app"], sourceApp: "com.apple.finder", concealed: false),
            clip("ann@example.com", app: "com.apple.mail"),
        ]
        for item in clips { _ = env.clipboard.store.record(item) }
        let model = QuickClipModel(store: env.clipboard.store)
        model.open()
        model.select(0)
        let view = QuickAccessView(model: model, store: env.clipboard.store, onChoose: { _, _ in }, onClose: {})
        let host = NSHostingController(rootView: view.injecting(env))
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.borderless]
        window.setContentSize(NSSize(width: 420, height: 500))
        window.backgroundColor = .clear
        window.setFrameOrigin(NSPoint(x: 240, y: 240))
        window.orderFrontRegardless()
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        snap(window, to: url)
        model.select(3)
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        snap(window, to: url.deletingLastPathComponent().appendingPathComponent("quickpaste-image.png"))
        window.orderOut(nil)
    }

    /// The launcher in four states: opening list, a chip with a query, a typed search, and selected-text actions.
    @MainActor
    private static func captureLauncher(env: AppEnvironment, into dir: URL) async {
        let palette = env.keyboard.palette
        func settle(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
        func snapPanel(_ name: String) {
            guard let window = palette.debugWindow else { return }
            snap(window, to: dir.appendingPathComponent(name))
        }
        palette.show()
        await settle(0.9)
        snapPanel("launcher-start.png")
        palette.model.query = "gh "
        await settle(0.4)
        palette.model.query = "swift concurrency"
        await settle(0.5)
        snapPanel("launcher-chip.png")
        palette.model.query = "#ff8800"
        await settle(0.5)
        snapPanel("launcher-color.png")
        palette.model.query = "5 km to mi"
        await settle(0.5)
        snapPanel("launcher-convert.png")
        palette.close()
        palette.show(selection: "the quick brown fox jumps over the lazy dog")
        await settle(0.9)
        snapPanel("launcher-selection.png")
        palette.close()
    }

    /// The window switcher's cards with sample windows, drawn on a plain backdrop so the glass shows.
    private static func captureSwitcher(to url: URL) {
        let apps: [(String, String, String, Bool)] = [
            ("Safari", "Kriya on GitHub", "/Applications/Safari.app", false), ("Xcode", "WindowSwitcher.swift", "/Applications/Xcode.app", false),
            ("Notes", "Ideas", "/System/Applications/Notes.app", false), ("Terminal", "zsh", "/System/Applications/Utilities/Terminal.app", false),
            ("Mail", "Inbox", "/System/Applications/Mail.app", true), ("Finder", "Downloads", "/System/Library/CoreServices/Finder.app", false),
            ("Calendar", "October", "/System/Applications/Calendar.app", false),
        ]
        let withPictures = ProcessInfo.processInfo.environment["KRIYA_SHOT_SWITCHER"] != "plain"
        func picture(_ index: Int) -> NSImage {
            NSImage(size: NSSize(width: 440, height: 273), flipped: false) { rect in
                let hue = CGFloat(index) / 8
                NSGradient(colors: [NSColor(hue: hue, saturation: 0.35, brightness: 0.9, alpha: 1), NSColor(hue: hue + 0.08, saturation: 0.5, brightness: 0.55, alpha: 1)])?.draw(in: rect, angle: 60)
                NSColor.white.withAlphaComponent(0.85).setFill()
                NSBezierPath(roundedRect: NSRect(x: 0, y: rect.height - 26, width: rect.width, height: 26), xRadius: 0, yRadius: 0).fill()
                return true
            }
        }
        let cards = apps.enumerated().map { index, app in
            SwitcherCardData(id: "\(index)", appName: app.0, title: app.1, icon: NSWorkspace.shared.icon(forFile: app.2), thumbnail: withPictures ? picture(index) : nil, isMinimized: app.3)
        }
        let size = SwitcherLayout.size(count: cards.count, maxWidth: 1400)
        let columns = SwitcherLayout.columns(count: cards.count, maxWidth: 1400)
        let host = NSHostingController(rootView: SwitcherCardsView(cards: cards, selected: 1, columns: columns).frame(width: size.width, height: size.height))
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.borderless]
        window.setContentSize(size)
        window.backgroundColor = .clear
        window.setFrameOrigin(NSPoint(x: 120, y: 160))
        window.orderFrontRegardless()
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        snap(window, to: url)
        window.orderOut(nil)
    }

    /// The real window as macOS draws it, including the title bar and sidebar material.
    private static func snap(_ window: NSWindow, to url: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", String(window.windowNumber), url.path]
        try? process.run()
        process.waitUntilExit()
    }
}
#endif
