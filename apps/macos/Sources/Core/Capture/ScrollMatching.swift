import Foundation

/// A small grayscale description of every line of a picture: a row for a page that scrolls down, a column for one that scrolls across.
/// Lines are compared with a tolerance, not for equality, so a blinking cursor, a fading scroll bar, anti-aliasing or a bit of animation
/// does not stop two pictures from being joined.
struct ScrollSignature: Equatable {
    /// How many brightness samples describe one line.
    static let samples = 32

    let width: Int
    private(set) var data: [UInt8]
    /// Whether each line says something: it has detail across it, or it differs from the line before. A plain white band says nothing,
    /// and matching one proves nothing.
    private(set) var info: [Bool]

    init(width: Int = ScrollSignature.samples, data: [UInt8] = []) {
        self.width = max(width, 1)
        self.data = data
        info = []
        info = Self.informative(data, width: self.width)
    }

    var count: Int { data.count / width }

    /// A few lines out of this one, as a signature of their own.
    func slice(_ range: Range<Int>) -> ScrollSignature {
        let r = range.clamped(to: 0..<count)
        return ScrollSignature(width: width, data: Array(data[(r.lowerBound * width)..<(r.upperBound * width)]))
    }

    func line(_ i: Int) -> ArraySlice<UInt8> { data[(i * width)..<((i + 1) * width)] }

    private static func informative(_ data: [UInt8], width: Int) -> [Bool] {
        let n = data.count / width
        guard n > 0 else { return [] }
        var result = [Bool](repeating: false, count: n)
        data.withUnsafeBufferPointer { p in
            var previousMean = -1
            for i in 0..<n {
                var low = 255, high = 0, sum = 0
                for s in 0..<width {
                    let v = Int(p[i * width + s])
                    low = min(low, v); high = max(high, v); sum += v
                }
                let mean = sum / width
                result[i] = (high - low) >= ScrollMatch.detailSpread || (previousMean >= 0 && abs(mean - previousMean) >= ScrollMatch.stepSpread)
                previousMean = mean
            }
        }
        return result
    }
}

enum ScrollMatch {
    /// The most two lines may differ, on average per sample, and still count as the same line.
    static let lineTolerance = 5
    /// A line with at least this much difference across it, or this much from the line before, has something to match.
    static let detailSpread = 20
    static let stepSpread = 8
    /// Fewer matching lines than this could be chance, so it is not trusted.
    static let minimumOverlap = 24
    /// At least this share of the lines in an overlap must match. Not all of them: part of the overlap may hold something that changes
    /// (a spinner, a clock, a video thumbnail), and the rest still says where the pictures meet.
    static let requiredShare = 0.65
    /// Below this share the overlap is a close call, and needs more lines of detail agreeing before it is believed.
    static let comfortableShare = 0.9

    @inline(__always)
    private static func linesMatch(_ a: UnsafePointer<UInt8>, _ b: UnsafePointer<UInt8>, _ n: Int) -> Bool {
        var total = 0
        for s in 0..<n { total += abs(Int(a[s]) - Int(b[s])) }
        return total <= lineTolerance * n
    }

    static func lineMatches(_ a: ScrollSignature, _ i: Int, _ b: ScrollSignature, _ j: Int) -> Bool {
        guard a.width == b.width, i < a.count, j < b.count else { return false }
        return a.data.withUnsafeBufferPointer { pa in b.data.withUnsafeBufferPointer { pb in
            linesMatch(pa.baseAddress! + i * a.width, pb.baseAddress! + j * b.width, a.width)
        } }
    }

    /// Whether two pictures show the same thing: nearly every line matches. A page that did not move gives the same picture again.
    static func same(_ a: ScrollSignature, _ b: ScrollSignature) -> Bool {
        guard a.count == b.count, a.count > 0, a.width == b.width else { return false }
        var mismatches = 0
        let allowed = max(a.count / 50, 1)       // 2%: a cursor, a spinner, a clock
        return a.data.withUnsafeBufferPointer { pa in b.data.withUnsafeBufferPointer { pb in
            for i in 0..<a.count where !linesMatch(pa.baseAddress! + i * a.width, pb.baseAddress! + i * b.width, a.width) {
                mismatches += 1
                if mismatches > allowed { return false }
            }
            return true
        } }
    }

