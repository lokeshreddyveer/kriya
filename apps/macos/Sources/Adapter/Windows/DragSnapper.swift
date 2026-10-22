import AppKit

/// Snaps a window when you drag its title bar to a screen edge or corner, showing where it will land first.
///
/// It watches mouse events without changing them, so it needs no Input Monitoring. It only acts when the window under
/// the pointer actually moved with the mouse, so selecting text or dragging a file never triggers it.
final class DragSnapper {
    private let store: WindowStore
    private let controller: WindowController
    private let overlay = SnapOverlay()
    private let zones = ZonesOverlay()
    /// Where the window will land when dropped on a saved layout's place, while the drop-zone keys are held.
    private var dropFrame: Rect?
    private var monitor: Any?

    private var window: AXWindow?
    private var startFrame: Rect?
    private var startPoint = CGPoint.zero
    private var isWindowDrag = false
    private var zone: WindowLayout?
    private var zoneDisplay: DisplayInfo?

    init(store: WindowStore, controller: WindowController) {
        self.store = store
        self.controller = controller
    }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            self?.handle(event)
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        reset()
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown: began()
        case .leftMouseDragged: dragged()
        case .leftMouseUp: ended()
        default: break
        }
    }

    private func began() {
        reset()
        let config = store.currentConfig
        guard config.snapOnDrag else { return }
        let point = DisplayManager.mouseLocation()
        guard let found = AXWindow.at(point), found.isStandard, !config.isExcluded(appId: found.appID),
              let frame = found.frame else { return }
        window = found
        startFrame = frame
        startPoint = point
    }

    private func dragged() {
        guard let window, let startFrame else { return }
        let point = DisplayManager.mouseLocation()
        if !isWindowDrag {
            // The window has to follow the mouse, with the same size, before this counts as a window drag.
            guard hypot(point.x - startPoint.x, point.y - startPoint.y) > 6, let now = window.frame else { return }
            let moved = hypot(now.x - startFrame.x, now.y - startFrame.y) > 4
            let sameSize = abs(now.width - startFrame.width) < 3 && abs(now.height - startFrame.height) < 3
            guard moved, sameSize else { return }
            isWindowDrag = true
            // Dragged away from where it was snapped: it gets its old size back.
            if let restored = controller.restoreSizeForDrag(window, current: now, pointer: point) {
                self.startFrame = restored
            }
        }
        let config = store.currentConfig
        guard let display = controller.displays.display(at: point) else { return }
        if let target = dropTarget(at: point, on: display, config: config) {
            dropFrame = target.frame
            zone = nil
            zoneDisplay = nil
            zones.show(frames: target.all, highlighted: target.index, on: display)
            overlay.show(target.frame)
            return
        }
        if dropFrame != nil {
            // The keys were let go, or the pointer left every place: back to snapping to the edges.
            dropFrame = nil
            zones.hide()
            overlay.hide()
        }
        // With a key required, nothing snaps unless it is held.
        let allowed = config.snapDragModifier == 0 || Self.held(config.snapDragModifier)
        let next = allowed ? windowSnapZone(point: Point(x: point.x, y: point.y), area: display.full, edge: config.edgeMargin, corner: config.cornerSize) : nil
        guard next != zone || display.id != zoneDisplay?.id else { return }
        zone = next
        zoneDisplay = display
        // A light tap as the window reaches an edge, so it can be felt as well as seen.
        if next != nil, config.hapticOnSnap {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        guard config.showPreview, let next else {
            overlay.hide()
            return
        }
        let frame = windowLayoutFrame(layout: next, area: controller.usableArea(display), current: self.startFrame ?? startFrame, gap: config.gap)
        overlay.show(frame)
    }

    private func ended() {
        defer { reset() }
        if isWindowDrag, let window, let dropFrame, let original = startFrame {
            controller.place(window, to: dropFrame, from: original, label: "Drop zone", layout: nil)
            return
        }
        guard isWindowDrag, let window, let zone, let zoneDisplay, let original = startFrame else { return }
        controller.place(window, layout: zone, on: zoneDisplay, from: original)
    }

    private func reset() {
        overlay.hide()
        zones.hide()
        dropFrame = nil
        window = nil
        startFrame = nil
        isWindowDrag = false
        zone = nil
        zoneDisplay = nil
    }

    // MARK: Drop zones

    /// The place under the pointer, when the drop-zone keys are held and a saved layout is chosen.
    private func dropTarget(at point: CGPoint, on display: DisplayInfo, config: WindowConfig) -> (frame: Rect, all: [Rect], index: Int?)? {
        guard config.dropZoneModifier != 0, Self.held(config.dropZoneModifier) else {
            zones.hide()
            return nil
        }
        let layout = store.layouts.first { $0.id == config.dropZoneLayoutId } ?? store.layouts.last { !$0.isAuto && !$0.isGroup }
        guard let layout else { return nil }
        var entries = layout.entries.filter { $0.displayId == display.id }
        if entries.isEmpty, controller.displays.displays.count == 1 { entries = layout.entries }
        guard !entries.isEmpty else { return nil }
        let area = controller.usableArea(display)
        let fractions = entries.map(\.frame)
        let all = fractions.map { windowZoneFrame(area: area, zone: $0) }
        guard let hit = windowDropZoneAt(point: Point(x: point.x, y: point.y), area: area, zones: fractions) else {
            // The keys are held but the pointer is between places: show them, drop nowhere.
            zones.show(frames: all, highlighted: nil, on: display)
            return nil
        }
        return (all[Int(hit)], all, Int(hit))
    }

    private static func held(_ bits: UInt64) -> Bool {
        let flags = NSEvent.modifierFlags
        return (bits & KeyModifiers.shift == 0 || flags.contains(.shift))
            && (bits & KeyModifiers.control == 0 || flags.contains(.control))
            && (bits & KeyModifiers.option == 0 || flags.contains(.option))
            && (bits & KeyModifiers.command == 0 || flags.contains(.command))
    }
}
