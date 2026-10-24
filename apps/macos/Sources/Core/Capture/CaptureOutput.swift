import CoreGraphics
import Foundation

/// The ways a capture can be handed on as text: a Markdown image, an HTML tag, a data address.
enum CaptureLinks {
    /// `![Capture](https://…/shot.png)`. `alt` is cleaned so it cannot break out of the brackets.
    static func markdown(url: String, alt: String = "Capture") -> String {
        let clean = alt.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "").replacingOccurrences(of: "\n", with: " ")
        return "![\(clean)](\(url.replacingOccurrences(of: " ", with: "%20").replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29")))"
    }

    static func html(url: String, alt: String = "Capture", width: Int? = nil) -> String {
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;") }
        return "<img src=\"\(esc(url))\" alt=\"\(esc(alt))\"\(width.map { " width=\"\($0)\"" } ?? "")>"
    }

    static func dataURI(_ data: Data, mime: String = "image/png") -> String { "data:\(mime);base64,\(data.base64EncodedString())" }

    /// A file path as a `file://` address that survives spaces and symbols.
    static func fileURL(_ path: String) -> String { URL(fileURLWithPath: path).absoluteString }
}

/// What a picture can be saved as. WebP is not here: macOS can read it but has no way to write it.
enum CaptureFormat: String, Codable, CaseIterable, Identifiable {
    case png, jpeg, heic, pdf, tiff
    var id: String { rawValue }
    var title: String { self == .jpeg ? "JPEG" : rawValue.uppercased() }
    var fileExtension: String { self == .jpeg ? "jpg" : rawValue }
    var mime: String { switch self { case .png: return "image/png"; case .jpeg: return "image/jpeg"; case .heic: return "image/heic"; case .pdf: return "application/pdf"; case .tiff: return "image/tiff" } }
}

/// Cleaning up text read from a picture: joined lines, paragraphs, Markdown, and tables as CSV. Works from the recognized words and
/// where they sit, so it needs no picture.
enum OCRText {
    /// All the words on one line, the way a sentence reads, with hyphenated line ends joined.
    static func joined(_ lines: [RecognizedLine]) -> String {
        var out = ""
        for line in lines.map(\.text) {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { continue }
            if out.hasSuffix("-"), let first = t.first, first.isLowercase { out.removeLast(); out += t } else { out += out.isEmpty ? t : " " + t }
        }
        return out
    }

    /// Lines grouped into paragraphs: a gap clearly bigger than the usual line gap starts a new one.
    static func paragraphs(_ lines: [RecognizedLine]) -> [String] {
        let usable = lines.filter { !$0.words.isEmpty }
        guard usable.count > 1 else { return usable.isEmpty ? [] : [joined(usable)] }
        let gaps = zip(usable, usable.dropFirst()).map { $1.words[0].box.minY - $0.words[0].box.maxY }
        let typical = gaps.sorted()[gaps.count / 2]
        var groups: [[RecognizedLine]] = [[usable[0]]]
        for (i, line) in usable.dropFirst().enumerated() {
            if gaps[i] > max(typical * 1.8, 0.012) { groups.append([line]) } else { groups[groups.count - 1].append(line) }
        }
        return groups.map(joined)
    }

