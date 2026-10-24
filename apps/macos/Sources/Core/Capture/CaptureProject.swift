import CoreGraphics
import Foundation

/// A marked-up capture that can be saved and opened again: the original picture, every mark as a separate thing to move or remove,
/// and the presentation settings. The original is never changed by editing.
struct CaptureProject: Codable, Equatable {
    struct Mark: Codable, Equatable {
        /// box, arrow, highlight, hide, blur, text, line, ellipse, number, pen
        var kind: String
        var text: String?
        var number: Int?
        /// Fractions of the picture from the top left: start and end, or every point of a pen stroke.
        var points: [[Double]]
        var color: String
    }

    static let fileExtension = "kriyashot"
    static let currentVersion = 1
    static let maxBytes = 200 * 1024 * 1024

    var version = Self.currentVersion
    /// The original picture as PNG.
    var image: Data
    var marks: [Mark] = []
    var beautify = CaptureBeautify()
    /// The part kept, as x, y, width, height fractions from the top left; nil keeps the whole picture.
    var crop: [Double]? = nil

    func encoded() -> Data? {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return try? e.encode(self)
    }

    /// Reads a saved project. Anything that is too big, from a newer version, or not a project is refused.
    static func decode(_ data: Data) -> CaptureProject? {
        guard data.count <= maxBytes, let project = try? JSONDecoder().decode(CaptureProject.self, from: data),
              project.version <= currentVersion, !project.image.isEmpty, project.marks.count <= 5000 else { return nil }
        var clean = project
        // Points are fractions; anything outside the picture is brought back in.
        clean.marks = project.marks.map { mark in
            var m = mark
            m.points = mark.points.prefix(5000).map { $0.prefix(2).map { min(max($0, 0), 1) } }.filter { $0.count == 2 }
            if m.text.map({ $0.count > 500 }) == true { m.text = String(m.text!.prefix(500)) }
            return m
        }
        if let c = clean.crop { clean.crop = c.count == 4 && c.allSatisfy({ $0.isFinite }) && c[2] > 0.001 && c[3] > 0.001 ? [min(max(c[0], 0), 1), min(max(c[1], 0), 1), min(c[2], 1), min(c[3], 1)] : nil }
        clean.beautify.padding = min(max(clean.beautify.padding, 0), 0.5)
        clean.beautify.corners = min(max(clean.beautify.corners, 0), 0.1)
        return clean
    }

    /// The numbers 1, 2, 3… for numbered steps, in the order they were added.
    static func nextStepNumber(after marks: [Mark]) -> Int { (marks.compactMap(\.number).max() ?? 0) + 1 }
}
