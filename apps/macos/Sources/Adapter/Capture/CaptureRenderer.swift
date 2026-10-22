import AppKit
import CoreGraphics
import CoreImage

/// One mark drawn on a capture. Points are fractions of the picture, from the top left.
struct Annotation: Identifiable, Equatable {
    enum Kind: Equatable {
        case box, arrow, highlight
        /// A solid block that hides what is under it.
        case hide
        /// A coarse mosaic over what is under it.
        case blur
        case text(String)
    }

    enum Color: String, CaseIterable, Identifiable {
        case red, yellow, blue, green, black, white
        var id: String { rawValue }

        var nsColor: NSColor {
            switch self {
            case .red: return NSColor(srgbRed: 0.82, green: 0.30, blue: 0.27, alpha: 1)
            case .yellow: return NSColor(srgbRed: 0.93, green: 0.76, blue: 0.20, alpha: 1)
            case .blue: return NSColor(srgbRed: 0.27, green: 0.50, blue: 0.82, alpha: 1)
            case .green: return NSColor(srgbRed: 0.30, green: 0.66, blue: 0.40, alpha: 1)
            case .black: return NSColor(srgbRed: 0.05, green: 0.05, blue: 0.05, alpha: 1)
            case .white: return NSColor.white
            }
        }
    }

    let id = UUID()
    var kind: Kind
    var start: CGPoint
    var end: CGPoint
    var color: Color = .red

    var rect: CGRect { CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y)) }
}

/// Painting marks onto a picture. Everything is drawn at the picture's own size, so nothing is lost.
enum CaptureRenderer {
    /// Solid black boxes over the given places (fractions, from the top left).
    static func hide(_ image: CGImage, rects: [CGRect]) -> CGImage? {
        render(image, annotations: rects.map { Annotation(kind: .hide, start: $0.origin, end: CGPoint(x: $0.maxX, y: $0.maxY), color: .black) })
    }

    static func render(_ image: CGImage, annotations: [Annotation]) -> CGImage? {
        let width = image.width, height = image.height
        guard width > 0, height > 0,
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        // Marks are placed from the top left, so the context is flipped to match.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        let size = CGSize(width: width, height: height)
        let unit = max(2, CGFloat(min(width, height)) / 300)

        for mark in annotations {
            let box = CGRect(x: mark.rect.minX * size.width, y: mark.rect.minY * size.height, width: mark.rect.width * size.width, height: mark.rect.height * size.height)
            let a = CGPoint(x: mark.start.x * size.width, y: mark.start.y * size.height)
            let b = CGPoint(x: mark.end.x * size.width, y: mark.end.y * size.height)
            switch mark.kind {
            case .hide:
                context.setFillColor(mark.color.nsColor.cgColor)
                context.fill(box)
            case .highlight:
                context.setFillColor(mark.color.nsColor.withAlphaComponent(0.35).cgColor)
                context.fill(box)
            case .box:
                context.setStrokeColor(mark.color.nsColor.cgColor)
                context.setLineWidth(unit * 1.5)
                context.stroke(box)
            case .arrow:
                drawArrow(in: context, from: a, to: b, color: mark.color.nsColor, width: unit * 1.6)
            case .blur:
                if let mosaic = mosaic(of: image, in: box, flippedHeight: height) {
                    context.saveGState()
                    context.translateBy(x: 0, y: CGFloat(height))
                    context.scaleBy(x: 1, y: -1)
                    // Back in the context's own bottom-left coordinates, so the place is measured from the bottom.
                    context.draw(mosaic.image, in: CGRect(x: mosaic.rect.minX, y: CGFloat(height) - mosaic.rect.maxY, width: mosaic.rect.width, height: mosaic.rect.height))
                    context.restoreGState()
                }
            case .text(let string):
                drawText(string, at: a, in: context, color: mark.color.nsColor, size: max(16, unit * 6))
            }
        }
        return context.makeImage()
    }

    private static func drawArrow(in context: CGContext, from a: CGPoint, to b: CGPoint, color: NSColor, width: CGFloat) {
        let length = hypot(b.x - a.x, b.y - a.y)
        guard length > 1 else { return }
        context.setStrokeColor(color.cgColor)
        context.setFillColor(color.cgColor)
        context.setLineWidth(width)
        context.setLineCap(.round)
        let angle = atan2(b.y - a.y, b.x - a.x)
        let head = min(length * 0.5, width * 6)
        // The shaft stops at the base of the head, so the tip stays sharp.
        let base = CGPoint(x: b.x - cos(angle) * head * 0.8, y: b.y - sin(angle) * head * 0.8)
        context.move(to: a)
        context.addLine(to: base)
        context.strokePath()
        context.move(to: b)
        context.addLine(to: CGPoint(x: b.x - cos(angle - .pi / 7) * head, y: b.y - sin(angle - .pi / 7) * head))
        context.addLine(to: CGPoint(x: b.x - cos(angle + .pi / 7) * head, y: b.y - sin(angle + .pi / 7) * head))
        context.closePath()
        context.fillPath()
    }

    private static func drawText(_ string: String, at point: CGPoint, in context: CGContext, color: NSColor, size: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: .semibold), .foregroundColor: color,
        ]
        let text = NSAttributedString(string: string, attributes: attributes)
        let bounds = text.boundingRect(with: CGSize(width: 4000, height: 4000), options: [.usesLineFragmentOrigin])
        let pad = size * 0.3
        let frame = CGRect(x: point.x, y: point.y, width: bounds.width + pad * 2, height: bounds.height + pad * 2)
        context.setFillColor(NSColor.black.withAlphaComponent(0.55).cgColor)
        context.fill(frame)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        text.draw(at: CGPoint(x: frame.minX + pad, y: frame.minY + pad))
        NSGraphicsContext.restoreGraphicsState()
    }

    /// A coarse mosaic of the part of the picture under `box` (top-left coordinates), with where to draw it.
    private static func mosaic(of image: CGImage, in box: CGRect, flippedHeight: Int) -> (image: CGImage, rect: CGRect)? {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let region = box.integral.intersection(bounds)
        guard region.width >= 2, region.height >= 2, let cropped = image.cropping(to: region) else { return nil }
        let scale = max(6, min(region.width, region.height) / 6)
        guard let filter = CIFilter(name: "CIPixellate") else { return nil }
        filter.setValue(CIImage(cgImage: cropped), forKey: kCIInputImageKey)
        filter.setValue(scale, forKey: kCIInputScaleKey)
        filter.setValue(CIVector(x: 0, y: 0), forKey: kCIInputCenterKey)
        guard let output = filter.outputImage?.cropped(to: CGRect(x: 0, y: 0, width: cropped.width, height: cropped.height)),
              let result = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return (result, region)
    }
}

extension CGImage {
    /// The picture as PNG data.
    var pngData: Data? {
        let representation = NSBitmapImageRep(cgImage: self)
        return representation.representation(using: .png, properties: [:])
    }
}
