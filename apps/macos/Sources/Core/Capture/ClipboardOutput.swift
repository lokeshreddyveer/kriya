import Foundation

/// What a copied screenshot puts on the clipboard.
enum ClipboardOutput: String, Codable, CaseIterable, Identifiable {
    /// The saved file, which Finder and chat apps paste as a file.
    case file
    /// The picture as PNG and TIFF data, which every app can paste. What Kriya has always done.
    case image
    /// Both, on the same clipboard item, so each app takes the form it prefers.
    case fileAndImage

    var id: String { rawValue }

    var title: String {
        switch self {
        case .file: return "File"
        case .image: return "Image (default)"
        case .fileAndImage: return "File and image"
        }
    }
}

/// Everything to put on the clipboard for one copy. Built completely before anything is written, so a copy that cannot be made leaves
/// what was on the clipboard alone.
struct ClipboardPayload: Equatable {
    var fileURL: URL?
    var png: Data?
    var tiff: Data?

    var isEmpty: Bool { fileURL == nil && png == nil && tiff == nil }
}

enum ClipboardPlan {
    struct Outcome: Equatable {
        /// What to write, or nil when nothing can be: the clipboard is then left as it was.
        var payload: ClipboardPayload?
        /// Said to the person when the copy was not what was chosen: a part that could not be made, or all of it.
        var note: String?
    }

    /// What to put on the clipboard for a mode, from what is available: the picture as data and the file it was saved to (or written to
    /// for the copy). A mode that needs a part that is missing does not guess: "File" without a file writes nothing, and "File and
    /// image" with only one of the two writes that one and says so.
    static func plan(_ mode: ClipboardOutput, png: Data?, tiff: Data?, file: URL?) -> Outcome {
        switch mode {
        case .image:
            guard png != nil else { return Outcome(payload: nil, note: "The picture could not be prepared, so the clipboard was left as it was.") }
            return Outcome(payload: ClipboardPayload(fileURL: nil, png: png, tiff: tiff), note: nil)
        case .file:
            guard let file else { return Outcome(payload: nil, note: "The picture could not be written to a file, so the clipboard was left as it was.") }
            return Outcome(payload: ClipboardPayload(fileURL: file, png: nil, tiff: nil), note: nil)
        case .fileAndImage:
            switch (file, png) {
            case let (file?, png?): return Outcome(payload: ClipboardPayload(fileURL: file, png: png, tiff: tiff), note: nil)
            case let (file?, nil): return Outcome(payload: ClipboardPayload(fileURL: file, png: nil, tiff: nil), note: "Only the file was copied: the picture could not be prepared.")
            case let (nil, png?): return Outcome(payload: ClipboardPayload(fileURL: nil, png: png, tiff: tiff), note: "Only the image was copied: the file could not be written.")
            case (nil, nil): return Outcome(payload: nil, note: "Nothing could be prepared to copy, so the clipboard was left as it was.")
            }
        }
    }
}
