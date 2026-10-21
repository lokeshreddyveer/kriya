import AppKit

/// The translucent rectangle that shows where a window will land while it is being dragged to an edge.
/// It never takes clicks, and glides from one target to the next instead of jumping.
final class SnapOverlay {
    private var window: NSWindow?

    /// Shows the preview over a frame given in top-left coordinates.
    func show(_ frame: Rect) {
        let target = DisplayManager.appKitFrame(frame).insetBy(dx: 4, dy: 4)
        let overlay = window ?? makeWindow(at: target)
        window = overlay
        if !overlay.isVisible {
            overlay.setFrame(target, display: false)
            overlay.alphaValue = 0
            overlay.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            overlay.animator().setFrame(target, display: true)
            overlay.animator().alphaValue = 1
        }
    }

    func hide() {
        guard let window, window.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.14
            window.animator().alphaValue = 0
        }, completionHandler: { [weak window] in
            // A new preview may have appeared meanwhile; only hide if it is still fading out.
            if let window, window.alphaValue == 0 { window.orderOut(nil) }
        })
    }

    private func makeWindow(at frame: CGRect) -> NSWindow {
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        let view = NSView()
        view.wantsLayer = true
        view.layer?.cornerRadius = 12
        view.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.22).cgColor
        view.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.8).cgColor
        view.layer?.borderWidth = 2
        window.contentView = view
        return window
    }
}
