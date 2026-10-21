import AppKit
import ScreenCaptureKit

/// Small pictures of windows for the switcher. They need the Screen Recording permission, and windows that are minimized
/// or on another Space cannot be captured, so those simply have no picture.
enum WindowThumbnails {
    /// A picture for each window, found by its owner and frame. Windows without a match are left out.
    static func capture(_ windows: [(key: String, pid: pid_t, frame: Rect)]) async -> [String: NSImage] {
        guard CGPreflightScreenCaptureAccess(),
              let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else { return [:] }
        var pictures: [String: NSImage] = [:]
        for item in windows {
            guard let match = content.windows.first(where: { window in
                window.owningApplication?.processID == item.pid
                    && abs(window.frame.origin.x - item.frame.x) < 6 && abs(window.frame.origin.y - item.frame.y) < 6
                    && abs(window.frame.width - item.frame.width) < 6
            }), match.frame.width > 0, match.frame.height > 0 else { continue }
            let scale = min(1, 220 / match.frame.width)
            let configuration = SCStreamConfiguration()
            configuration.width = max(1, Int(match.frame.width * scale))
            configuration.height = max(1, Int(match.frame.height * scale))
            configuration.showsCursor = false
            let filter = SCContentFilter(desktopIndependentWindow: match)
            if let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) {
                pictures[item.key] = NSImage(cgImage: image, size: NSSize(width: configuration.width, height: configuration.height))
            }
        }
        return pictures
    }
}
