import Foundation

/// Joins pictures taken while a page scrolled into one long picture. Each picture is described by one hash per row of pixels (or per
/// column, for a page that scrolls sideways); a new picture overlaps the one before where its first rows equal the last rows of what
/// is joined so far. Bars that do not scroll (a toolbar at the top, a footer at the bottom) are found by comparing the first two
/// pictures and are kept once, not repeated down the page.
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

    // MARK: Bars that stay put

    /// How many rows at the top, and at the bottom, are the same in both pictures: a toolbar or a footer that does not scroll. A bar
    /// is only trusted if it is under two fifths of the picture and the pictures differ between the bars (otherwise nothing scrolled).
    static func fixedBars(_ first: [UInt64], _ second: [UInt64]) -> (header: Int, footer: Int) {
        let n = min(first.count, second.count)
        guard n > 2 * minimumOverlap, first != second else { return (0, 0) }
        var header = 0
        while header < n, first[header] == second[header] { header += 1 }
        var footer = 0
        while footer < n - header, first[first.count - 1 - footer] == second[second.count - 1 - footer] { footer += 1 }
        let limit = n * 2 / 5
        return (header <= limit ? header : 0, footer <= limit ? footer : 0)
    }

    // MARK: The plan

    /// Which rows of which picture make up the finished one, in order, and how it went.
    struct Plan: Equatable {
        struct Strip: Equatable { var frame: Int; var rows: Range<Int> }
        var strips: [Strip]
        /// Rows at the top and bottom that did not scroll.
        var header: Int
        var footer: Int
        /// Pictures that did not join: nothing in them matched what came before (the page jumped, or was still loading).
        var gaps: [Int]
        /// Pictures where the page had not moved.
        var repeats: [Int]

        var length: Int { strips.reduce(0) { $0 + $1.rows.count } }
        var isClean: Bool { gaps.isEmpty }
    }

    /// Works out how to join the pictures. `frames` holds each picture's hashes (rows, or columns for a sideways scroll).
    static func plan(frames: [[UInt64]]) -> Plan {
        guard let first = frames.first, !first.isEmpty else { return Plan(strips: [], header: 0, footer: 0, gaps: [], repeats: []) }
        guard frames.count > 1 else { return Plan(strips: [.init(frame: 0, rows: 0..<first.count)], header: 0, footer: 0, gaps: [], repeats: []) }
        let (header, footer) = fixedBars(first, frames[1])
        var strips: [Plan.Strip] = [.init(frame: 0, rows: 0..<(first.count - footer))]
        var joined = Array(first[0..<(first.count - footer)])
        var lastBody = Array(first[min(header, first.count)..<(first.count - footer)])
        var gaps: [Int] = [], repeats: [Int] = []
        var last = 0
        for index in 1..<frames.count {
            let next = frames[index]
            guard next.count > header + footer else { gaps.append(index); continue }
            let body = Array(next[header..<(next.count - footer)])
            if body == lastBody { repeats.append(index); continue }
            let k = overlap(rows: joined, next: body)
            if k == 0 { gaps.append(index); continue }
            if k == body.count { repeats.append(index); continue }
            strips.append(.init(frame: index, rows: (header + k)..<(next.count - footer)))
            joined += body[k...]
            lastBody = body
            last = index
        }
        if footer > 0 {
            let rows = frames[last].count
            strips.append(.init(frame: last, rows: (rows - footer)..<rows))
        }
        return Plan(strips: strips, header: header, footer: footer, gaps: gaps, repeats: repeats)
    }

    // MARK: Long captures

    /// A capture this long (in pixels) is worth a warning, and this long is stopped.
    static let warnLength = 30_000
    static let maxLength = 80_000

    static func shouldWarn(length: Int, warned: Bool) -> Bool { !warned && length >= warnLength }
    static func mustStop(length: Int) -> Bool { length >= maxLength }
}
