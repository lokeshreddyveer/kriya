import Foundation

/// Joins pictures taken while a page scrolled into one tall picture. Each picture is described by one hash per row of
/// pixels; the new picture overlaps the one before where its first rows equal the last rows of the picture so far.
enum ScrollStitch {
    /// Fewer matching rows than this could be a coincidence (a plain white band), so it is not trusted.
    static let minimumOverlap = 24

    /// How many rows at the top of `next` repeat the end of `rows`, or 0 if they do not clearly overlap. The largest match wins.
    static func overlap(rows: [UInt64], next: [UInt64], minimum: Int = minimumOverlap) -> Int {
        let most = min(rows.count, next.count)
        guard most >= minimum else { return 0 }
        var k = most
        while k >= minimum {
            if rows.suffix(k).elementsEqual(next.prefix(k)) { return k }
            k -= 1
        }
        return 0
    }

    /// The rows of `next` that are new, once `overlap` rows are dropped. Nothing new means the page did not move.
    static func newRows(next: [UInt64], overlap: Int) -> Range<Int> { overlap..<next.count }

    /// One number for a row of pixel bytes. The right edge is left out so a fading scroll bar does not spoil a match.
    static func hash(row bytes: UnsafeBufferPointer<UInt8>, bytesPerPixel: Int) -> UInt64 {
        let usable = (bytes.count / bytesPerPixel) * 85 / 100 * bytesPerPixel
        var h: UInt64 = 0xcbf29ce484222325
        for i in 0..<usable { h = (h ^ UInt64(bytes[i])) &* 0x100000001b3 }
        return h
    }
}
