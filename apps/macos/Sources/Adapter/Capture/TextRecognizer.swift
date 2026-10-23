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
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
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
