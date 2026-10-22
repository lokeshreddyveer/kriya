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

/// A ring that grows and fades, for clicks and for finding the pointer.
private struct RippleView: View {
    let color: Color
    let duration: Double
    @State private var grown = false

    var body: some View {
        Circle()
            .strokeBorder(color, lineWidth: 5)
            .background(Circle().fill(color.opacity(0.18)))
            .scaleEffect(grown ? 1 : 0.25)
            .opacity(grown ? 0 : 0.95)
            .onAppear { withAnimation(.easeOut(duration: duration)) { grown = true } }
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

/// A live, zoomed view of the screen around the pointer, in a small window that follows it. Needs Screen Recording.
private final class PointerMagnifier: NSObject, SCStreamOutput {
    private var stream: SCStream?
    private var panel: NSPanel?
    private let imageLayer = CALayer()
    private let ciContext = CIContext()
    private var timer: Timer?
    private var screenSize = CGSize.zero
    private var displayOrigin = CGPoint.zero      // the display's top-left, in the accessibility coordinates
    private var size: Double = 220
    private(set) var zoom: Double = 2.5
    private var updating = false
    private let queue = DispatchQueue(label: "app.kriya.magnifier", qos: .userInteractive)

    var isOn: Bool { stream != nil }

    func start(config: PointerEffectsConfig, displays: DisplayManager, zoom: Double) async -> String? {
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            return "The magnifier needs Screen Recording. Allow it in System Settings, then try again."
        }
        displays.refresh()
        let pointer = DisplayManager.mouseLocation()
        guard let display = displays.display(at: pointer),
              let screen = NSScreen.screens.first(where: { abs($0.frame.width - display.full.width) < 2 && abs($0.frame.height - display.full.height) < 2 && abs($0.frame.minX - display.full.x) < 2 }),
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true),
              let scDisplay = content.displays.first(where: { $0.displayID == number }) else { return "Could not capture this display." }
        self.zoom = zoom
        size = config.magnifierSize
        screenSize = CGSize(width: display.full.width, height: display.full.height)
        displayOrigin = CGPoint(x: display.full.x, y: display.full.y)

        let mine = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        let filter = SCContentFilter(display: scDisplay, excludingApplications: mine, exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        let scale = screen.backingScaleFactor
        configuration.width = Int(size * scale)
        configuration.height = Int(size * scale)
        configuration.sourceRect = sourceRect(for: pointer, config: config)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.showsCursor = true
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            try await stream.startCapture()
        } catch {
            return "Could not start the magnifier: \(error.localizedDescription)"
        }
        self.stream = stream
        await MainActor.run { showPanel(config: config) }
        return nil
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        let stream = stream
        self.stream = nil
        Task { try? await stream?.stopCapture() }
        panel?.orderOut(nil)
        panel = nil
    }

    func adjustZoom(by factor: Double) {
        zoom = min(8, max(1.5, zoom * factor))
    }

    // MARK: Showing it

    private func showPanel(config: PointerEffectsConfig) {
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
        let timer = Timer(timeInterval: 1.0 / 40.0, repeats: true) { [weak self] _ in self?.tick(config: config) }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Moves the window beside the pointer and points the capture at what is under it.
    private func tick(config: PointerEffectsConfig) {
        let pointer = DisplayManager.mouseLocation()
        let mouse = NSEvent.mouseLocation
        if let panel, let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main {
            var origin = NSPoint(x: mouse.x + 28, y: mouse.y + 28)
            let frame = screen.visibleFrame
            if origin.x + CGFloat(size) > frame.maxX { origin.x = mouse.x - 28 - CGFloat(size) }
            if origin.y + CGFloat(size) > frame.maxY { origin.y = mouse.y - 28 - CGFloat(size) }
            panel.setFrameOrigin(origin)
        }
        guard let stream, !updating else { return }
        updating = true
        let configuration = SCStreamConfiguration()
        configuration.width = Int(size * (NSScreen.main?.backingScaleFactor ?? 2))
        configuration.height = configuration.width
        configuration.sourceRect = sourceRect(for: pointer, config: config)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.showsCursor = true
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        Task { [weak self] in
            try? await stream.updateConfiguration(configuration)
            self?.updating = false
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
}

// MARK: - Hiding the pointer when it is idle

/// Hides the pointer after it has been still for a while and brings it back at the first movement. macOS lets only the app
/// in front hide the pointer, so this asks the window server to allow it from the background; if that is not possible the
/// pointer simply stays visible.
private final class PointerHider {
    private var timer: Timer?
    private var monitors: [Any] = []
    private var lastMove = Date()
    private var hidden = false
    private var after: TimeInterval = 5

    /// Watches for the pointer moving, which brings it back.
    private func watchMovement() {
        guard monitors.isEmpty else { return }
        let wake: (NSEvent) -> Void = { [weak self] _ in self?.moved() }
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .scrollWheel, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: events, handler: wake) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: events, handler: { event in wake(event); return event }) { monitors.append(local) }
    }

    /// Hides the pointer while the person types, until the mouse moves. Works from the background, like hiding when idle.
    func hideForTyping() {
        watchMovement()
        guard !hidden else { return }
        allowBackgroundCursorControl()
        CGDisplayHideCursor(CGMainDisplayID())
        hidden = true
    }

    func start(after seconds: Double) {
        after = seconds
        guard timer == nil else { return }
        lastMove = Date()
        watchMovement()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.check() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
        show()
    }

    func show() {
        guard hidden else { return }
        CGDisplayShowCursor(CGMainDisplayID())
        hidden = false
    }

    private func moved() {
        lastMove = Date()
        show()
    }

    private func check() {
        guard !hidden, Date().timeIntervalSince(lastMove) >= after else { return }
        allowBackgroundCursorControl()
        CGDisplayHideCursor(CGMainDisplayID())
        hidden = true
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
            entry("pointer.presentation", "Presentation mode (on or off)"),
        ]
    }()

