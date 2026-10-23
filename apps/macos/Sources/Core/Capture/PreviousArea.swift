import CoreGraphics
import Foundation

/// The last area the person captured, kept so the same area can be captured again. It is only valid on the display layout it was
/// taken on: when a display is added, removed, moved or changes size, it is dropped and the person picks again.
struct PreviousArea: Codable, Equatable {
    /// Points, with the origin at the top left of the main display and y growing downwards (what `screencapture -R` takes).
    var x: Double, y: Double, width: Double, height: Double
    var layout: String
    var date: Date

    static let minimumSide = 8.0

    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }

    init?(rect: CGRect, layout: String, date: Date = Date()) {
        guard rect.width.isFinite, rect.height.isFinite, rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.width >= Self.minimumSide, rect.height >= Self.minimumSide else { return nil }
        x = Double(rect.origin.x.rounded()); y = Double(rect.origin.y.rounded())
        width = Double(rect.width.rounded()); height = Double(rect.height.rounded())
        self.layout = layout
        self.date = date
    }

    /// A short description of the displays, so a change in them is noticed.
    static func layoutKey(_ frames: [CGRect], scales: [CGFloat]) -> String {
        zip(frames, scales).map { "\(Int($0.origin.x)),\(Int($0.origin.y)),\(Int($0.size.width))x\(Int($0.size.height))@\($1)" }.sorted().joined(separator: ";")
    }

    /// The area if the displays are as they were; nil otherwise.
    func valid(for currentLayout: String) -> CGRect? { layout == currentLayout ? rect : nil }

    /// AppKit's rectangle (origin bottom left of the main display, y up) to the one `screencapture -R` takes.
    static func fromAppKit(_ rect: CGRect, mainHeight: CGFloat) -> CGRect {
        CGRect(x: rect.origin.x, y: mainHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    var captureArgument: String { "\(Int(x)),\(Int(y)),\(Int(width)),\(Int(height))" }
}

extension ScreenCaptureArguments {
    /// A capture of exactly this area, with no questions asked.
    static func area(_ area: PreviousArea, delay: Int, sound: Bool, output: URL) -> [String] {
        var arguments = ["-R", area.captureArgument]
        if !sound { arguments.append("-x") }
        if delay > 0 { arguments += ["-T", String(min(delay, 30))] }
        arguments += ["-t", "png", output.path]
        return arguments
    }
}
