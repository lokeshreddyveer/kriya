import AppKit
import SwiftUI

// MARK: - Focus by direction and pointer to window

extension WindowController {
    /// Moves focus to the nearest window in a direction, from the window that has focus now.
    func focusWindow(_ direction: Direction) {
        guard AXIsProcessTrusted(), let current = AXWindow.focused(), let from = current.frame else { return }
        let candidates = WindowController.openWindows(excluding: store.currentConfig)
            .filter { $0.window.key != current.key }
            .map { FocusCandidate(id: $0.window.key, frame: $0.frame) }
        guard let id = windowFocusTarget(from: from, candidates: candidates, direction: direction),
              let target = WindowController.openWindows(excluding: store.currentConfig).first(where: { $0.window.key == id }) else {
            diagnostics.note("No window to the \(String(describing: direction).lowercased())")
            return
        }
        target.window.raise()
    }

    /// Puts the pointer in the middle of the window that has focus, so a keyboard user does not have to hunt for it.
    func movePointerToActiveWindow() {
        guard AXIsProcessTrusted(), let frame = AXWindow.focused()?.frame else { return }
        CGWarpMouseCursorPosition(CGPoint(x: frame.x + frame.width / 2, y: frame.y + frame.height / 2))
        // Warping detaches the mouse from the cursor for a moment; this puts them back together.
        CGAssociateMouseAndMouseCursorPosition(1)
    }
}

// MARK: - Stash

/// Parks windows at the side of the screen, leaving a thin sliver to point at. Pointing at the sliver slides the window
/// out; moving away tucks it back. Doing the command again puts the window where it was.
final class StashManager {
    private struct Entry {
        let window: AXWindow
        var home: Rect
        var edge: StashEdge
        var area: Rect
        var revealed = false
        var outsideSince: Date?
    }

    private let displays: DisplayManager
    private let config: () -> WindowConfig
    private var entries: [String: Entry] = [:]
    private var timer: Timer?
    private var animations: [String: Timer] = [:]

    init(displays: DisplayManager, config: @escaping () -> WindowConfig) {
        self.displays = displays
        self.config = config
    }

    var isEmpty: Bool { entries.isEmpty }

    /// Stashes the focused window, or brings it back if it is already stashed.
    func toggleFocused() {
        guard AXIsProcessTrusted(), let window = AXWindow.focused(), let frame = window.frame else { return }
        if entries[window.key] != nil {
            unstash(window.key)
        } else {
            stash(window, frame: frame)
        }
    }

    func unstashAll() {
        for key in Array(entries.keys) { unstash(key) }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        for animation in animations.values { animation.invalidate() }
        animations.removeAll()
        unstashAll()
    }

    // MARK: Stashing and unstashing

    private func stash(_ window: AXWindow, frame: Rect) {
        guard !window.isFullScreen, let display = displays.display(containing: frame) else { return }
        let sliver = config().stashSliver
        let preferred = windowNearestStashEdge(frame: frame, area: display.full)
        let other: StashEdge = preferred == .left ? .right : .left
        // Hiding a window past an edge that has another display beside it would just show it there.
        guard let edge = [preferred, other].first(where: { !hasNeighbour(of: display, on: $0) }) else {
            Log.info("Windows", "Stash skipped: displays on both sides")
            return
        }
        let hidden = windowStashFrame(frame: frame, area: display.full, edge: edge, sliver: sliver)
        entries[window.key] = Entry(window: window, home: frame, edge: edge, area: display.full)
        slide(window, to: hidden)
        startWatching()
    }

    private func unstash(_ key: String) {
        guard let entry = entries.removeValue(forKey: key) else { return }
        slide(entry.window, to: entry.home)
        if entries.isEmpty { stopWatching() }
    }

    private func hasNeighbour(of display: DisplayInfo, on edge: StashEdge) -> Bool {
        displays.displays.contains { other in
            guard other.id != display.id else { return false }
            let verticalOverlap = min(other.full.y + other.full.height, display.full.y + display.full.height) - max(other.full.y, display.full.y)
            guard verticalOverlap > 0 else { return false }
            switch edge {
            case .left: return abs((other.full.x + other.full.width) - display.full.x) < 2
            case .right: return abs(other.full.x - (display.full.x + display.full.width)) < 2
            }
        }
    }

