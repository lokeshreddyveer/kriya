import AppKit

/// Darkens displays with a dark window over each, so the display being recorded stands out. Nothing about the displays themselves is
/// changed (no brightness, no colour tables), so there is nothing that could be left wrong: closing the windows, which also happens when
/// Kriya quits or a display is unplugged, puts the screens back exactly as they were.
final class ScreenDim {
    private var panels: [CGDirectDisplayID: NSPanel] = [:]
    private var observers: [NSObjectProtocol] = []

    var isShowing: Bool { !panels.isEmpty }
    var dimmedDisplays: Set<CGDirectDisplayID> { Set(panels.keys) }

    /// Darkens these displays (replacing any already darkened). A display that is not connected is skipped.
    func show(on displays: [CGDirectDisplayID], opacity: CGFloat = 0.6) {
        hide()
        for id in displays {
            guard let screen = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == id }) else { continue }
            let panel = NSPanel(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
            panel.isOpaque = false
            panel.backgroundColor = NSColor.black.withAlphaComponent(min(max(opacity, 0), 0.9))
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.level = .screenSaver
            panel.sharingType = .none
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            panel.setFrame(screen.frame, display: true)
            panel.orderFrontRegardless()
            panels[id] = panel
        }
        guard !panels.isEmpty else { return }
        // Put back whatever happens: Kriya quits, or the displays change (one was unplugged, so what it covered no longer exists).
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in self?.hide() },
            center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.hide() },
        ]
    }

    /// Takes the dimming away. Safe to call again and again.
    func hide() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        for panel in panels.values { panel.orderOut(nil); panel.close() }
        panels = [:]
    }

    deinit { hide() }

    /// The display being recorded, as far as it can be told now: the one with the window for a window recording, otherwise the one the
    /// pointer is on (which is where Kriya's recorder takes the screen from). Nil if it cannot be told.
    static func recordedDisplay(for source: RecordingSource, target: NSRunningApplication?) -> CGDirectDisplayID? {
        func display(at point: CGPoint) -> CGDirectDisplayID? {
            NSScreen.screens.first { $0.frame.contains(point) }.flatMap { $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID }
        }
        if source == .window, AXIsProcessTrusted(), let frame = AXWindow.focused()?.frame?.cg {
            // Accessibility's frame has its origin at the top left of the main display; the screens' frames are from the bottom left.
            let mainHeight = NSScreen.screens.first?.frame.height ?? 0
            if let found = display(at: CGPoint(x: frame.midX, y: mainHeight - frame.midY)) { return found }
        }
        let pointer = NSEvent.mouseLocation
        return display(at: pointer) ?? (NSScreen.main?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID)
    }

    static func connectedDisplays() -> [CGDirectDisplayID] {
        NSScreen.screens.compactMap { $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID }
    }
}
