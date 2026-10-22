import AppKit

/// Resting the pointer over a window brings it to the front, without a click. Moving on cancels it, nothing happens while
/// a button is held (a drag), and an app that is excluded in the window settings is left alone.
final class FocusFollowsMouse {
    private let store: WindowStore
    private var monitor: Any?
    private var pending: DispatchWorkItem?

    init(store: WindowStore) {
        self.store = store
    }

    /// Starts or stops watching to match the setting.
    func apply() {
        if store.currentConfig.focusFollowsMouse {
            guard monitor == nil else { return }
            monitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in self?.moved() }
        } else {
            stop()
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        pending?.cancel()
        pending = nil
    }

    private func moved() {
        pending?.cancel()
        let delay = Double(store.currentConfig.focusDelayMs) / 1000
        let work = DispatchWorkItem { [weak self] in self?.settle() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func settle() {
        guard AXIsProcessTrusted(), NSEvent.pressedMouseButtons == 0 else { return }
        let config = store.currentConfig
        let point = DisplayManager.mouseLocation()
        guard let window = AXWindow.at(point), window.isStandard, !window.isFullScreen,
              window.appID != Bundle.main.bundleIdentifier, !config.isExcluded(appId: window.appID) else { return }
        // Already in front: nothing to do, and a window that is behind another of the same app is left to the person.
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier != window.pid else { return }
        window.raise()
    }
}