    // MARK: Watching the pointer

    private func startWatching() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopWatching() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let pointer = DisplayManager.mouseLocation()
        let point = Point(x: pointer.x, y: pointer.y)
        let sliver = config().stashSliver
        for key in Array(entries.keys) {
            guard var entry = entries[key], let frame = entry.window.frame else {
                // The window was closed.
                entries[key] = nil
                continue
            }
            if !entry.revealed {
                let hidden = windowStashFrame(frame: entry.home, area: entry.area, edge: entry.edge, sliver: sliver)
                if windowStashHit(pointer: point, stashed: hidden, area: entry.area, edge: entry.edge) {
                    entry.revealed = true
                    entry.outsideSince = nil
                    entries[key] = entry
                    slide(entry.window, to: windowUnstashFrame(stashed: hidden, area: entry.area, edge: entry.edge))
                    entry.window.raise()
                }
            } else {
                let inside = frame.cg.insetBy(dx: -14, dy: -14).contains(pointer)
                if inside {
                    entry.outsideSince = nil
                } else if let since = entry.outsideSince {
                    if Date().timeIntervalSince(since) > 0.5 {
                        entry.revealed = false
                        entry.outsideSince = nil
                        slide(entry.window, to: windowStashFrame(frame: entry.home, area: entry.area, edge: entry.edge, sliver: sliver))
                    }
                } else {
                    entry.outsideSince = Date()
                }
                entries[key] = entry
            }
        }
        if entries.isEmpty { stopWatching() }
    }

    // MARK: Moving smoothly

    /// Glides a window to a frame instead of jumping. Only the position changes while stashing, so it is cheap.
    private func slide(_ window: AXWindow, to target: Rect) {
        let key = window.key
        animations[key]?.invalidate()
        guard let start = window.frame else { return }
        if abs(start.width - target.width) > 1 || abs(start.height - target.height) > 1 {
            _ = AXWindow.withoutEnhancedInterface(pid: window.pid) { window.setFrame(target) }
            return
        }
        let began = Date()
        let duration = 0.18
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            let t = min(1, Date().timeIntervalSince(began) / duration)
            let eased = 1 - pow(1 - t, 3)
            AXWindow.withoutEnhancedInterface(pid: window.pid) {
                window.setPosition(start.x + (target.x - start.x) * eased, start.y + (target.y - start.y) * eased)
            }
            if t >= 1 {
                timer.invalidate()
                self?.animations[key] = nil
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        animations[key] = timer
    }
}

// MARK: - Radial menu

private let radialLayouts: [WindowLayout] = {
    // Eight compass directions, clockwise from the right.
    (0..<8).map { step in
        let angle = Double(step) * .pi / 4
        return windowRadialLayout(dx: cos(angle) * 100, dy: sin(angle) * 100, deadZone: 0)
    }
}()

private func radialSymbol(_ layout: WindowLayout) -> String {
    switch layout {
    case .leftHalf: return "rectangle.lefthalf.inset.filled"
    case .rightHalf: return "rectangle.righthalf.inset.filled"
    case .topHalf: return "rectangle.tophalf.inset.filled"
    case .bottomHalf: return "rectangle.bottomhalf.inset.filled"
    case .topLeft: return "rectangle.inset.topleft.filled"
    case .topRight: return "rectangle.inset.topright.filled"
    case .bottomLeft: return "rectangle.inset.bottomleft.filled"
    case .bottomRight: return "rectangle.inset.bottomright.filled"
    default: return "rectangle.inset.filled"
    }
}

final class RadialModel: ObservableObject {
    @Published var selected: WindowLayout = .maximize
}

/// A ring of eight sectors and a centre, drawn around the pointer. Moving the pointer picks a sector; the matching
/// place for the window previews on screen, and a click puts the window there.
private struct RadialView: View {
    @ObservedObject var model: RadialModel
    let outer: CGFloat
    let inner: CGFloat
    let tint: Color

