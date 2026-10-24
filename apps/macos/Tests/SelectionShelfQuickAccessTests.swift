import XCTest
@testable import Kriya

final class SelectionRankingTests: XCTestCase {
    private func action(_ id: String, _ title: String, _ kind: SelectionActionKind, group: String? = nil) -> SelectionAction {
        SelectionAction(id: id, title: title, symbol: "star", kind: kind, enabled: true, applies: .anything, appIds: [], group: group)
    }

    private func ranked(_ text: String, editable: Bool = true, usage: [String: Int] = [:], pinned: Set<String> = [], _ list: [SelectionAction]) -> [String] {
        SelectionRanking.rank(list, signals: .init(context: .detect(text), editable: editable, usage: usage, pinned: pinned)).map(\.id)
    }

    private var all: [SelectionAction] {
        [action("copy", "Copy", .copy), action("upper", "UPPERCASE", .transform(ops: [.uppercase], copyOnly: false)),
         action("json", "Format JSON", .transform(ops: [.jsonFormat], copyOnly: false)), action("links", "Open link", .openUrls),
         action("define", "Look up", .dictionary), action("ai", "Summarize", .intelligence(task: .summarize), group: "AI"),
         action("reveal", "Show in Finder", .revealPath), action("decode", "URL decode", .transform(ops: [.urlDecode], copyOnly: false)),
         action("unix", "Unix time to date", .transform(ops: [.unixTimeToDate], copyOnly: false)), action("join", "Remove line breaks", .transform(ops: [.joinLines], copyOnly: false))]
    }

    func testContextIsReadFromTheText() {
        XCTAssertTrue(SelectionContext.detect("https://example.com/a").isLink)
        XCTAssertTrue(SelectionContext.detect("see https://example.com now").hasLink)
        XCTAssertFalse(SelectionContext.detect("see https://example.com now").isLink)
        XCTAssertTrue(SelectionContext.detect("{\"a\": 1}").isJSON)
        XCTAssertTrue(SelectionContext.detect("/Users/me/file.txt").isPath)
        XCTAssertFalse(SelectionContext.detect("//cdn.example.com/x").isPath)
        XCTAssertTrue(SelectionContext.detect("mail me@example.com please").hasEmail)
        XCTAssertTrue(SelectionContext.detect("serendipity").isSingleWord)
        XCTAssertTrue(SelectionContext.detect("1700000000").isNumberLike)
        XCTAssertFalse(SelectionContext.detect("12345").isNumberLike)
        XCTAssertTrue(SelectionContext.detect("a%20b").looksPercentEncoded)
        XCTAssertTrue(SelectionContext.detect("one\ntwo").multiline)
        XCTAssertFalse(SelectionContext.detect("").multiline)
    }

    func testWhatFitsTheSelectionComesFirst() {
        XCTAssertEqual(ranked("{\"a\":1}", all).prefix(2).first, "json")
        XCTAssertEqual(ranked("https://example.com/x", editable: false, all).first, "links")
        XCTAssertEqual(ranked("/Users/me/Documents", editable: false, all).first, "reveal")
        XCTAssertEqual(ranked("serendipity", editable: false, all).first, "define")
        XCTAssertEqual(ranked("1700000000", all).first, "unix")
        XCTAssertEqual(ranked("a%20b%20c", all).first, "decode")
        XCTAssertEqual(ranked("line one\nline two\nline three", all).first, "join")
    }

    func testPinnedAndUsedActionsRiseAndTheSlowOneWaitsForShortText() {
        XCTAssertEqual(ranked("hello there", pinned: ["upper"], all).first, "upper")
        XCTAssertEqual(ranked("hello there", usage: ["Look up": 20], all).first, "define", "what is used most comes up")
        let short = ranked("hello there friend", all)
        XCTAssertGreaterThan(try XCTUnwrap(short.firstIndex(of: "ai")), try XCTUnwrap(short.firstIndex(of: "copy")))
        let long = String(repeating: "word ", count: 80)
        XCTAssertLessThan(try XCTUnwrap(ranked(long, all).firstIndex(of: "ai")), try XCTUnwrap(ranked(long, all).firstIndex(of: "upper")), "a long text brings the AI actions up")
    }

