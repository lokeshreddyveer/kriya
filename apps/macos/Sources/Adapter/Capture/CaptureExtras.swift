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

/// Reading and joining the pictures of a scrolling capture. (Taking them, and deciding when to stop, is `ScrollCaptureSession`.)
enum ScrollingCapture {
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
