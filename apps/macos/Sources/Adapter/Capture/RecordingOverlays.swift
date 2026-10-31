import AppKit
import AVFoundation
import Carbon.HIToolbox
import Combine
import SwiftUI

/// Windows that appear on screen while recording. The ones meant to be in the video (the keys, the camera) are ordinary
/// windows that the screen stream captures; the control strip is left out of the stream by its window number.
private func makeFloatingPanel(size: NSSize, clickThrough: Bool) -> NSPanel {
    final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }
    let panel = Panel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.level = .statusBar
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    panel.isReleasedWhenClosed = false
    panel.ignoresMouseEvents = clickThrough
    return panel
}

private func screenUnderPointer() -> NSScreen? {
    let mouse = NSEvent.mouseLocation
    return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
}

// MARK: - Keys on screen

/// Shows the keys being pressed in a pill near the bottom of the screen, so they are in the recording.
final class KeystrokeOverlay: ObservableObject {
    @Published fileprivate var text = ""
    private var strip = KeystrokeStrip()
    private var monitor: Any?
    private var flagsMonitor: Any?
    private var timer: Timer?
    private var panel: NSPanel?

    @Published fileprivate var options = KeystrokeOptions()

    func show(options: KeystrokeOptions = KeystrokeOptions()) {
        guard panel == nil else { return }
        guard let screen = screenUnderPointer() else { return }
        self.options = options
        let size = NSSize(width: 640, height: 90)
        let panel = makeFloatingPanel(size: size, clickThrough: true)
        panel.contentView = NSHostingView(rootView: KeystrokePill(overlay: self))
        let frame = screen.visibleFrame
        let x: CGFloat
        switch options.position {
        case .bottomLeft: x = frame.minX + 24
        case .bottomRight: x = frame.maxX - size.width - 24
        default: x = frame.midX - size.width / 2
        }
        let y = options.position == .topCenter ? frame.maxY - size.height - 40 : frame.minY + 60
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
        self.panel = panel
        strip = KeystrokeStrip()
        strip.lifetime = options.fade
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in self?.keyDown(event) }
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
    }

    func hide() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        monitor = nil
        flagsMonitor = nil
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
        panel = nil
        text = ""
        strip = KeystrokeStrip()
    }

    private func keyDown(_ event: NSEvent) {
        var modifiers: KeystrokeLabel.Modifiers = []
        let flags = event.modifierFlags
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.command) { modifiers.insert(.command) }
        // Typing into a password field is not shown (unless that was turned off).
        let label = options.label(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers, modifiers: modifiers, secureInput: IsSecureEventInputEnabled())
        guard let label else { return }
        strip.add(label, at: ProcessInfo.processInfo.systemUptime)
        text = strip.text(at: ProcessInfo.processInfo.systemUptime)
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        strip.prune(at: now)
        let next = strip.text(at: now)
        if next != text { text = next }
    }
}

private struct KeystrokePill: View {
    @ObservedObject var overlay: KeystrokeOverlay

    var body: some View {
        ZStack {
            if !overlay.text.isEmpty {
                Text(overlay.text)
                    .font(.system(size: overlay.options.size.fontSize, weight: .semibold, design: .rounded))
                    .foregroundStyle(overlay.options.theme == .light ? Color.black : Color.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .padding(.horizontal, 22).padding(.vertical, 10)
                    .background(Capsule().fill(overlay.options.theme == .light ? Color.white.opacity(0.9) : overlay.options.theme == .accent ? Color.accentColor.opacity(0.9) : Color.black.opacity(0.72)))
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.12), value: overlay.text)
    }
}

// MARK: - The camera

/// A small round window showing the camera. It is on screen, so it is in the recording; it can be dragged anywhere.
final class WebcamBubble {
    private var panel: NSPanel?
    private var session: AVCaptureSession?
    private var preview: AVCaptureVideoPreviewLayer?
    private var style = CameraStyle()
    /// Where the window was before it went full screen.
    private var smallFrame: NSRect?

    var isShown: Bool { panel != nil }
    var isFullscreen: Bool { smallFrame != nil }

