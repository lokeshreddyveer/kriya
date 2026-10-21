import AppKit

/// Runs a saved action when the pointer rests in a screen corner. The pointer has to stay there for the dwell time, and
/// leave before the same corner can fire again, so passing through a corner on the way to a menu does nothing.
final class HotCorners {
    private let store: ScreenToolsStore
    private let run: (String) -> Void
    private var monitor: Any?
    private var current: ScreenCorner?
    private var pending: DispatchWorkItem?
    private var fired = false

    init(store: ScreenToolsStore, run: @escaping (String) -> Void) {
        self.store = store
        self.run = run
    }

    /// Starts or stops watching to match the settings.
    func apply() {
        let config = store.current
        if config.hotCornersEnabled, !config.corners.isEmpty {
            guard monitor == nil else { return }
            monitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in self?.moved() }
        } else {
            stop()
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        cancel()
        current = nil
        fired = false
    }

    private func cancel() {
        pending?.cancel()
        pending = nil
    }

    private func moved() {
        let config = store.current
        let point = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) else { return }
        // AppKit's y grows upward; the corner maths want it growing downward.
        let x = Double(point.x - screen.frame.minX)
        let y = Double(screen.frame.maxY - point.y)
        let corner = screenCornerAt(x: x, y: y, width: Double(screen.frame.width), height: Double(screen.frame.height), size: config.cornerSize)
        guard corner != current else { return }
        current = corner
        fired = false
        cancel()
        guard let corner, let binding = config.corners.first(where: { $0.corner == corner }) else { return }
        // With keys required, the corner counts only while they are held.
        let held = Self.heldBits()
        guard binding.modifiers == 0 || held == binding.modifiers else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.fired, self.current == corner else { return }
            self.fired = true
            self.run(binding.actionId)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(config.cornerDwellMs) / 1000, execute: work)
    }

    private static func heldBits() -> UInt64 {
        KeyModifiers.bits(from: NSEvent.modifierFlags)
    }
}
