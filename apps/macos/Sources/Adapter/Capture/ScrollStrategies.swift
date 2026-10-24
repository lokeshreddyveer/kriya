import AppKit
import ApplicationServices
import PDFKit

// MARK: - What is under the scrolling area

/// The window and app under a point, for choosing how to scroll and whether the page can be taken whole.
enum ScrollTarget {
    struct Hit {
        var pid: pid_t
        var bundleID: String?
        var windowFrame: CGRect
    }

    /// The front-most ordinary window of another app at `point` (top-left screen coordinates).
    static func at(_ point: CGPoint) -> Hit? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for window in list {
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t, pid != getpid(),
                  let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"], let w = bounds["Width"], let h = bounds["Height"] else { continue }
            let frame = CGRect(x: x, y: y, width: w, height: h)
            guard frame.contains(point), w > 40, h > 40 else { continue }
            return Hit(pid: pid, bundleID: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier, windowFrame: frame)
        }
        return nil
    }
}

// MARK: - Browsers

/// A web browser that can be asked, through its scripting, to scroll the page and say where it is. That is exact; the wheel is not.
/// Safari needs "Allow JavaScript from Apple Events" (Develop menu) and the Chromium browsers need the same under View › Developer;
/// when it is off the script fails and Kriya falls back to the wheel.
enum BrowserKind: Equatable {
    case safari
    case chromium(name: String)

    static let chromiumNames: [String: String] = [
        "com.google.Chrome": "Google Chrome", "com.microsoft.edgemac": "Microsoft Edge", "com.brave.Browser": "Brave Browser",
        "company.thebrowser.Browser": "Arc", "com.vivaldi.Vivaldi": "Vivaldi", "org.chromium.Chromium": "Chromium",
    ]

    static func detect(bundleID: String?) -> BrowserKind? {
        guard let bundleID else { return nil }
        if bundleID == "com.apple.Safari" || bundleID == "com.apple.SafariTechnologyPreview" { return .safari }
        return chromiumNames[bundleID].map { .chromium(name: $0) }
    }

    /// The JavaScript that scrolls by (dx, dy) and answers where the page is: scroll x and y, the window's width and height, and the
    /// page's width and height. Single quotes only, so it sits inside an AppleScript string.
    static func javascript(dx: Int, dy: Int) -> String {
        "(function(){var d=document.documentElement,b=document.body;window.scrollBy(\(dx),\(dy));return [window.scrollX,window.scrollY,window.innerWidth,window.innerHeight,Math.max(d.scrollWidth,b?b.scrollWidth:0),Math.max(d.scrollHeight,b?b.scrollHeight:0)].join(',')})()"
    }

    func appleScript(javascript js: String) -> String {
        switch self {
        case .safari: return "tell application \"Safari\" to do JavaScript \"\(js)\" in current tab of front window"
        case .chromium(let name): return "tell application \"\(name)\" to execute active tab of front window javascript \"\(js)\""
        }
    }

    /// Reads the answer the JavaScript gave, for the way the page is being scrolled.
    static func parse(_ answer: String, axis: CaptureScrollAxis) -> ScrollPosition? {
        let numbers = answer.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard numbers.count == 6 else { return nil }
        return axis == .horizontal ? ScrollPosition(offset: numbers[0], total: numbers[4], viewport: numbers[2])
                                   : ScrollPosition(offset: numbers[1], total: numbers[5], viewport: numbers[3])
    }
}

final class BrowserScroller {
    let kind: BrowserKind

    init(kind: BrowserKind) { self.kind = kind }

    /// Runs the script away from the calling thread (starting a process blocks).
    private func answer(dx: Int, dy: Int) async -> String? {
        let script = kind.appleScript(javascript: BrowserKind.javascript(dx: dx, dy: dy))
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: try? ToolRunner.run("/usr/bin/osascript", ["-e", script], timeout: 8))
            }
        }
    }

    /// Whether the browser answers, which needs the script switch to be on and Automation to be allowed.
    func works() async -> Bool {
        guard let text = await answer(dx: 0, dy: 0) else { return false }
        return BrowserKind.parse(text, axis: .vertical) != nil
    }

    func position(axis: CaptureScrollAxis) async -> ScrollPosition? {
        guard let text = await answer(dx: 0, dy: 0) else { return nil }
        return BrowserKind.parse(text, axis: axis)
    }

    /// Scrolls the page and says whether it moved.
    func scroll(by points: Int, axis: CaptureScrollAxis) async -> Bool {
        let before = await position(axis: axis)
        guard let text = await answer(dx: axis == .horizontal ? points : 0, dy: axis == .horizontal ? 0 : points),
              let after = BrowserKind.parse(text, axis: axis) else { return false }
        return before.map { abs($0.offset - after.offset) > 0.5 } ?? true
    }
}

