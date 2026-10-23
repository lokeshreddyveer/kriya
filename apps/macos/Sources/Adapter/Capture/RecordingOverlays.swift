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

    func show() {
        guard panel == nil else { return }
        guard let screen = screenUnderPointer() else { return }
        let size = NSSize(width: 640, height: 90)
        let panel = makeFloatingPanel(size: size, clickThrough: true)
        panel.contentView = NSHostingView(rootView: KeystrokePill(overlay: self))
        let frame = screen.visibleFrame
        panel.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.minY + 60, width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
        self.panel = panel
        strip = KeystrokeStrip()
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
        // Typing into a password field is never shown.
        let label = KeystrokeLabel.label(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers, modifiers: modifiers, secureInput: IsSecureEventInputEnabled())
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
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .padding(.horizontal, 22).padding(.vertical, 10)
                    .background(Capsule().fill(Color.black.opacity(0.72)))
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

    /// Shows the camera. Calls back with a reason if it cannot.
    func show(cameraID: String, completion: @escaping (String?) -> Void) {
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
                self.present(session)
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
    }

    private func present(_ session: AVCaptureSession) {
        let size = NSSize(width: 220, height: 220)
        let panel = makeFloatingPanel(size: size, clickThrough: false)
        panel.isMovableByWindowBackground = true
        let view = NSView(frame: NSRect(origin: .zero, size: size))
        view.wantsLayer = true
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.frame = view.bounds
        preview.videoGravity = .resizeAspectFill
        preview.cornerRadius = size.width / 2
        preview.masksToBounds = true
        preview.borderWidth = 3
        preview.borderColor = NSColor.white.withAlphaComponent(0.85).cgColor
        view.layer?.addSublayer(preview)
        panel.contentView = view
        if let screen = screenUnderPointer() {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.maxX - size.width - 30, y: frame.minY + 30))
        }
        panel.orderFrontRegardless()
        self.panel = panel
    }
}

// MARK: - The control strip

/// A small strip with the time, Pause and Stop. It is kept out of the video.
final class RecordingHUD {
    private var panel: NSPanel?
    private let hosting: NSHostingView<RecordingHUDView>

    init(recorder: ScreenRecorder, onPause: @escaping () -> Void, onStop: @escaping () -> Void) {
        hosting = NSHostingView(rootView: RecordingHUDView(recorder: recorder, onPause: onPause, onStop: onStop))
    }

    /// The window's number, to leave it out of the recording. Zero until it is shown.
    var windowNumber: Int { panel?.windowNumber ?? 0 }

    func show() {
        let size = NSSize(width: 250, height: 44)
        let panel = makeFloatingPanel(size: size, clickThrough: false)
        panel.isMovableByWindowBackground = true
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
    let onPause: () -> Void
    let onStop: () -> Void

    private var timeText: String {
        let total = Int(recorder.elapsed)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(recorder.state == .paused ? Color.orange : Color.red).frame(width: 10, height: 10)
            Text(recorder.state == .paused ? "Paused  \(timeText)" : timeText)
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundStyle(.white)
            Spacer()
            Button(action: onPause) { Image(systemName: recorder.state == .paused ? "play.fill" : "pause.fill") }
                .buttonStyle(.plain).foregroundStyle(.white).help(recorder.state == .paused ? "Resume" : "Pause")
            Button(action: onStop) { Image(systemName: "stop.fill") }
                .buttonStyle(.plain).foregroundStyle(.white).help("Stop and save")
        }
        .padding(.horizontal, 16)
        .frame(width: 250, height: 44)
        .background(Capsule().fill(Color.black.opacity(0.82)))
    }
}
