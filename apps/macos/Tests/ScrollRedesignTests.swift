import XCTest
@testable import Kriya

/// The scrolling-capture redesign: pictures joined with a tolerance for small changes, a confidence for every join, pictures that
/// cannot be joined kept as sections instead of dropped, a manual mode that can capture, undo and keep, several ways of scrolling tried
/// in turn, and whole PDFs and browser pages taken from the document itself.
final class ScrollRedesignTests: XCTestCase {
    // MARK: A page that is not perfectly still

    /// A page of numbered lines whose pictures carry noise, a blinking block and, if asked, a spinner that never stops.
    final class RestlessPage: ScrollWorld {
        let content: Int, viewport: Int
        var offset = 0
        var noise = 3, blink = true, spinnerRows = 0
        var strategies: [ScrollStrategy] = [.wheel]
        var grabs = 0
        var scale: CGFloat { 1 }
        /// Lines that appear only after the end has been reached twice (a page that loads more).
        var extra = 0
        var endScrolls = 0
        var total: Int { content + extra }
        var maxOffset: Int { total - viewport }

        init(content: Int, viewport: Int) { self.content = content; self.viewport = viewport }

        func grab() async throws -> CGImage {
            grabs += 1
            let cross = 120
            var data = [UInt8](repeating: 255, count: cross * viewport * 4)
            var seed = UInt32(truncatingIfNeeded: grabs &* 7919)
            for y in 0..<viewport {
                let line = offset + y
                for x in 0..<cross {
                    var hash = UInt32(truncatingIfNeeded: line) &* 2_654_435_761 &+ UInt32(x / 6) &* 40_503
                    hash ^= hash >> 15; hash = hash &* 2_246_822_519; hash ^= hash >> 13
                    seed = seed &* 1_664_525 &+ 1_013_904_223
                    let jitter = noise == 0 ? 0 : Int(seed >> 28) % (2 * noise + 1) - noise
                    let i = (y * cross + x) * 4
                    for c in 0..<3 { data[i + c] = UInt8(max(0, min(255, Int((hash >> UInt32(8 * c)) & 0xFF) + jitter))) }
                    data[i + 3] = 255
                }
                // A caret that blinks every other picture, in the same place on the screen.
                if blink, grabs % 2 == 0, y >= 40, y < 46 { for x in 10..<14 { let i = (y * cross + x) * 4; data[i] = 0; data[i + 1] = 0; data[i + 2] = 0 } }
                // A spinner in a corner whose pixels are different every time.
                if y < spinnerRows { for x in 90..<120 { let i = (y * cross + x) * 4; data[i] = UInt8(truncatingIfNeeded: seed >> 8); data[i + 1] = UInt8(truncatingIfNeeded: seed >> 16); data[i + 2] = UInt8(truncatingIfNeeded: seed >> 24) } }
            }
            return CGImage(width: cross, height: viewport, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: cross * 4, space: CGColorSpaceCreateDeviceRGB(),
                           bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: CGDataProvider(data: Data(data) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        }

        func scroll(by points: Int, axis: CaptureScrollAxis) async {
            if offset >= maxOffset, points > 0 {
                endScrolls += 1
                if endScrolls == 2, extra == 0, loadsMore { extra = 300 }
            }
            offset = min(max(offset + points, 0), maxOffset)
        }
        var loadsMore = false
        func pageForward() async -> Bool { false }
    }

    private func engine(_ world: ScrollWorld, mode: ScrollMode = .automatic) -> ScrollEngine {
        let e = ScrollEngine(world: world, axis: .vertical, mode: mode)
        e.settle = 0; e.pollInterval = 0.01; e.stableWait = 0.01
        return e
    }

    /// The finished picture compared line by line, with a tolerance, with what the page is.
    private func assertWholePage(_ result: ScrollEngine.Result, lines: Int, file: StaticString = #filePath, line: UInt = #line) throws {
        let image = try XCTUnwrap(ScrollImage.assemble(frames: result.frames, plan: result.plan, axis: result.axis), file: file, line: line)
        XCTAssertEqual(image.height, lines, "every line once: none repeated, none missing", file: file, line: line)
    }

    func testSmallChangesBetweenPicturesDoNotStopThemFromJoining() async throws {
        let page = RestlessPage(content: 1500, viewport: 300)
        let result = await engine(page).run()
        XCTAssertTrue(result.plan.gaps.isEmpty, "noise and a blinking caret are not a reason to give up")
        XCTAssertGreaterThan(result.frames.count, 4)
        try assertWholePage(result, lines: 1500)
        XCTAssertTrue(result.plan.uncertain.isEmpty, "and the joins are confident")
    }

    func testASpinnerThatNeverStopsDoesNotMakeItScrollForever() async throws {
        let page = RestlessPage(content: 900, viewport: 300)
        page.spinnerRows = 36            // 12% of the picture changes every time
        let result = await engine(page).run()
        XCTAssertLessThan(result.frames.count, 40, "at the end the page does not move; a spinner is not movement, so it stops")
        try assertWholePage(result, lines: 900)
    }

    func testAPageThatLoadsMoreAtTheEndIsWaitedFor() async throws {
        let page = RestlessPage(content: 900, viewport: 300)
        page.loadsMore = true
        let result = await engine(page).run()
        XCTAssertEqual(page.extra, 300, "reaching the end again triggered more content")
        try assertWholePage(result, lines: 1200)
    }

    // MARK: Pictures that cannot be joined are kept

    func testAPictureThatJoinsNothingStartsASectionBelowALine() async throws {
        let page = RestlessPage(content: 4000, viewport: 300)
        page.noise = 0; page.blink = false
        let first = try await page.grab()
        page.offset = 2500
        let far = try await page.grab()
        let sigs = [ScrollImage.rowSignature(first), ScrollImage.rowSignature(far)]
        let plan = ScrollStitch.plan(signatures: sigs)
        XCTAssertEqual(plan.gaps, [1])
        XCTAssertEqual(plan.breaks, [1], "a new section starts at the second strip")
        XCTAssertEqual(plan.length, 600, "both pictures are in the result: nothing was dropped")
        let image = try XCTUnwrap(ScrollImage.assemble(frames: [first, far], plan: plan, axis: .vertical))
        XCTAssertEqual(image.height, 600 + ScrollImage.separatorThickness, "with a line between them")
    }

    func testPicturesAfterAnUnjoinedOneJoinToIt() async throws {
        let page = RestlessPage(content: 4000, viewport: 300)
        page.noise = 0; page.blink = false
        var images: [CGImage] = []
        for offset in [0, 200, 2500, 2700] { page.offset = offset; images.append(try await page.grab()) }
        let plan = ScrollStitch.plan(signatures: images.map(ScrollImage.rowSignature))
        XCTAssertEqual(plan.gaps, [2], "only the jump is a gap")
        XCTAssertEqual(plan.length, 300 + 200 + 300 + 200, "the picture after the jump joined the picture at the jump")
    }

    // MARK: The person scrolls

    func testAPictureTakenBackIsNotTakenAgainWhileTheScreenStaysThere() async throws {
        let page = RestlessPage(content: 3000, viewport: 300)
        page.noise = 0; page.blink = false
        let e = engine(page, mode: .manual)
        let run = Task { await e.run() }
        for position in [150, 300, 450] {
            try await Task.sleep(nanoseconds: 120_000_000)
            page.offset = position
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        e.undoLast()
        try await Task.sleep(nanoseconds: 150_000_000)
        e.stop()
        let result = await run.value
        let image = try XCTUnwrap(ScrollImage.assemble(frames: result.frames, plan: result.plan, axis: result.axis))
        XCTAssertEqual(image.height, 600, "the last picture was taken back and, with the screen still showing it, not taken again")
    }

    func testAJumpIsHeldTheClientIsToldAndItIsKeptWhenAsked() async throws {
        let page = RestlessPage(content: 5000, viewport: 300)
        page.noise = 0; page.blink = false
        let e = engine(page, mode: .manual)
        var told: [Bool] = []
        e.onNeedsOverlap = { told.append($0) }
        let run = Task { await e.run() }
        try await Task.sleep(nanoseconds: 120_000_000)
        page.offset = 3000
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(told.last, true, "scrolling too far is said at once")
        e.keepUnjoined()
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(told.last, false)
        e.stop()
        let result = await run.value
        XCTAssertEqual(result.plan.gaps.count, 1, "kept as a section of its own, not thrown away")
        XCTAssertEqual(result.frames.count, 2)
    }

    func testFinishingWithAHeldPictureKeepsItInsteadOfLosingIt() async throws {
        let page = RestlessPage(content: 5000, viewport: 300)
        page.noise = 0; page.blink = false
        let e = engine(page, mode: .manual)
        let run = Task { await e.run() }
        try await Task.sleep(nanoseconds: 100_000_000)
        page.offset = 3500
        try await Task.sleep(nanoseconds: 250_000_000)
        e.stop()
        let result = await run.value
        XCTAssertEqual(result.frames.count, 2)
        XCTAssertEqual(result.plan.gaps.count, 1)
    }

    func testCapturingThisPositionTakesItWithoutWaiting() async throws {
        let page = RestlessPage(content: 3000, viewport: 300)
        page.noise = 0; page.blink = false
        let e = engine(page, mode: .manual)
        e.pollInterval = 5          // the ordinary look is far away
        let run = Task { await e.run() }
        try await Task.sleep(nanoseconds: 80_000_000)
        page.offset = 150
        e.captureNow()
        try await Task.sleep(nanoseconds: 200_000_000)
        e.stop()
        let result = await run.value
        XCTAssertEqual(result.frames.count, 2, "taken at once, not at the next look")
    }

    // MARK: Ways of scrolling

    /// A page where one way of scrolling works and the others do nothing, and that can say where it is.
    final class OneWayPage: ScrollWorld {
        let works: ScrollStrategy
        let content = 1200, viewport = 300
        var offset = 0
        var tried: [ScrollStrategy] = []
        var knowsPosition = false
        var strategies: [ScrollStrategy]
        var scale: CGFloat { 1 }
        init(works: ScrollStrategy, strategies: [ScrollStrategy]) { self.works = works; self.strategies = strategies }
        func grab() async throws -> CGImage {
            var data = [UInt8](repeating: 255, count: 100 * viewport * 4)
            for y in 0..<viewport {
                var hash = UInt32(truncatingIfNeeded: offset + y) &* 2_654_435_761
                hash ^= hash >> 15; hash = hash &* 2_246_822_519; hash ^= hash >> 13
                for x in 0..<100 { let i = (y * 100 + x) * 4; data[i] = UInt8(truncatingIfNeeded: hash); data[i + 1] = UInt8(truncatingIfNeeded: hash >> 8); data[i + 2] = UInt8(truncatingIfNeeded: hash >> 16) }
            }
            return CGImage(width: 100, height: viewport, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 400, space: CGColorSpaceCreateDeviceRGB(),
                           bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: CGDataProvider(data: Data(data) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        }
        func scroll(by points: Int, axis: CaptureScrollAxis) async { _ = await scroll(by: points, axis: axis, using: .wheel) }
        func pageForward() async -> Bool { await scroll(by: 270, axis: .vertical, using: .pageKey) }
        func scroll(by points: Int, axis: CaptureScrollAxis, using strategy: ScrollStrategy) async -> Bool {
            tried.append(strategy)
            guard strategy == works else { return false }
            offset = min(max(offset + points, 0), content - viewport)
            return true
        }
        func position(axis: CaptureScrollAxis) async -> ScrollPosition? {
            knowsPosition ? ScrollPosition(offset: Double(offset), total: Double(content), viewport: Double(viewport)) : nil
        }
    }

    func testTheFirstWayThatDoesNothingIsGivenUpForTheNext() async throws {
        let page = OneWayPage(works: .arrowKeys, strategies: [.browser, .accessibility, .wheel, .pageKey, .arrowKeys])
        let result = await engine(page).run()
        XCTAssertEqual(result.strategy, .arrowKeys)
        XCTAssertTrue(result.warnings.contains { $0.contains("the arrow keys") })
        XCTAssertEqual(result.frames.count, 6, "0, 210, 420, 630, 840 and the last stretch")
        XCTAssertEqual(result.plan.length, 1200)
    }

    func testAnExactWayIsUsedFirstAndTheEndIsKnownFromPosition() async throws {
        let page = OneWayPage(works: .browser, strategies: [.browser, .wheel])
        page.knowsPosition = true
        let result = await engine(page).run()
        XCTAssertEqual(result.strategy, .browser)
        XCTAssertEqual(result.plan.length, 1200)
        XCTAssertFalse(page.tried.contains(.wheel), "the wheel was never needed")
        XCTAssertLessThanOrEqual(page.tried.count, 6, "and it stopped when the page said it was at the end, with no waiting for stalls")
    }

    func testScrollPositionKnowsWhereItIs() {
        let top = ScrollPosition(offset: 0, total: 1200, viewport: 300)
        XCTAssertFalse(top.atEnd); XCTAssertEqual(top.fraction, 0.25, accuracy: 1e-9)
        XCTAssertTrue(ScrollPosition(offset: 900, total: 1200, viewport: 300).atEnd)
        XCTAssertTrue(ScrollPosition(offset: 0, total: 200, viewport: 300).atEnd, "a page that fits is already at its end")
    }

    // MARK: Matching lines with a tolerance

    /// A signature with a line for each value. A line is a pattern of its own across the width (as a real line of a page is), except
    /// the value 250, which is plain white.
    private func signature(_ lines: [UInt8], width: Int = ScrollSignature.samples) -> ScrollSignature {
        var data: [UInt8] = []
        for v in lines {
            if v == 250 { data += [UInt8](repeating: 250, count: width); continue }
            for s in 0..<width {
                var h = (UInt32(v) &+ 1) &* 2_654_435_761 &+ UInt32(s) &* 40_503
                h ^= h >> 15; h = h &* 2_246_822_519; h ^= h >> 13
                data.append(UInt8(truncatingIfNeeded: h))
            }
        }
        return ScrollSignature(width: width, data: data)
    }

    /// Lines with a value of their own, spread so neighbours differ.
    private func ramp(_ range: Range<Int>) -> [UInt8] { range.map { UInt8(truncatingIfNeeded: ($0 &* 53) ^ ($0 >> 2) &* 7) } }

    func testLinesThatDifferALittleStillMatch() {
        let page = ramp(0..<300)
        let previous = signature(Array(page[0..<150]))
        // Everything a little off: every third line two shades brighter in every sample.
        let exact = signature(Array(page[90..<240]))
        var data = exact.data
        for line in stride(from: 0, to: exact.count, by: 3) { for s in 0..<exact.width { data[line * exact.width + s] = data[line * exact.width + s] &+ 2 } }
        let overlap = ScrollMatch.overlap(previous: previous, next: ScrollSignature(width: exact.width, data: data))
        XCTAssertEqual(overlap?.lines, 60)
        XCTAssertGreaterThan(overlap?.confidence ?? 0, 0.85)
    }

    func testDifferentContentDoesNotMatch() {
        let a = signature(ramp(0..<150)), b = signature(ramp(500..<650))
        XCTAssertNil(ScrollMatch.overlap(previous: a, next: b))
    }

    func testAPlainBandIsNotEvidenceOfAnOverlap() {
        let blankThenText = signature([UInt8](repeating: 250, count: 100) + ramp(0..<20))
        let blankAgain = signature([UInt8](repeating: 250, count: 120))
        XCTAssertNil(ScrollMatch.overlap(previous: blankThenText, next: blankAgain), "matching white proves nothing")
    }

    func testIdenticalRowsAreFlaggedAndTheExpectedMoveChoosesBetweenThem() {
        // A table: the same eight-line pattern over and over.
        let pattern: [UInt8] = [10, 200, 60, 240, 30, 180, 90, 250]
        let rows = (0..<200).map { pattern[$0 % 8] }
        let previous = signature(Array(rows[0..<120]))
        let next = signature(Array(rows[40..<160]))             // really 80 lines of overlap
        let guess = ScrollMatch.overlap(previous: previous, next: next)
        XCTAssertEqual(guess?.ambiguous, true, "several overlaps fit equally well")
        XCTAssertLessThan(guess?.confidence ?? 1, 0.7, "so it is not trusted")
        let told = ScrollMatch.overlap(previous: previous, next: next, expected: 80)
        XCTAssertEqual(told?.lines, 80, "the step that was asked settles it")
        XCTAssertEqual(told?.ambiguous, false)
    }

    func testBlankMarginsAreNotMistakenForToolbars() {
        let blank = [UInt8](repeating: 250, count: 40)
        let first = signature(blank + ramp(0..<150)), second = signature(blank + ramp(60..<210))
        XCTAssertEqual(ScrollMatch.fixedBars(first, second).header, 0, "forty blank lines at the top of two pictures are not a toolbar")
        let bar = ramp(1000..<1030)
        XCTAssertEqual(ScrollMatch.fixedBars(signature(bar + ramp(0..<150)), signature(bar + ramp(60..<210))).header, 30, "a bar with something in it is")
    }

    func testTheSamePictureWithACursorIsTheSamePicture() {
        let page = ramp(0..<300)
        var other = page
        other[40] = 0; other[41] = 0; other[42] = 0
        XCTAssertTrue(ScrollMatch.same(signature(page), signature(other)))
        var moved = ramp(100..<400)
        moved[0] = 1
        XCTAssertFalse(ScrollMatch.same(signature(page), signature(moved)))
    }

    func testSignaturesDescribeEveryRowAndColumn() throws {
        let image = ScrollEngineTests.picture(lines: Array(0..<200), vertical: true)
        XCTAssertEqual(ScrollImage.rowSignature(image).count, 200)
        let across = ScrollEngineTests.picture(lines: Array(0..<260), vertical: false)
        XCTAssertEqual(ScrollImage.columnSignature(across).count, 260)
    }

    // MARK: Telling the person how it went

    func testTheSummaryNamesWhatDidNotJoinAndWhatWasACloseCall() {
        var plan = ScrollStitch.Plan(strips: [], header: 0, footer: 0, gaps: [3], repeats: [])
        plan.joins = [.init(frame: 1, overlap: 40, confidence: 0.95, ambiguous: false), .init(frame: 2, overlap: 40, confidence: 0.5, ambiguous: true)]
        let result = ScrollEngine.Result(frames: [], axis: .vertical, plan: plan, cancelled: false, reason: "Reached the end.", hitLimit: false, warnings: ["Scrolled with the arrow keys."])
        let text = ScrollCaptureSession.summary(of: result)
        XCTAssertTrue(text.contains("did not join"), text); XCTAssertTrue(text.contains("red line"), text); XCTAssertTrue(text.contains("nothing was left out"), text)
        XCTAssertTrue(text.contains("close call"), text); XCTAssertTrue(text.contains("arrow keys"), text)
        let clean = ScrollEngine.Result(frames: [], axis: .vertical, plan: ScrollStitch.Plan(strips: [], header: 0, footer: 0, gaps: [], repeats: []), cancelled: false, reason: "Reached the end.", hitLimit: false)
        XCTAssertFalse(ScrollCaptureSession.summary(of: clean).contains("red line"))
    }

    // MARK: Browsers and PDFs

    func testBrowsersAreFoundAndAskedByTheirOwnScripting() {
        XCTAssertEqual(BrowserKind.detect(bundleID: "com.apple.Safari"), .safari)
        XCTAssertEqual(BrowserKind.detect(bundleID: "com.google.Chrome"), .chromium(name: "Google Chrome"))
        XCTAssertNil(BrowserKind.detect(bundleID: "com.apple.TextEdit")); XCTAssertNil(BrowserKind.detect(bundleID: nil))
        let js = BrowserKind.javascript(dx: 0, dy: 420)
        XCTAssertTrue(js.contains("scrollBy(0,420)")); XCTAssertFalse(js.contains("\""), "it sits inside an AppleScript string")
        XCTAssertTrue(BrowserKind.safari.appleScript(javascript: js).hasPrefix("tell application \"Safari\""))
        XCTAssertTrue(BrowserKind.chromium(name: "Arc").appleScript(javascript: js).contains("execute active tab of front window javascript"))
    }

    func testTheBrowsersAnswerIsReadForEitherDirection() {
        let answer = "0,1200,1440,900,1440,8000\n"
        XCTAssertEqual(BrowserKind.parse(answer, axis: .vertical), ScrollPosition(offset: 1200, total: 8000, viewport: 900))
        XCTAssertEqual(BrowserKind.parse(answer, axis: .horizontal), ScrollPosition(offset: 0, total: 1440, viewport: 1440))
        XCTAssertNil(BrowserKind.parse("missing value", axis: .vertical)); XCTAssertNil(BrowserKind.parse("1,2,3", axis: .vertical))
    }

    func testAPdfIsLaidOutPageUnderPageAndCutAtTheLongestLength() {
        let layout = PDFRender.layout(pageSizes: [CGSize(width: 600, height: 800), CGSize(width: 700, height: 800)], gap: 16)
        XCTAssertEqual(layout.width, 700, "as wide as the widest page")
        XCTAssertEqual(layout.height, 800 + 16 + 800)
        XCTAssertEqual(layout.pages.map(\.top), [0, 816])
        XCTAssertFalse(layout.truncated)
        let long = PDFRender.layout(pageSizes: Array(repeating: CGSize(width: 600, height: 900), count: 200), gap: 0, maxHeight: 10_000)
        XCTAssertTrue(long.truncated); XCTAssertEqual(long.pages.count, 11)
        XCTAssertEqual(PDFRender.layout(pageSizes: []).height, 0)
    }

    func testTheScrollingSettingsStayInRangeAndOldOnesStillLoad() throws {
        let old = try JSONDecoder().decode(CaptureModeSettings.self, from: Data(#"{"scrollAxis":"vertical"}"#.utf8))
        XCTAssertEqual(old.scrollStep, 0.7); XCTAssertTrue(old.scrollUsesDocument)
        let wild = try JSONDecoder().decode(CaptureModeSettings.self, from: Data(#"{"scrollStep":5}"#.utf8))
        XCTAssertEqual(wild.scrollStep, 0.9)
        let tiny = try JSONDecoder().decode(CaptureModeSettings.self, from: Data(#"{"scrollStep":0}"#.utf8))
        XCTAssertEqual(tiny.scrollStep, 0.3)
    }
}