// MARK: - Scroll bars (Accessibility)

/// The scroll area under a point, found through Accessibility. Walks outwards from what is under the pointer to the first scroll area
/// that can really scroll, which is how a small scrolling box inside a larger scrolling page is told apart from the page.
final class AccessibilityScroller {
    private let bar: (vertical: AXUIElement?, horizontal: AXUIElement?)
    private let area: AXUIElement
    private let content: CGSize
    let areaFrame: CGRect

    init?(at point: CGPoint) {
        guard AXIsProcessTrusted() else { return nil }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.2)
        var found: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &found) == .success, var element = found else { return nil }
        var chosen: (AXUIElement, CGRect, CGSize, AXUIElement?, AXUIElement?)?
        for _ in 0..<24 {
            if Self.string(element, kAXRoleAttribute) == "AXScrollArea", let frame = Self.frame(of: element) {
                let vertical = Self.element(element, kAXVerticalScrollBarAttribute)
                let horizontal = Self.element(element, kAXHorizontalScrollBarAttribute)
                let size = Self.contentSize(of: element) ?? frame.size
                // It can scroll if what it holds is bigger than what shows.
                if (vertical != nil && size.height > frame.height + 4) || (horizontal != nil && size.width > frame.width + 4) {
                    chosen = (element, frame, size, vertical, horizontal)
                    break
                }
            }
            guard let parent = Self.element(element, kAXParentAttribute) else { break }
            element = parent
        }
        guard let chosen else { return nil }
        area = chosen.0; areaFrame = chosen.1; content = chosen.2; bar = (chosen.3, chosen.4)
    }

    private static func string(_ e: AXUIElement, _ attribute: String) -> String? {
        var out: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, attribute as CFString, &out) == .success ? out as? String : nil
    }

    private static func element(_ e: AXUIElement, _ attribute: String) -> AXUIElement? {
        var out: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attribute as CFString, &out) == .success, let raw = out, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(raw, to: AXUIElement.self)
    }

    private static func frame(of e: AXUIElement) -> CGRect? {
        var pos: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, kAXPositionAttribute as CFString, &pos) == .success,
              AXUIElementCopyAttributeValue(e, kAXSizeAttribute as CFString, &size) == .success,
              let p = pos, let s = size else { return nil }
        var point = CGPoint.zero, dims = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(p, to: AXValue.self), .cgPoint, &point), AXValueGetValue(unsafeBitCast(s, to: AXValue.self), .cgSize, &dims) else { return nil }
        return CGRect(origin: point, size: dims)
    }

    /// The size of what the scroll area holds: its biggest child.
    private static func contentSize(of area: AXUIElement) -> CGSize? {
        var out: CFTypeRef?
        guard AXUIElementCopyAttributeValue(area, kAXChildrenAttribute as CFString, &out) == .success, let children = out as? [AXUIElement] else { return nil }
        let sizes = children.compactMap { frame(of: $0)?.size }
        return sizes.max { $0.height * $0.width < $1.height * $1.width }
    }

    private func value(_ element: AXUIElement?) -> Double? {
        guard let element else { return nil }
        var out: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &out) == .success else { return nil }
        return (out as? NSNumber)?.doubleValue
    }

    func position(axis: CaptureScrollAxis) -> ScrollPosition? {
        let horizontal = axis == .horizontal
        guard let v = value(horizontal ? bar.horizontal : bar.vertical) else { return nil }
        let total = horizontal ? content.width : content.height
        let viewport = horizontal ? areaFrame.width : areaFrame.height
        guard total > viewport else { return nil }
        return ScrollPosition(offset: v * (total - viewport), total: total, viewport: viewport)
    }

    /// Moves the scroll bar by this many points. False if it could not.
    func scroll(by points: Int, axis: CaptureScrollAxis) -> Bool {
        let horizontal = axis == .horizontal
        guard let element = horizontal ? bar.horizontal : bar.vertical, let before = value(element) else { return false }
        let total = horizontal ? content.width : content.height
        let viewport = horizontal ? areaFrame.width : areaFrame.height
        let range = Double(total - viewport)
        guard range > 1 else { return false }
        let next = min(max(before + Double(points) / range, 0), 1)
        guard AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, NSNumber(value: next)) == .success else { return false }
        return abs((value(element) ?? before) - before) > 0.0001
    }
}

