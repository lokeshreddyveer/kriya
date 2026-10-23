import AppKit

/// A frozen picture of the screen to measure on. Move for a magnifier and the colour under the pointer; drag to measure a box;
/// hold ⌥ to see how far it is to the edges around the pointer; click without dragging to measure the box of one colour you are on.
/// Return or ⌘C copies the size, C copies the colour, Esc leaves. Needs Screen Recording; nothing is saved.
final class PixelRuler {
    private var window: NSWindow?
    private let toast = Toast()
    var hasPermission: () -> Bool = { CGPreflightScreenCaptureAccess() }

    func show() {
        guard window == nil else { return }
        guard hasPermission() else {
            _ = CGRequestScreenCaptureAccess()
            toast.show("Allow Screen Recording for Kriya in System Settings, then try again.", isError: true)
            return
        }
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main,
              let index = NSScreen.screens.firstIndex(of: screen) else { return }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("kriya-ruler-\(UUID().uuidString).png")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            task.arguments = ["-x", "-t", "png", "-D", String(index + 1), file.path]
            try? task.run()
            task.waitUntilExit()
            let image = ScreenCaptureService.loadImage(at: file)
            try? FileManager.default.removeItem(at: file)
            DispatchQueue.main.async {
                guard let self, let image else { self?.toast.show("The screen could not be captured.", isError: true); return }
                self.open(image, on: screen)
            }
        }
    }

    private func open(_ image: CGImage, on screen: NSScreen) {
        let view = RulerView(image: image, scale: screen.backingScaleFactor, frame: NSRect(origin: .zero, size: screen.frame.size))
        view.onClose = { [weak self] in self?.close() }
        view.onCopy = { [weak self] text, message in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            self?.toast.show(message)
        }
        let w = RulerWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.level = .screenSaver
        w.isOpaque = true
        w.hasShadow = false
        w.isReleasedWhenClosed = false
        w.contentView = view
        w.setFrame(screen.frame, display: true)
        w.makeKeyAndOrderFront(nil)
        w.makeFirstResponder(view)
        NSApp.activate(ignoringOtherApps: true)
        NSCursor.crosshair.push()
        window = w
    }

    func close() {
        guard let w = window else { return }
        NSCursor.pop()
        window = nil
        w.orderOut(nil)
    }

    private final class RulerWindow: NSWindow { override var canBecomeKey: Bool { true } }
}

private final class RulerView: NSView {
    let image: CGImage
    let scale: CGFloat
    let grid: PixelGrid
    var onClose: () -> Void = {}
    var onCopy: (String, String) -> Void = { _, _ in }

    private var cursor: CGPoint?
    private var dragStart: CGPoint?
    private var box: CGRect?          // the last measured box, in view points
    private var showEdges = false

    init(image: CGImage, scale: CGFloat, frame: NSRect) {
        self.image = image
        self.scale = scale
        let w = image.width, h = image.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        if let context = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        grid = PixelGrid(width: w, height: h, bytes: data)
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private func pixel(_ p: CGPoint) -> (x: Int, y: Int) { (Int(p.x * scale), Int(p.y * scale)) }

    // MARK: Events

    override func mouseMoved(with event: NSEvent) { cursor = convert(event.locationInWindow, from: nil); showEdges = event.modifierFlags.contains(.option); needsDisplay = true }
    override func flagsChanged(with event: NSEvent) { showEdges = event.modifierFlags.contains(.option); needsDisplay = true }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        dragStart = p; cursor = p; box = nil
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        cursor = p
        if let s = dragStart { box = PixelMeasure.rect(from: s, to: p) }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        defer { dragStart = nil; needsDisplay = true }
        guard let s = dragStart else { return }
        if hypot(p.x - s.x, p.y - s.y) < 3 {
            // A click: the box of one colour under the pointer.
            let px = pixel(p)
            if let r = grid.region(around: px.x, y: px.y) {
                box = CGRect(x: CGFloat(r.x) / scale, y: CGFloat(r.y) / scale, width: CGFloat(r.width) / scale, height: CGFloat(r.height) / scale)
            }
        }
    }

