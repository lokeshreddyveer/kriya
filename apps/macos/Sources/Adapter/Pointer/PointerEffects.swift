import AppKit
import Combine
import CoreImage
import CoreMedia
import CoreVideo
import ScreenCaptureKit
import SwiftUI

// MARK: - Views

/// The glow that follows the pointer.
private struct HaloView: View {
    let style: HaloStyle
    let color: Color
    let opacity: Double
    let pulse: Bool
    let size: CGFloat
    @State private var breathing = false

    var body: some View {
        Group {
            switch style {
            case .filled: Circle().fill(color.opacity(opacity))
            case .ring: Circle().strokeBorder(color.opacity(opacity), lineWidth: max(3, size * 0.09))
            }
        }
        .padding(4)
        .scaleEffect(pulse && breathing ? 1.12 : 1)
        .animation(pulse ? .easeInOut(duration: 1.1).repeatForever(autoreverses: true) : .default, value: breathing)
        .onAppear { breathing = true }
    }
}

/// The rings for clicks and for finding the pointer. Each is drawn with Core Animation in a small window that is made once and then
/// used again, never a new window for every click: making and discarding a top-level window on every mouse press made the whole
/// screen flash dark on some Macs, most visibly when a press landed on Kriya's own menu-bar windows.
final class RingPool {
    private final class Ring {
        let panel: NSPanel
        let layer = CAShapeLayer()
        let shareable: Bool
        init(shareable: Bool) {
            self.shareable = shareable
            panel = makeOverlay(size: 64, shareable: shareable)
            let view = NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
            view.wantsLayer = true
            layer.opacity = 0
            view.layer?.addSublayer(layer)
            panel.contentView = view
        }
    }

    /// The name of the animation on a ring's layer (an animation key, not a saved preference).
    private static let animationName = "kriya.ring"
    private var idle: [Ring] = []
    private var inUse = 0
    private static let limit = 8

    /// Windows waiting to be used, for the tests.
    var idleCount: Int { idle.count }
    var activeCount: Int { inUse }

    func show(at point: NSPoint, color: NSColor, side: CGFloat, duration: Double, shareable: Bool) {
        guard inUse < Self.limit, side > 0 else { return }
        // Windows made for the other sharing choice are let go: macOS only lets a window's sharing be tightened, not loosened.
        idle.removeAll { $0.shareable != shareable }
        let ring = idle.popLast() ?? Ring(shareable: shareable)
        inUse += 1
        ring.panel.setFrame(NSRect(x: point.x - side / 2, y: point.y - side / 2, width: side, height: side), display: false)
        ring.panel.contentView?.frame = NSRect(x: 0, y: 0, width: side, height: side)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let layer = ring.layer
        layer.frame = NSRect(x: 0, y: 0, width: side, height: side)
        let lineWidth: CGFloat = 5
        layer.path = CGPath(ellipseIn: layer.bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2), transform: nil)
        layer.lineWidth = lineWidth
        layer.strokeColor = color.cgColor
        layer.fillColor = color.withAlphaComponent(0.18).cgColor
        layer.opacity = 0
        CATransaction.commit()
        ring.panel.orderFrontRegardless()

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            layer.removeAllAnimations()
            ring.panel.orderOut(nil)
            self?.inUse -= 1
            self?.idle.append(ring)
        }
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.25
        grow.toValue = 1
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.95
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [grow, fade]
        group.duration = max(duration, 0.05)
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(group, forKey: Self.animationName)
        CATransaction.commit()
    }
}

// MARK: - Panels

/// A borderless, click-through panel above everything. Hidden from screen capture unless the person wants it shown.
private func makeOverlay(size: CGFloat, shareable: Bool) -> NSPanel {
    let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: size, height: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.ignoresMouseEvents = true
    panel.level = .screenSaver
    panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
    panel.isReleasedWhenClosed = false
    panel.sharingType = shareable ? .readOnly : .none
    return panel
}

// MARK: - Magnifier