// MARK: - Taking a PDF whole

/// A PDF open in a viewer is drawn from its file, page after page: nothing is scrolled and nothing can be missed.
enum PDFRender {
    /// The PDF file the window under the area is showing, when the area covers most of that window.
    static func file(for hit: ScrollTarget.Hit, area: CGRect) -> URL? {
        guard AXIsProcessTrusted() else { return nil }
        let window = hit.windowFrame
        guard window.width > 0, window.height > 0, area.intersection(window).width * area.intersection(window).height >= 0.4 * window.width * window.height else { return nil }
        let app = AXUIElementCreateApplication(hit.pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        var out: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &out) == .success, let windows = out as? [AXUIElement] else { return nil }
        for candidate in windows {
            var document: CFTypeRef?
            guard AXUIElementCopyAttributeValue(candidate, "AXDocument" as CFString, &document) == .success, let text = document as? String,
                  let url = URL(string: text), url.isFileURL, url.pathExtension.lowercased() == "pdf",
                  FileManager.default.isReadableFile(atPath: url.path) else { continue }
            return url
        }
        return nil
    }

    struct Layout: Equatable {
        /// Each page's size in pixels and where it starts.
        var pages: [(size: CGSize, top: Int)]
        var width: Int
        var height: Int
        var truncated: Bool

        static func == (a: Layout, b: Layout) -> Bool {
            a.width == b.width && a.height == b.height && a.truncated == b.truncated && a.pages.count == b.pages.count
                && zip(a.pages, b.pages).allSatisfy { $0.size == $1.size && $0.top == $1.top }
        }
    }

    /// Where each page goes: one under another, centred, with a gap between, stopping before the picture gets longer than Kriya joins.
    static func layout(pageSizes: [CGSize], gap: Int = 16, maxHeight: Int = ScrollStitch.maxLength, maxWidth: Int = 4000) -> Layout {
        var placed: [(size: CGSize, top: Int)] = []
        var top = 0
        var truncated = false
        for size in pageSizes {
            let h = Int(size.height.rounded(.up))
            if top + h > maxHeight { truncated = true; break }
            placed.append((size, top))
            top += h + gap
        }
        let width = min(placed.map { Int($0.size.width.rounded(.up)) }.max() ?? 0, maxWidth)
        return Layout(pages: placed, width: width, height: max(top - gap, 0), truncated: truncated)
    }

    /// The whole document as one tall picture, at this many pixels per point. Nil if it cannot be read.
    static func render(url: URL, scale: CGFloat = 1.5) -> (image: CGImage, pages: Int, truncated: Bool)? {
        guard let document = PDFDocument(url: url), !document.isLocked, document.pageCount > 0 else { return nil }
        let pages = (0..<document.pageCount).compactMap { document.page(at: $0) }
        let sizes: [CGSize] = pages.map { page in
            let box = page.bounds(for: .cropBox)
            let turned = page.rotation % 180 != 0
            return CGSize(width: (turned ? box.height : box.width) * scale, height: (turned ? box.width : box.height) * scale)
        }
        let plan = layout(pageSizes: sizes)
        guard plan.width > 0, plan.height > 0,
              let context = CGContext(data: nil, width: plan.width, height: plan.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 0.93, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: plan.width, height: plan.height))
        for (index, placement) in plan.pages.enumerated() {
            autoreleasepool {
                let image = pages[index].thumbnail(of: NSSize(width: placement.size.width, height: placement.size.height), for: .cropBox)
                guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
                let x = (plan.width - Int(placement.size.width)) / 2
                // The context's origin is at the bottom; the layout counts from the top.
                context.draw(cg, in: CGRect(x: CGFloat(x), y: CGFloat(plan.height - placement.top) - placement.size.height, width: placement.size.width, height: placement.size.height))
            }
        }
        guard let result = context.makeImage() else { return nil }
        return (result, plan.pages.count, plan.truncated)
    }
}