    var body: some View {
        ZStack {
            Circle().fill(.regularMaterial).frame(width: outer * 2, height: outer * 2)
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.12)))
                .shadow(color: .black.opacity(0.25), radius: 14, y: 4)
            ForEach(0..<8, id: \.self) { step in
                let layout = radialLayouts[step]
                Wedge(step: step, inner: inner, outer: outer)
                    .fill(model.selected == layout ? tint.opacity(0.6) : Color.clear)
                    .overlay(Wedge(step: step, inner: inner, outer: outer).stroke(Color.primary.opacity(0.10), lineWidth: 1))
                Image(systemName: radialSymbol(layout))
                    .font(.system(size: 15))
                    .foregroundStyle(model.selected == layout ? Color.white : Color.secondary)
                    .offset(x: cos(Double(step) * .pi / 4) * (inner + outer) / 2, y: sin(Double(step) * .pi / 4) * (inner + outer) / 2)
            }
            Circle()
                .fill(model.selected == .maximize ? tint.opacity(0.6) : Color.primary.opacity(0.06))
                .frame(width: inner * 2, height: inner * 2)
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 14))
                .foregroundStyle(model.selected == .maximize ? Color.white : Color.secondary)
            // The name of what the pointer is on, below the ring, so the direction is never a guess.
            Text(model.selected.title)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(.regularMaterial, in: Capsule())
                .offset(y: outer + 22)
        }
        .animation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .smooth(duration: 0.12), value: model.selected)
        .frame(width: outer * 2, height: outer * 2 + 56, alignment: .top)
    }
}

/// One sector of the ring, drawn with plain trigonometry so the direction is the same as the pointer maths.
private struct Wedge: Shape {
    let step: Int
    let inner: CGFloat
    let outer: CGFloat

    func path(in rect: CGRect) -> Path {
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let mid = Double(step) * .pi / 4
        let start = mid - .pi / 8
        let end = mid + .pi / 8
        let steps = 10
        var path = Path()
        for i in 0...steps {
            let a = start + (end - start) * Double(i) / Double(steps)
            let p = CGPoint(x: centre.x + cos(a) * outer, y: centre.y + sin(a) * outer)
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        for i in stride(from: steps, through: 0, by: -1) {
            let a = start + (end - start) * Double(i) / Double(steps)
            path.addLine(to: CGPoint(x: centre.x + cos(a) * inner, y: centre.y + sin(a) * inner))
        }
        path.closeSubpath()
        return path
    }
}

/// Covers the display with a clear layer that takes the pointer, so choosing a sector never clicks the window behind.
private final class RadialCaptureView: NSView {
    var onMove: ((CGPoint) -> Void)?
    var onClick: ((CGPoint) -> Void)?
    var onCancel: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) { onMove?(convert(event.locationInWindow, from: nil)) }
    override func mouseDragged(with event: NSEvent) { onMove?(convert(event.locationInWindow, from: nil)) }
    override func mouseDown(with event: NSEvent) { let p = convert(event.locationInWindow, from: nil); onMove?(p); onClick?(p) }
    override func rightMouseDown(with event: NSEvent) { onCancel?() }
}

final class RadialMenu {
    private let controller: WindowController
    private let store: WindowStore
    private let model = RadialModel()
    private let preview = SnapOverlay()
    private var panel: NSPanel?
    private var keyMonitor: Any?
    private var releaseTimer: Timer?
    private var heldModifiers: NSEvent.ModifierFlags = []
    private var timeout: DispatchWorkItem?
    private var target: AXWindow?
    private var centre = CGPoint.zero      // in the capture view's coordinates (AppKit, origin bottom left)
    private var display: DisplayInfo?
    private var outer: CGFloat = 104
    private var inner: CGFloat = 30

    init(controller: WindowController, store: WindowStore) {
        self.controller = controller
        self.store = store
    }

    var isOpen: Bool { panel != nil }

