import AppKit
import AVFoundation
import ScreenCaptureKit

/// A live, view-only copy of another app's window that floats above everything. Other apps' windows cannot be made to stay on
/// top, so this shows a picture of the window instead. Clicks do not reach the real window.
final class LiveMirror: NSObject, SCStreamOutput, SCStreamDelegate {
    private var panel: NSPanel?
    private var stream: SCStream?
    private var displayLayer: AVSampleBufferDisplayLayer?
    private var closeObserver: NSObjectProtocol?
    private let queue = DispatchQueue(label: "app.kriya.mirror", qos: .userInitiated)

    var isShowing: Bool { panel != nil }

    /// Mirrors the window in front. Calls back with why not if it cannot.
    func show(completion: @escaping (String?) -> Void) {
        close()
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
                    return await MainActor.run { completion("Bring the window you want to mirror to the front first.") }
                }
                let windows = content.windows.filter { $0.owningApplication?.processID == app.processIdentifier && $0.windowLayer == 0 && $0.frame.width > 50 }
                var chosen = windows.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
                if AXIsProcessTrusted(), let focused = AXWindow.focused()?.frame?.cg {
                    chosen = windows.min { Self.gap($0.frame, focused) < Self.gap($1.frame, focused) } ?? chosen
                }
                guard let window = chosen else { return await MainActor.run { completion("There is no window to mirror.") } }
                let filter = SCContentFilter(desktopIndependentWindow: window)
                let info = SCShareableContent.info(for: filter)
                let configuration = SCStreamConfiguration()
                configuration.width = max(2, Int(info.contentRect.width * CGFloat(info.pointPixelScale)))
                configuration.height = max(2, Int(info.contentRect.height * CGFloat(info.pointPixelScale)))
                configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
                configuration.showsCursor = false
                configuration.queueDepth = 4
                let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
                await MainActor.run { self.present(title: window.owningApplication?.applicationName ?? "Window", size: info.contentRect.size) }
                self.stream = stream
                try await stream.startCapture()
                await MainActor.run { completion(nil) }
            } catch {
                await MainActor.run {
                    self.close()
                    completion("Kriya cannot see that window. Allow Screen Recording for Kriya in System Settings, then quit and open Kriya again.")
                }
            }
        }
    }

    func close() {
        let running = stream
        stream = nil
        Task { try? await running?.stopCapture() }
        panel?.orderOut(nil)
        panel = nil
        displayLayer = nil
    }

    private static func gap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        abs(a.minX - b.minX) + abs(a.minY - b.minY) + abs(a.width - b.width) + abs(a.height - b.height)
    }

    private func present(title: String, size: CGSize) {
        let scale = min(1, 480 / max(size.width, 1))
        let content = NSSize(width: max(160, size.width * scale), height: max(100, size.height * scale))
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: content), styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Mirror: \(title)"
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        // The mirrored window is somebody else's content: keep it out of screen sharing when the person asked for that.
        panel.sharingType = CaptureOverlay.hideWhenSharing ? .none : .readOnly
        panel.contentAspectRatio = content
        let view = NSView(frame: NSRect(origin: .zero, size: content))
        view.wantsLayer = true
        let layer = AVSampleBufferDisplayLayer()
        layer.frame = view.bounds
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer.videoGravity = .resizeAspect
        view.layer?.addSublayer(layer)
        panel.contentView = view
        if let screen = NSScreen.main {
            panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - content.width - 24, y: screen.visibleFrame.maxY - content.height - 60))
        }
        panel.makeKeyAndOrderFront(nil)
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: panel, queue: .main) { [weak self] _ in self?.close() }
        self.panel = panel
        displayLayer = layer
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, CMSampleBufferGetImageBuffer(sampleBuffer) != nil else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) as? [NSMutableDictionary], let first = attachments.first {
            first[kCMSampleAttachmentKey_DisplayImmediately] = true
        }
        DispatchQueue.main.async {
            guard let layer = self.displayLayer else { return }
            if layer.status == .failed { layer.flush() }
            layer.enqueue(sampleBuffer)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { self.close() }
    }
}
