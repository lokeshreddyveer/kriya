import AppKit
import SwiftUI

/// The real screen for a scrolling capture: pictures of the chosen area from ScreenCaptureKit, and scrolling done with wheel events
/// at its centre. The pointer is moved there for the scrolling and put back afterwards.
final class ScreenScrollWorld: ScrollWorld {
    let rect: CGRect
    let options: ScreenGrabber.Options
    let scale: CGFloat
    private var saved: CGPoint?

    init(rect: CGRect, options: ScreenGrabber.Options) {
        self.rect = rect
        self.options = options
        let id = NSScreen.screens.compactMap { $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID }.first { CGDisplayBounds($0).intersects(rect) } ?? CGMainDisplayID()
        scale = ScreenGrabber.scale(of: id)
    }

    private var centre: CGPoint { CGPoint(x: rect.midX, y: rect.midY) }

    func prepare() {
        saved = CGEvent(source: nil)?.location
        CGWarpMouseCursorPosition(centre)
    }

    func restore() { if let saved { CGWarpMouseCursorPosition(saved) } }

    func grab() async throws -> CGImage { try await ScreenGrabber.areaImage(rect, options: options) }

    func scroll(by points: Int, axis: CaptureScrollAxis) async {
        CGWarpMouseCursorPosition(centre)
        // In pieces, a few milliseconds apart: some apps drop one big wheel event, and a page that eases to a stop looks the same.
        var left = points
        while left != 0 {
            let piece = max(min(left, 160), -160)
            left -= piece
            let horizontal = axis == .horizontal
            if let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: horizontal ? 0 : Int32(-piece), wheel2: horizontal ? Int32(-piece) : 0, wheel3: 0) {
                event.location = centre
                event.setIntegerValueField(.eventSourceUserData, value: EventMonitor.syntheticMarker)
                event.post(tap: .cghidEventTap)
            }
            try? await Task.sleep(nanoseconds: 9_000_000)
        }
    }

    func pageForward() async -> Bool {
        guard AXIsProcessTrusted() else { return false }
        for down in [true, false] {
            if let event = CGEvent(keyboardEventSource: nil, virtualKey: 121, keyDown: down) {      // Page Down
                event.setIntegerValueField(.eventSourceUserData, value: EventMonitor.syntheticMarker)
                event.post(tap: .cghidEventTap)
            }
        }
        return true
    }
}

/// A scrolling capture from start to finish: it shows a small panel (outside the area, hidden from the picture) with the count and
/// length so far and Pause, Stop and Cancel, runs the engine, and hands back the joined picture.
@MainActor
final class ScrollCaptureSession: ObservableObject {
    @Published private(set) var frames = 1
    @Published private(set) var length = 0
    @Published private(set) var paused = false
    @Published private(set) var note: String?

    let mode: ScrollMode
    let axis: CaptureScrollAxis
    private let engine: ScrollEngine
    private let world: ScreenScrollWorld
    private var panel: NSPanel?
    private var monitors: [Any] = []
    private var finished = false

    init(rect: CGRect, axis: CaptureScrollAxis, mode: ScrollMode, options: ScreenGrabber.Options) {
        self.axis = axis
        self.mode = mode
        world = ScreenScrollWorld(rect: rect, options: options)
        engine = ScrollEngine(world: world, axis: axis, mode: mode)
        engine.onProgress = { [weak self] frames, length in DispatchQueue.main.async { self?.frames = frames; self?.length = length } }
        engine.onLong = { [weak self] length in
            DispatchQueue.main.async { self?.note = "This is getting very long (\(length) px). Stop when you have enough." }
        }
        showPanel(near: rect)
    }

    var isRunning: Bool { !finished }

    func pause() { engine.pause(); paused = true }
    func resume() { engine.resume(); paused = false }
    func stop() { engine.stop() }
    func cancel() { engine.cancel() }

    /// Runs the capture. The joined picture, or nil if it was cancelled or nothing was taken, and a sentence about how it went.
    func run() async -> (image: CGImage?, summary: String) {
        world.prepare()
        monitors = [NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { Task { @MainActor in self?.cancel() } }
        }].compactMap { $0 }
        let result = await engine.run()
        world.restore()
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
        finished = true
        panel?.orderOut(nil)
        panel = nil
        if result.cancelled { return (nil, "Scrolling capture cancelled.") }
        guard let image = ScrollImage.assemble(frames: result.frames, plan: result.plan, axis: result.axis) else { return (nil, "Nothing was captured.") }
        var summary = "\(result.frames.count) picture\(result.frames.count == 1 ? "" : "s") joined. \(result.reason)"
        if !result.plan.gaps.isEmpty { summary += " \(result.plan.gaps.count) did not join and were left out." }
        return (image, summary)
    }

    // MARK: The panel

    private func showPanel(near rect: CGRect) {
        let size = NSSize(width: 360, height: 128)
        let host = NSHostingView(rootView: HUD(session: self))
        host.frame = NSRect(origin: .zero, size: size)
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = host
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.sharingType = .none
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // Outside the area being captured: below it if there is room, above it if not, else at the bottom of the display.
        let main = NSScreen.screens.first?.frame.height ?? 0
        let area = NSRect(x: rect.minX, y: main - rect.maxY, width: rect.width, height: rect.height)
        let screen = NSScreen.screens.first { $0.frame.intersects(area) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        var origin = NSPoint(x: min(max(area.midX - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8), y: area.minY - size.height - 12)
        if origin.y < visible.minY + 8 { origin.y = area.maxY + 12 }
        if origin.y + size.height > visible.maxY - 8 { origin.y = visible.minY + 16 }
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    private struct HUD: View {
        @ObservedObject var session: ScrollCaptureSession

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: session.axis == .horizontal ? "arrow.left.and.right" : session.axis == .both ? "arrow.up.left.and.arrow.down.right" : "arrow.up.and.down")
                        .foregroundStyle(session.paused ? .orange : .red)
                    Text(session.mode == .automatic ? (session.paused ? "Paused" : "Scrolling for you…") : "Scroll the page yourself")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("\(session.frames) picture\(session.frames == 1 ? "" : "s") · \(session.length) px")
                        .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                }
                if let note = session.note { Text(note).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
                HStack(spacing: 8) {
                    if session.mode == .automatic {
                        Button(session.paused ? "Resume" : "Pause") { session.paused ? session.resume() : session.pause() }
                    }
                    Button("Stop and Save") { session.stop() }.keyboardShortcut(.defaultAction)
                    Button("Cancel") { session.cancel() }
                    Spacer()
                    Text("⎋ cancels").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                .controlSize(.small)
            }
            .padding(14).frame(width: 360, height: 128, alignment: .topLeading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}