    // MARK: Finding how two pictures overlap

    struct Overlap: Equatable {
        /// How many lines at the start of the new picture repeat the end of the one before.
        var lines: Int
        /// 0 to 1: how well the lines agree, and how much there was to agree about. Low means a guess.
        var confidence: Double
        /// More than one overlap fit about equally well (a table of identical rows, say) and nothing told them apart.
        var ambiguous: Bool
    }

    private struct Candidate { var k: Int; var score: Double }

    /// How well the last `k` lines of `previous` agree with the first `k` of `next`, or nil if they do not agree enough.
    private static func score(k: Int, previous: ScrollSignature, next: ScrollSignature, step: Int) -> Candidate? {
        let pc = previous.count
        var sampled = 0, matched = 0, informative = 0, informativeMatched = 0
        let ok: Bool = previous.data.withUnsafeBufferPointer { pp in next.data.withUnsafeBufferPointer { pn in
            let w = previous.width
            var i = 0
            while i < k {
                let p = pc - k + i
                let match = linesMatch(pp.baseAddress! + p * w, pn.baseAddress! + i * w, w)
                sampled += 1
                if match { matched += 1 }
                if previous.info[p] || next.info[i] {
                    informative += 1
                    if match { informativeMatched += 1 }
                }
                // Clearly not this overlap: stop looking.
                if sampled >= 16, matched * 2 < sampled { return false }
                i += step
            }
            return true
        } }
        guard ok, sampled > 0 else { return nil }
        let share = Double(matched) / Double(sampled)
        let detailShare = informative > 0 ? Double(informativeMatched) / Double(informative) : 0
        var needed = k < 2 * minimumOverlap ? 6 : 3
        if share < comfortableShare || detailShare < comfortableShare { needed = max(needed, 8) }
        guard share >= requiredShare, detailShare >= requiredShare, informativeMatched >= needed else { return nil }
        return Candidate(k: k, score: share * 0.4 + detailShare * 0.6)
    }

    /// How the start of `next` overlaps the end of `previous`. `expected` is how many lines the overlap should be if the page moved by
    /// the amount asked, used to choose between overlaps that fit equally well. Nil if nothing overlaps well enough.
    static func overlap(previous: ScrollSignature, next: ScrollSignature, minimum: Int = minimumOverlap, expected: Int? = nil) -> Overlap? {
        guard previous.width == next.width else { return nil }
        let most = min(previous.count, next.count)
        guard most >= minimum else { return nil }
        var candidates: [Candidate] = []
        var k = most
        while k >= minimum {
            if let c = score(k: k, previous: previous, next: next, step: max(1, k / 48)) { candidates.append(c) }
            k -= 1
        }
        guard let top = candidates.map(\.score).max() else { return nil }
        let near = candidates.filter { $0.score >= top - 0.015 }
        var chosen: Candidate
        if let expected {
            chosen = near.min { abs($0.k - expected) < abs($1.k - expected) }!
        } else {
            chosen = near.max { $0.k < $1.k }!
        }
        // Looked at every few lines to be quick; now every line around the answer, to land on the exact one.
        let sparse = max(1, chosen.k / 48)
        if sparse > 1 {
            var refined = chosen
            for k in max(minimum, chosen.k - sparse)...min(most, chosen.k + sparse) {
                if let c = score(k: k, previous: previous, next: next, step: 1), c.score > refined.score || (c.score == refined.score && k == chosen.k) { refined = c }
            }
            chosen = refined
        }
        let rivals = near.filter { abs($0.k - chosen.k) > max(8, chosen.k / 50) }
        let decidedByExpectation = expected.map { e in abs(chosen.k - e) <= max(8, chosen.k / 50) && rivals.allSatisfy { abs($0.k - e) > abs(chosen.k - e) } } ?? false
        let ambiguous = !rivals.isEmpty && !decidedByExpectation
        return Overlap(lines: chosen.k, confidence: chosen.score * (ambiguous ? 0.6 : 1), ambiguous: ambiguous)
    }

