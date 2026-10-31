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
        /// A plain line, an outlined oval, a numbered step marker, and a freehand stroke (its points are in `points`).
        case line, ellipse, number(Int), pen
        /// Everything outside the box is darkened, so what is inside stands out.
        case spotlight
        /// A solid rectangle of the colour.
        case filledBox
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
    /// A freehand stroke's points, as fractions of the picture.
    var points: [CGPoint] = []
    /// The shadow under the mark, drawn before the mark itself.
    var shadow = AnnotationShadow()

    var rect: CGRect { CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y)) }

    // MARK: Saving as part of a project

    var mark: CaptureProject.Mark {
        let name: String, text: String?, number: Int?
        switch kind {
        case .box: (name, text, number) = ("box", nil, nil)
        case .arrow: (name, text, number) = ("arrow", nil, nil)
        case .highlight: (name, text, number) = ("highlight", nil, nil)
        case .hide: (name, text, number) = ("hide", nil, nil)
        case .blur: (name, text, number) = ("blur", nil, nil)
        case .text(let s): (name, text, number) = ("text", s, nil)
        case .line: (name, text, number) = ("line", nil, nil)
        case .ellipse: (name, text, number) = ("ellipse", nil, nil)
        case .number(let n): (name, text, number) = ("number", nil, n)
        case .pen: (name, text, number) = ("pen", nil, nil)
        case .spotlight: (name, text, number) = ("spotlight", nil, nil)
        case .filledBox: (name, text, number) = ("filledBox", nil, nil)
        }
        let pts = kind == .pen ? points : [start, end]
        return CaptureProject.Mark(kind: name, text: text, number: number, points: pts.map { [Double($0.x), Double($0.y)] }, color: color.rawValue, shadow: shadow.enabled ? shadow : nil)
    }

    init(kind: Kind, start: CGPoint, end: CGPoint, color: Color = .red, points: [CGPoint] = [], shadow: AnnotationShadow = AnnotationShadow()) {
        self.kind = kind; self.start = start; self.end = end; self.color = color; self.points = points; self.shadow = shadow
    }

    init?(mark: CaptureProject.Mark) {
        let kind: Kind
        switch mark.kind {
        case "box": kind = .box
        case "arrow": kind = .arrow
        case "highlight": kind = .highlight
        case "hide": kind = .hide
        case "blur": kind = .blur
        case "text": kind = .text(mark.text ?? "")
        case "line": kind = .line
        case "ellipse": kind = .ellipse
        case "number": kind = .number(mark.number ?? 1)
        case "pen": kind = .pen
        case "spotlight": kind = .spotlight
        case "filledBox": kind = .filledBox
        default: return nil
        }
        let pts = mark.points.filter { $0.count == 2 }.map { CGPoint(x: $0[0], y: $0[1]) }
        guard let first = pts.first, let last = pts.last else { return nil }
        self.init(kind: kind, start: first, end: last, color: Color(rawValue: mark.color) ?? .red, points: kind == .pen ? pts : [], shadow: mark.shadow?.sanitized() ?? AnnotationShadow())
    }

    /// The place the mark covers in the picture's own pixels (top left origin), with room for its stroke and its shadow. Marks can lie
    /// outside the picture, which is what makes the canvas grow.
    func pixelBounds(in size: CGSize, unit: CGFloat) -> CGRect {
        func p(_ q: CGPoint) -> CGPoint { CGPoint(x: q.x * size.width, y: q.y * size.height) }
        let a = p(start), b = p(end)
        var box: CGRect
        switch kind {
        case .text(let string):
            let fontSize = max(16, unit * 6)
            box = CGRect(x: a.x, y: a.y, width: CGFloat(max(string.count, 1)) * fontSize * 0.62, height: fontSize * 1.4)
        case .number:
            let r = max(12, unit * 5)
            box = CGRect(x: a.x - r, y: a.y - r, width: r * 2, height: r * 2)
        case .pen:
            guard let first = points.first else { return .null }
            box = points.dropFirst().reduce(CGRect(origin: p(first), size: .zero)) { $0.union(CGRect(origin: p($1), size: .zero)) }
        default:
            box = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
        }
        // The stroke is wider than the line it follows, and an arrow's head sticks out.
        var margin = unit * 2.5
        if shadow.enabled && canHaveShadow {
            let s = shadow.sanitized()
            margin += (s.blur + max(abs(s.offset.width), abs(s.offset.height))) * unit / 2
        }
        return box.insetBy(dx: -margin, dy: -margin)
    }

    /// Whether this kind of mark can have a shadow: a block that hides, or a mosaic, is meant to look flat.
    var canHaveShadow: Bool {
        switch kind {
        case .hide, .blur, .spotlight: return false
        default: return true
        }
    }
}