    func toggle() {
        if isOpen { close() } else { open() }
    }

    func close() {
        timeout?.cancel()
        releaseTimer?.invalidate()
        releaseTimer = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        preview.hide()
        guard let panel else { return }
        self.panel = nil
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: { panel.orderOut(nil) })
    }

    private func open() {
        guard AXIsProcessTrusted(), let window = AXWindow.focused(), window.frame != nil, !window.isFullScreen else { return }
        let pointer = DisplayManager.mouseLocation()
        guard let display = controller.displays.display(at: pointer),
              let screen = NSScreen.screens.first(where: { $0.frame.insetBy(dx: -1, dy: -1).contains(NSEvent.mouseLocation) }) ?? NSScreen.main else { return }
        target = window
        self.display = display
        model.selected = .maximize

        let capture = RadialCaptureView(frame: CGRect(origin: .zero, size: screen.frame.size))
        // Keep the whole ring on screen, even when the pointer is at an edge.
        outer = CGFloat(store.currentConfig.radialSize)
        inner = outer * 0.29
        let mouse = NSEvent.mouseLocation
        let margin = outer + 8
        centre = CGPoint(
            x: min(max(mouse.x - screen.frame.minX, margin), screen.frame.width - margin),
            y: min(max(mouse.y - screen.frame.minY, margin), screen.frame.height - margin)
        )
        let host = NSHostingView(rootView: RadialView(model: model, outer: outer, inner: inner, tint: .fromHex(store.currentConfig.radialColor)))
        host.frame = CGRect(x: centre.x - outer, y: centre.y - outer - 56, width: outer * 2, height: outer * 2 + 56)
        capture.addSubview(host)
        capture.onMove = { [weak self] point in self?.moved(to: point) }
        // A click well outside the ring is a way out: nothing is moved.
        capture.onClick = { [weak self] point in
            guard let self else { return }
            if hypot(point.x - self.centre.x, point.y - self.centre.y) > self.outer + 16 { self.close() } else { self.commit() }
        }
        capture.onCancel = { [weak self] in self?.close() }

        let panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isReleasedWhenClosed = false
        panel.acceptsMouseMovedEvents = true
        panel.contentView = capture
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            panel.animator().alphaValue = 1
        }
        self.panel = panel

        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            switch event.keyCode {
            case 53: self?.close()        // Escape
            case 36, 76: self?.commit()   // Return
            default: break
            }
        }
        // Held like Loop's ring: while the shortcut's modifiers stay down, moving toward a sector picks it and letting go
        // applies it. Letting go without having moved leaves the ring open to be clicked.
        let relevant: NSEvent.ModifierFlags = [.control, .option, .command, .shift]
        heldModifiers = NSEvent.modifierFlags.intersection(relevant)
        if !heldModifiers.isEmpty {
            let timer = Timer(timeInterval: 0.02, repeats: true) { [weak self] _ in
                guard let self, self.isOpen else { return }
                if !NSEvent.modifierFlags.intersection(relevant).isSuperset(of: self.heldModifiers) {
                    self.releaseTimer?.invalidate()
                    self.releaseTimer = nil
                    if self.model.selected != .maximize { self.commit() }
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            releaseTimer = timer
        }
        let work = DispatchWorkItem { [weak self] in self?.close() }
        timeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
    }

    private func moved(to point: CGPoint) {
        // AppKit's y grows upward; the sector maths use screen y growing downward.
        let layout = windowRadialLayout(dx: point.x - centre.x, dy: -(point.y - centre.y), deadZone: inner)
        guard layout != model.selected else { return }
        model.selected = layout
        showPreview(for: layout)
    }

    private func showPreview(for layout: WindowLayout) {
        guard store.currentConfig.showPreview, let display, let frame = target?.frame else { return }
        preview.show(windowLayoutFrame(layout: layout, area: controller.usableArea(display), current: frame, gap: store.currentConfig.gap))
    }

    private func commit() {
        let layout = model.selected
        let window = target
        close()
        guard let window else { return }
        controller.snap(window, to: layout)
    }
}