/// A live, zoomed view of the screen around the pointer, in a small window that follows it. Needs Screen Recording. The capture
/// follows the pointer from one display to the next, at each display's own scale, and the window takes new settings while it is on.
final class PointerMagnifier: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private var panel: NSPanel?
    private let imageLayer = CALayer()
    private let ciContext = CIContext()
    private var timer: Timer?
    private var screenSize = CGSize.zero
    private var displayOrigin = CGPoint.zero      // the display's top-left, in the accessibility coordinates
    private(set) var size: Double = 220
    private(set) var zoom: Double = 2.5
    private(set) var config: PointerEffectsConfig?
    /// The display being captured, and its scale (a Retina display and an ordinary one differ).
    private var capturedDisplay: CGDirectDisplayID?
    private var scale: CGFloat = 2
    private var updating = false
    private var starting = false
    private var retargeting = false
    private var displays: DisplayManager?
    private let queue = DispatchQueue(label: "app.kriya.magnifier", qos: .userInteractive)

    /// Said when the capture ends by itself (Screen Recording taken away, the display went away), so the person is told why.
    var onStopped: ((String) -> Void)?

    /// On, including the moment it is moving its capture to another display.
    var isOn: Bool { stream != nil || retargeting }
    var hasPanel: Bool { panel != nil }

    func start(config: PointerEffectsConfig, displays: DisplayManager, zoom: Double) async -> String? {
        guard !starting, !retargeting, stream == nil else { return nil }
        starting = true
        defer { starting = false }
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            return "The magnifier needs Screen Recording. Allow it in System Settings, then try again."
        }
        self.config = config
        self.displays = displays
        self.zoom = zoom
        size = config.magnifierSize
        if let problem = await attach() { return problem }
        await MainActor.run { showPanel() }
        return nil
    }

    /// Points the capture at the display the pointer is on, replacing the stream that was running. Used to start, and again when the
    /// pointer moves to another display or the displays change.
    private func attach() async -> String? {
        guard let config, let displays else { return "Could not capture this display." }
        displays.refresh()
        let pointer = DisplayManager.mouseLocation()
        guard let display = displays.display(at: pointer),
              let screen = NSScreen.screens.first(where: { abs($0.frame.width - display.full.width) < 2 && abs($0.frame.height - display.full.height) < 2 && abs($0.frame.minX - display.full.x) < 2 }),
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true),
              let scDisplay = content.displays.first(where: { $0.displayID == number }) else { return "Could not capture this display." }
        let old = stream
        stream = nil
        try? await old?.stopCapture()
        screenSize = CGSize(width: display.full.width, height: display.full.height)
        displayOrigin = CGPoint(x: display.full.x, y: display.full.y)
        scale = screen.backingScaleFactor

        let mine = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        let filter = SCContentFilter(display: scDisplay, excludingApplications: mine, exceptingWindows: [])
        let stream = SCStream(filter: filter, configuration: streamConfiguration(pointer: pointer, config: config), delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            try await stream.startCapture()
        } catch {
            return "Could not start the magnifier: \(error.localizedDescription)"
        }
        self.stream = stream
        capturedDisplay = number
        return nil
    }

    private func streamConfiguration(pointer: CGPoint, config: PointerEffectsConfig) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        let pixels = MagnifierGeometry.pixels(points: size, scale: Double(scale))
        configuration.width = pixels
        configuration.height = pixels
        configuration.sourceRect = sourceRect(for: pointer, config: config)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.showsCursor = true
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        return configuration
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        let stream = stream
        self.stream = nil
        capturedDisplay = nil
        Task { try? await stream?.stopCapture() }
        panel?.orderOut(nil)
        panel = nil
    }

    func adjustZoom(by factor: Double) {
        zoom = min(8, max(1.5, zoom * factor))
    }

    /// New settings while the magnifier is on: its size, shape, whether the audience sees it, and its zoom. The capture picks up the
    /// new size at the next frame.
    func update(config new: PointerEffectsConfig) {
        let old = config
        config = new
        size = new.magnifierSize
        if old?.magnifierZoom != new.magnifierZoom { zoom = new.magnifierZoom }
        guard let panel else { return }
        // macOS lets a window's sharing be tightened but not loosened once it exists, so a change is made with a new window.
        if old?.showWhenSharing != new.showWhenSharing {
            panel.orderOut(nil)
            self.panel = nil
            buildPanel()
            return
        }
        let side = CGFloat(size)
        panel.setContentSize(NSSize(width: side, height: side))
        panel.contentView?.frame = NSRect(x: 0, y: 0, width: side, height: side)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = NSRect(x: 0, y: 0, width: side, height: side)
        imageLayer.cornerRadius = new.magnifierShape == .circle ? side / 2 : 14
        CATransaction.commit()
    }

    // MARK: Showing it

    private func showPanel() {
        buildPanel()
        let timer = Timer(timeInterval: 1.0 / 40.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// The window that shows the picture. Made new whenever it has to change in a way an open window cannot.
    private func buildPanel() {
        guard let config else { return }
        let panel = makeOverlay(size: CGFloat(size), shareable: config.showWhenSharing)
        let view = NSView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        view.wantsLayer = true
        imageLayer.frame = view.bounds
        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.masksToBounds = true
        imageLayer.cornerRadius = config.magnifierShape == .circle ? CGFloat(size) / 2 : 14
        imageLayer.borderWidth = 2
        imageLayer.borderColor = NSColor.white.withAlphaComponent(0.85).cgColor
        view.layer?.addSublayer(imageLayer)
        panel.contentView = view
        panel.hasShadow = true
        panel.orderFrontRegardless()
        self.panel = panel
    }

    /// Moves the window beside the pointer and points the capture at what is under it.
    private func tick() {
        guard let config else { return }
        let pointer = DisplayManager.mouseLocation()
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
        if let panel, let screen {
            var origin = NSPoint(x: mouse.x + 28, y: mouse.y + 28)
            let frame = screen.visibleFrame
            if origin.x + CGFloat(size) > frame.maxX { origin.x = mouse.x - 28 - CGFloat(size) }
            if origin.y + CGFloat(size) > frame.maxY { origin.y = mouse.y - 28 - CGFloat(size) }
            panel.setFrameOrigin(origin)
        }
        guard let stream, !updating, !retargeting else { return }
        // The pointer went to another display (or the picture is at another scale there): capture that one instead.
        if let number = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID, number != capturedDisplay {
            retarget()
            return
        }
        updating = true
        let configuration = streamConfiguration(pointer: pointer, config: config)
        Task { [weak self] in
            try? await stream.updateConfiguration(configuration)
            self?.updating = false
        }
    }

    private func retarget() {
        retargeting = true
        Task { [weak self] in
            guard let self else { return }
            let problem = await self.attach()
            await MainActor.run {
                self.retargeting = false
                if let problem { self.stop(); self.onStopped?(problem) }
            }
        }
    }

    /// The area to show, in the display's own top-left coordinates.
    private func sourceRect(for pointer: CGPoint, config: PointerEffectsConfig) -> CGRect {
        let local = Point(x: pointer.x - displayOrigin.x, y: pointer.y - displayOrigin.y)
        let source = pointerMagnifierSource(pointer: local, size: size, zoom: zoom, bounds: Rect(x: 0, y: 0, width: screenSize.width, height: screenSize.height))
        return CGRect(x: source.x, y: source.y, width: source.width, height: source.height)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let image = CIImage(cvPixelBuffer: buffer)
        guard let cg = ciContext.createCGImage(image, from: image.extent) else { return }
        DispatchQueue.main.async { [weak self] in
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self?.imageLayer.contents = cg
            CATransaction.commit()
        }
    }

    /// The capture ended without being asked to: Screen Recording was taken away, or the display went. The window goes with it.
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.stream === stream else { return }
            self.stop()
            self.onStopped?("The magnifier stopped: \(error.localizedDescription)")
        }
    }
}

