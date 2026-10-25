import AppKit
import SwiftUI

/// The real screen for a scrolling capture: pictures of the chosen area from ScreenCaptureKit, and several ways to move what is in it,
/// tried best first: the browser's own scripting, the scroll bar of the scroll area under the pointer, the mouse wheel, Page Down and
/// the arrow keys. The pointer is moved to the middle of the area for the scrolling and put back afterwards.
final class ScreenScrollWorld: ScrollWorld {
    let rect: CGRect
    let options: ScreenGrabber.Options
    let scale: CGFloat
    private var saved: CGPoint?
    private var browser: BrowserScroller?
    private var accessibility: AccessibilityScroller?
    private(set) var strategies: [ScrollStrategy] = [.wheel, .pageKey, .arrowKeys]
    private(set) var advice: String?

    init(rect: CGRect, options: ScreenGrabber.Options) {
        self.rect = rect
        self.options = options
        let id = NSScreen.screens.compactMap { $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID }.first { CGDisplayBounds($0).intersects(rect) } ?? CGMainDisplayID()
        scale = ScreenGrabber.scale(of: id)
    }

    var centre: CGPoint { CGPoint(x: rect.midX, y: rect.midY) }

    func prepare() {
        saved = CGEvent(source: nil)?.location
        CGWarpMouseCursorPosition(centre)
    }

    func restore() { if let saved { CGWarpMouseCursorPosition(saved) } }

    /// Looks at what is under the area and decides which ways of scrolling are worth trying. Done once, before the first scroll.
    func prepareStrategies() async {
        let hit = ScrollTarget.at(centre)
        var best: [ScrollStrategy] = []
        if let kind = BrowserKind.detect(bundleID: hit?.bundleID) {
            let scroller = BrowserScroller(kind: kind)
            if await scroller.works() {
                browser = scroller
                best.append(.browser)
            } else {
                advice = "To scroll this browser exactly, turn on “Allow JavaScript from Apple Events” (Safari: Develop menu; Chrome: View › Developer) and allow Kriya to control it. The mouse wheel is used instead."
            }
        }
        if browser == nil, let scroller = AccessibilityScroller(at: centre) {
            // Only when this scroll area is most of what was selected: a small box inside a page is not the page.
            if scroller.areaFrame.height >= rect.height * 0.7 || scroller.areaFrame.width >= rect.width * 0.7 {
                accessibility = scroller
                best.append(.accessibility)
            } else {
                advice = "The box under the pointer scrolls only part of what you selected. Select just that box, or point at the part that scrolls."
            }
        }
        strategies = best + [.wheel, .pageKey, .arrowKeys]
    }

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

    func pageForward() async -> Bool { press(121, times: 1) }

    private func press(_ key: CGKeyCode, times: Int) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        for _ in 0..<times {
            for down in [true, false] {
                if let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down) {
                    event.setIntegerValueField(.eventSourceUserData, value: EventMonitor.syntheticMarker)
                    event.post(tap: .cghidEventTap)
                }
            }
        }
        return true
    }

    func scroll(by points: Int, axis: CaptureScrollAxis, using strategy: ScrollStrategy) async -> Bool {
        switch strategy {
        case .wheel: await scroll(by: points, axis: axis); return true
        case .pageKey: return axis == .horizontal ? false : (points >= 0 ? await pageForward() : press(116, times: 1))     // Page Up for the other way
        case .arrowKeys: return axis == .horizontal ? false : press(points >= 0 ? 125 : 126, times: max(abs(points) / 40, 1))
        case .browser: return await browser?.scroll(by: points, axis: axis) ?? false
        case .accessibility: return accessibility?.scroll(by: points, axis: axis) ?? false
        }
    }

    func position(axis: CaptureScrollAxis) async -> ScrollPosition? {
        if let browser { return await browser.position(axis: axis) }
        return accessibility?.position(axis: axis)
    }
}

/// A scrolling capture from start to finish: it shows a panel (outside the area, hidden from the picture) with the latest picture, how
/// far along it is, and the controls, runs the engine, and hands back the joined picture. When the area shows a PDF from a file, the
/// whole document is drawn from the file instead of scrolled.
@MainActor
final class ScrollCaptureSession: ObservableObject {
    @Published private(set) var frames = 1
    @Published private(set) var length = 0
    @Published private(set) var paused = false
    @Published private(set) var note: String?
    @Published private(set) var progress: Double?
    @Published private(set) var preview: NSImage?
    @Published private(set) var needsOverlap = false

    let mode: ScrollMode
    let axis: CaptureScrollAxis
    private let engine: ScrollEngine
    private let world: ScreenScrollWorld
    private let useDocument: Bool
    private let rect: CGRect
    private var panel: NSPanel?
    private var monitors: [Any] = []
    private var finished = false

    init(rect: CGRect, axis: CaptureScrollAxis, mode: ScrollMode, options: ScreenGrabber.Options, stepFraction: Double = 0.7, useDocument: Bool = true) {
        self.axis = axis
        self.mode = mode
        self.rect = rect
        self.useDocument = useDocument
        world = ScreenScrollWorld(rect: rect, options: options)
        engine = ScrollEngine(world: world, axis: axis, mode: mode)
        engine.stepFraction = stepFraction
        engine.onProgress = { [weak self] frames, length in DispatchQueue.main.async { self?.frames = frames; self?.length = length } }
        engine.onLong = { [weak self] length in
            DispatchQueue.main.async { self?.note = "This is getting very long (\(length) px). Stop when you have enough." }
        }
        engine.onPosition = { [weak self] fraction in DispatchQueue.main.async { self?.progress = fraction } }
        engine.onFrame = { [weak self] image in
            let thumbnail = Self.thumbnail(of: image)
            DispatchQueue.main.async { self?.preview = thumbnail }
        }
        engine.onNeedsOverlap = { [weak self] needed in DispatchQueue.main.async { self?.needsOverlap = needed } }
        engine.onNote = { [weak self] text in DispatchQueue.main.async { self?.note = text } }
        showPanel(near: rect)
    }