/// Painting marks onto a picture. Everything is drawn at the picture's own size, so nothing is lost.
enum CaptureRenderer {
    /// Solid black boxes over the given places (fractions, from the top left).
    static func hide(_ image: CGImage, rects: [CGRect]) -> CGImage? {
        render(image, annotations: rects.map { Annotation(kind: .hide, start: $0.origin, end: CGPoint(x: $0.maxX, y: $0.maxY), color: .black) })
    }

    /// Paints the marks on the picture. With `expandPadding`, the canvas grows (by that much around) when a mark reaches past the picture,
    /// so nothing is cut off; the picture itself is drawn at its own size, and where it sits on the larger canvas is what moves.
    static func render(_ image: CGImage, annotations: [Annotation], expandPadding: CGFloat? = nil) -> CGImage? {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
        let unit = max(2, CGFloat(min(width, height)) / 300)
        let imageRect = CGRect(x: 0, y: 0, width: width, height: height)
        var canvas = CanvasExpansion.Result(bounds: imageRect, expanded: false)
        if let expandPadding {
            let marks = CanvasExpansion.union(annotations.map { $0.pixelBounds(in: CGSize(width: width, height: height), unit: unit) })
            canvas = CanvasExpansion.canvas(imageRect: imageRect, annotationBounds: marks, padding: expandPadding)
        }
        let canvasWidth = Int(canvas.size.width), canvasHeight = Int(canvas.size.height)
        guard let context = CGContext(
                data: nil, width: canvasWidth, height: canvasHeight, bitsPerComponent: 8, bytesPerRow: 0,
                space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        let offset = canvas.offset
        context.draw(image, in: CGRect(x: offset.x, y: CGFloat(canvasHeight) - offset.y - CGFloat(height), width: CGFloat(width), height: CGFloat(height)))
        // Marks are placed from the top left of the picture, so the context is moved there and flipped to match.
        context.translateBy(x: offset.x, y: CGFloat(canvasHeight) - offset.y)
        context.scaleBy(x: 1, y: -1)
        let size = CGSize(width: width, height: height)
        // The whole canvas, in the picture's own coordinates, for marks that darken everything around a place.
        let wholeCanvas = canvas.bounds

        for mark in annotations {
            let box = CGRect(x: mark.rect.minX * size.width, y: mark.rect.minY * size.height, width: mark.rect.width * size.width, height: mark.rect.height * size.height)
            let a = CGPoint(x: mark.start.x * size.width, y: mark.start.y * size.height)
            let b = CGPoint(x: mark.end.x * size.width, y: mark.end.y * size.height)
            // The shadow is drawn first, under the mark: the mark is drawn into a transparency layer, which gives the whole of it one
            // shadow, before anything of the mark itself is seen. (A shadow offset is in the context's own space, so down is negative.)
            let shadow = mark.shadow.sanitized()
            let shadowed = shadow.enabled && mark.canHaveShadow
            if shadowed {
                context.saveGState()
                let scale = unit / 2
                context.setShadow(offset: CGSize(width: shadow.offset.width * scale, height: -shadow.offset.height * scale), blur: shadow.blur * scale,
                                  color: CGColor(gray: 0, alpha: shadow.opacity))
                context.beginTransparencyLayer(auxiliaryInfo: nil)
            }
            defer { if shadowed { context.endTransparencyLayer(); context.restoreGState() } }
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
            case .line:
                context.setStrokeColor(mark.color.nsColor.cgColor)
                context.setLineWidth(unit * 1.5)
                context.setLineCap(.round)
                context.move(to: a); context.addLine(to: b); context.strokePath()
            case .ellipse:
                context.setStrokeColor(mark.color.nsColor.cgColor)
                context.setLineWidth(unit * 1.5)
                context.strokeEllipse(in: box)
            case .number(let n):
                drawStep(n, at: a, in: context, color: mark.color.nsColor, radius: max(12, unit * 5))
            case .spotlight:
                context.setFillColor(CGColor(gray: 0, alpha: 0.55))
                context.addRect(wholeCanvas); context.addRect(box)
                context.fillPath(using: .evenOdd)
            case .filledBox:
                context.setFillColor(mark.color.nsColor.cgColor)
                context.fill(box)
            case .pen:
                guard mark.points.count > 1 else { continue }
                context.setStrokeColor(mark.color.nsColor.cgColor)
                context.setLineWidth(unit * 1.4)
                context.setLineCap(.round); context.setLineJoin(.round)
                context.move(to: CGPoint(x: mark.points[0].x * size.width, y: mark.points[0].y * size.height))
                for p in mark.points.dropFirst() { context.addLine(to: CGPoint(x: p.x * size.width, y: p.y * size.height)) }
                context.strokePath()
            }
        }
        return context.makeImage()
    }

