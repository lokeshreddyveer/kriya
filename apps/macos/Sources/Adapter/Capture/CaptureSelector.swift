import AppKit
import ScreenCaptureKit

/// What the person chose on screen.
struct SelectorResult {
    enum Kind { case area, window, display }
    /// What to do with it, picked on the toolbar that appears under a chosen area (or ⏎ for the usual).
    enum Action { case capture, copy, save, annotate, pin, text, redact }

    var kind: Kind
    var action: Action
    /// Global points, top-left origin (what the displays report and `PreviousArea` keeps).
    var rect: CGRect
    var displayID: CGDirectDisplayID
    var windowID: CGWindowID?
    var windowTitle: String?
    /// The part of the frozen still inside `rect`, for an area (so what is captured is exactly what was seen).
    var image: CGImage?
}

/// Freezes every display and lets the person choose an area, a window or a display on the frozen picture: crosshair and a magnifier,
/// the size beside the area as it is dragged, snapping to screen and window edges, a fixed shape with Shift, growing from the centre
/// with Option, moving with Space, the arrow keys to nudge (Option to resize, Shift for ten), ⏎ to capture, Escape to cancel, and a
/// small toolbar for what to do with it. Everything it shows is hidden from screen sharing.
@MainActor
final class CaptureSelector {
    struct Still {
        let displayID: CGDirectDisplayID
        let bounds: CGRect          // global points, top-left origin
        let scale: CGFloat
        let image: CGImage
        let screen: NSScreen
    }

    private var windows: [SelectorWindow] = []
    private var model: SelectorModel?
    private var continuation: CheckedContinuation<SelectorResult?, Never>?

    /// Made where the capture service is made (not on the main actor), so this must not need it.
    nonisolated init() {}

    var isShowing: Bool { !windows.isEmpty }

    /// Shows the selector. Returns nil if the person cancelled, or if nothing could be shown (with the reason in `problem`).
    func select(_ kind: SelectorResult.Kind, shape: SelectionGeometry.Shape = SelectionGeometry.shapes[0], toolbar: Bool = true, hint: String? = nil) async -> (result: SelectorResult?, problem: String?) {
        guard !isShowing else { return (nil, nil) }
        let stills: [Still]
        let list: [ScreenGrabber.WindowInfo]
        do {
            let content = try await ScreenGrabber.content()
            list = ScreenGrabber.windows(in: content)
            var found: [Still] = []
            for screen in NSScreen.screens {
                guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { continue }
                let image = try await ScreenGrabber.displayImage(id, options: .init(includeCursor: false, hideDesktopIcons: false, excludeKriya: true, cropNotch: false), content: content)
                found.append(Still(displayID: id, bounds: CGDisplayBounds(id), scale: ScreenGrabber.scale(of: id), image: image, screen: screen))
            }
            stills = found
        } catch {
            return (nil, error.localizedDescription)
        }
        guard !stills.isEmpty else { return (nil, "There is no display to choose on.") }

        let model = SelectorModel(kind: kind, stills: stills, windows: Self.inFrontToBackOrder(list), shape: shape, showToolbar: toolbar, hint: hint)
        self.model = model
        // The pointer is where it is before it has moved, so the magnifier starts there and not in the corner.
        let pointer = NSEvent.mouseLocation
        model.cursor = CGPoint(x: pointer.x, y: (NSScreen.screens.first?.frame.height ?? 0) - pointer.y)
        if kind == .display { model.hoverDisplay = stills.first { $0.bounds.contains(model.cursor) }?.displayID ?? stills.first?.displayID }
        let result: SelectorResult? = await withCheckedContinuation { continuation in
            self.continuation = continuation
            model.finish = { [weak self] result in self?.end(result) }
            for still in stills {
                let window = SelectorWindow(contentRect: still.screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: still.screen)
                window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
                window.isOpaque = true
                window.backgroundColor = .black
                window.hasShadow = false
                window.sharingType = .none
                window.acceptsMouseMovedEvents = true
                window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
                let view = SelectorView(frame: NSRect(origin: .zero, size: still.screen.frame.size), model: model, still: still)
                window.contentView = view
                windows.append(window)
            }
            model.views = windows.compactMap { $0.contentView as? SelectorView }
            NSApp.activate(ignoringOtherApps: true)
            // The window under the pointer is key, so the keyboard goes to the screen being used.
            let pointer = NSEvent.mouseLocation
            let first = windows.first { $0.frame.contains(pointer) } ?? windows[0]
            windows.forEach { $0 === first ? $0.makeKeyAndOrderFront(nil) : $0.orderFront(nil) }
            first.makeFirstResponder(first.contentView)
        }
        return (result, nil)
    }

