import CoreGraphics

/// The sizes the switcher's cards are drawn at, for a size setting (1 is normal).
struct SwitcherMetrics: Equatable {
    let scale: CGFloat

    init(scale: Double = 1) { self.scale = CGFloat(min(max(scale.isFinite ? scale : 1, 0.7), 1.5)) }

    var cardWidth: CGFloat { (232 * scale).rounded() }
    var cardHeight: CGFloat { (186 * scale).rounded() }
    var spacing: CGFloat { (14 * scale).rounded() }
    var padding: CGFloat { (24 * scale).rounded() }
    var previewWidth: CGFloat { cardWidth - 16 }
    var previewHeight: CGFloat { (previewWidth * 0.62).rounded() }
    var badge: CGFloat { (34 * scale).rounded() }
    var titleSize: CGFloat { 12 * scale }
    /// The line under the cards that names the chosen window in full.
    var hintHeight: CGFloat { 40 }
    /// The bar above the cards that shows what was typed.
    var searchHeight: CGFloat { 46 }
}

/// How the window switcher lays out its cards (the ⌥Tab view that looks like AltTab): a grid that wraps to the width of the
/// screen, and how the arrow keys and Tab move around it.
enum SwitcherLayout {
    /// The cards at normal size, for callers that do not have a size setting.
    static let cardWidth = SwitcherMetrics().cardWidth
    static let cardHeight = SwitcherMetrics().cardHeight
    static let spacing = SwitcherMetrics().spacing
    static let padding = SwitcherMetrics().padding
    static let hintHeight = SwitcherMetrics().hintHeight
    /// More rows than this scroll.
    static let maxVisibleRows = 3

    /// How many cards sit side by side when `maxWidth` is available. Rows are balanced, so seven windows are two rows of
    /// four and not five with a stray two.
    static func columns(count: Int, maxWidth: CGFloat, scale: Double = 1) -> Int {
        guard count > 0 else { return 1 }
        let m = SwitcherMetrics(scale: scale)
        let fit = max(1, Int(((maxWidth - m.padding * 2 + m.spacing) / (m.cardWidth + m.spacing)).rounded(.down)))
        let rows = Int((Double(count) / Double(fit)).rounded(.up))
        return max(1, min(count, Int((Double(count) / Double(rows)).rounded(.up))))
    }

    /// The window's size for this many cards on a screen `maxWidth` wide, with room for the typed text when searching.
    static func size(count: Int, maxWidth: CGFloat, scale: Double = 1, searching: Bool = false, maxHeight: CGFloat = .greatestFiniteMagnitude) -> CGSize {
        let m = SwitcherMetrics(scale: scale)
        let cols = columns(count: count, maxWidth: maxWidth, scale: scale)
        let rows = max(1, Int((Double(max(count, 1)) / Double(cols)).rounded(.up)))
        // Rows that would not fit on the screen scroll instead.
        let extra = m.padding * 2 + m.hintHeight + (searching ? m.searchHeight : 0)
        let room = ((maxHeight - extra + m.spacing) / (m.cardHeight + m.spacing)).rounded(.down)
        // No limit means no bound; a huge or odd number is never turned into an integer as it is.
        let fitting = room.isFinite ? max(1, Int(min(room, 1000))) : (room > 0 ? 1000 : 1)
        let shown = min(rows, maxVisibleRows, fitting)
        return CGSize(
            width: CGFloat(cols) * m.cardWidth + CGFloat(cols - 1) * m.spacing + m.padding * 2,
            height: CGFloat(shown) * m.cardHeight + CGFloat(shown - 1) * m.spacing + extra
        )
    }

    enum Direction { case left, right, up, down }

    /// Where the highlight goes after an arrow key. It stops at the edges, except left and right, which carry on to the
    /// previous or next row as reading does.
    static func move(from index: Int, _ direction: Direction, count: Int, columns: Int) -> Int {
        guard count > 0 else { return 0 }
        let current = min(max(index, 0), count - 1)
        switch direction {
        case .left: return current == 0 ? count - 1 : current - 1
        case .right: return current == count - 1 ? 0 : current + 1
        case .up:
            let target = current - columns
            return target >= 0 ? target : current
        case .down:
            let target = current + columns
            return target < count ? target : current
        }
    }

    /// The next window of the same app, after `index`, wrapping around; nil when the app has no other window.
    static func nextOfSameApp(from index: Int, appIDs: [String]) -> Int? {
        guard appIDs.indices.contains(index), appIDs.count > 1 else { return nil }
        for step in 1..<appIDs.count {
            let candidate = (index + step) % appIDs.count
            if appIDs[candidate] == appIDs[index] { return candidate }
        }
        return nil
    }

    /// Which card a digit key picks: 1 to 9 are the first nine. Nil for anything else or a number past the end.
    static func index(forDigit key: String, count: Int) -> Int? {
        guard key.count == 1, let digit = Int(key), (1...9).contains(digit), digit <= count else { return nil }
        return digit - 1
    }

    /// Where the highlight starts: the window before this one normally, the last window when going backwards, and the first
    /// when there is only one.
    static func startIndex(count: Int, backwards: Bool) -> Int {
        guard count > 1 else { return 0 }
        return backwards ? count - 1 : 1
    }
}