// MARK: - Spotlight

/// Where the bright area of the spotlight is.
enum SpotlightGeometry {
    /// The bright area around `center`, `size` points wide: a circle, or a wider, shorter rounded rectangle.
    static func hole(center: CGPoint, size: Double, shape: SpotlightShape) -> CGRect {
        switch shape {
        case .circle:
            return CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)
        case .roundedRectangle:
            let width = size * 1.6
            let height = size * 0.8
            return CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
        }
    }

    static func cornerRadius(for hole: CGRect, shape: SpotlightShape) -> CGFloat {
        shape == .circle ? hole.width / 2 : min(hole.height * 0.2, 28)
    }

    /// The dimmed part of a display: all of it except the hole (drawn with the even-odd rule).
    static func dimPath(bounds: CGRect, hole: CGRect?, shape: SpotlightShape) -> CGPath {
        let path = CGMutablePath()
        path.addRect(bounds)
        if let hole, hole.intersects(bounds) {
            let radius = cornerRadius(for: hole, shape: shape)
            path.addRoundedRect(in: hole, cornerWidth: radius, cornerHeight: radius)
        }
        return path
    }
}

private final class SpotlightDimView: NSView {
    private let dim = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        dim.fillRule = .evenOdd
        dim.fillColor = NSColor.black.cgColor
        layer?.addSublayer(dim)
    }

    required init?(coder: NSCoder) { nil }

    /// Redraws the dim with the hole at `center` (in this view's own coordinates), without any implicit animation.
    func update(center: CGPoint, size: Double, shape: SpotlightShape, dim opacity: Double) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dim.frame = bounds
        dim.opacity = Float(opacity)
        dim.path = SpotlightGeometry.dimPath(bounds: bounds, hole: SpotlightGeometry.hole(center: center, size: size, shape: shape), shape: shape)
        CATransaction.commit()
    }
}

/// Darkens every display except the area around the pointer. One click-through window per display, so the bright area can
/// sit across two displays, and each follows the pointer.
final class PointerSpotlight {
    private var panels: [(panel: NSPanel, view: SpotlightDimView, screen: NSScreen)] = []
    private var monitors: [Any] = []
    private var screenObserver: NSObjectProtocol?
    private var config: PointerEffectsConfig?

