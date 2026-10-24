import AppKit
import ScreenCaptureKit

/// Takes pictures of the screen through ScreenCaptureKit, in the places Kriya's own selector needs them: a still of each display to
/// choose from, then the chosen display, area or window. Everything is in points with the origin at the top left of the main display
/// and y growing down, which is what the displays report and what `PreviousArea` keeps.
enum ScreenGrabber {
    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    struct Options: Equatable {
        var includeCursor = false
        /// Leave the desktop's icons out (they are windows of the Finder that sit on the wallpaper).
        var hideDesktopIcons = false
        /// Leave Kriya's own windows out: the selector, the countdown, the cards.
        var excludeKriya = true
        /// Cut the camera notch's strip off the top of a display that has one.
        var cropNotch = false
    }

    /// A window that could be chosen.
    struct WindowInfo: Equatable, Identifiable {
        let id: CGWindowID
        /// Points, global, top-left origin.
        let frame: CGRect
        let title: String
        let appName: String
        let bundleID: String?
    }

    // MARK: What is on screen

    static func content() async throws -> SCShareableContent {
        do { return try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) }
        catch { throw Failure("macOS did not let Kriya see the screen (\(error.localizedDescription)). Allow Screen Recording for Kriya in System Settings › Privacy & Security, then try again.") }
    }

    /// The windows a person could mean, front to back: ordinary windows with a size, none of Kriya's own.
    static func windows(in content: SCShareableContent) -> [WindowInfo] {
        let own = Bundle.main.bundleIdentifier
        return content.windows.compactMap { w in
            guard w.windowLayer == 0, w.isOnScreen, w.frame.width >= 40, w.frame.height >= 40,
                  let app = w.owningApplication, app.bundleIdentifier != own else { return nil }
            return WindowInfo(id: w.windowID, frame: w.frame, title: w.title ?? "", appName: app.applicationName, bundleID: app.bundleIdentifier)
        }
    }

    /// The point-to-pixel scale of a display.
    static func scale(of displayID: CGDirectDisplayID) -> CGFloat {
        if let screen = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == displayID }) { return screen.backingScaleFactor }
        let bounds = CGDisplayBounds(displayID)
        return bounds.width > 0 ? CGFloat(CGDisplayPixelsWide(displayID)) / bounds.width : 1
    }

    /// The strip across the top that the notch takes, in points; zero on a display without one.
    static func notchHeight(of displayID: CGDirectDisplayID) -> CGFloat {
        guard let screen = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == displayID }) else { return 0 }
        return screen.safeAreaInsets.top
    }

    // MARK: Filters

    private static func filter(display: SCDisplay, content: SCShareableContent, options: Options) -> SCContentFilter {
        // One list of windows to leave out: the desktop's icons (windows of the Finder below the level of ordinary windows) and
        // Kriya's own (the selector, the countdown, the cards).
        var leftOut: [SCWindow] = []
        if options.hideDesktopIcons {
            leftOut += content.windows.filter { $0.owningApplication?.bundleIdentifier == "com.apple.finder" && $0.windowLayer < 0 }
        }
        if options.excludeKriya, let id = Bundle.main.bundleIdentifier {
            leftOut += content.windows.filter { $0.owningApplication?.bundleIdentifier == id }
        }
        return SCContentFilter(display: display, excludingWindows: leftOut)
    }

    private static func configuration(width: CGFloat, height: CGFloat, scale: CGFloat, options: Options) -> SCStreamConfiguration {
        let c = SCStreamConfiguration()
        c.width = max(Int((width * scale).rounded()), 1)
        c.height = max(Int((height * scale).rounded()), 1)
        c.showsCursor = options.includeCursor
        c.captureResolution = .best
        c.scalesToFit = false
        return c
    }

    // MARK: Pictures

    /// A display, whole. `options.cropNotch` cuts the notch's strip off the top.
    static func displayImage(_ id: CGDirectDisplayID, options: Options = Options(), content known: SCShareableContent? = nil) async throws -> CGImage {
        let shareable: SCShareableContent
        if let known { shareable = known } else { shareable = try await content() }
        guard let display = shareable.displays.first(where: { $0.displayID == id }) else { throw Failure("That display is not available.") }
        let bounds = CGDisplayBounds(id)
        let pixelScale = Self.scale(of: id)
        var top: CGFloat = 0
        if options.cropNotch { top = notchHeight(of: id) }
        let config = configuration(width: bounds.width, height: bounds.height - top, scale: pixelScale, options: options)
        if top > 0 { config.sourceRect = CGRect(x: 0, y: top, width: bounds.width, height: bounds.height - top) }
        return try await SCScreenshotManager.captureImage(contentFilter: filter(display: display, content: shareable, options: options), configuration: config)
    }

    /// Every display side by side in one picture, placed as they are arranged.
    static func allDisplaysImage(options: Options = Options()) async throws -> CGImage {
        let shareable = try await content()
        let ids = shareable.displays.map(\.displayID)
        guard !ids.isEmpty else { throw Failure("There is no display to capture.") }
        if ids.count == 1 { return try await displayImage(ids[0], options: options, content: shareable) }
        var pieces: [(image: CGImage, bounds: CGRect)] = []
        for id in ids { pieces.append((try await displayImage(id, options: options, content: shareable), CGDisplayBounds(id))) }
        let union = pieces.map(\.bounds).reduce(CGRect.null) { $0.union($1) }
        let ratio = pieces.map { CGFloat($0.image.width) / $0.bounds.width }.max() ?? 1
        guard let context = CGContext(data: nil, width: Int((union.width * ratio).rounded()), height: Int((union.height * ratio).rounded()), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw Failure("The displays could not be joined into one picture.")
        }
        for piece in pieces {
            // Core Graphics counts y from the bottom; the displays count it from the top.
            let x = (piece.bounds.minX - union.minX) * ratio
            let y = (union.maxY - piece.bounds.maxY) * ratio
            context.draw(piece.image, in: CGRect(x: x, y: y, width: piece.bounds.width * ratio, height: piece.bounds.height * ratio))
        }
        guard let joined = context.makeImage() else { throw Failure("The displays could not be joined into one picture.") }
        return joined
    }

    /// An area given in global points, on the display that holds most of it.
    static func areaImage(_ area: CGRect, options: Options = Options()) async throws -> CGImage {
        let shareable = try await content()
        guard let display = shareable.displays.max(by: { CGDisplayBounds($0.displayID).intersection(area).area < CGDisplayBounds($1.displayID).intersection(area).area }),
              CGDisplayBounds(display.displayID).intersects(area) else { throw Failure("That area is not on any display.") }
        let bounds = CGDisplayBounds(display.displayID)
        let local = area.intersection(bounds).offsetBy(dx: -bounds.minX, dy: -bounds.minY)
        let pixelScale = Self.scale(of: display.displayID)
        let config = configuration(width: local.width, height: local.height, scale: pixelScale, options: options)
        config.sourceRect = local
        return try await SCScreenshotManager.captureImage(contentFilter: filter(display: display, content: shareable, options: options), configuration: config)
    }

    /// One window, looked at the way `look` says (the backdrop and Kriya's own shadow are put on afterwards by the caller).
    static func windowImage(_ id: CGWindowID, look: WindowLook, options: Options = Options()) async throws -> CGImage {
        let shareable = try await content()
        guard let window = shareable.windows.first(where: { $0.windowID == id }) else { throw Failure("That window is gone.") }
        // At the sharpness of the display the window is on.
        let centre = CGPoint(x: window.frame.midX, y: window.frame.midY)
        let pixelScale = shareable.displays.first { CGDisplayBounds($0.displayID).contains(centre) }.map { Self.scale(of: $0.displayID) } ?? (NSScreen.main?.backingScaleFactor ?? 2)
        let config = configuration(width: window.frame.width, height: window.frame.height, scale: pixelScale, options: options)
        config.ignoreShadowsSingleWindow = look.dropsSystemShadow
        return try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config)
    }
}

private extension CGRect {
    var area: CGFloat { isNull || isEmpty ? 0 : width * height }
}
