import CoreGraphics

/// How big the launcher window is for what it is showing: a bar alone, then growing as results appear, up to a limit.
enum PaletteLayout {
    static let width: CGFloat = 700
    static let searchHeight: CGFloat = 68
    static let rowHeight: CGFloat = 50
    static let headerHeight: CGFloat = 28
    static let footerHeight: CGFloat = 36
    static let listPadding: CGFloat = 8
    static let maxRows = 8
    /// The bar with only a line of help under it.
    static let emptyHeight: CGFloat = 132

    /// The height of the window for rows that sit under these headings (one per row, in order).
    static func height(sections: [String], typed: Bool) -> CGFloat {
        guard !sections.isEmpty else { return typed ? searchHeight + 70 : emptyHeight }
        var total: CGFloat = 0
        var previous: String?
        for heading in sections.prefix(maxRows) {
            if heading != previous { total += headerHeight }
            total += rowHeight
            previous = heading
        }
        return searchHeight + 1 + total + listPadding * 2 + footerHeight
    }

    /// Where the window goes: its top a fixed way down from the top of the usable area, centered across it, and always
    /// completely inside it. The window grows downward from there.
    static func frame(height: CGFloat, in visible: CGRect) -> CGRect {
        let w = min(width, visible.width - 24)
        let top = visible.maxY - visible.height * 0.17
        var y = top - height
        y = max(y, visible.minY + 12)
        return CGRect(x: visible.midX - w / 2, y: y, width: w, height: min(height, visible.height - 24))
    }

    /// The same window after its height changed: the top edge stays put.
    static func resized(_ current: CGRect, toHeight height: CGFloat, in visible: CGRect) -> CGRect {
        var y = current.maxY - height
        y = max(y, visible.minY + 12)
        return CGRect(x: current.minX, y: y, width: current.width, height: min(height, visible.height - 24))
    }
}
