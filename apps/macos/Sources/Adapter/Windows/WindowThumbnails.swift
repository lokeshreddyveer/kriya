import AppKit
import ScreenCaptureKit

/// Pictures of windows for the switcher. They need the Screen Recording permission, and windows that are minimized or on
/// another Space cannot be captured, so those simply have no picture.
enum WindowThumbnails {
    /// Takes a picture of each window in turn, in the order given, and hands each over as soon as it is ready so the
    /// switcher can fill in as they come. Returns early if `isCancelled` says the switcher has gone.
    static func stream(_ windows: [(key: String, pid: pid_t, frame: Rect)], width: CGFloat, isCancelled: @escaping () -> Bool, onEach: @escaping (String, NSImage) -> Void) async {
        guard CGPreflightScreenCaptureAccess(),
              let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else { return }
        for item in windows {
            if isCancelled() { return }
            guard let match = content.windows.first(where: { window in
                window.owningApplication?.processID == item.pid
                    && abs(window.frame.origin.x - item.frame.x) < 6 && abs(window.frame.origin.y - item.frame.y) < 6
                    && abs(window.frame.width - item.frame.width) < 6
            }), match.frame.width > 0, match.frame.height > 0 else { continue }
            let scale = min(1, width / match.frame.width)
            let configuration = SCStreamConfiguration()
            configuration.width = max(1, Int(match.frame.width * scale))
            configuration.height = max(1, Int(match.frame.height * scale))
            configuration.showsCursor = false
            let filter = SCContentFilter(desktopIndependentWindow: match)
            if let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) {
                onEach(item.key, NSImage(cgImage: image, size: NSSize(width: configuration.width, height: configuration.height)))
            }
        }
    }
}