    /// Fills the screen the camera is on with the picture, or puts the small window back where it was.
    func toggleFullscreen() {
        guard let panel, let preview else { return }
        let radius: CGFloat
        let frame: NSRect
        if let back = smallFrame {
            frame = back
            smallFrame = nil
            radius = CGFloat(style.cornerRadius(side: style.size.side))
        } else {
            guard let screen = panel.screen ?? screenUnderPointer() else { return }
            smallFrame = panel.frame
            frame = screen.frame
            radius = 0
        }
        panel.setFrame(frame, display: true, animate: true)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        preview.frame = NSRect(origin: .zero, size: frame.size)
        preview.cornerRadius = radius
        preview.borderWidth = radius == 0 ? 0 : (style.border ? 3 : 0)
        CATransaction.commit()
    }

    /// Shows the camera. Calls back with a reason if it cannot.
    func show(cameraID: String, style: CameraStyle = CameraStyle(), completion: @escaping (String?) -> Void) {
        guard panel == nil else { return completion(nil) }
        AVCaptureDevice.requestAccess(for: .video) { granted in
            DispatchQueue.main.async {
                guard granted else { return completion("Allow the camera for Kriya in System Settings › Privacy & Security, or turn the camera off for recordings.") }
                let device = (cameraID.isEmpty ? nil : AVCaptureDevice(uniqueID: cameraID)) ?? AVCaptureDevice.default(for: .video)
                guard let device, let input = try? AVCaptureDeviceInput(device: device) else { return completion("There is no camera to show.") }
                let session = AVCaptureSession()
                session.sessionPreset = .medium
                guard session.canAddInput(input) else { return completion("The camera could not be used.") }
                session.addInput(input)
                self.session = session
                self.present(session, style: style)
                DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
                completion(nil)
            }
        }
    }

    func hide() {
        let running = session
        session = nil
        DispatchQueue.global(qos: .userInitiated).async { running?.stopRunning() }
        panel?.orderOut(nil)
        panel = nil
        preview = nil
        smallFrame = nil
    }

    /// Moves the camera to another corner while it is showing.
    func move(to style: CameraStyle) {
        guard smallFrame == nil, let panel, let screen = panel.screen ?? screenUnderPointer() else { return }
        panel.setFrameOrigin(NSPoint(x: style.origin(in: screen.visibleFrame).x, y: style.origin(in: screen.visibleFrame).y))
    }

    private func present(_ session: AVCaptureSession, style: CameraStyle) {
        self.style = style
        let size = NSSize(width: style.size.side, height: style.size.side)
        let panel = makeFloatingPanel(size: size, clickThrough: false)
        panel.isMovableByWindowBackground = true
        let view = NSView(frame: NSRect(origin: .zero, size: size))
        view.wantsLayer = true
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.frame = view.bounds
        preview.videoGravity = .resizeAspectFill
        preview.cornerRadius = CGFloat(style.cornerRadius(side: style.size.side))
        preview.masksToBounds = true
        preview.borderWidth = style.border ? 3 : 0
        preview.borderColor = NSColor.white.withAlphaComponent(0.85).cgColor
        if style.mirrored { preview.connection?.automaticallyAdjustsVideoMirroring = false; preview.connection?.isVideoMirrored = true }
        view.layer?.addSublayer(preview)
        self.preview = preview
        panel.contentView = view
        if let screen = screenUnderPointer() {
            panel.setFrameOrigin(style.origin(in: screen.visibleFrame))
        }
        panel.orderFrontRegardless()
        self.panel = panel
    }
}

// MARK: - The control strip

/// What the strip shows besides the time: which inputs are on, and whether the disk is running out of room.
final class RecordingStatus: ObservableObject {
    let systemAudio: Bool
    let microphone: Bool
    let camera: Bool
    @Published var diskWarning: String?

    init(options: RecordingOptions) {
        systemAudio = options.systemAudio
        microphone = options.microphone
        camera = options.webcam
    }
}

/// A small strip with the time, which inputs are on, a warning if the disk is nearly full, and Pause, Restart, Cancel and Stop. It is
/// kept out of the video, and it works from the moment it appears, while the recording is still starting.
final class RecordingHUD {
    private var panel: NSPanel?
    private let hosting: NSHostingView<RecordingHUDView>

