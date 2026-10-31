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

    /// A picture's pixel size and its colours reduced to `levels` of each channel, using a table (see `GIFColour`). A new picture; the one
    /// given is not changed.
    static func posterized(_ image: CGImage, levels: Int) -> CGImage {
        guard levels < 256, let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                                     space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { return image }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let table = GIFColour.table(levels: levels)
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        for i in stride(from: 0, to: image.width * image.height * 4, by: 4) {
            bytes[i] = table[Int(bytes[i])]; bytes[i + 1] = table[Int(bytes[i + 1])]; bytes[i + 2] = table[Int(bytes[i + 2])]
        }
        return context.makeImage() ?? image
    }

    /// A small grey picture of a frame, for telling whether two frames are the same.
    static func signature(of image: CGImage) -> [UInt8] {
        let w = GIFFrameSignature.width, h = GIFFrameSignature.height
        var bytes = [UInt8](repeating: 0, count: w * h)
        bytes.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return bytes
    }

    /// Makes a GIF from a recording with the options given: the frame rate, size, colours and length they ask for, with pictures that
    /// repeat merged when asked. `progress` is told how far along it is (0 to 1); `isCancelled` is asked before each picture, and when
    /// it says yes nothing is left behind. It stops, and removes what it wrote, if the disk is nearly full. Before starting it says if
    /// there may not be room.
    static func convert(movie: URL, to gif: URL, options: GIFOptions = GIFOptions(), progress: @escaping (Double) -> Void = { _ in },
                        isCancelled: @escaping () -> Bool = { false }, freeBytes: @escaping (URL) -> Int64? = { RecordingDisk.freeBytes(at: $0) }) async -> GIFOutcome {
        let options = options.sanitized()
        let asset = AVURLAsset(url: movie)
        guard let duration = try? await asset.load(.duration).seconds, duration > 0, duration.isFinite else {
            return .failed("The recording could not be read, so no GIF was made.")
        }
        // The size the pictures come out at.
        var source = CGSize(width: 1280, height: 720)
        if let track = try? await asset.loadTracks(withMediaType: .video).first, let natural = try? await track.load(.naturalSize) {
            let transformed = natural.applying((try? await track.load(.preferredTransform)) ?? .identity)
            source = CGSize(width: abs(transformed.width), height: abs(transformed.height))
        }
        let size = options.resolution.outputSize(for: source)
        // Which moments, kept to what memory can hold: the GIF holds every picture until it is written.
        var times = GIFPlan.frameTimes(duration: duration, options: options)
        let memoryLimit = GIFPlan.memoryFrameLimit(for: size)
        var note: String?
        if times.count > memoryLimit {
            times = Array(times.prefix(memoryLimit))
            note = "It was limited to the first \(Int((Double(memoryLimit) / Double(options.frameRate)).rounded())) seconds to keep memory in check. Use a smaller size or a lower frame rate for longer."
        }
        guard !times.isEmpty else { return .failed("The recording is too short to make a GIF from.") }
        let folder = gif.deletingLastPathComponent()
        if let problem = GIFDisk.problem(estimated: GIFPlan.estimatedBytes(frames: times.count, size: size, options: options), free: freeBytes(folder)) { return .failed(problem) }

        func generator(maximum: CGSize) -> AVAssetImageGenerator {
            let g = AVAssetImageGenerator(asset: asset)
            g.appliesPreferredTrackTransform = true
            g.maximumSize = maximum
            g.requestedTimeToleranceBefore = .zero
            g.requestedTimeToleranceAfter = .zero
            return g
        }
        func at(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 600) }

        // Pass one, only when merging: small pictures, to see which frames repeat the one before.
        var plan = GIFPlan.all(count: times.count, delay: options.frameDelay)
        let share = options.optimize ? 0.25 : 0
        if options.optimize {
            let small = generator(maximum: CGSize(width: 96, height: 96))
            var signatures: [[UInt8]] = []
            for (n, time) in times.enumerated() {
                if isCancelled() { return .cancelled }
                if let image = try? await small.image(at: at(time)).image { signatures.append(signature(of: image)) } else { signatures.append([]) }
                progress(share * Double(n + 1) / Double(times.count))
            }
            let repeats = signatures.enumerated().map { n, s in n > 0 && GIFFrameSignature.same(s, signatures[n - 1]) }
            plan = GIFPlan.collapse(repeats: repeats, delay: options.frameDelay)
        }

        guard let destination = CGImageDestinationCreateWithURL(gif as CFURL, UTType.gif.identifier as CFString, plan.count, nil) else {
            return .failed("The GIF file could not be created in \(folder.lastPathComponent).")
        }
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        func abandon(_ outcome: GIFOutcome) -> GIFOutcome { try? FileManager.default.removeItem(at: gif); return outcome }

        // Pass two: the pictures that stay, at the size and colours asked for.
        let full = generator(maximum: size)
        var previous: CGImage?
        let levels = options.colourLevels
        for (n, item) in plan.enumerated() {
            if isCancelled() { return abandon(.cancelled) }
            if n % 20 == 0, GIFDisk.isTooLow(free: freeBytes(folder)) {
                return abandon(.failed("The disk is nearly full, so the GIF was stopped and nothing was kept. Free some space and try again."))
            }
            var image = (try? await full.image(at: at(times[item.index])).image) ?? previous
            if let made = image, levels < 256, previous == nil || made !== previous { image = posterized(made, levels: levels) }
            guard let image else { return abandon(.failed("A picture of the recording could not be read, so no GIF was made.")) }
            previous = image
            let properties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: max(item.delay, 0.02)]] as CFDictionary
            CGImageDestinationAddImage(destination, image, properties)
            progress(share + (1 - share) * 0.95 * Double(n + 1) / Double(plan.count))
        }
        if isCancelled() { return abandon(.cancelled) }
        guard CGImageDestinationFinalize(destination) else { return abandon(.failed("The GIF could not be written. Check that there is room in \(folder.lastPathComponent).")) }
        progress(1)
        let bytes = Int64((try? gif.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        return .saved(frames: plan.count, bytes: bytes, note: note)
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