    /// Paragraphs separated by a blank line, with lines that look like list items turned into Markdown bullets.
    static func markdown(_ lines: [RecognizedLine]) -> String {
        paragraphs(lines).map { p in
            p.replacingOccurrences(of: #"^[•●▪◦·]\s*"#, with: "- ", options: .regularExpression)
        }.joined(separator: "\n\n")
    }

    /// A table read as rows and columns: words on the same row (by height), split into cells wherever there is a wide gap.
    static func table(_ lines: [RecognizedLine], gap: CGFloat = 0.02) -> [[String]] {
        var rows: [[String]] = []
        for line in lines.sorted(by: { ($0.words.first?.box.minY ?? 0) < ($1.words.first?.box.minY ?? 0) }) {
            var cells: [String] = [], current: [String] = []
            var lastRight: CGFloat?
            for word in line.words.sorted(by: { $0.box.minX < $1.box.minX }) {
                if let lastRight, word.box.minX - lastRight > gap, !current.isEmpty { cells.append(current.joined(separator: " ")); current = [] }
                current.append(word.text)
                lastRight = word.box.maxX
            }
            if !current.isEmpty { cells.append(current.joined(separator: " ")) }
            if !cells.isEmpty { rows.append(cells) }
        }
        return rows
    }

    static func csv(_ rows: [[String]]) -> String {
        func q(_ s: String) -> String { s.contains(",") || s.contains("\"") || s.contains("\n") ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s }
        return rows.map { $0.map(q).joined(separator: ",") }.joined(separator: "\n")
    }
}

/// Making a plain screenshot presentable: space around it, a background, round corners and a shadow, at a chosen shape.
struct CaptureBeautify: Codable, Equatable {
    enum Background: String, Codable, CaseIterable, Identifiable {
        case none, white, black, ocean, sunset, forest, graphite
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        /// The two colours of the backdrop (the same twice for a plain one), as red-green-blue fractions.
        var colors: ((CGFloat, CGFloat, CGFloat), (CGFloat, CGFloat, CGFloat)) {
            switch self {
            case .none, .white: return ((1, 1, 1), (1, 1, 1))
            case .black: return ((0.05, 0.05, 0.06), (0.05, 0.05, 0.06))
            case .ocean: return ((0.15, 0.45, 0.85), (0.40, 0.80, 0.90))
            case .sunset: return ((0.95, 0.45, 0.35), (0.98, 0.78, 0.40))
            case .forest: return ((0.12, 0.45, 0.35), (0.50, 0.80, 0.55))
            case .graphite: return ((0.18, 0.19, 0.22), (0.42, 0.45, 0.50))
            }
        }
    }

    /// Width and height as a ratio the finished canvas is stretched to, or nil to keep the natural shape.
    enum Aspect: String, Codable, CaseIterable, Identifiable {
        case free, square, wide, standard, social
        var id: String { rawValue }
        var title: String { switch self { case .free: return "Free"; case .square: return "1:1"; case .wide: return "16:9"; case .standard: return "4:3"; case .social: return "1.91:1" } }
        var ratio: CGFloat? { switch self { case .free: return nil; case .square: return 1; case .wide: return 16.0 / 9; case .standard: return 4.0 / 3; case .social: return 1.91 } }
    }

    var background: Background = .none
    /// Space around the picture as a fraction of its shorter side, 0 to 0.5.
    var padding: Double = 0.08
    /// Corner radius as a fraction of the shorter side, 0 to 0.1.
    var corners: Double = 0.02
    var shadow = true
    var aspect: Aspect = .free

    var isOn: Bool { background != .none }

    /// The size of the finished canvas and where the picture sits on it (top-left origin). The picture is never scaled.
    func layout(for size: CGSize) -> (canvas: CGSize, picture: CGRect) {
        guard isOn, size.width > 0, size.height > 0 else { return (size, CGRect(origin: .zero, size: size)) }
        let pad = (min(size.width, size.height) * CGFloat(min(max(padding, 0), 0.5))).rounded()
        var canvas = CGSize(width: size.width + pad * 2, height: size.height + pad * 2)
        if let ratio = aspect.ratio {
            if canvas.width / canvas.height < ratio { canvas.width = (canvas.height * ratio).rounded() } else { canvas.height = (canvas.width / ratio).rounded() }
        }
        let origin = CGPoint(x: ((canvas.width - size.width) / 2).rounded(), y: ((canvas.height - size.height) / 2).rounded())
        return (canvas, CGRect(origin: origin, size: size))
    }
}

/// Which apps a capture refuses to take a picture of: password managers and similar, so a secret is never captured by accident.
enum CaptureExclusions {
    static let defaults = ["com.agilebits.onepassword7", "com.1password.1password", "com.bitwarden.desktop", "com.lastpass.LastPass", "com.dashlane.dashlanephonefinal", "com.apple.keychainaccess", "org.keepassxc.keepassxc", "com.apple.Passwords"]

    static func isExcluded(_ bundleID: String?, list: [String]) -> Bool {
        guard let bundleID, !bundleID.isEmpty else { return false }
        return list.contains { $0.caseInsensitiveCompare(bundleID) == .orderedSame }
    }
}
