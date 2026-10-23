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
                    captureClipboardPanel(env: env, to: dir.appendingPathComponent("quickpaste.png"))
                    captureSwitcher(to: dir.appendingPathComponent("switcher.png"))
                    let only = ProcessInfo.processInfo.environment["KRIYA_SHOT_PANES"]?.split(separator: ",").map(String.init)
                    for pane in SettingsPane.allCases where only == nil || only!.contains(pane.rawValue) {
                        show(pane)
                        try? await Task.sleep(nanoseconds: 900_000_000)
                        guard let window = settings?.window else { continue }
                        snap(window, to: dir.appendingPathComponent("\(pane.rawValue).png"))
                        // Visit every tab of a pane that has them.
                        if let control = segmentedControl(in: window.contentView), control.segmentCount > 1 {
                            for index in 1..<control.segmentCount {
                                control.selectedSegment = index
                                if let action = control.action { NSApp.sendAction(action, to: control.target, from: control) }
                                try? await Task.sleep(nanoseconds: 700_000_000)
                                snap(window, to: dir.appendingPathComponent("\(pane.rawValue)-\(index).png"))
                            }
                        }
                    }
                }
                NSApp.terminate(nil)
            }
        }
    }

    private static func segmentedControl(in view: NSView?) -> NSSegmentedControl? {
        guard let view else { return nil }
        if let control = view as? NSSegmentedControl { return control }
        for sub in view.subviews { if let found = segmentedControl(in: sub) { return found } }
        return nil
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
