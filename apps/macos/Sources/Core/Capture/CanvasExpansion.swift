import Foundation

/// Making the canvas large enough to hold every mark, so a mark drawn past the edge of the picture is not cut off. This only decides the
/// size and where the picture sits: the picture and its bounds in a project are never changed, and the canvas is made when the picture
/// is exported.
enum CanvasExpansion {
    /// The most the canvas may grow to on a side, in pixels. A stray mark far outside cannot ask for a picture that cannot be made.
    static let maxSide: CGFloat = 16_384
    /// Marks may be placed this far outside the picture, as a multiple of its size (so 2 is two picture-widths away).
    static let reach: CGFloat = 2

    struct Result: Equatable {
        /// The canvas, in the picture's own pixel coordinates (top left origin). It always contains the picture.
        var bounds: CGRect
        /// Where the picture's top left sits on the canvas.
        var offset: CGPoint { CGPoint(x: -bounds.minX, y: -bounds.minY) }
        var size: CGSize { bounds.size }
        var expanded: Bool
    }

    /// The canvas for a picture and the room its marks need: the picture united with the marks, with `padding` added around, as
    ///     `imageRect.union(annotationBounds).insetBy(dx: -padding, dy: -padding)`
    /// but only when a mark reaches past the picture: with every mark inside it, the canvas is the picture itself and nothing is added.
    /// A canvas past `maxSide` is brought back by dropping the room on the sides that grew, never the picture.
    static func canvas(imageRect: CGRect, annotationBounds: CGRect?, padding: CGFloat) -> Result {
        guard let marks = annotationBounds, !marks.isNull, marks.width.isFinite, marks.height.isFinite else { return Result(bounds: imageRect, expanded: false) }
        let union = imageRect.union(marks)
        guard union != imageRect else { return Result(bounds: imageRect, expanded: false) }
        let pad = max(padding, 0)
        var bounds = union.insetBy(dx: -pad, dy: -pad).integral
        bounds = fit(bounds, around: imageRect)
        return Result(bounds: bounds, expanded: bounds != imageRect)
    }

    /// The bounds with no side longer than `maxSide`, still containing `imageRect`.
    private static func fit(_ bounds: CGRect, around image: CGRect) -> CGRect {
        var out = bounds
        if out.width > maxSide {
            let spare = max(maxSide - image.width, 0)
            let left = min(image.minX - out.minX, spare / 2), right = min(out.maxX - image.maxX, spare - left)
            out.origin.x = image.minX - left; out.size.width = image.width + left + right
        }
        if out.height > maxSide {
            let spare = max(maxSide - image.height, 0)
            let top = min(image.minY - out.minY, spare / 2), bottom = min(out.maxY - image.maxY, spare - top)
            out.origin.y = image.minY - top; out.size.height = image.height + top + bottom
        }
        return out
    }

    /// The union of rectangles, or nil for none.
    static func union(_ rects: [CGRect]) -> CGRect? {
        rects.dropFirst().reduce(rects.first) { $0?.union($1) }
    }

    /// A mark's place held to what the editor allows: within `reach` picture-sizes of the picture when the canvas may grow, otherwise on
    /// the picture. Fractions of the picture, from its top left.
    static func clamped(_ point: CGPoint, canGrow: Bool) -> CGPoint {
        let low: CGFloat = canGrow ? -reach : 0, high: CGFloat = canGrow ? 1 + reach : 1
        func c(_ v: CGFloat) -> CGFloat { v.isNaN ? 0 : min(max(v, low), high) }
        return CGPoint(x: c(point.x), y: c(point.y))
    }
}