    var isOn: Bool { !panels.isEmpty }
    /// How many windows it has open, one per display.
    var panelCount: Int { panels.count }
    /// Whether each window is open to screen sharing, for the tests.
    var sharingTypes: [NSWindow.SharingType] { panels.map(\.panel.sharingType) }

    func start(config: PointerEffectsConfig) {
        guard !isOn else { update(config); return }
        self.config = config
        buildPanels()
        let move: (NSEvent) -> Void = { [weak self] _ in self?.follow() }
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: events, handler: move) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: events, handler: { event in move(event); return event }) { monitors.append(local) }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.rebuild()
        }
        follow()
        for item in panels {
            item.panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.22; item.panel.animator().alphaValue = 1 }
        }
    }

    func update(_ config: PointerEffectsConfig) {
        let sharingChanged = config.showWhenSharing != self.config?.showWhenSharing
        self.config = config
        // macOS lets a window's sharing be tightened but not loosened once it exists, so a change is made by opening new windows.
        if isOn, sharingChanged { rebuild() } else { follow() }
    }

    func stop() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        let closing = panels.map(\.panel)
        panels.removeAll()
        guard !closing.isEmpty else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            for panel in closing { panel.animator().alphaValue = 0 }
        }, completionHandler: {
            for panel in closing { panel.orderOut(nil) }
        })
    }

    private func buildPanels() {
        panels = NSScreen.screens.map { screen in
            let panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            panel.isReleasedWhenClosed = false
            panel.sharingType = config?.showWhenSharing == true ? .readOnly : .none
            panel.alphaValue = 0
            let view = SpotlightDimView(frame: NSRect(origin: .zero, size: screen.frame.size))
            panel.contentView = view
            panel.setFrame(screen.frame, display: false)
            return (panel, view, screen)
        }
    }

    /// The displays changed (one was plugged in, or the arrangement changed): start over on the new set.
    private func rebuild() {
        let old = panels.map(\.panel)
        panels.removeAll()
        for panel in old { panel.orderOut(nil) }
        buildPanels()
        for item in panels {
            item.panel.alphaValue = 1
            item.panel.orderFrontRegardless()
        }
        follow()
    }

    private func follow() {
        guard let config else { return }
        let mouse = NSEvent.mouseLocation
        for item in panels {
            // The pointer in this display's own coordinates; a bright area that crosses into the next display is drawn on both.
            let local = CGPoint(x: mouse.x - item.screen.frame.minX, y: mouse.y - item.screen.frame.minY)
            item.view.update(center: local, size: config.spotlightSize, shape: config.spotlightShape, dim: config.spotlightDim)
        }
    }
}

// MARK: - Hiding the pointer

/// Hides the pointer after it has been still for a while, while the person types, or when asked, and brings it back at the first
/// movement. Each reason is kept apart, so turning one off never shows a pointer another still wants hidden, and every hide is matched
/// with one show on the same display. macOS lets only the app in front hide the pointer, so this asks the window server to allow it
/// from the background; if that is not possible the pointer simply stays visible.
final class PointerHider {
    private var timer: Timer?
    private var monitors: [Any] = []
    private var lastMove = Date()
    private(set) var state = PointerHideState()
    /// The display the hide was issued for, so the show is issued for the same one.
    private var hiddenOn: CGDirectDisplayID?
    private var idleEnabled = false
    private var typingEnabled = false
    private var after: TimeInterval = 5

    var isHidden: Bool { state.isHidden }

    /// Turns hiding when idle on or off, and sets how long the pointer must be still.
    func setIdle(_ on: Bool, after seconds: Double) {
        after = seconds
        if on, !idleEnabled {
            idleEnabled = true
            lastMove = Date()
            let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.check() }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else if !on, idleEnabled {
            idleEnabled = false
            timer?.invalidate()
            timer = nil
            if state.remove(.idle) { show() }
        }
        updateWatchers()
    }

    /// Turns hiding while typing on or off.
    func setTyping(_ on: Bool) {
        guard typingEnabled != on else { return }
        typingEnabled = on
        if !on, state.remove(.typing) { show() }
        updateWatchers()
    }

    /// A key was pressed: hide until the mouse moves.
    func hideForTyping() {
        guard typingEnabled else { return }
        add(.typing)
    }

    /// The "Hide the pointer" command: hide until the mouse moves.
    func hideManually() { add(.manual) }

    /// The "Show the pointer now" command.
    func showNow() {
        if state.removeAll() { show() }
        updateWatchers()
    }

    /// Everything off: the pointer is shown and nothing is watched.
    func stop() {
        idleEnabled = false
        typingEnabled = false
        timer?.invalidate()
        timer = nil
        if state.removeAll() { show() }
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
    }

    private func add(_ reason: PointerHideReason) {
        updateWatchers(force: true)
        if state.add(reason) { hide() }
    }