    var isRunning: Bool { !finished }

    func pause() { engine.pause(); paused = true }
    func resume() { engine.resume(); paused = false }
    func stop() { engine.stop() }
    func cancel() { engine.cancel() }
    func captureNow() { engine.captureNow() }
    func undoLast() { engine.undoLast() }
    func keepSeparately() { engine.keepUnjoined() }

    /// A small picture of the latest frame for the panel.
    nonisolated private static func thumbnail(of image: CGImage) -> NSImage {
        let width = 412.0
        let height = min(max(width * Double(image.height) / Double(max(image.width, 1)), 40), 190)
        return NSImage(cgImage: image, size: NSSize(width: width, height: height))
    }

    /// Runs the capture. The joined picture, or nil if it was cancelled or nothing was taken, and a sentence about how it went.
    func run() async -> (image: CGImage?, summary: String) {
        world.prepare()
        monitors = [NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { Task { @MainActor in self?.cancel() } }
        }].compactMap { $0 }
        defer {
            world.restore()
            monitors.forEach { NSEvent.removeMonitor($0) }
            monitors = []
            finished = true
            panel?.orderOut(nil)
            panel = nil
        }

        // A PDF in a viewer: draw it from the file. Nothing to scroll, nothing to miss.
        if useDocument, axis != .horizontal, let hit = ScrollTarget.at(world.centre), let url = PDFRender.file(for: hit, area: rect) {
            note = "Drawing the whole PDF from its file…"
            let drawn = await Task.detached(priority: .userInitiated) { PDFRender.render(url: url) }.value
            if let drawn {
                var summary = "Took all \(drawn.pages) page\(drawn.pages == 1 ? "" : "s") of the PDF straight from its file, not by scrolling."
                if drawn.truncated { summary += " It is cut at the longest length Kriya joins." }
                return (drawn.image, summary)
            }
        }

        await world.prepareStrategies()
        if let advice = world.advice { note = advice }
        let result = await engine.run()
        if result.cancelled { return (nil, "Scrolling capture cancelled.") }
        guard let image = ScrollImage.assemble(frames: result.frames, plan: result.plan, axis: result.axis) else { return (nil, "Nothing was captured.") }
        return (image, Self.summary(of: result))
    }

    /// What to tell the person about how it went: the count, why it ended, and anything that was not clean. Nothing is left out quietly.
    nonisolated static func summary(of result: ScrollEngine.Result) -> String {
        var parts = ["\(result.frames.count) picture\(result.frames.count == 1 ? "" : "s") joined. \(result.reason)"]
        let gaps = result.plan.gaps.count
        if gaps > 0 {
            parts.append("\(gaps) picture\(gaps == 1 ? "" : "s") did not join the one before, so \(gaps == 1 ? "it starts" : "they start") a new section below a red line: nothing was left out.")
        }
        let uncertain = result.plan.uncertain.count
        if uncertain > 0 { parts.append("\(uncertain) join\(uncertain == 1 ? " was" : "s were") a close call; look at the picture around \(uncertain == 1 ? "it" : "them").") }
        parts += result.warnings
        return parts.joined(separator: " ")
    }

    // MARK: The panel

    private func showPanel(near rect: CGRect) {
        let size = NSSize(width: 440, height: mode == .manual ? 440 : 380)
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
                    Text("\(session.frames) picture\(session.frames == 1 ? "" : "s") · \(session.length) px \(session.axis == .horizontal ? "wide" : "tall")")
                        .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                }
                if let progress = session.progress {
                    ProgressView(value: progress).controlSize(.small)
                }
                if let preview = session.preview {
                    ZStack(alignment: .bottom) {
                        Image(nsImage: preview).resizable().scaledToFill().frame(width: 412, height: 190, alignment: .bottom).clipped()
                        if session.mode == .automatic {
                            Text("The latest picture taken")
                                .font(.system(size: 10, weight: .medium)).foregroundStyle(.white).padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Color.black.opacity(0.55), in: Capsule()).padding(6).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        }
                        if session.mode == .manual {
                            // Where the next picture has to overlap: the bottom third of this one must still be in view.
                            Text("Keep this strip in view as you scroll")
                                .font(.system(size: 10, weight: .medium)).foregroundStyle(.white).padding(.vertical, 3).frame(maxWidth: .infinity)
                                .background(Color.accentColor.opacity(0.75))
                        }
                    }
                    .frame(width: 412, height: 190).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.quaternary))
                }
                if session.needsOverlap {
                    Text("This position does not overlap the last picture. Scroll back up a little, or keep it as a separate section.")
                        .font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                if let note = session.note { Text(note).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
                HStack(spacing: 8) {
                    if session.mode == .automatic {
                        Button(session.paused ? "Resume" : "Pause") { session.paused ? session.resume() : session.pause() }
                    } else {
                        Button("Capture This Position") { session.captureNow() }
                        Button("Undo Last") { session.undoLast() }.disabled(session.frames <= 1)
                        if session.needsOverlap { Button("Keep Separately") { session.keepSeparately() } }
                    }
                    Spacer()
                }
                HStack(spacing: 8) {
                    Button(session.mode == .manual ? "Finish and Save" : "Stop and Save") { session.stop() }.keyboardShortcut(.defaultAction)
                    Button("Cancel") { session.cancel() }
                    Spacer()
                    Text("⎋ cancels").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            .controlSize(.small)
            .padding(14).frame(width: 440, alignment: .topLeading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}