    override func rightMouseDown(with event: NSEvent) { onClose() }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onClose()                                   // Escape
        case 36, 76: copySize()                              // Return
        case 8: if event.modifierFlags.contains(.command) { copySize() } else { copyColor() }   // C
        default: break
        }
    }

    private func copySize() {
        guard let b = box else { return }
        let w = Int((b.width * scale).rounded()), h = Int((b.height * scale).rounded())
        let text = "\(w) × \(h)"
        onCopy(text, "Copied \(text) px")
    }

    private func copyColor() {
        guard let c = cursor, let hex = grid.hex(x: pixel(c).x, y: pixel(c).y) else { return }
        onCopy(hex, "Copied \(hex)")
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSImage(cgImage: image, size: bounds.size).draw(in: bounds)
        if let b = box { drawBox(b) }
        guard let c = cursor else { return }
        drawCrosshair(at: c)
        if showEdges { drawEdges(at: c) }
        drawLoupe(at: c)
    }

    private func drawCrosshair(at c: CGPoint) {
        let path = NSBezierPath()
        path.move(to: CGPoint(x: c.x, y: 0)); path.line(to: CGPoint(x: c.x, y: bounds.height))
        path.move(to: CGPoint(x: 0, y: c.y)); path.line(to: CGPoint(x: bounds.width, y: c.y))
        path.lineWidth = 1
        NSColor.systemPink.withAlphaComponent(0.55).setStroke()
        path.stroke()
    }

    private func drawBox(_ b: CGRect) {
        NSColor.systemPink.withAlphaComponent(0.14).setFill()
        b.fill()
        let path = NSBezierPath(rect: b)
        path.lineWidth = 1
        NSColor.systemPink.setStroke()
        path.stroke()
        let wPx = Int((b.width * scale).rounded()), hPx = Int((b.height * scale).rounded())
        label(PixelMeasure.label(widthPixels: wPx, heightPixels: hPx, scale: Double(scale)), near: CGPoint(x: b.midX, y: b.maxY + 16))
    }

    private func drawEdges(at c: CGPoint) {
        let p = pixel(c)
        let left = grid.run(fromX: p.x, y: p.y, dx: -1, dy: 0), right = grid.run(fromX: p.x, y: p.y, dx: 1, dy: 0)
        let up = grid.run(fromX: p.x, y: p.y, dx: 0, dy: -1), down = grid.run(fromX: p.x, y: p.y, dx: 0, dy: 1)
        func pt(_ v: Int) -> CGFloat { CGFloat(v) / scale }
        let lines: [(CGPoint, CGPoint, Int)] = [
            (CGPoint(x: c.x - pt(left), y: c.y), c, left), (c, CGPoint(x: c.x + pt(right), y: c.y), right),
            (CGPoint(x: c.x, y: c.y - pt(up)), c, up), (c, CGPoint(x: c.x, y: c.y + pt(down)), down),
        ]
        NSColor.systemCyan.setStroke()
        for (a, b, n) in lines where n > 0 {
            let path = NSBezierPath(); path.move(to: a); path.line(to: b); path.lineWidth = 2; path.stroke()
            label("\(n)", near: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 - 12))
        }
    }

    private func drawLoupe(at c: CGPoint) {
        let cells = 13, cell: CGFloat = 11, size = CGFloat(cells) * cell
        var origin = CGPoint(x: c.x + 24, y: c.y + 24)
        if origin.x + size + 130 > bounds.width { origin.x = c.x - 24 - size - 130 }
        if origin.y + size + 30 > bounds.height { origin.y = c.y - 24 - size - 30 }
        let frame = CGRect(x: origin.x, y: origin.y, width: size, height: size)
        NSColor.black.withAlphaComponent(0.85).setFill()
        NSBezierPath(roundedRect: frame.insetBy(dx: -4, dy: -4), xRadius: 10, yRadius: 10).fill()
        let p = pixel(c)
        let half = cells / 2
        for row in 0..<cells {
            for col in 0..<cells {
                guard let color = grid.color(x: p.x - half + col, y: p.y - half + row) else { continue }
                NSColor(srgbRed: CGFloat(color.r) / 255, green: CGFloat(color.g) / 255, blue: CGFloat(color.b) / 255, alpha: 1).setFill()
                CGRect(x: frame.minX + CGFloat(col) * cell, y: frame.minY + CGFloat(row) * cell, width: cell, height: cell).fill()
            }
        }
        let centre = CGRect(x: frame.minX + CGFloat(half) * cell, y: frame.minY + CGFloat(half) * cell, width: cell, height: cell)
        let ring = NSBezierPath(rect: centre.insetBy(dx: -1, dy: -1)); ring.lineWidth = 2; NSColor.white.setStroke(); ring.stroke()
        let hex = grid.hex(x: p.x, y: p.y) ?? ""
        let text = "\(hex)    \(p.x), \(p.y)"
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white]
        (text as NSString).draw(at: CGPoint(x: frame.minX, y: frame.maxY + 8), withAttributes: attrs)
    }

    private func label(_ text: String, near point: CGPoint) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.white]
        let size = (text as NSString).size(withAttributes: attrs)
        let rect = CGRect(x: point.x - size.width / 2 - 6, y: point.y - size.height / 2 - 2, width: size.width + 12, height: size.height + 4)
        NSColor.systemPink.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
        (text as NSString).draw(at: CGPoint(x: rect.minX + 6, y: rect.minY + 2), withAttributes: attrs)
    }
}