    // MARK: Bars that stay put

    /// How many lines at the top, and at the bottom, are the same in both pictures: a toolbar or a footer that does not scroll. Only
    /// trusted when under two fifths of the picture, when the pictures differ between the bars, and when the bar has something in it
    /// (blank space at the top of two pages is not a toolbar).
    static func fixedBars(_ first: ScrollSignature, _ second: ScrollSignature) -> (header: Int, footer: Int) {
        let n = min(first.count, second.count)
        guard first.width == second.width, n > 2 * minimumOverlap, !same(first, second) else { return (0, 0) }
        var header = 0
        while header < n, lineMatches(first, header, second, header) { header += 1 }
        var footer = 0
        while footer < n - header, lineMatches(first, first.count - 1 - footer, second, second.count - 1 - footer) { footer += 1 }
        let limit = n * 2 / 5
        func worthy(_ range: Range<Int>) -> Bool { range.isEmpty ? false : range.filter { first.info[$0] }.count >= max(3, range.count / 5) }
        let headerRange = 0..<header
        let footerRange = (first.count - footer)..<first.count
        return (header <= limit && worthy(headerRange) ? header : 0, footer <= limit && worthy(footerRange) ? footer : 0)
    }
}

// MARK: - The plan

extension ScrollStitch {
    /// Works out how to join pictures described by tolerant signatures. A picture that does not join the one before is never dropped:
    /// it starts a new section, which the finished picture shows below a visible line, and the pictures after it join to it.
    /// `expected` gives, for each picture, how many lines it should overlap the one before if the page moved by the step asked.
    static func plan(signatures frames: [ScrollSignature], expected: [Int?] = []) -> Plan {
        guard let first = frames.first, first.count > 0 else { return Plan(strips: [], header: 0, footer: 0, gaps: [], repeats: []) }
        guard frames.count > 1 else { return Plan(strips: [.init(frame: 0, rows: 0..<first.count)], header: 0, footer: 0, gaps: [], repeats: []) }
        let (header, footer) = ScrollMatch.fixedBars(first, frames[1])
        var strips: [Plan.Strip] = [.init(frame: 0, rows: 0..<(first.count - footer))]
        var lastBody = first.slice(header..<(first.count - footer))
        var gaps: [Int] = [], repeats: [Int] = [], breaks: [Int] = [], joins: [Plan.Join] = []
        var last = 0
        for index in 1..<frames.count {
            let next = frames[index]
            guard next.count > header + footer else { gaps.append(index); continue }
            let body = next.slice(header..<(next.count - footer))
            if ScrollMatch.same(lastBody, body) { repeats.append(index); continue }
            let hint = index < expected.count ? expected[index] : nil
            guard let overlap = ScrollMatch.overlap(previous: lastBody, next: body, expected: hint) else {
                // Nothing in common with what came before: a new section, kept, with a line between.
                gaps.append(index)
                breaks.append(strips.count)
                strips.append(.init(frame: index, rows: header..<(next.count - footer)))
                lastBody = body
                last = index
                continue
            }
            if overlap.lines >= body.count { repeats.append(index); continue }
            strips.append(.init(frame: index, rows: (header + overlap.lines)..<(next.count - footer)))
            joins.append(.init(frame: index, overlap: overlap.lines, confidence: overlap.confidence, ambiguous: overlap.ambiguous))
            lastBody = body
            last = index
        }
        if footer > 0 {
            let rows = frames[last].count
            strips.append(.init(frame: last, rows: (rows - footer)..<rows))
        }
        return Plan(strips: strips, header: header, footer: footer, gaps: gaps, repeats: repeats, breaks: breaks, joins: joins)
    }
}