    func testRankingIsStableAndKeepsGroupsTogether() {
        let list = [action("a", "A", .copyPlain), action("b", "B", .copyPlain), action("g1", "G1", .intelligence(task: .summarize), group: "AI"), action("c", "C", .copyPlain), action("g2", "G2", .intelligence(task: .keyPoints), group: "AI")]
        let order = ranked("plain text here", list)
        XCTAssertEqual(order.filter { ["a", "b", "c"].contains($0) }, ["a", "b", "c"], "the person's order is the tie-breaker")
        let g1 = try! XCTUnwrap(order.firstIndex(of: "g1")), g2 = try! XCTUnwrap(order.firstIndex(of: "g2"))
        XCTAssertEqual(abs(g1 - g2), 1, "members of a group stay side by side")
        XCTAssertEqual(ranked("x", []), [])
    }

    func testOverflowIsSortedUnderHeadingsInAFixedOrder() {
        let list = all + [action("search", "Search", .urlTemplate(template: "https://x/{text}")), action("share", "Share", .share)]
        let sections = SelectionRanking.grouped(list)
        XCTAssertEqual(sections.map(\.title), ["Transform", "Search", "Share", "Developer", "AI", "Apps", "More"].filter { name in sections.contains { $0.title == name } })
        XCTAssertEqual(SelectionRanking.category(action("j", "j", .transform(ops: [.jsonFormat], copyOnly: false))), "Developer")
        XCTAssertEqual(SelectionRanking.category(action("u", "u", .transform(ops: [.uppercase], copyOnly: false))), "Transform")
        XCTAssertEqual(SelectionRanking.category(action("i", "i", .intelligence(task: .explain))), "AI")
        XCTAssertEqual(SelectionRanking.category(action("c", "c", .copy)), "More")
    }

    func testReplacementSummaryAndPreview() {
        let s = ReplacementSummary(original: "one two three four", result: "one two")
        XCTAssertEqual(s.headline, "4 → 2 words")
        XCTAssertEqual(ReplacementSummary(original: "a", result: "a").headline, "No change")
        XCTAssertEqual(ReplacementSummary.preview("line one\nline two", limit: 12), "line one ⏎ l…")
        XCTAssertEqual(ReplacementSummary.preview("short"), "short")
    }

    func testNewTextActionsFromTheCore() throws {
        XCTAssertEqual(try textApplyAll(ops: [.joinLines], text: "one\n two \n\nthree"), "one two three")
        XCTAssertEqual(textToHtml(text: "A & B\n\nC"), "<p>A &amp; B</p>\n<p>C</p>")
        XCTAssertTrue(selectionLooksLikePath(text: "~/code/app"))
        XCTAssertFalse(selectionLooksLikePath(text: "a sentence"))
        XCTAssertEqual(textOpTitle(op: .joinLines), "Remove line breaks")
        let list = selectionSuggestedActions()
        for id in ["s-join-lines", "s-copy-html", "s-reveal-path", "s-terminal-here", "s-to-shelf"] { XCTAssertTrue(list.contains { $0.id == id }, id) }
    }

    func testCountsAddReadingTimeForALongText() {
        XCTAssertEqual(SelectionActionRunner.counts("two words"), "2 words · 9 characters · 1 line")
        XCTAssertTrue(SelectionActionRunner.counts(String(repeating: "word ", count: 440)).hasSuffix("2 min read"))
    }

    func testPathsBecomeFileAddresses() {
        XCTAssertEqual(SelectionActionRunner.fileURL(from: " /Users/me/a ")?.path, "/Users/me/a")
        XCTAssertEqual(SelectionActionRunner.fileURL(from: "~/x")?.path, NSHomeDirectory() + "/x")
        XCTAssertEqual(SelectionActionRunner.fileURL(from: "file:///tmp/a%20b")?.path, "/tmp/a b")
        XCTAssertNil(SelectionActionRunner.fileURL(from: "relative/path"))
    }
}

