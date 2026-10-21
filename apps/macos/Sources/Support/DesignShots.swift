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
