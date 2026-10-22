import AppKit

/// Auto-scroll: click a button and the page scrolls by itself, faster the further the pointer is from where it was
/// clicked. A click, the Escape key or turning the wheel stops it. The state and the arithmetic live here, apart from the
/// event tap, so they can be tested.
final class AutoScroll {
    enum StopReason: String {
        case escape, click, wheel, toggled, disabled
    }

    static let escapeKeyCode: UInt16 = 53

    private let lock = NSLock()
    private var anchorPoint: CGPoint?

    /// Called, from whichever thread stopped it, after it has stopped.
    var onStop: (StopReason) -> Void = { _ in }

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return anchorPoint != nil
    }

    var anchor: CGPoint? {
        lock.lock()
        defer { lock.unlock() }
        return anchorPoint
    }

    func start(at point: CGPoint) {
        lock.lock()
        anchorPoint = point
        lock.unlock()
    }

    func stop(_ reason: StopReason) {
        lock.lock()
        let was = anchorPoint != nil
        anchorPoint = nil
        lock.unlock()
        if was { onStop(reason) }
    }

    /// A key was pressed. Escape stops it, and the key is taken (so it does not also close something in the app).
    func key(_ code: UInt16) -> Bool {
        guard isActive, code == Self.escapeKeyCode else { return false }
        stop(.escape)
        return true
    }

    /// A button was pressed while it is running: any button stops it, and that click is taken.
    func click() -> Bool {
        guard isActive else { return false }
        stop(.click)
        return true
    }

    /// The wheel turned: the person has taken over, so it stops, and the scroll goes through.
    func wheel() {
        if isActive { stop(.wheel) }
    }

    /// How far to scroll now, in the direction content moves, for a pointer at `pointer` after `seconds`. Nothing when it
    /// is not running or the pointer is within the dead zone.
    func step(pointer: CGPoint, seconds: Double, speed: Double) -> (dx: Double, dy: Double) {
        guard let anchor = anchor, seconds > 0, seconds < 0.5 else { return (0, 0) }
        let velocity = autoScrollVelocity(offsetX: pointer.x - anchor.x, offsetY: pointer.y - anchor.y, speed: speed)
        // The pointer going down means reading further down, which moves the content up.
        return (-velocity.x * seconds, -velocity.y * seconds)
    }
}

/// A small mark where auto-scroll started, so it is clear it is on and where the middle is.
final class AutoScrollMarker {
    private var panel: NSPanel?

    func show(at point: CGPoint) {
        DispatchQueue.main.async { [self] in
            hideNow()
            let size: CGFloat = 30
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: size, height: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel.isReleasedWhenClosed = false
            let view = NSImageView(frame: NSRect(x: 0, y: 0, width: size, height: size))
            let image = NSImage(systemSymbolName: "arrow.up.and.down.and.arrow.left.and.right", accessibilityDescription: "Auto-scroll")
            view.image = image?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 16, weight: .semibold))
            view.contentTintColor = .labelColor
            view.wantsLayer = true
            view.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.85).cgColor
            view.layer?.cornerRadius = size / 2
            view.layer?.borderWidth = 1
            view.layer?.borderColor = NSColor.separatorColor.cgColor
            panel.contentView = view
            let screenHeight = NSScreen.screens.first?.frame.height ?? 0
            panel.setFrameOrigin(NSPoint(x: point.x - size / 2, y: screenHeight - point.y - size / 2))
            panel.orderFrontRegardless()
            self.panel = panel
        }
    }

    func hide() { DispatchQueue.main.async { [self] in hideNow() } }

    private func hideNow() {
        panel?.orderOut(nil)
        panel = nil
    }
}
