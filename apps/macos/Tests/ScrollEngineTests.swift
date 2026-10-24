import XCTest
@testable import Kriya

/// Scrolling capture, against a page held in memory: Kriya scrolls it (or watches someone else scroll it), takes the pictures, and the
/// joined result is compared line by line with the page itself.
final class ScrollEngineTests: XCTestCase {
    // MARK: A page in memory

    /// A picture where each line (a row, or a column when `vertical` is false) has a colour of its own, made from the line's number.
    static func picture(lines: [Int], vertical: Bool, cross: Int = 120) -> CGImage {
        let w = vertical ? cross : lines.count, h = vertical ? lines.count : cross
        var data = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let n = vertical ? lines[y] : lines[x]
                let i = (y * w + x) * 4
                data[i] = UInt8(truncatingIfNeeded: n &* 37 &+ 11)
                data[i + 1] = UInt8(truncatingIfNeeded: (n >> 4) &* 91 &+ n &* 5)
                data[i + 2] = UInt8(truncatingIfNeeded: n &* 53 &+ (n >> 8) &* 17)
                data[i + 3] = 255
            }
        }
        let provider = CGDataProvider(data: Data(data) as CFData)!
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    final class FakePage: ScrollWorld {
        let content: [Int]
        let viewport: Int
        let header: Int
        let footer: Int
        let vertical: Bool
        var offset = 0
        var multiplier = 1          // the page moves this many times as far as asked
        var inverted = false        // the wheel goes the other way
        var wheelWorks = true
        var pageKeyWorks = true
        var scale: CGFloat { 1 }
        private(set) var scrolls = 0

        init(content: Int, viewport: Int, header: Int = 0, footer: Int = 0, vertical: Bool = true) {
            self.content = Array(0..<content)
            self.viewport = viewport
            self.header = header
            self.footer = footer
            self.vertical = vertical
        }

        var body: Int { viewport - header - footer }
        var maxOffset: Int { content.count - body }

        func lines() -> [Int] {
            let head = (0..<header).map { 100_000 + $0 }
            let foot = (0..<footer).map { 200_000 + $0 }
            return head + Array(content[offset..<(offset + body)]) + foot
        }

        func grab() async throws -> CGImage { ScrollEngineTests.picture(lines: lines(), vertical: vertical) }

        func scroll(by points: Int, axis: CaptureScrollAxis) async {
            scrolls += 1
            guard wheelWorks else { return }
            let delta = (inverted ? -points : points) * multiplier
            offset = min(max(offset + delta, 0), maxOffset)
        }

        func pageForward() async -> Bool {
            guard pageKeyWorks else { return false }
            offset = min(offset + body * 9 / 10, maxOffset)
            return true
        }
    }

    private func expectedLines(_ page: FakePage) -> [Int] {
        (0..<page.header).map { 100_000 + $0 } + page.content + (0..<page.footer).map { 200_000 + $0 }
    }

    private func engine(_ page: FakePage, mode: ScrollMode = .automatic, axis: CaptureScrollAxis = .vertical) -> ScrollEngine {
        let e = ScrollEngine(world: page, axis: axis, mode: mode)
        e.settle = 0
        e.pollInterval = 0.01
        e.stableWait = 0.01
        return e
    }

    private func assert(_ result: ScrollEngine.Result, equals expected: [Int], vertical: Bool = true, file: StaticString = #filePath, line: UInt = #line) throws {
        let image = try XCTUnwrap(ScrollImage.assemble(frames: result.frames, plan: result.plan, axis: result.axis), file: file, line: line)
        let got = vertical ? ScrollingCapture.rowHashes(image) : ScrollImage.columnHashes(image)
        let want = ScrollEngine_hashes(expected, vertical: vertical)
        XCTAssertEqual(got.count, want.count, "the joined picture is as long as the page", file: file, line: line)
        XCTAssertEqual(got, want, "and every line is in its place, none repeated and none missing", file: file, line: line)
    }

    private func ScrollEngine_hashes(_ lines: [Int], vertical: Bool) -> [UInt64] {
        let image = Self.picture(lines: lines, vertical: vertical)
        return vertical ? ScrollingCapture.rowHashes(image) : ScrollImage.columnHashes(image)
    }

    // MARK: Kriya scrolls

    func testAWholePageIsJoinedLineForLine() async throws {
        let page = FakePage(content: 1200, viewport: 300)
        let result = await engine(page).run()
        XCTAssertFalse(result.cancelled)
        XCTAssertTrue(result.plan.isClean)
        XCTAssertGreaterThan(result.frames.count, 4)
        try assert(result, equals: expectedLines(page))
    }

    func testAToolbarAndAFooterThatStayPutAppearOnce() async throws {
        let page = FakePage(content: 1000, viewport: 300, header: 24, footer: 18)
        let result = await engine(page).run()
        XCTAssertEqual(result.plan.header, 24)
        XCTAssertEqual(result.plan.footer, 18)
        try assert(result, equals: expectedLines(page))
    }

    func testAWheelThatGoesTheOtherWayIsTurnedRound() async throws {
        let page = FakePage(content: 900, viewport: 300)
        page.inverted = true
        let result = await engine(page).run()
        try assert(result, equals: expectedLines(page))
    }

    func testAPageThatIgnoresTheWheelIsMovedWithPageDown() async throws {
        let page = FakePage(content: 900, viewport: 300)
        page.wheelWorks = false
        let e = engine(page)
        // With the wheel dead only Page Down moves it, and that is tried once the first scroll does nothing.
        let result = await e.run()
        XCTAssertGreaterThan(result.frames.count, 1, "Page Down was tried")
        XCTAssertLessThanOrEqual(result.frames.count, 3, "but a page that only moves while Page Down is pressed once ends quickly")
    }

    func testAPageThatMovesFurtherThanAskedIsTakenInSmallerSteps() async throws {
        let page = FakePage(content: 1500, viewport: 300)
        page.multiplier = 3          // each requested step goes three times as far, past the overlap
        let result = await engine(page).run()
        try assert(result, equals: expectedLines(page))
    }

    func testAShortPageIsJustOnePicture() async throws {
        let page = FakePage(content: 300, viewport: 300)       // already fits
        page.offset = 0
        let result = await engine(page).run()
        XCTAssertEqual(result.frames.count, 1)
        XCTAssertEqual(result.plan.length, 300)
    }

    func testPageAcrossIsJoinedColumnForColumn() async throws {
        let page = FakePage(content: 1100, viewport: 280, header: 16, footer: 0, vertical: false)
        let result = await engine(page, axis: .horizontal).run()
        XCTAssertEqual(result.axis, .horizontal)
        try assert(result, equals: expectedLines(page), vertical: false)
    }

    func testProgressIsReportedAndALongPageIsWarnedAbout() async throws {
        let page = FakePage(content: 600, viewport: 300)
        let e = engine(page)
        var counts: [Int] = []
        var lengths: [Int] = []
        e.onProgress = { f, l in counts.append(f); lengths.append(l) }
        _ = await e.run()
        XCTAssertEqual(counts.first, 1)
        XCTAssertEqual(counts, counts.sorted(), "the count only goes up")
        XCTAssertEqual(lengths, lengths.sorted())
        XCTAssertEqual(lengths.last, 600)
        XCTAssertTrue(ScrollStitch.shouldWarn(length: 30_000, warned: false))
        XCTAssertFalse(ScrollStitch.shouldWarn(length: 30_000, warned: true))
        XCTAssertFalse(ScrollStitch.shouldWarn(length: 29_999, warned: false))
        XCTAssertTrue(ScrollStitch.mustStop(length: 80_000))
    }

    func testCancelKeepsNothingAndStopKeepsWhatWasTaken() async throws {
        let page = FakePage(content: 5000, viewport: 300)
        let cancelled = engine(page)
        cancelled.cancel()
        let a = await cancelled.run()
        XCTAssertTrue(a.cancelled)

        let page2 = FakePage(content: 5000, viewport: 300)
        let stopping = engine(page2)
        var seen = 0
        stopping.onProgress = { f, _ in seen = f; if f >= 4 { stopping.stop() } }
        let b = await stopping.run()
        XCTAssertFalse(b.cancelled)
        XCTAssertGreaterThanOrEqual(b.frames.count, 4)
        XCTAssertLessThan(b.frames.count, 10, "it stopped soon after being asked (not at the end of a 5000-line page)")
        let image = try XCTUnwrap(ScrollImage.assemble(frames: b.frames, plan: b.plan, axis: b.axis))
        XCTAssertEqual(ScrollingCapture.rowHashes(image), Array(ScrollEngine_hashes(expectedLines(page2), vertical: true).prefix(image.height)), "what was kept is the top of the page, in order")
        _ = seen
    }

    func testPausingHoldsTheScrollingUntilResumed() async throws {
        let page = FakePage(content: 3000, viewport: 300)
        let e = engine(page)
        e.pause()
        let run = Task { await e.run() }
        try await Task.sleep(nanoseconds: 300_000_000)
        let whilePaused = page.scrolls
        XCTAssertEqual(whilePaused, 0, "nothing scrolls while paused")
        e.resume()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertGreaterThan(page.scrolls, 0, "and it carries on afterwards")
        e.stop()
        _ = await run.value
    }

    // MARK: The person scrolls

    func testWatchingKeepsEachPictureThePageSettlesOn() async throws {
        let page = FakePage(content: 1000, viewport: 300, header: 20, footer: 0)
        let e = engine(page, mode: .manual)
        let run = Task { await e.run() }
        // Someone scrolling down in steps, pausing at each.
        for _ in 0..<5 {
            try await Task.sleep(nanoseconds: 150_000_000)
            page.offset = min(page.offset + 150, page.maxOffset)
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        e.stop()
        let result = await run.value
        XCTAssertGreaterThanOrEqual(result.frames.count, 3)
        let image = try XCTUnwrap(ScrollImage.assemble(frames: result.frames, plan: result.plan, axis: result.axis))
        let want = ScrollEngine_hashes(expectedLines(page), vertical: true)
        XCTAssertEqual(ScrollingCapture.rowHashes(image), Array(want.prefix(image.height)), "the joined picture is the top of the page, in order, with the toolbar once")
        XCTAssertGreaterThan(image.height, 600)
    }

    func testWatchingIgnoresAJumpThatCannotBeJoined() async throws {
        let page = FakePage(content: 4000, viewport: 300)
        let e = engine(page, mode: .manual)
        let run = Task { await e.run() }
        try await Task.sleep(nanoseconds: 100_000_000)
        page.offset = 2000                       // a jump of far more than a screen: nothing overlaps
        try await Task.sleep(nanoseconds: 250_000_000)
        page.offset = 150                        // scrolled on from the start by half a screen
        try await Task.sleep(nanoseconds: 250_000_000)
        e.stop()
        let result = await run.value
        let image = try XCTUnwrap(ScrollImage.assemble(frames: result.frames, plan: result.plan, axis: result.axis))
        XCTAssertEqual(ScrollingCapture.rowHashes(image), Array(ScrollEngine_hashes(expectedLines(page), vertical: true).prefix(image.height)), "the jump left no hole and no wrong piece")
        XCTAssertEqual(image.height, 450)
    }

    // MARK: Down and across

    func testDownAndAcrossJoinsColumnsOfAPageWiderThanTheArea() async throws {
        // A page 3 screens down and 2.4 across: each position shows a different part, and the joined picture is the whole page.
        final class Grid: ScrollWorld {
            let rows = 700, cols = 420
            let viewH = 250, viewW = 180
            var x = 0, y = 0
            var scale: CGFloat { 1 }
            private func cell(_ r: Int, _ c: Int) -> Int { r * 1000 + c }
            func grab() async throws -> CGImage {
                var data = [UInt8](repeating: 255, count: viewW * viewH * 4)
                for j in 0..<viewH {
                    for i in 0..<viewW {
                        let n = cell(y + j, x + i)
                        let k = (j * viewW + i) * 4
                        data[k] = UInt8(truncatingIfNeeded: n &* 37); data[k + 1] = UInt8(truncatingIfNeeded: (n >> 3) &* 91 &+ n); data[k + 2] = UInt8(truncatingIfNeeded: n &* 53 &+ (n >> 9)); data[k + 3] = 255
                    }
                }
                return CGImage(width: viewW, height: viewH, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: viewW * 4, space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: CGDataProvider(data: Data(data) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
            }
            func scroll(by points: Int, axis: CaptureScrollAxis) async {
                if axis == .horizontal { x = min(max(x + points, 0), cols - viewW) } else { y = min(max(y + points, 0), rows - viewH) }
            }
            func pageForward() async -> Bool { false }
        }
        let grid = Grid()
        let e = ScrollEngine(world: grid, axis: .both, mode: .automatic)
        e.settle = 0
        let result = await e.run()
        XCTAssertFalse(result.cancelled)
        XCTAssertEqual(result.axis, .horizontal, "the columns are joined side by side")
        let image = try XCTUnwrap(ScrollImage.assemble(frames: result.frames, plan: result.plan, axis: result.axis))
        XCTAssertEqual(image.height, grid.rows, "all the way down")
        XCTAssertEqual(image.width, grid.cols, "and all the way across, with no column repeated")
    }

    // MARK: The plan on its own

    func testThePlanSkipsRepeatsAndNamesGaps() {
        let page = Array(0..<400).map { UInt64($0 + 1) }
        let a = Array(page[0..<100]), b = Array(page[60..<160]), repeatOfB = b, c = Array(page[300..<400]), d = Array(page[130..<230])
        let plan = ScrollStitch.plan(frames: [a, b, repeatOfB, c, d])
        XCTAssertEqual(plan.repeats, [2], "a picture where the page had not moved")
        XCTAssertEqual(plan.gaps, [3], "a picture that overlaps nothing before it")
        XCTAssertEqual(plan.length, 230, "a, b and d join into rows 0 to 230")
        XCTAssertFalse(plan.isClean)
        let lone = ScrollStitch.plan(frames: [a])
        XCTAssertEqual(lone.length, 100)
        XCTAssertEqual(ScrollStitch.plan(frames: []).length, 0)
        let (header, footer) = ScrollStitch.fixedBars([1, 1, 1, 7, 8, 9, 5, 5], [1, 1, 1, 8, 9, 10, 5, 5])
        XCTAssertEqual(header, 0, "too short to trust a bar")
        _ = footer
    }

    func testBarsAreOnlyTrustedWhenModestAndWhenThingsMoved() {
        let top = Array(repeating: UInt64(9), count: 30)
        let a = top + (1...100).map { UInt64($0) } + Array(repeating: UInt64(8), count: 20)
        let b = top + (51...150).map { UInt64($0) } + Array(repeating: UInt64(8), count: 20)
        let bars = ScrollStitch.fixedBars(a, b)
        XCTAssertEqual(bars.header, 30)
        XCTAssertEqual(bars.footer, 20)
        XCTAssertEqual(ScrollStitch.fixedBars(a, a).header, 0, "identical pictures: nothing scrolled, so no bar is claimed")
        let mostlyBlank = Array(repeating: UInt64(1), count: 100)
        let alsoBlank = Array(repeating: UInt64(1), count: 99) + [2]
        XCTAssertEqual(ScrollStitch.fixedBars(mostlyBlank, alsoBlank).header, 0, "a blank page is not a toolbar")
    }
}