    private func end(_ result: SelectorResult?) {
        windows.forEach { $0.orderOut(nil) }
        windows = []
        model = nil
        let waiting = continuation
        continuation = nil
        // Let the dimmed screens leave before anything else is captured.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { waiting?.resume(returning: result) }
    }

    /// Windows front to back, by asking the window server for the order they are stacked in.
    private static func inFrontToBackOrder(_ list: [ScreenGrabber.WindowInfo]) -> [ScreenGrabber.WindowInfo] {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return list }
        let order = Dictionary(uniqueKeysWithValues: info.enumerated().compactMap { index, item in (item[kCGWindowNumber as String] as? CGWindowID).map { ($0, index) } })
        return list.sorted { (order[$0.id] ?? Int.max) < (order[$1.id] ?? Int.max) }
    }
}

// MARK: - The shared state

@MainActor
final class SelectorModel {
    enum Phase { case idle, dragging, adjusting }

    let kind: SelectorResult.Kind
    let stills: [CaptureSelector.Still]
    let windows: [ScreenGrabber.WindowInfo]
    let showToolbar: Bool
    let hint: String?
    var shape: SelectionGeometry.Shape
    var finish: (SelectorResult?) -> Void = { _ in }
    var views: [SelectorView] = []

    var phase = Phase.idle
    /// Global points, top-left origin.
    var cursor = CGPoint.zero
    var selection = CGRect.zero
    var activeDisplay: CGDirectDisplayID?
    var hoverWindow: ScreenGrabber.WindowInfo?
    var hoverDisplay: CGDirectDisplayID?
    var modifiers: NSEvent.ModifierFlags = []

    init(kind: SelectorResult.Kind, stills: [CaptureSelector.Still], windows: [ScreenGrabber.WindowInfo], shape: SelectionGeometry.Shape, showToolbar: Bool, hint: String?) {
        self.kind = kind
        self.stills = stills
        self.windows = windows
        self.shape = shape
        self.showToolbar = showToolbar
        self.hint = hint
    }

    func still(_ id: CGDirectDisplayID) -> CaptureSelector.Still? { stills.first { $0.displayID == id } }
    func still(at point: CGPoint) -> CaptureSelector.Still? { stills.first { $0.bounds.contains(point) } }
    func redraw() { views.forEach { $0.needsDisplay = true } }

    /// The edges on one display worth snapping to.
    func snapEdges(on still: CaptureSelector.Still) -> (xs: [CGFloat], ys: [CGFloat]) {
        SelectionGeometry.edges(display: still.bounds, windows: windows.map(\.frame).filter { $0.intersects(still.bounds) })
    }

    /// The frozen picture inside the chosen area.
    func croppedImage(of rect: CGRect, on still: CaptureSelector.Still) -> CGImage? {
        let local = rect.offsetBy(dx: -still.bounds.minX, dy: -still.bounds.minY)
        let crop = SelectionGeometry.cropRect(for: local, scale: still.scale, displayHeight: still.bounds.height, topLeft: true)
        return still.image.cropping(to: crop)
    }

    func confirm(_ action: SelectorResult.Action = .capture) {
        switch kind {
        case .area:
            guard let id = activeDisplay, let still = still(id), SelectionGeometry.isUsable(selection) else { return }
            finish(SelectorResult(kind: .area, action: action, rect: selection, displayID: id, windowID: nil, windowTitle: nil, image: croppedImage(of: selection, on: still)))
        case .window:
            guard let window = hoverWindow, let still = still(at: CGPoint(x: window.frame.midX, y: window.frame.midY)) ?? stills.first else { return }
            finish(SelectorResult(kind: .window, action: action, rect: window.frame, displayID: still.displayID, windowID: window.id, windowTitle: window.title, image: nil))
        case .display:
            guard let id = hoverDisplay ?? stills.first?.displayID, let still = still(id) else { return }
            finish(SelectorResult(kind: .display, action: action, rect: still.bounds, displayID: id, windowID: nil, windowTitle: nil, image: nil))
        }
    }