    private let store: PointerEffectsStore
    private let displays: DisplayManager
    private let executor: ActionExecutor
    private let toast = Toast()
    private let magnifier = PointerMagnifier()
    private let hider = PointerHider()

    private var halo: NSPanel?
    private var haloKey = ""
    private var monitors: [Any] = []
    private var registered = Set<String>()
    private var cancellables = Set<AnyCancellable>()
    private var presentation = false

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
    }

    func start() {
        for (command, _) in Self.commands { register(command) { [weak self] in self?.run(command) } }
        store.$config
            .receive(on: DispatchQueue.main)
            .sink { [weak self] config in
                self?.registerPositions(config)
                self?.apply()
            }
            .store(in: &cancellables)
    }

    func stop() {
        cancellables.removeAll()
        stopWatching()
        hider.stop()
        magnifier.stop()
        stopFindWatchers()
        for command in registered { executor.unregisterCommand(command) }
        registered.removeAll()
    }

    // MARK: Commands

    private func register(_ command: String, _ work: @escaping () -> Void) {
        registered.insert(command)
        executor.registerCommand(command) { [weak self] in
            guard self?.store.current.enabled == true else { return }
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

    private func run(_ command: String) {
        switch command {
        case "pointer.locate": locate()
        case "pointer.magnifier": toggleMagnifier()
        case "pointer.zoom_in": magnifier.adjustZoom(by: 1.25)
        case "pointer.zoom_out": magnifier.adjustZoom(by: 0.8)
        case "pointer.show": hider.show()
        case "pointer.presentation":
            presentation.toggle()
            toast.show(presentation ? "Presentation mode on" : "Presentation mode off")
            apply()
        default: break
        }
    }

    // MARK: Keeping the watchers in step with the settings

    /// Starts and stops the halo, the click rings and the idle hiding to match the settings and presentation mode.
    private func apply() {
        let config = store.current
        let wantsHalo = config.enabled && (config.haloEnabled || presentation)
        let wantsClicks = config.enabled && (config.clickEnabled || presentation)
        if wantsHalo || wantsClicks { startWatching(halo: wantsHalo, clicks: wantsClicks) } else { stopWatching() }
        if wantsHalo { updateHalo(config) } else { halo?.orderOut(nil) }
        if config.enabled, config.hideWhenIdle { hider.start(after: config.hideAfterSeconds) } else if !(config.enabled && config.hideWhileTyping) { hider.stop() }
        if !config.enabled, magnifier.isOn { magnifier.stop() }
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
            var turns = 0
            var lastDirection = 0.0
            for index in 1..<max(shakeTrail.count, 1) {
                let dx = shakeTrail[index].point.x - shakeTrail[index - 1].point.x
                guard abs(dx) > 8 else { continue }
                if lastDirection != 0, dx.sign != lastDirection.sign { turns += 1 }
                lastDirection = dx
            }
            if turns >= 4, now.timeIntervalSince(lastShakeFind) > 1.5 {
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
        let side = CGFloat(size)
        let panel = makeOverlay(size: side, shareable: config.showWhenSharing)
        panel.contentView = NSHostingView(rootView: RippleView(color: .fromHex(color), duration: duration))
        panel.setFrameOrigin(NSPoint(x: point.x - side / 2, y: point.y - side / 2))
        panel.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.1) { panel.orderOut(nil) }
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
        if let index = position.display, Int(index) < list.count { target = list[Int(index)] } else { target = displays.display(at: pointer) }
        guard let display = target else { return }
        let point = pointerPositionPoint(area: display.full, x: position.x, y: position.y)
        CGWarpMouseCursorPosition(CGPoint(x: point.x, y: point.y))
        // Warping detaches the mouse from the cursor for a moment; this puts them back together.
        CGAssociateMouseAndMouseCursorPosition(1)
    }
}