final class ShelfAdditionsTests: XCTestCase {
    private func library() -> ShelfSet {
        ShelfSet(id: "s", name: "Work", items: [
            ShelfRecord(kind: .file, value: "/Users/me/a.txt", added: Date(timeIntervalSince1970: 1_700_000_000), group: "Docs"),
            ShelfRecord(kind: .text, value: "hello", added: Date(timeIntervalSince1970: 1_700_000_100)),
            ShelfRecord(kind: .image, value: "pic.png", added: Date(timeIntervalSince1970: 1_700_000_200)),
        ])
    }

    func testAShelfSurvivesAnExportAndImport() throws {
        let data = try XCTUnwrap(ShelfExchange.exported(library(), imageData: { $0 == "pic.png" ? Data([1, 2, 3, 4, 5, 6, 7, 8, 9]) : nil }))
        let imported = try XCTUnwrap(ShelfExchange.imported(data))
        XCTAssertEqual(imported.name, "Work")
        XCTAssertEqual(imported.items.count, 3)
        XCTAssertEqual(imported.items[0], ShelfExchange.Imported(kind: .file, value: "/Users/me/a.txt", group: "Docs", added: Date(timeIntervalSince1970: 1_700_000_000), png: nil))
        XCTAssertEqual(imported.items[2].png?.count, 9)
        XCTAssertEqual(imported.skipped, 0)
    }

    func testBadShelfFilesAreRefusedAndBadItemsLeftOut() throws {
        XCTAssertNil(ShelfExchange.imported(Data("nope".utf8)))
        let wrongFormat = ShelfExport(format: "something-else", version: 1, name: "x", items: [])
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        XCTAssertNil(ShelfExchange.imported(try enc.encode(wrongFormat)))
        XCTAssertNil(ShelfExchange.imported(try enc.encode(ShelfExport(version: 99, name: "x", items: []))), "from a newer version")
        let mixed = ShelfExport(name: "  ", items: [
            .init(kind: "file", value: "relative.txt", group: nil, added: Date()), .init(kind: "file", value: "/ok.txt", group: String(repeating: "g", count: 90), added: Date()),
            .init(kind: "text", value: "", group: nil, added: Date()), .init(kind: "image", value: "", group: nil, added: Date(), png: nil), .init(kind: "weird", value: "x", group: nil, added: Date()),
        ])
        let parsed = try XCTUnwrap(ShelfExchange.imported(try enc.encode(mixed)))
        XCTAssertEqual(parsed.name, "Imported")
        XCTAssertEqual(parsed.items.map(\.value), ["/ok.txt"])
        XCTAssertEqual(parsed.items[0].group?.count, 40)
        XCTAssertEqual(parsed.skipped, 4)
    }

    func testAShelfMarkedDoNotSaveIsNeverWritten() {
        var lib = ShelfLibrary()
        lib.shelves = [ShelfSet(id: "main", name: "Shelf", items: [ShelfRecord(kind: .text, value: "keep", added: Date())]), ShelfSet(id: "tmp", name: "Secret", items: [ShelfRecord(kind: .text, value: "private", added: Date())], temporary: true)]
        lib.currentID = "tmp"
        let saved = lib.persistable
        XCTAssertEqual(saved.shelves.map(\.id), ["main"])
        XCTAssertEqual(saved.currentID, "main", "the current shelf is always one that is kept")
        XCTAssertFalse(saved.shelves.flatMap(\.items).contains { $0.value == "private" })
        var only = ShelfLibrary(); only.shelves = [ShelfSet(id: "t", name: "T", temporary: true)]; only.currentID = "t"
        XCTAssertEqual(only.persistable.shelves.count, 1, "there is always a shelf")
        let old = #"{"shelves":[{"id":"a","name":"A","items":[]}],"currentID":"a","history":[]}"#
        XCTAssertNoThrow(try JSONDecoder().decode(ShelfLibrary.self, from: Data(old.utf8)), "a file from before the flag still loads")
    }

