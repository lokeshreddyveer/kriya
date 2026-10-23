import AppKit
import AVFoundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// Reads QR codes in a picture, on this Mac.
enum QRCodeReader {
    static func read(_ image: CGImage) -> [String] {
        let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        let features = detector?.features(in: CIImage(cgImage: image)) ?? []
        return features.compactMap { ($0 as? CIQRCodeFeature)?.messageString }
    }
}

/// Turns a screen recording into an animated GIF, entirely on this Mac.
enum GIFExporter {
    /// Writes pictures as a looping GIF. False if the file could not be made.
    static func write(frames: [CGImage], delay: Double, to url: URL) -> Bool {
        guard !frames.isEmpty, let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames.count, nil) else { return false }
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let frameProperties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary
        for frame in frames { CGImageDestinationAddImage(destination, frame, frameProperties) }
        return CGImageDestinationFinalize(destination)
    }

    /// Takes frames from a movie at `fps`, no wider than `maxWidth`, and at most `limit` of them.
    static func frames(of movie: URL, fps: Double = 10, maxWidth: CGFloat = 720, limit: Int = 300) async -> [CGImage] {
        let asset = AVURLAsset(url: movie)
        guard let duration = try? await asset.load(.duration).seconds, duration > 0 else { return [] }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxWidth, height: maxWidth * 4)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let count = min(Int(duration * fps) + 1, limit)
        let step = count > 1 ? duration / Double(count) : 0
        var out: [CGImage] = []
        for i in 0..<count {
            let time = CMTime(seconds: Double(i) * step, preferredTimescale: 600)
            if let image = try? await generator.image(at: time).image { out.append(image) }
        }
        return out
    }

    static func convert(movie: URL, to gif: URL, fps: Double = 10) async -> Bool {
        let frames = await frames(of: movie, fps: fps)
        return write(frames: frames, delay: 1 / fps, to: gif)
    }
}

/// A scrolling capture: scrolls the window in front a page at a time, takes each page, and joins them.
final class ScrollingCapture {
    private let capturer: ([String]) -> Void
    init(capturer: @escaping ([String]) -> Void) { self.capturer = capturer }

    static let maxPages = 40

    /// Runs on a background queue. Returns nil if nothing could be captured.
    func run(frame: CGRect) -> CGImage? {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let before = CGEvent(source: nil)?.location
        defer { if let before { CGWarpMouseCursorPosition(before) } }
        CGWarpMouseCursorPosition(center)
        usleep(150_000)

        var pages: [CGImage] = []
        var rows: [UInt64] = []
        var strips: [(image: CGImage, from: Int)] = []
        var scrollPixels = Int32(frame.height * 0.7)
        var failures = 0
        guard let first = shot(frame) else { return nil }
        pages.append(first)
        rows = Self.rowHashes(first)
        strips.append((first, 0))

        for _ in 1..<Self.maxPages {
            post(scroll: scrollPixels, at: center)
            usleep(450_000)
            guard let next = shot(frame) else { break }
            let nextRows = Self.rowHashes(next)
            let overlap = ScrollStitch.overlap(rows: rows, next: nextRows)
            if overlap == nextRows.count { break }   // nothing moved: the end of the page
            if overlap == 0 {
                failures += 1
                if failures > 2 { break }
                scrollPixels = max(scrollPixels / 2, 40)
                continue
            }
            strips.append((next, overlap))
            rows += nextRows[overlap...]
        }
        return Self.join(strips)
    }

    private func shot(_ frame: CGRect) -> CGImage? {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("kriya-scroll-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: file) }
        capturer(["-x", "-R", "\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width)),\(Int(frame.height))", "-t", "png", file.path])
        return ScreenCaptureService.loadImage(at: file)
    }

    private func post(scroll pixels: Int32, at point: CGPoint) {
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -pixels, wheel2: 0, wheel3: 0) else { return }
        event.location = point
        event.setIntegerValueField(.eventSourceUserData, value: EventMonitor.syntheticMarker)
        event.post(tap: .cghidEventTap)
    }

    static func rowHashes(_ image: CGImage) -> [UInt64] {
        let w = image.width, h = image.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        guard let context = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return data.withUnsafeBufferPointer { buffer in
            (0..<h).map { y in ScrollStitch.hash(row: UnsafeBufferPointer(rebasing: buffer[(y * w * 4)..<((y + 1) * w * 4)]), bytesPerPixel: 4) }
        }
    }

    /// Stacks the strips, dropping the first `from` rows of each.
    static func join(_ strips: [(image: CGImage, from: Int)]) -> CGImage? {
        guard let first = strips.first else { return nil }
        let width = first.image.width
        let total = strips.reduce(0) { $0 + $1.image.height - $1.from }
        guard total > 0, let context = CGContext(data: nil, width: width, height: total, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        var top = total
        for strip in strips {
            let keep = strip.image.height - strip.from
            guard let cropped = strip.image.cropping(to: CGRect(x: 0, y: strip.from, width: width, height: keep)) else { continue }
            top -= keep
            context.draw(cropped, in: CGRect(x: 0, y: top, width: width, height: keep))
        }
        return context.makeImage()
    }
}