    init(recorder: ScreenRecorder, status: RecordingStatus, onPause: @escaping () -> Void, onStop: @escaping () -> Void, onRestart: @escaping () -> Void, onCancel: @escaping () -> Void) {
        hosting = NSHostingView(rootView: RecordingHUDView(recorder: recorder, status: status, onPause: onPause, onStop: onStop, onRestart: onRestart, onCancel: onCancel))
    }

    /// The window's number, to leave it out of the recording. Zero until it is shown.
    var windowNumber: Int { panel?.windowNumber ?? 0 }

    func show() {
        let size = NSSize(width: 360, height: 48)
        let panel = makeFloatingPanel(size: size, clickThrough: false)
        panel.isMovableByWindowBackground = true
        panel.sharingType = .none
        hosting.frame = NSRect(origin: .zero, size: size)
        panel.contentView = hosting
        if let screen = screenUnderPointer() {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.maxY - size.height - 16))
        }
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}

struct RecordingHUDView: View {
    @ObservedObject var recorder: ScreenRecorder
    @ObservedObject var status: RecordingStatus
    let onPause: () -> Void
    let onStop: () -> Void
    let onRestart: () -> Void
    let onCancel: () -> Void

    private var timeText: String { RecordingTime.text(recorder.elapsed) }
    private var starting: Bool { recorder.state == .starting }

    private func chip(_ symbol: String, _ on: Bool, _ help: String) -> some View {
        Image(systemName: on ? symbol : symbol + ".slash").font(.system(size: 11)).foregroundStyle(on ? Color.white : Color.white.opacity(0.4)).help(help)
    }

    /// Throwing away a recording that has run for a while is asked about first; a few seconds in, it just happens.
    private func discarding(_ title: String, _ detail: String, _ run: @escaping () -> Void) -> () -> Void {
        return {
            guard recorder.elapsed > 10 else { run(); return }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = title
            alert.informativeText = "\(detail) It has been running for \(timeText) and cannot be brought back."
            alert.addButton(withTitle: "Discard")
            alert.addButton(withTitle: "Keep Recording")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn { run() }
        }
    }

    private func button(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 22, height: 22) }
            .buttonStyle(.plain).foregroundStyle(.white).help(help).accessibilityLabel(help)
    }

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(recorder.state == .paused ? Color.orange : starting ? Color.gray : Color.red).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 1) {
                Text(starting ? "Starting…" : recorder.state == .paused ? "Paused  \(timeText)" : timeText)
                    .font(.system(size: 14, weight: .medium, design: .monospaced)).foregroundStyle(.white)
                if let warning = status.diskWarning {
                    Text(warning).font(.system(size: 10)).foregroundStyle(.orange).lineLimit(1)
                } else {
                    HStack(spacing: 6) {
                        chip("speaker.wave.2", status.systemAudio, status.systemAudio ? "Recording the Mac's sound" : "The Mac's sound is not recorded")
                        chip("mic", status.microphone, status.microphone ? "Recording the microphone" : "The microphone is not recorded")
                        chip("video", status.camera, status.camera ? "The camera is shown" : "No camera")
                    }
                }
            }
            Spacer(minLength: 4)
            if !starting {
                button(recorder.state == .paused ? "play.fill" : "pause.fill", recorder.state == .paused ? "Resume" : "Pause", action: onPause)
                button("arrow.counterclockwise", "Start over (discard this and record again)", action: discarding("Start over?", "What has been recorded is thrown away and a new recording starts.", onRestart))
            }
            button("xmark.circle", "Cancel (discard this recording)", action: discarding("Discard this recording?", "Nothing is saved.", onCancel))
            button("stop.fill", starting ? "Cancel starting" : "Stop and save", action: onStop)
        }
        .padding(.horizontal, 14)
        .frame(width: 360, height: 48)
        .background(Capsule().fill(Color.black.opacity(0.84)))
    }
}
