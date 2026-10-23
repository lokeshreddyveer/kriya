import AppKit
import AVFoundation
import Vision
import CoreImage

/// Lifts the main subject of a picture off its background, on this Mac, with Vision.
enum SubjectCutout {
    /// The picture with everything but the subject made transparent, or nil when no subject was found.
    static func cut(_ image: CGImage) -> CGImage? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil, let result = request.results?.first, !result.allInstances.isEmpty,
              let buffer = try? result.generateMaskedImage(ofInstances: result.allInstances, from: handler, croppedToInstancesExtent: true) else { return nil }
        let context = CIContext()
        let ci = CIImage(cvPixelBuffer: buffer)
        return context.createCGImage(ci, from: ci.extent)
    }
}

/// Cuts a recording down to a part of it, writing a new file next to the original. The original is never changed.
enum RecordingTrimmer {
    static func trim(_ url: URL, start: Double, end: Double, completion: @escaping (Result<URL, Error>) -> Void) {
        let asset = AVURLAsset(url: url)
        Task {
            do {
                let duration = try await asset.load(.duration).seconds
                guard let range = RecordingTrim.range(start: start, end: end, duration: duration) else {
                    throw NSError(domain: "Kriya", code: 1, userInfo: [NSLocalizedDescriptionKey: "That part is empty, or outside the recording (it is \(Int(duration)) seconds long)."])
                }
                guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
                    throw NSError(domain: "Kriya", code: 2, userInfo: [NSLocalizedDescriptionKey: "This recording cannot be trimmed."])
                }
                var out = url.deletingPathExtension().appendingPathExtension("trimmed").appendingPathExtension(url.pathExtension)
                var n = 2
                while FileManager.default.fileExists(atPath: out.path) {
                    out = url.deletingPathExtension().appendingPathExtension("trimmed \(n)").appendingPathExtension(url.pathExtension)
                    n += 1
                }
                session.outputURL = out
                session.outputFileType = url.pathExtension.lowercased() == "mov" ? .mov : .mp4
                session.timeRange = CMTimeRange(start: CMTime(seconds: range.start, preferredTimescale: 600), end: CMTime(seconds: range.end, preferredTimescale: 600))
                await session.export()
                if let error = session.error { throw error }
                completion(.success(out))
            } catch {
                completion(.failure(error))
            }
        }
    }
}
