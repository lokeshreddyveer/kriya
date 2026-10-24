import CoreGraphics
import Foundation
import Vision

/// Reading the text in a picture with the Mac's own recognizer. It runs on this Mac and nothing is sent anywhere.
final class TextRecognizer {
    /// The language codes the reader on this Mac understands.
    static var supportedLanguages: [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        return (try? request.supportedRecognitionLanguages()) ?? []
    }

    /// The lines of text in the picture, each with its words and where they are.
    func recognize(_ image: CGImage) throws -> [RecognizedLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let chosen = OCRLanguages.resolve(chosen: OCRLanguages.parse(UserDefaults.standard.string(forKey: OCRLanguages.defaultsKey) ?? ""), supported: Self.supportedLanguages)
        if chosen.isEmpty { request.automaticallyDetectsLanguage = true } else { request.recognitionLanguages = chosen; request.automaticallyDetectsLanguage = false }
        // On some Macs the neural engine refuses the accurate model ("e5rt" errors). Then the same request is tried on the CPU, and
        // finally with the fast model, so reading text still works.
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            let retry = VNRecognizeTextRequest()
            retry.recognitionLevel = .accurate
            retry.usesLanguageCorrection = true
            retry.usesCPUOnly = true
            if chosen.isEmpty { retry.automaticallyDetectsLanguage = true } else { retry.recognitionLanguages = chosen; retry.automaticallyDetectsLanguage = false }
            do { try VNImageRequestHandler(cgImage: image, options: [:]).perform([retry]); return try Self.lines(from: retry) } catch {
                let fast = VNRecognizeTextRequest()
                fast.recognitionLevel = .fast
                fast.usesCPUOnly = true
                // The fast model reads fewer languages than the accurate one. The person's chosen languages are kept: only the ones
                // it can read are asked for, and if none of them is, it is not used at all (a wrong-language reading is worse than
                // an error), so Telugu or Hindi never silently turn into guessed Latin text.
                if chosen.isEmpty {
                    fast.automaticallyDetectsLanguage = true
                } else {
                    let readable = (try? fast.supportedRecognitionLanguages()) ?? []
                    let usable = chosen.filter { readable.contains($0) }
                    guard !usable.isEmpty else { throw error }
                    fast.recognitionLanguages = usable
                    fast.automaticallyDetectsLanguage = false
                }
                try VNImageRequestHandler(cgImage: image, options: [:]).perform([fast])
                return try Self.lines(from: fast)
            }
        }
        return try Self.lines(from: request)
    }

    private static func lines(from request: VNRecognizeTextRequest) throws -> [RecognizedLine] {
        var lines: [RecognizedLine] = []
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let text = candidate.string
            var words: [RecognizedWord] = []
            var index = text.startIndex
            while index < text.endIndex {
                // Skip the spaces, then take everything up to the next one.
                while index < text.endIndex, text[index].isWhitespace { index = text.index(after: index) }
                guard index < text.endIndex else { break }
                let start = index
                while index < text.endIndex, !text[index].isWhitespace { index = text.index(after: index) }
                let range = start..<index
                if let box = (try? candidate.boundingBox(for: range))?.boundingBox {
                    // The recognizer measures from the bottom left; everything else here measures from the top left.
                    words.append(RecognizedWord(text: String(text[range]), box: CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)))
                }
            }
            if !words.isEmpty { lines.append(RecognizedLine(words: words)) }
        }
        // Top to bottom, then left to right, so the text reads in order.
        return lines.sorted {
            let a = $0.words[0].box, b = $1.words[0].box
            return abs(a.minY - b.minY) > 0.01 ? a.minY < b.minY : a.minX < b.minX
        }
    }

    /// All the text, one line per line.
    func text(in image: CGImage) throws -> String {
        try recognize(image).map(\.text).joined(separator: "\n")
    }
}