    func testPictureSizesAndOutputNames() {
        XCTAssertEqual(ImageResize.fit(CGSize(width: 4000, height: 3000), maxEdge: 1000), CGSize(width: 1000, height: 750))
        XCTAssertEqual(ImageResize.fit(CGSize(width: 800, height: 600), maxEdge: 1000), CGSize(width: 800, height: 600), "never made larger")
        XCTAssertEqual(ImageResize.fit(CGSize(width: 600, height: 3000), maxEdge: 1500), CGSize(width: 300, height: 1500))
        XCTAssertEqual(ShelfOutputNaming.name(for: "photo.jpg", suffix: "1280px", ext: "jpg", existing: []), "photo 1280px.jpg")
        XCTAssertEqual(ShelfOutputNaming.name(for: "photo.jpg", suffix: "1280px", ext: "jpg", existing: ["Photo 1280px.jpg", "photo 1280px 2.jpg"]), "photo 1280px 3.jpg")
        XCTAssertEqual(ShelfOutputNaming.name(for: "a.png", suffix: "", ext: "jpg", existing: []), "a.jpg")
    }

    private func makeImages() throws -> (folder: URL, urls: [URL]) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kriya-shelf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var urls: [URL] = []
        for (i, size) in [(400, 200), (100, 100)].enumerated() {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size.0, pixelsHigh: size.1, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            let url = folder.appendingPathComponent("img\(i).png")
            try rep.representation(using: .png, properties: [:])!.write(to: url)
            urls.append(url)
        }
        return (folder, urls)
    }

    func testInstantActionsMakeNewFilesBesideTheOriginalsAndLeaveThemAlone() throws {
        let (folder, urls) = try makeImages()
        defer { try? FileManager.default.removeItem(at: folder) }
        let before = try urls.map { try Data(contentsOf: $0) }
        let small = ShelfInstant.resize(urls, maxEdge: 200)
        XCTAssertEqual(small.outputs.count, 1, "the 100-pixel one is already small enough")
        XCTAssertEqual(small.outputs[0].lastPathComponent, "img0 200px.png")
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(small.outputs[0] as CFURL, nil))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual(props[kCGImagePropertyPixelWidth] as? Int, 200)
        let jpegs = ShelfInstant.convert(urls, to: .jpeg)
        XCTAssertEqual(jpegs.outputs.map(\.pathExtension), ["jpg", "jpg"])
        XCTAssertEqual(try urls.map { try Data(contentsOf: $0) }, before, "the originals are untouched")
        XCTAssertTrue(ShelfInstant.resize([folder.appendingPathComponent("none.txt")], maxEdge: 100).isError)
        XCTAssertEqual(ShelfInstant.paths(urls), urls.map(\.path).joined(separator: "\n"))
        XCTAssertEqual(ShelfInstant.images([urls[0], folder.appendingPathComponent("a.txt")]), [urls[0]])
    }
}