    /// The mouse is only watched while something could hide the pointer or the pointer is hidden.
    private func updateWatchers(force: Bool = false) {
        let needed = force || idleEnabled || typingEnabled || state.isHidden
        if needed, monitors.isEmpty {
            let wake: (NSEvent) -> Void = { [weak self] _ in self?.moved() }
            let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .scrollWheel, .leftMouseDown, .rightMouseDown, .otherMouseDown]
            if let global = NSEvent.addGlobalMonitorForEvents(matching: events, handler: wake) { monitors.append(global) }
            if let local = NSEvent.addLocalMonitorForEvents(matching: events, handler: { event in wake(event); return event }) { monitors.append(local) }
        } else if !needed, !monitors.isEmpty {
            for monitor in monitors { NSEvent.removeMonitor(monitor) }
            monitors.removeAll()
        }
    }

    private func moved() {
        lastMove = Date()
        if state.removeAll() { show() }
        updateWatchers()
    }

    private func check() {
        guard idleEnabled, !state.isHidden, Date().timeIntervalSince(lastMove) >= after else { return }
        if state.add(.idle) { hide() }
    }

    /// The display the pointer is on.
    private static func displayUnderPointer() -> CGDirectDisplayID {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
        return (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) ?? CGMainDisplayID()
    }

    private func hide() {
        allowBackgroundCursorControl()
        let display = Self.displayUnderPointer()
        CGDisplayHideCursor(display)
        hiddenOn = display
    }

    private func show() {
        CGDisplayShowCursor(hiddenOn ?? CGMainDisplayID())
        hiddenOn = nil
    }

    private func allowBackgroundCursorControl() {
        typealias MainConnection = @convention(c) () -> Int32
        typealias SetProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
        guard let handle = dlopen(nil, RTLD_NOW), let mainPointer = dlsym(handle, "CGSMainConnectionID"),
              let setPointer = dlsym(handle, "CGSSetConnectionProperty") else { return }
        let main = unsafeBitCast(mainPointer, to: MainConnection.self)
        let set = unsafeBitCast(setPointer, to: SetProperty.self)
        let connection = main()
        _ = set(connection, connection, "SetsCursorInBackground" as CFString, kCFBooleanTrue as CFTypeRef)
    }
}

// MARK: - The service

/// Pointer effects: a halo, click rings, finding the pointer, a magnifier, hiding the pointer when idle, saved positions
/// and a presentation mode that turns on the halo and the click rings. Each action is a command.
final class PointerEffects {
    static let commands: [(command: String, title: String)] = {
        func entry(_ command: String, _ title: String) -> (command: String, title: String) { (command: command, title: title) }
        return [
            entry("pointer.locate", "Find the pointer"),
            entry("pointer.magnifier", "Magnify around the pointer (on or off)"),
            entry("pointer.zoom_in", "Magnifier: zoom in"),
            entry("pointer.zoom_out", "Magnifier: zoom out"),
            entry("pointer.show", "Show the pointer now"),
            entry("pointer.hide", "Hide the pointer until the mouse moves"),
            entry("pointer.center_display", "Move the pointer to the middle of its display"),
            entry("pointer.presentation", "Presentation mode (on or off)"),
            entry("pointer.spotlight", "Spotlight (on or off)"),
        ]
    }()

    private let store: PointerEffectsStore
    private let displays: DisplayManager
    private let executor: ActionExecutor
    private let toast = Toast()
    private let magnifier = PointerMagnifier()
    private let hider = PointerHider()
    private let spotlight = PointerSpotlight()

    private var halo: NSPanel?
    private var haloKey = ""
    private let rings = RingPool()
    private var monitors: [Any] = []
    private var registered = Set<String>()
    private var cancellables = Set<AnyCancellable>()
    private var presentation = false
    private lazy var hotkeys = HotkeyCenter(owner: "Pointer effects") { [weak self] command in self?.run(command) }

    // Double-tap Control and mouse shaking, watched only while the effects are on and one of them is wanted.
    private var findMonitors: [Any] = []
    private var controlDownAt: Date?
    private var lastControlTap: Date?
    private var shakeTrail: [(point: NSPoint, time: Date)] = []
    private var lastShakeFind = Date.distantPast

    init(store: PointerEffectsStore, displays: DisplayManager, executor: ActionExecutor) {
        self.store = store
        self.displays = displays
        self.executor = executor
        magnifier.onStopped = { [weak self] message in self?.toast.show(message, isError: true) }
    }

    // Sleep and wake: the spotlight and the magnifier are taken down when the displays go to sleep (a capture does not survive it, and
    // a transparent window must not be left behind) and put back when they wake.
    private var sleepObservers: [NSObjectProtocol] = []
    private var resumeAfterWake: (spotlight: Bool, magnifier: Bool)?

