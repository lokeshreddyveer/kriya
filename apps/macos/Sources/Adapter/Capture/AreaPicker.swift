import AppKit

/// Dims every display and lets the person drag out an area. Escape cancels. Gives the area in the form `screencapture -R` takes.
final class AreaPicker {
    private var windows: [PickerWindow] = []
    private var finish: ((CGRect?) -> Void)?

    /// The layout of the displays now, as `PreviousArea` keeps it.
    static var currentLayout: String {
        PreviousArea.layoutKey(NSScreen.screens.map(\.frame), scales: NSScreen.screens.map(\.backingScaleFactor))
    }

    func pick(completion: @escaping (CGRect?) -> Void) {
        finish = completion
        for screen in NSScreen.screens {
            let window = PickerWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
            window.level = .screenSaver
            window.isOpaque = false
            window.backgroundColor = NSColor.black.withAlphaComponent(0.25)
            window.hasShadow = false
            window.ignoresMouseEvents = false
            let view = PickerView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.done = { [weak self, weak window] rect in
                guard let self else { return }
                let global = rect.flatMap { r in window.map { $0.convertToScreen(r) } }
                self.end(global)
            }
            window.contentView = view
            windows.append(window)
        }
        NSApp.activate(ignoringOtherApps: true)
        windows.forEach { $0.makeKeyAndOrderFront(nil) }
        windows.first?.makeFirstResponder(windows.first?.contentView)
    }

    private func end(_ appKitRect: CGRect?) {
        windows.forEach { $0.orderOut(nil) }
        windows = []
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        let result = appKitRect.map { PreviousArea.fromAppKit($0, mainHeight: mainHeight) }
        let callback = finish
        finish = nil
        // Let the dimming leave the screen before anything is captured.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { callback?(result) }
    }
}

private final class PickerWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

private final class PickerView: NSView {
    var done: ((CGRect?) -> Void)?
    private var start: NSPoint?
    private var current: NSPoint?

    override var acceptsFirstResponder: Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    private var selection: NSRect? {
        guard let a = start, let b = current else { return nil }
        return NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    override func mouseDown(with event: NSEvent) { start = convert(event.locationInWindow, from: nil); current = start; needsDisplay = true }
    override func mouseDragged(with event: NSEvent) { current = convert(event.locationInWindow, from: nil); needsDisplay = true }
    override func mouseUp(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        let rect = selection
        done?(rect.flatMap { $0.width >= PreviousArea.minimumSide && $0.height >= PreviousArea.minimumSide ? $0 : nil })
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { done?(nil) } else { super.keyDown(with: event) }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let rect = selection else { return }
        NSColor.clear.setFill()
        rect.fill(using: .copy)
        NSColor.white.setStroke()
        let path = NSBezierPath(rect: rect)
        path.lineWidth = 1
        path.stroke()
        let label = "\(Int(rect.width)) × \(Int(rect.height))" as NSString
        label.draw(at: NSPoint(x: rect.minX + 4, y: rect.maxY + 4), withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white])
    }
}