    /// The picture brought to `width` pixels, keeping its shape. The picture given is not changed.
    static func resized(_ image: CGImage, toWidth width: Int) -> CGImage {
        let target = ResizeRules.size(of: CGSize(width: image.width, height: image.height), width: min(max(width, ResizeRules.widthRange.lowerBound), ResizeRules.widthRange.upperBound))
        let w = Int(target.width), h = Int(target.height)
        guard w != image.width || h != image.height, let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                                                              space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return context.makeImage() ?? image
    }

    /// A filled circle with the step's number in it, centred on `point`.
    private static func drawStep(_ number: Int, at point: CGPoint, in context: CGContext, color: NSColor, radius: CGFloat) {
        context.setFillColor(color.cgColor)
        context.fillEllipse(in: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
        let text = NSAttributedString(string: "\(number)", attributes: [.font: NSFont.systemFont(ofSize: radius * 1.15, weight: .bold), .foregroundColor: NSColor.white])
        let bounds = text.size()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        text.draw(at: CGPoint(x: point.x - bounds.width / 2, y: point.y - bounds.height / 2))
        NSGraphicsContext.restoreGraphicsState()
    }

    /// The part of the picture inside `unit` (fractions from the top left), or the picture itself when the part is too small.
    static func crop(_ image: CGImage, to unit: CGRect) -> CGImage {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let rect = CGRect(x: unit.minX * w, y: unit.minY * h, width: unit.width * w, height: unit.height * h).integral.intersection(CGRect(x: 0, y: 0, width: w, height: h))
        guard rect.width >= 4, rect.height >= 4, let cropped = image.cropping(to: rect) else { return image }
        return cropped
    }

    /// The picture on a backdrop with space around it, rounded corners and a shadow, at the chosen shape, with its border in the ring just
    /// outside it. The picture is not scaled and no part of it is covered by the border. With no backdrop, a border alone gives a canvas
    /// that is the picture and its border, transparent around the border's rounded corners.
    static func beautified(_ image: CGImage, _ style: CaptureBeautify) -> CGImage? {
        guard style.needsCanvas else { return image }
        let size = CGSize(width: image.width, height: image.height)
        let layout = style.layout(for: size)
        let cw = Int(layout.canvas.width), ch = Int(layout.canvas.height)
        guard cw > 0, ch > 0, let context = CGContext(data: nil, width: cw, height: ch, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        if style.isOn {
            let (c1, c2) = style.background.colors
            let colors = [CGColor(red: c1.0, green: c1.1, blue: c1.2, alpha: 1), CGColor(red: c2.0, green: c2.1, blue: c2.2, alpha: 1)] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: CGFloat(ch)), end: CGPoint(x: CGFloat(cw), y: 0), options: [])
            }
        }
        // The context's origin is bottom left; the layout's is top left.
        let picture = CGRect(x: layout.picture.minX, y: CGFloat(ch) - layout.picture.maxY, width: layout.picture.width, height: layout.picture.height)
        let radius = style.isOn ? min(size.width, size.height) * CGFloat(min(max(style.corners, 0), 0.1)) : 0
        let path = CGPath(roundedRect: picture, cornerWidth: radius, cornerHeight: radius, transform: nil)
        if style.isOn, style.shadow {
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: -min(size.width, size.height) * 0.012), blur: min(size.width, size.height) * 0.04, color: CGColor(gray: 0, alpha: 0.35))
            context.addPath(path); context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fillPath()
            context.restoreGState()
        }
        context.saveGState()
        context.addPath(path); context.clip()
        context.draw(image, in: picture)
        context.restoreGState()
        // The border: the ring between the picture's edge and the same shape grown by its width. The canvas has at least that much room.
        if style.border.enabled {
            let width = CGFloat(style.border.drawnWidth)
            let outer = CGPath(roundedRect: picture.insetBy(dx: -width, dy: -width), cornerWidth: radius + width, cornerHeight: radius + width, transform: nil)
            context.saveGState()
            context.addPath(outer); context.addPath(path)
            context.setFillColor(style.border.color.cgColor)
            context.fillPath(using: .evenOdd)
            context.restoreGState()
        }
        return context.makeImage()
    }

    /// The picture redrawn in an sRGB bitmap, so its colours are the ones apps that ignore colour profiles show. A picture already in
    /// sRGB comes back as it is. The one given is never changed: a new picture is made.
    static func srgb(_ image: CGImage) -> CGImage {
        guard let target = CGColorSpace(name: CGColorSpace.sRGB) else { return image }
        if let current = image.colorSpace, (current.name as String?) == (target.name as String?) { return image }
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0, space: target,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage() ?? image
    }

    /// The picture as it is written, by the output policy: at 1x on a Retina screen if asked, and in the sRGB colour profile if asked. The
    /// border is not drawn here; `beautified` draws it, with or without a backdrop. The picture is returned as it was when nothing is asked.
    static func written(_ image: CGImage, output: OutputPolicy, backingScale: CGFloat) -> CGImage {
        guard output.scale == .oneX || output.convertToSRGB else { return image }
        let target = output.outputSize(pixels: CGSize(width: image.width, height: image.height), backingScale: backingScale)
        let w = Int(target.width), h = Int(target.height)
        // Nothing to do when 1x was asked for on a screen that is already 1x.
        if w == image.width, h == image.height, !output.convertToSRGB { return image }
        let srgb = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let space = output.convertToSRGB ? srgb : (image.colorSpace ?? srgb)
        let bitmap = CGImageAlphaInfo.premultipliedLast.rawValue
        // A colour space the system cannot draw into falls back to sRGB rather than leaving the picture at the wrong size.
        guard w > 0, h > 0, let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: bitmap)
                ?? CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: srgb, bitmapInfo: bitmap) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return context.makeImage() ?? image
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
    /// The picture in the chosen format. JPEG has no transparency, so it is put on white; a PDF is one page the size of the picture.
    /// With `convertToSRGB`, the picture is first redrawn in the sRGB colour profile, whatever format it is written in, so it looks the same
    /// in apps that ignore colour profiles. The picture itself is not changed.
    func data(as format: CaptureFormat, convertToSRGB: Bool = false) -> Data? {
        let space = CGColorSpace(name: CGColorSpace.sRGB)
        guard convertToSRGB, let space else { return encoded(as: format, flatSpace: CGColorSpaceCreateDeviceRGB()) }
        return CaptureRenderer.srgb(self).encoded(as: format, flatSpace: space)
    }

    private func encoded(as format: CaptureFormat, flatSpace: CGColorSpace) -> Data? {
        switch format {
        case .png: return pngData
        case .tiff: return NSBitmapImageRep(cgImage: self).representation(using: .tiff, properties: [:])
        case .jpeg:
            guard let flat = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: flatSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
            flat.setFillColor(CGColor(gray: 1, alpha: 1)); flat.fill(CGRect(x: 0, y: 0, width: width, height: height))
            flat.draw(self, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let opaque = flat.makeImage() else { return nil }
            return NSBitmapImageRep(cgImage: opaque).representation(using: .jpeg, properties: [.compressionFactor: 0.9])
        case .heic:
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, "public.heic" as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(destination, self, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
            return CGImageDestinationFinalize(destination) ? data as Data : nil
        case .pdf:
            let data = NSMutableData()
            var box = CGRect(x: 0, y: 0, width: width, height: height)
            guard let consumer = CGDataConsumer(data: data), let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
            context.beginPDFPage(nil)
            context.draw(self, in: box)
            context.endPDFPage()
            context.closePDF()
            return data as Data
        }
    }

    /// The picture as PNG data.
    var pngData: Data? {
        let representation = NSBitmapImageRep(cgImage: self)
        return representation.representation(using: .png, properties: [:])
    }
}

extension CodableColor {
    var cgColor: CGColor { CGColor(srgbRed: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue), alpha: CGFloat(alpha)) }
}