    private func watchSleep() {
        guard sleepObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        sleepObservers = [
            center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in self?.suspend() },
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in self?.suspend() },
            center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.resume() },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.resume() },
        ]
    }

    private func suspend() {
        guard resumeAfterWake == nil, spotlight.isOn || magnifier.isOn else { return }
        resumeAfterWake = (spotlight.isOn, magnifier.isOn)
        if spotlight.isOn { spotlight.stop() }
        if magnifier.isOn { magnifier.stop() }
    }

    private func resume() {
        guard let wanted = resumeAfterWake else { return }
        resumeAfterWake = nil
        // The displays take a moment to come back.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            if wanted.spotlight, !self.spotlight.isOn { self.setSpotlight(true) }
            if wanted.magnifier, !self.magnifier.isOn, self.store.current.enabled { self.toggleMagnifier() }
        }
    }

    func start() {
        watchSleep()
        for (command, _) in Self.commands { register(command) { [weak self] in self?.run(command) } }
        store.$config
            .receive(on: DispatchQueue.main)
            .sink { [weak self] config in
                self?.registerPositions(config)
                self?.updateShortcuts(config)
                self?.apply()
            }
            .store(in: &cancellables)
    }

    func stop() {
        cancellables.removeAll()
        for observer in sleepObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        sleepObservers.removeAll()
        resumeAfterWake = nil
        stopWatching()
        hider.stop()
        magnifier.stop()
        spotlight.stop()
        hotkeys.unregisterAll()
        stopFindWatchers()
        for command in registered { executor.unregisterCommand(command) }
        registered.removeAll()
    }

    // MARK: Commands

    /// Presentation mode and the spotlight are things a person asks for outright, so they work even with the master switch off.
    private static let alwaysAvailable: Set<String> = ["pointer.presentation", "pointer.spotlight"]

    private func register(_ command: String, _ work: @escaping () -> Void) {
        registered.insert(command)
        let always = Self.alwaysAvailable.contains(command)
        executor.registerCommand(command) { [weak self] in
            guard always || self?.store.current.enabled == true else { return }
            DispatchQueue.main.async { work() }
        }
    }

    private func registerPositions(_ config: PointerEffectsConfig) {
        for command in registered where command.hasPrefix("pointer.go.") {
            executor.unregisterCommand(command)
            registered.remove(command)
        }
        for position in config.positions {
            let id = position.id
            register(pointerPositionCommand(id: id)) { [weak self] in self?.go(to: id) }
        }
    }

    /// Puts the pointer in the middle of the display it is on (the Mac's own coordinates: origin top left of the main display).
    static func centerPointerOnItsDisplay() {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main, let primary = NSScreen.screens.first else { return }
        let x = screen.frame.midX
        let y = primary.frame.height - screen.frame.midY
        CGWarpMouseCursorPosition(CGPoint(x: x, y: y))
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    private func run(_ command: String) {
        switch command {
        case "pointer.locate": locate()
        case "pointer.magnifier": toggleMagnifier()
        case "pointer.zoom_in": magnifier.adjustZoom(by: 1.25)
        case "pointer.zoom_out": magnifier.adjustZoom(by: 0.8)
        case "pointer.show": hider.showNow()
        case "pointer.hide": hider.hideManually()
        case "pointer.center_display": Self.centerPointerOnItsDisplay()
        case "pointer.spotlight":
            setSpotlight(!spotlight.isOn)
            toast.show(spotlight.isOn ? "Spotlight on" : "Spotlight off")
        case "pointer.presentation":
            presentation.toggle()
            store.presentationOn = presentation
            // The spotlight follows presentation mode when the person asked for that.
            if store.current.presentationSpotlight { setSpotlight(presentation) }
            toast.show(presentation ? "Presentation mode on" : "Presentation mode off")
            apply()
        default: break
        }
    }

    private func setSpotlight(_ on: Bool) {
        if on { spotlight.start(config: store.current) } else { spotlight.stop() }
        store.spotlightOn = spotlight.isOn
    }

    private func updateShortcuts(_ config: PointerEffectsConfig) {
        var bindings: [ShortcutBinding] = []
        if let key = config.spotlightKey, config.spotlightModifiers != 0 {
            bindings.append(ShortcutBinding(command: "pointer.spotlight", keyCode: key, modifiers: config.spotlightModifiers))
        }
        if let key = config.presentationKey, config.presentationModifiers != 0 {
            bindings.append(ShortcutBinding(command: "pointer.presentation", keyCode: key, modifiers: config.presentationModifiers))
        }
        hotkeys.update(bindings)
    }

    // MARK: Keeping the watchers in step with the settings

    /// Starts and stops the halo, the click rings and the idle hiding to match the settings and presentation mode.
    private func apply() {
        let config = store.current
        // Presentation mode stands on its own: it shows the highlight and the rings even when the master switch is off.
        let wantsHalo = (config.enabled && config.haloEnabled) || presentation
        let wantsClicks = (config.enabled && config.clickEnabled) || presentation
        if wantsHalo || wantsClicks { startWatching(halo: wantsHalo, clicks: wantsClicks) } else { stopWatching() }
        if wantsHalo { updateHalo(config) } else { halo?.orderOut(nil) }
        // Hiding when idle and hiding while typing are separate reasons: turning one off never shows a pointer the other still hides.
        hider.setIdle(config.enabled && config.hideWhenIdle, after: config.hideAfterSeconds)
        hider.setTyping(config.enabled && config.hideWhileTyping)
        if !config.enabled, magnifier.isOn { magnifier.stop() } else if magnifier.isOn { magnifier.update(config: config) }
        if spotlight.isOn { spotlight.update(config) }
        if config.enabled, config.doubleTapControl || config.shakeToLocate || config.magnifierHoldModifier != 0 || config.hideWhileTyping { startFindWatchers() } else { stopFindWatchers() }
    }

    // MARK: Finding the pointer with a double tap or a shake

    private func startFindWatchers() {
        guard findMonitors.isEmpty else { return }
        let handler: (NSEvent) -> Void = { [weak self] event in self?.handleFind(event) }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .mouseMoved, .keyDown], handler: handler) { findMonitors.append(global) }
    }

    private func stopFindWatchers() {
        for monitor in findMonitors { NSEvent.removeMonitor(monitor) }
        findMonitors.removeAll()
        controlDownAt = nil
        shakeTrail.removeAll()
    }

    private var holdingMagnifier = false

    private func handleFind(_ event: NSEvent) {
        let config = store.current
        // Hold the chosen keys and the magnifier shows; let go and it goes.
        if event.type == .flagsChanged, config.magnifierHoldModifier != 0 {
            let held = KeyModifiers.bits(from: event.modifierFlags)
            if held == config.magnifierHoldModifier, !magnifier.isOn {
                holdingMagnifier = true
                toggleMagnifier()
            } else if held != config.magnifierHoldModifier, holdingMagnifier {
                holdingMagnifier = false
                if magnifier.isOn { magnifier.stop() }
            }
        }
        // The pointer steps out of the way while typing, and comes back when the mouse moves.
        if event.type == .keyDown, config.hideWhileTyping, !event.isARepeat, !event.modifierFlags.contains(.command) {
            hider.hideForTyping()
        }
        switch event.type {
        case .flagsChanged where config.doubleTapControl:
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).intersection([.control, .shift, .option, .command])
            if flags == [.control] {
                controlDownAt = Date()
            } else if flags.isEmpty, let down = controlDownAt {
                controlDownAt = nil
                // A quick press and release counts as a tap; two within 0.4 s find the pointer.
                guard Date().timeIntervalSince(down) < 0.3 else { return }
                if let last = lastControlTap, Date().timeIntervalSince(last) < 0.4 {
                    lastControlTap = nil
                    locate()
                } else {
                    lastControlTap = Date()
                }
            } else {
                controlDownAt = nil
                lastControlTap = nil
            }
        case .mouseMoved where config.shakeToLocate:
            let now = Date()
            shakeTrail.append((NSEvent.mouseLocation, now))
            shakeTrail.removeAll { now.timeIntervalSince($0.time) > 0.6 }
            // Several quick turns of direction along the same line is a shake.
            // Along either axis: a shake can be side to side or up and down.
            var turnsX = 0, turnsY = 0
            var lastX = 0.0, lastY = 0.0
            for index in 1..<max(shakeTrail.count, 1) {
                let dx = shakeTrail[index].point.x - shakeTrail[index - 1].point.x
                let dy = shakeTrail[index].point.y - shakeTrail[index - 1].point.y
                if abs(dx) > 8 {
                    if lastX != 0, dx.sign != lastX.sign { turnsX += 1 }
                    lastX = dx
                }
                if abs(dy) > 8 {
                    if lastY != 0, dy.sign != lastY.sign { turnsY += 1 }
                    lastY = dy
                }
            }
            if max(turnsX, turnsY) >= 4, now.timeIntervalSince(lastShakeFind) > 1.5 {
                lastShakeFind = now
                shakeTrail.removeAll()
                locate()
            }
        default:
            break
        }
    }

    /// Whether the app in front is one the person chose to keep the halo and rings out of.
    private func isExcludedNow(_ config: PointerEffectsConfig) -> Bool {
        guard !config.excludedAppIds.isEmpty, let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return false }
        return config.excludedAppIds.contains(id)
    }

    private var watching: (halo: Bool, clicks: Bool)?

    private func startWatching(halo wantsHalo: Bool, clicks wantsClicks: Bool) {
        if let watching, watching.halo == wantsHalo, watching.clicks == wantsClicks { return }
        stopWatching()
        watching = (wantsHalo, wantsClicks)
        var events: NSEvent.EventTypeMask = []
        if wantsHalo { events.formUnion([.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]) }
        if wantsClicks { events.formUnion([.leftMouseDown, .rightMouseDown, .otherMouseDown]) }
        let handle: (NSEvent) -> Void = { [weak self] event in self?.handle(event) }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: events, handler: handle) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: events, handler: { event in handle(event); return event }) { monitors.append(local) }
    }

    private func stopWatching() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
        watching = nil
        halo?.orderOut(nil)
    }

    private func handle(_ event: NSEvent) {
        let config = store.current
        switch event.type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            moveHalo(config)
        case .leftMouseDown where isExcludedNow(config):
            break
        case .rightMouseDown where isExcludedNow(config), .otherMouseDown where isExcludedNow(config):
            break
        case .leftMouseDown:
            ripple(at: NSEvent.mouseLocation, color: config.leftClickColor, size: config.clickSize, duration: Double(config.clickDurationMs) / 1000, config: config)
        case .rightMouseDown, .otherMouseDown:
            ripple(at: NSEvent.mouseLocation, color: config.rightClickColor, size: config.clickSize, duration: Double(config.clickDurationMs) / 1000, config: config)
        default:
            break
        }
    }

    // MARK: The halo

    private func updateHalo(_ config: PointerEffectsConfig) {
        let key = "\(config.haloStyle)\(config.haloSize)\(config.haloColor)\(config.haloOpacity)\(config.haloPulse)\(config.showWhenSharing)"
        if halo == nil || key != haloKey {
            halo?.orderOut(nil)
            let size = CGFloat(config.haloSize) + 8
            let panel = makeOverlay(size: size, shareable: config.showWhenSharing)
            let view = HaloView(style: config.haloStyle, color: .fromHex(config.haloColor), opacity: config.haloOpacity, pulse: config.haloPulse, size: CGFloat(config.haloSize))
            panel.contentView = NSHostingView(rootView: view)
            halo = panel
            haloKey = key
        }
        moveHalo(config)
        halo?.orderFrontRegardless()
    }

    private func moveHalo(_ config: PointerEffectsConfig) {
        guard let halo else { return }
        if isExcludedNow(config) {
            if halo.isVisible { halo.orderOut(nil) }
            return
        }
        let mouse = NSEvent.mouseLocation
        let half = halo.frame.width / 2
        halo.setFrameOrigin(NSPoint(x: mouse.x - half, y: mouse.y - half))
        if !halo.isVisible { halo.orderFrontRegardless() }
    }

    // MARK: Rings

    private func ripple(at point: NSPoint, color: String, size: Double, duration: Double, config: PointerEffectsConfig) {
        rings.show(at: point, color: NSColor(Color.fromHex(color)), side: CGFloat(size), duration: duration, shareable: config.showWhenSharing)
    }

    /// Three rings spreading out from the pointer, so it can be found at a glance.
    private func locate() {
        let config = store.current
        let point = NSEvent.mouseLocation
        for step in 0..<3 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(step) * 0.22) { [weak self] in
                self?.ripple(at: point, color: config.haloColor, size: config.locateSize, duration: 0.9, config: config)
            }
        }
    }

    // MARK: Magnifier

    private func toggleMagnifier() {
        if magnifier.isOn {
            magnifier.stop()
            return
        }
        let config = store.current
        Task { [weak self] in
            guard let self else { return }
            if let problem = await self.magnifier.start(config: config, displays: self.displays, zoom: config.magnifierZoom) {
                await MainActor.run { self.toast.show(problem, isError: true) }
            }
        }
    }

    // MARK: Saved positions

    private func go(to id: String) {
        guard let position = store.current.positions.first(where: { $0.id == id }) else { return }
        displays.refresh()
        let list = displays.ordered
        let pointer = DisplayManager.mouseLocation()
        let target: DisplayInfo?
        switch PointerPositionResolver.resolve(index: position.display, remembered: store.rememberedDisplay(for: id), connected: list.map(\.id)) {
        case .display(let place): target = list[place]
        // Not connected: the display the pointer is on, not whichever monitor now has that place in the row.
        case .pointerDisplay, .missing: target = displays.display(at: pointer)
        }
        guard let display = target else { return }
        let point = pointerPositionPoint(area: display.full, x: position.x, y: position.y)
        CGWarpMouseCursorPosition(CGPoint(x: point.x, y: point.y))
        // Warping detaches the mouse from the cursor for a moment; this puts them back together.
        CGAssociateMouseAndMouseCursorPosition(1)
    }
}