final class QuickAccessTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let panel = CGSize(width: 280, height: 220)

    func testEveryPositionLandsInItsPlaceAndOnTheScreen() {
        func o(_ p: QuickAccessPosition, _ i: Int = 0) -> CGPoint { QuickAccessLayout.origin(position: p, panel: panel, screen: screen, margin: 20, pointer: CGPoint(x: 700, y: 400), stackIndex: i) }
        XCTAssertEqual(o(.bottomLeft), CGPoint(x: 20, y: 20))
        XCTAssertEqual(o(.bottomRight), CGPoint(x: 1140, y: 20))
        XCTAssertEqual(o(.bottomCenter), CGPoint(x: 580, y: 20))
        XCTAssertEqual(o(.topLeft), CGPoint(x: 20, y: 660))
        XCTAssertEqual(o(.topRight), CGPoint(x: 1140, y: 660))
        XCTAssertEqual(o(.topCenter), CGPoint(x: 580, y: 660))
        XCTAssertEqual(o(.center), CGPoint(x: 580, y: 340))
        XCTAssertEqual(o(.middleLeft), CGPoint(x: 20, y: 340))
        XCTAssertEqual(o(.middleRight), CGPoint(x: 1140, y: 340))
        XCTAssertEqual(o(.nearPointer), CGPoint(x: 718, y: 162))
        for p in QuickAccessPosition.allCases { XCTAssertTrue(screen.contains(CGRect(origin: o(p), size: panel)), p.rawValue) }
    }

    func testCardsStackAwayFromTheEdgeAndStayOnScreen() {
        func o(_ p: QuickAccessPosition, _ i: Int) -> CGPoint { QuickAccessLayout.origin(position: p, panel: panel, screen: screen, margin: 20, stackIndex: i) }
        XCTAssertEqual(o(.bottomLeft, 1).y - o(.bottomLeft, 0).y, 230, "upwards from a bottom position")
        XCTAssertEqual(o(.topLeft, 0).y - o(.topLeft, 1).y, 230, "downwards from a top position")
        XCTAssertTrue(screen.contains(CGRect(origin: o(.bottomLeft, 20), size: panel)), "even a deep stack is kept on the screen")
        let tiny = QuickAccessLayout.origin(position: .center, panel: CGSize(width: 500, height: 500), screen: CGRect(x: 0, y: 0, width: 300, height: 300), margin: 20)
        XCTAssertEqual(tiny, CGPoint(x: 0, y: 0), "a card bigger than the screen sits at its corner")
        let second = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        XCTAssertEqual(QuickAccessLayout.origin(position: .bottomLeft, panel: panel, screen: second, margin: 20).x, 1460, "another display is honoured")
    }

    func testSettingsDecideWhichCapturesGetACardAndAreKeptInRange() {
        var s = QuickAccessSettings()
        XCTAssertTrue(s.shows(recording: false)); XCTAssertTrue(s.shows(recording: true))
        s.scope = .screenshots; XCTAssertTrue(s.shows(recording: false)); XCTAssertFalse(s.shows(recording: true))
        s.scope = .recordings; XCTAssertFalse(s.shows(recording: false)); XCTAssertTrue(s.shows(recording: true))
        s.scope = .off; XCTAssertFalse(s.shows(recording: false)); XCTAssertFalse(s.shows(recording: true))
        s.margin = 900; s.autoCloseSeconds = -5; s.stackLimit = 99
        let c = s.clamped
        XCTAssertEqual(c.margin, 120); XCTAssertEqual(c.autoCloseSeconds, 0); XCTAssertEqual(c.stackLimit, 6)
        XCTAssertEqual(try JSONDecoder().decode(QuickAccessSettings.self, from: JSONEncoder().encode(s)), s)
        XCTAssertEqual(QuickAccessSize.small.thumbnailWidth, 190); XCTAssertGreaterThan(QuickAccessSize.large.thumbnailWidth, QuickAccessSize.regular.thumbnailWidth)
        XCTAssertEqual(QuickAccessPosition.allCases.count, 10)
    }

    func testTheInfoLineSaysWhatAndWhen() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let line = QuickAccessInfo.line(width: 1920, height: 1080, bytes: 2_100_000, format: "png", date: now, now: now)
        XCTAssertTrue(line.hasPrefix("1920 × 1080 · PNG · "))
        XCTAssertEqual(line.split(separator: "·").count, 4)
        XCTAssertFalse(QuickAccessInfo.line(width: nil, height: nil, bytes: nil, format: "mov", date: now, now: now).contains("×"))
        XCTAssertTrue(QuickAccessInfo.line(width: nil, height: nil, bytes: nil, format: "", date: now.addingTimeInterval(-3 * 86_400), now: now).split(separator: " ").count >= 3, "an older capture shows its day")
    }

    func testKeysMapToActionsAndIgnoreShortcutsOfOtherApps() {
        func key(_ c: String, code: UInt16 = 0, mod: Bool = false) -> QuickAccessKey? { QuickAccessKey.action(characters: c, keyCode: code, hasCommandLikeModifier: mod) }
        XCTAssertEqual(key("c"), .copy); XCTAssertEqual(key("S"), .save); XCTAssertEqual(key("e"), .annotate); XCTAssertEqual(key("o"), .text)
        XCTAssertEqual(key("p"), .pin); XCTAssertEqual(key("h"), .shelf); XCTAssertEqual(key("x"), .share); XCTAssertEqual(key("y"), .history)
        XCTAssertEqual(key("", code: 51), .delete); XCTAssertEqual(key("", code: 53), .dismiss)
        XCTAssertNil(key("c", mod: true), "⌘C is not the card's")
        XCTAssertNil(key("z"))
        let keys = QuickAccessKey.allCases.map(\.key)
        XCTAssertEqual(Set(keys).count, keys.count, "no two actions share a key")
    }
}