    func cancel() { finish(nil) }
}

// MARK: - One screen

private final class SelectorWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class SelectorView: NSView {
    private let model: SelectorModel
    private let still: CaptureSelector.Still
    private var anchor = CGPoint.zero
    private var grab: Grab?
    private var lastDrag = CGPoint.zero
    private var spaceDown = false
    private var hoverButton: Int?
    private var tracking: NSTrackingArea?

    /// What a press on the chosen area took hold of: the inside (to move it) or one of the eight handles (to resize).
    private enum Grab { case move, handle(Handle) }
    private struct Handle: Equatable { var left = false, right = false, top = false, bottom = false }

    private let image: NSImage

    init(frame: NSRect, model: SelectorModel, still: CaptureSelector.Still) {
        self.model = model
        self.still = still
        self.image = NSImage(cgImage: still.image, size: NSSize(width: still.bounds.width, height: still.bounds.height))
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }       // top-left origin, like the displays
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect, .cursorUpdate], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: model.kind == .area ? .crosshair : .arrow) }
    override func cursorUpdate(with event: NSEvent) { (model.kind == .area ? NSCursor.crosshair : NSCursor.arrow).set() }

    // MARK: Coordinates

    private func global(_ local: CGPoint) -> CGPoint { CGPoint(x: still.bounds.minX + local.x, y: still.bounds.minY + local.y) }
    private func local(_ global: CGPoint) -> CGPoint { CGPoint(x: global.x - still.bounds.minX, y: global.y - still.bounds.minY) }
    private func localRect(_ r: CGRect) -> CGRect { r.offsetBy(dx: -still.bounds.minX, dy: -still.bounds.minY) }
    private var isActive: Bool { model.activeDisplay == still.displayID }

    // MARK: Mouse

    override func mouseEntered(with event: NSEvent) { window?.makeKey(); window?.makeFirstResponder(self) }

    override func mouseMoved(with event: NSEvent) {
        let point = global(convert(event.locationInWindow, from: nil))
        model.cursor = point
        model.modifiers = event.modifierFlags
        switch model.kind {
        case .area:
            if model.phase == .adjusting, isActive { hoverButton = toolbarButtons.firstIndex { $0.frame.contains(convert(event.locationInWindow, from: nil)) } }
        case .window:
            model.hoverWindow = model.windows.first { $0.frame.contains(point) }
        case .display:
            model.hoverDisplay = still.displayID
        }
        model.redraw()
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let point = global(p)
        model.cursor = point
        switch model.kind {
        case .window:
            model.hoverWindow = model.windows.first { $0.frame.contains(point) }
            model.confirm()
        case .display:
            model.hoverDisplay = still.displayID
            model.confirm()
        case .area:
            if model.phase == .adjusting, isActive {
                if let index = toolbarButtons.firstIndex(where: { $0.frame.contains(p) }) { chooseButton(index); return }
                if let handle = handle(at: p) { grab = .handle(handle); lastDrag = point; return }
                if localRect(model.selection).contains(p) { grab = .move; lastDrag = point; return }
            }
            // A new area, from here, on this display.
            model.activeDisplay = still.displayID
            model.phase = .dragging
            anchor = point
            model.selection = CGRect(origin: point, size: .zero)
            grab = nil
            model.redraw()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard model.kind == .area else { return }
        let point = global(convert(event.locationInWindow, from: nil))
        let flags = event.modifierFlags
        model.cursor = point
        model.modifiers = flags
        let bounds = still.bounds
        let clamped = CGPoint(x: min(max(point.x, bounds.minX), bounds.maxX), y: min(max(point.y, bounds.minY), bounds.maxY))
        if let grab {
            switch grab {
            case .move:
                model.selection = SelectionGeometry.moved(model.selection, dx: clamped.x - lastDrag.x, dy: clamped.y - lastDrag.y, within: bounds)
            case .handle(let h):
                model.selection = resize(model.selection, by: h, to: clamped, ratio: ratio(flags))
            }
            lastDrag = clamped
        } else if model.phase == .dragging {
            if spaceDown {
                // Holding Space carries the area along instead of changing its size.
                model.selection = SelectionGeometry.moved(model.selection, dx: clamped.x - lastDrag.x, dy: clamped.y - lastDrag.y, within: bounds)
                anchor = CGPoint(x: anchor.x + clamped.x - lastDrag.x, y: anchor.y + clamped.y - lastDrag.y)
            } else {
                var rect = SelectionGeometry.rect(from: anchor, to: clamped, fromCenter: flags.contains(.option), ratio: ratio(flags))
                if !flags.contains(.command) {
                    let edges = model.snapEdges(on: still)
                    rect = SelectionGeometry.snapped(rect, xs: edges.xs, ys: edges.ys)
                    if ratio(flags) == nil, let common = SelectionGeometry.commonSize(for: rect) { rect.size = common }
                }
                model.selection = SelectionGeometry.clamped(rect, to: bounds)
            }
            lastDrag = clamped
        }
        model.redraw()
    }

    override func mouseUp(with event: NSEvent) {
        guard model.kind == .area else { return }
        if grab != nil { grab = nil; model.redraw(); return }
        guard model.phase == .dragging else { return }
        if SelectionGeometry.isUsable(model.selection) {
            model.phase = .adjusting
        } else {
            model.phase = .idle
            model.selection = .zero
            model.activeDisplay = nil
        }
        model.redraw()
    }

    private func ratio(_ flags: NSEvent.ModifierFlags) -> CGFloat? {
        if let r = model.shape.ratio { return r }
        return flags.contains(.shift) ? 1 : nil
    }

    // MARK: Keyboard

    override func flagsChanged(with event: NSEvent) { model.modifiers = event.modifierFlags; model.redraw() }

    override func keyUp(with event: NSEvent) { if event.keyCode == 49 { spaceDown = false } }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags
        let step: CGFloat = flags.contains(.shift) ? 10 : 1
        switch event.keyCode {
        case 53: model.cancel()                                        // Escape
        case 36, 76: model.confirm()                                   // Return, Enter
        case 49: spaceDown = true                                      // Space: carry the area while dragging
        case 15 where model.kind == .area:                             // R: the next fixed shape
            model.shape = SelectionGeometry.nextShape(after: model.shape)
            if model.phase == .adjusting, let id = model.activeDisplay, let still = model.still(id), let ratio = model.shape.ratio {
                model.selection = SelectionGeometry.resized(model.selection, dw: 0, dh: 0, within: still.bounds, ratio: ratio)
                let w = model.selection.width
                model.selection.size.height = w / ratio
                model.selection = SelectionGeometry.clamped(model.selection, to: still.bounds)
            }
            model.redraw()
        case 123, 124, 125, 126:
            // Left, right, down, up: nudge the chosen area (Option resizes it, Shift makes the step ten).
            guard model.kind == .area, model.phase == .adjusting, let id = model.activeDisplay, let area = model.still(id) else { return }
            let dx: CGFloat = event.keyCode == 123 ? -step : event.keyCode == 124 ? step : 0
            let dy: CGFloat = event.keyCode == 126 ? -step : event.keyCode == 125 ? step : 0
            if flags.contains(.option) {
                model.selection = SelectionGeometry.resized(model.selection, dw: dx, dh: dy, within: area.bounds, ratio: model.shape.ratio)
            } else {
                model.selection = SelectionGeometry.moved(model.selection, dx: dx, dy: dy, within: area.bounds)
            }
            model.redraw()
        default: super.keyDown(with: event)
        }
    }

    // MARK: Handles and toolbar

    private let handleSize: CGFloat = 10

    private func handle(at p: CGPoint) -> Handle? {
        let r = localRect(model.selection)
        let near = handleSize
        let left = abs(p.x - r.minX) <= near, right = abs(p.x - r.maxX) <= near
        let top = abs(p.y - r.minY) <= near, bottom = abs(p.y - r.maxY) <= near
        let withinX = p.x >= r.minX - near && p.x <= r.maxX + near, withinY = p.y >= r.minY - near && p.y <= r.maxY + near
        guard withinX, withinY else { return nil }
        let h = Handle(left: left, right: right && !left, top: top, bottom: bottom && !top)
        return h.left || h.right || h.top || h.bottom ? h : nil
    }

    private func resize(_ rect: CGRect, by h: Handle, to p: CGPoint, ratio: CGFloat?) -> CGRect {
        var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        if h.left { minX = min(p.x, maxX - SelectionGeometry.minimumSide) }
        if h.right { maxX = max(p.x, minX + SelectionGeometry.minimumSide) }
        if h.top { minY = min(p.y, maxY - SelectionGeometry.minimumSide) }
        if h.bottom { maxY = max(p.y, minY + SelectionGeometry.minimumSide) }
        var r = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        if let ratio, ratio > 0 {
            // The edge being pulled decides; the other side follows to keep the shape.
            if h.left || h.right { r.size.height = r.width / ratio } else { r.size.width = r.height * ratio }
        }
        return SelectionGeometry.clamped(r, to: still.bounds)
    }

    private struct Button { let symbol: String; let title: String; let action: SelectorResult.Action? ; var frame: CGRect }

    private var toolbarButtons: [Button] {
        guard model.kind == .area, model.phase == .adjusting, isActive else { return [] }
        // Without the full toolbar (a scrolling capture) the area still needs a visible way to go on, not only ⏎.
        let defs: [(String, String, SelectorResult.Action?)] = model.showToolbar ? [
            ("camera.viewfinder", "Capture  ⏎", .capture), ("doc.on.doc", "Copy", .copy), ("square.and.arrow.down", "Save", .save),
            ("pencil.tip.crop.circle", "Annotate", .annotate), ("pin", "Pin", .pin), ("text.viewfinder", "Copy text", .text),
            ("eye.slash", "Hide private text", .redact), ("xmark", "Cancel  ⎋", nil),
        ] : [
            ("play.fill", "Start  ⏎", .capture), ("xmark", "Cancel  ⎋", nil),
        ]
        let size: CGFloat = 32, gap: CGFloat = 2, pad: CGFloat = 6
        let total = CGFloat(defs.count) * size + CGFloat(defs.count - 1) * gap + pad * 2
        let r = localRect(model.selection)
        var x = min(max(r.midX - total / 2, 6), bounds.width - total - 6)
        var y = r.maxY + 10
        if y + size + pad * 2 > bounds.height - 6 { y = max(r.minY - size - pad * 2 - 10, 6) }
        x += pad; y += pad
        return defs.enumerated().map { i, d in Button(symbol: d.0, title: d.1, action: d.2, frame: CGRect(x: x + CGFloat(i) * (size + gap), y: y, width: size, height: size)) }
    }

    private func chooseButton(_ index: Int) {
        let buttons = toolbarButtons
        guard buttons.indices.contains(index) else { return }
        if let action = buttons[index].action { model.confirm(action) } else { model.cancel() }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        drawStill()
        switch model.kind {
        case .area: drawArea(context)
        case .window: drawWindow(context)
        case .display: drawDisplay(context)
        }
        if let hint = model.hint, !(model.kind == .area && model.phase != .idle && model.showToolbar) { drawPill(hint, at: CGPoint(x: bounds.midX, y: 44), center: true) }
    }

    /// The frozen picture across the whole screen. This view counts y from the top, so the picture is drawn with that in mind.
    private func drawStill() {
        image.draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
    }

    private func dim(_ context: CGContext, except hole: CGRect?) {
        context.saveGState()
        context.setFillColor(NSColor.black.withAlphaComponent(0.38).cgColor)
        if let hole {
            let path = CGMutablePath()
            path.addRect(bounds)
            path.addRect(hole)
            context.addPath(path)
            context.fillPath(using: .evenOdd)
        } else {
            context.fill(bounds)
        }
        context.restoreGState()
    }

    private func drawArea(_ context: CGContext) {
        let shown = isActive && model.selection.width > 0
        if shown {
            let r = localRect(model.selection)
            dim(context, except: r)
            context.saveGState()
            context.setStrokeColor(NSColor.white.cgColor)
            context.setLineWidth(1)
            context.stroke(r.insetBy(dx: 0.5, dy: 0.5))
            context.setStrokeColor(NSColor.black.withAlphaComponent(0.45).cgColor)
            context.stroke(r.insetBy(dx: -0.5, dy: -0.5))
            context.restoreGState()
            if model.phase == .adjusting { drawHandles(context, r) }
            var label = SelectionGeometry.sizeLabel(model.selection, scale: still.scale)
            if model.shape.ratio != nil { label += "   \(model.shape.name)" }
            if SelectionGeometry.commonSize(for: model.selection) != nil { label += "   ✓" }
            let y = r.minY > 34 ? r.minY - 30 : r.maxY + 8
            drawPill(label, at: CGPoint(x: max(r.minX, 6), y: y), center: false)
            drawToolbar(context)
        } else {
            dim(context, except: nil)
        }
        if model.phase != .adjusting, still.bounds.contains(model.cursor) { drawLoupe(context) }
    }

    private func drawHandles(_ context: CGContext, _ r: CGRect) {
        let points = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                      CGPoint(x: r.minX, y: r.midY), CGPoint(x: r.maxX, y: r.midY),
                      CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.midX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)]
        context.saveGState()
        for p in points {
            let box = CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)
            context.setFillColor(NSColor.white.cgColor)
            context.fill(box)
            context.setStrokeColor(NSColor.black.withAlphaComponent(0.5).cgColor)
            context.stroke(box.insetBy(dx: 0.5, dy: 0.5))
        }
        context.restoreGState()
    }

    private func drawWindow(_ context: CGContext) {
        dim(context, except: nil)
        guard let w = model.hoverWindow, w.frame.intersects(still.bounds) else { return }
        let r = localRect(w.frame).intersection(bounds)
        context.saveGState()
        context.clip(to: r)
        drawStill()
        context.restoreGState()
        context.setStrokeColor(NSColor.controlAccentColor.cgColor)
        context.setLineWidth(3)
        context.stroke(r.insetBy(dx: 1.5, dy: 1.5))
        let name = w.title.isEmpty ? w.appName : "\(w.appName) — \(w.title)"
        drawPill("\(name.count > 60 ? String(name.prefix(59)) + "…" : name)   \(Int(w.frame.width)) × \(Int(w.frame.height))", at: CGPoint(x: r.midX, y: r.midY), center: true)
    }

    private func drawDisplay(_ context: CGContext) {
        let chosen = model.hoverDisplay == still.displayID
        if !chosen { dim(context, except: nil) }
        if chosen {
            context.setStrokeColor(NSColor.controlAccentColor.cgColor)
            context.setLineWidth(6)
            context.stroke(bounds.insetBy(dx: 3, dy: 3))
        }
        let index = (model.stills.firstIndex { $0.displayID == still.displayID } ?? 0) + 1
        drawPill("Display \(index)   \(Int(still.bounds.width)) × \(Int(still.bounds.height))", at: CGPoint(x: bounds.midX, y: bounds.midY), center: true)
    }

    private func drawToolbar(_ context: CGContext) {
        let buttons = toolbarButtons
        guard let first = buttons.first, let last = buttons.last else { return }
        let bar = CGRect(x: first.frame.minX - 6, y: first.frame.minY - 6, width: last.frame.maxX - first.frame.minX + 12, height: first.frame.height + 12)
        let path = NSBezierPath(roundedRect: bar, xRadius: 12, yRadius: 12)
        NSColor.black.withAlphaComponent(0.82).setFill()
        path.fill()
        NSColor.white.withAlphaComponent(0.14).setStroke()
        path.lineWidth = 1
        path.stroke()
        for (i, button) in buttons.enumerated() {
            if hoverButton == i {
                NSColor.white.withAlphaComponent(0.18).setFill()
                NSBezierPath(roundedRect: button.frame, xRadius: 8, yRadius: 8).fill()
            }
            if let symbol = NSImage(systemSymbolName: button.symbol, accessibilityDescription: button.title)?.withSymbolConfiguration(.init(pointSize: 15, weight: .medium)) {
                let tinted = symbol.tinted(.white)
                let s = tinted.size
                tinted.draw(in: CGRect(x: button.frame.midX - s.width / 2, y: button.frame.midY - s.height / 2, width: s.width, height: s.height),
                            from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        }
        if let i = hoverButton, buttons.indices.contains(i) {
            drawPill(buttons[i].title, at: CGPoint(x: buttons[i].frame.midX, y: bar.maxY + 6), center: true)
        }
    }

    private func drawPill(_ text: String, at origin: CGPoint, center: Bool) {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white]
        let size = (text as NSString).size(withAttributes: attributes)
        var box = CGRect(x: origin.x, y: origin.y, width: size.width + 16, height: size.height + 8)
        if center { box.origin.x -= box.width / 2; box.origin.y -= box.height / 2 }
        box.origin.x = min(max(box.origin.x, 4), bounds.width - box.width - 4)
        box.origin.y = min(max(box.origin.y, 4), bounds.height - box.height - 4)
        NSColor.black.withAlphaComponent(0.78).setFill()
        NSBezierPath(roundedRect: box, xRadius: box.height / 2, yRadius: box.height / 2).fill()
        (text as NSString).draw(at: CGPoint(x: box.minX + 8, y: box.minY + 4), withAttributes: attributes)
    }

    /// A magnifier beside the pointer: the pixels around it, large, with the pointer's position and the colour under it.
    private func drawLoupe(_ context: CGContext) {
        let p = local(model.cursor)
        let diameter: CGFloat = 132, zoom: CGFloat = 8
        let span = diameter / zoom                         // points shown across
        var origin = CGPoint(x: p.x + 26, y: p.y + 26)
        if origin.x + diameter > bounds.width - 6 { origin.x = p.x - 26 - diameter }
        if origin.y + diameter + 22 > bounds.height - 6 { origin.y = p.y - 26 - diameter - 22 }
        let circle = CGRect(origin: origin, size: CGSize(width: diameter, height: diameter))
        let source = CGRect(x: (p.x - span / 2) * still.scale, y: (p.y - span / 2) * still.scale, width: span * still.scale, height: span * still.scale).integral
        let clipped = source.intersection(CGRect(x: 0, y: 0, width: still.image.width, height: still.image.height))
        guard !clipped.isEmpty, let crop = still.image.cropping(to: clipped) else { return }
        context.saveGState()
        context.addEllipse(in: circle)
        context.clip()
        context.setFillColor(NSColor.black.cgColor)
        context.fill(circle)
        context.interpolationQuality = .none
        // The picture is drawn upside down in a flipped view unless flipped back.
        context.translateBy(x: circle.minX, y: circle.maxY)
        context.scaleBy(x: 1, y: -1)
        // Where the part that exists lands inside the loupe (it is smaller than the loupe at a screen edge).
        let drawn = CGRect(x: (clipped.minX - source.minX) / still.scale * zoom, y: (clipped.minY - source.minY) / still.scale * zoom,
                           width: clipped.width / still.scale * zoom, height: clipped.height / still.scale * zoom)
        context.draw(crop, in: CGRect(x: drawn.minX, y: diameter - drawn.maxY, width: drawn.width, height: drawn.height))
        context.restoreGState()
        // The pixel the pointer is on, boxed.
        let cell = zoom / 1
        context.setStrokeColor(NSColor.white.cgColor)
        context.setLineWidth(1)
        context.stroke(CGRect(x: circle.midX - cell / 2, y: circle.midY - cell / 2, width: cell, height: cell))
        context.setStrokeColor(NSColor.black.cgColor)
        context.stroke(CGRect(x: circle.midX - cell / 2 - 1, y: circle.midY - cell / 2 - 1, width: cell + 2, height: cell + 2))
        context.setStrokeColor(NSColor.white.cgColor)
        context.setLineWidth(2)
        context.strokeEllipse(in: circle)
        drawPill("\(Int(model.cursor.x)), \(Int(model.cursor.y))   \(pixelHex(atLocalX: p.x, y: p.y))", at: CGPoint(x: circle.midX, y: circle.maxY + 14), center: true)
    }

    private func pixelHex(atLocalX x: CGFloat, y: CGFloat) -> String {
        let px = CGRect(x: (x * still.scale).rounded(.down), y: (y * still.scale).rounded(.down), width: 1, height: 1)
        guard let one = still.image.cropping(to: px) else { return "" }
        var rgba = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(data: &rgba, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return "" }
        context.draw(one, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return String(format: "#%02X%02X%02X", rgba[0], rgba[1], rgba[2])
    }
}

private extension NSImage {
    /// The symbol in a single colour.
    func tinted(_ color: NSColor) -> NSImage {
        let copy = NSImage(size: size, flipped: false) { rect in
            self.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        return copy
    }
}
