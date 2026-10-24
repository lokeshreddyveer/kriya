import XCTest
@testable import Kriya

final class ClipboardInsightTests: XCTestCase {
    // MARK: Secret labels

    func testKnownKeyShapesAreLabelled() {
        XCTAssertEqual(ClipSecrets.classify("AKIAIOSFODNN7EXAMPLE"), .awsKey)
        XCTAssertEqual(ClipSecrets.classify("ghp_" + String(repeating: "a1B2", count: 9)), .githubToken)
        XCTAssertEqual(ClipSecrets.classify("xoxb-123456789012-abcdefghijkl"), .slackToken)
        XCTAssertEqual(ClipSecrets.classify("sk_live_" + String(repeating: "x9", count: 10)), .stripeKey)
        XCTAssertEqual(ClipSecrets.classify("AIza" + String(repeating: "A", count: 35)), .googleKey)
        XCTAssertEqual(ClipSecrets.classify("eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.c2ln"), .jwt)
        XCTAssertEqual(ClipSecrets.classify("-----BEGIN OPENSSH PRIVATE KEY-----\nabc\n-----END OPENSSH PRIVATE KEY-----"), .privateKey)
    }

    func testCardNumbersNeedTheCheckDigit() {
        XCTAssertEqual(ClipSecrets.classify("4242 4242 4242 4242"), .creditCard)
        XCTAssertEqual(ClipSecrets.classify("4242-4242-4242-4242"), .creditCard)
        XCTAssertNil(ClipSecrets.classify("4242 4242 4242 4243"), "fails the check digit, so it is just a number")
        XCTAssertNil(ClipSecrets.classify("1234567890123"), "a phone-number-like run is not a card")
        XCTAssertTrue(ClipSecrets.luhn("79927398713"))
        XCTAssertFalse(ClipSecrets.luhn("79927398710"))
    }

    func testOrdinaryTextLinksAndPathsAreNotSecrets() {
        for text in ["Meeting notes for Monday", "https://Example.com/Path/To1?x=Y!", "/Users/Me/Documents/Report-1.pdf", "hello", "Hello World 123!", "user@example.com", "~/Projects/App2", ""] {
            XCTAssertNil(ClipSecrets.classify(text), text)
        }
    }

    func testPasswordsNeedFourKindsOfCharacters() {
        XCTAssertEqual(ClipSecrets.classify("Tr0ub4dor&3"), .password)
        XCTAssertNil(ClipSecrets.classify("trustno1"), "two kinds of characters")
        XCTAssertEqual(ClipSecrets.classify("sk-" + String(repeating: "Ab3", count: 10)), .apiKey)
    }

    func testTheLabelIsAKeptAsATagAndReadsBack() {
        for kind in ClipSecretKind.allCases { XCTAssertEqual(ClipSecretKind.from(tag: kind.tag), kind) }
        XCTAssertNil(ClipSecretKind.from(tag: "secret:nonsense"))
        XCTAssertNil(ClipSecretKind.from(tag: "work"))
    }

    // MARK: Filters

    private func clip(_ id: String, app: String?, daysAgo: Double, uses: UInt32 = 1, sensitive: Bool = false, tags: [String] = []) -> ClipItem {
        let t = Int64(Date().addingTimeInterval(-daysAgo * 86_400).timeIntervalSince1970)
        return ClipItem(id: id, kind: .text, preview: id, title: nil, sourceApp: app, createdAt: t, lastUsedAt: t, useCount: uses, pinned: false, favorite: false, collectionId: nil, tags: tags, byteSize: 1, imageWidth: nil, imageHeight: nil, files: [], hasRich: false, sensitive: sensitive)
    }

    func testFiltersCombine() {
        let items = [clip("a", app: "com.apple.Safari", daysAgo: 0), clip("b", app: "com.apple.Notes", daysAgo: 3, uses: 5), clip("c", app: "com.apple.Safari", daysAgo: 40, sensitive: true), clip("d", app: nil, daysAgo: 10, tags: ["secret:awsKey"])]
        XCTAssertEqual(ClipViewFilter(sourceApp: "com.apple.Safari").apply(items).map(\.id), ["a", "c"])
        XCTAssertEqual(ClipViewFilter(range: .today).apply(items).map(\.id), ["a"])
        XCTAssertEqual(ClipViewFilter(range: .week).apply(items).map(\.id), ["a", "b"])
        XCTAssertEqual(ClipViewFilter(range: .month).apply(items).map(\.id), ["a", "b", "d"])
        XCTAssertEqual(ClipViewFilter(frequentOnly: true).apply(items).map(\.id), ["b"])
        XCTAssertEqual(ClipViewFilter(secretsOnly: true).apply(items).map(\.id), ["c", "d"], "a sensitive flag or a secret label both count")
        XCTAssertEqual(ClipViewFilter(sourceApp: "com.apple.Safari", range: .week).apply(items).map(\.id), ["a"])
        XCTAssertFalse(ClipViewFilter().isActive)
        XCTAssertTrue(ClipViewFilter(frequentOnly: true).isActive)
    }

    func testSourcesAreOrderedByHowOftenTheyCopied() {
        let items = [clip("1", app: "b", daysAgo: 0), clip("2", app: "a", daysAgo: 0), clip("3", app: "a", daysAgo: 0), clip("4", app: nil, daysAgo: 0)]
        XCTAssertEqual(ClipViewFilter.sources(in: items), ["a", "b"])
    }

    // MARK: Expiry, pause, paste text

    func testExpiryListsOnlyWhatIsDueAndForgetsIt() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var e = ClipExpiry()
        e.schedule("soon", after: 60, now: now)
        e.schedule("later", after: 3600, now: now)
        XCTAssertTrue(e.due(now: now).isEmpty)
        XCTAssertEqual(e.due(now: now.addingTimeInterval(61)), ["soon"])
        XCTAssertEqual(e.remaining("later", now: now), 3600)
        e.forget(["soon"])
        XCTAssertTrue(e.due(now: now.addingTimeInterval(61)).isEmpty)
        e.cancel("later")
        XCTAssertNil(e.remaining("later", now: now))
        XCTAssertEqual(try JSONDecoder().decode(ClipExpiry.self, from: JSONEncoder().encode(e)), e)
    }

    func testPauseEndsOnTimeOrNever() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(ClipPause.resumeAt(minutes: 5, now: now), now.addingTimeInterval(300))
        XCTAssertNil(ClipPause.resumeAt(minutes: 0, now: now))
        XCTAssertFalse(ClipPause.isOver(until: now.addingTimeInterval(1), now: now))
        XCTAssertTrue(ClipPause.isOver(until: now, now: now))
        XCTAssertFalse(ClipPause.isOver(until: nil, now: now), "an open-ended pause never ends by itself")
        XCTAssertEqual(ClipPause.label(until: nil), "Paused until you resume")
        XCTAssertEqual(ClipPause.label(until: now.addingTimeInterval(1500), now: now), "Paused for 25 more minutes")
    }

    func testMarkdownLinksAndJoinedPastes() {
        XCTAssertEqual(ClipPasteText.markdownLink("https://www.example.com/a_(b)"), "[example.com](https://www.example.com/a_%28b%29)")
        XCTAssertNil(ClipPasteText.markdownLink("not a link"))
        XCTAssertNil(ClipPasteText.markdownLink("file:///etc/passwd"))
        XCTAssertEqual(ClipPasteText.joined(["a", "b", "c"], by: .tab), "a\tb\tc")
        XCTAssertEqual(ClipPasteText.joined(["a", "b"], by: .newline), "a\nb")
        XCTAssertEqual(ClipPasteText.joined(["a", "b"], by: .comma), "a, b")
        XCTAssertEqual(ClipPasteText.joined([], by: .space), "")
    }

    // MARK: Pictures

    private func pngData(width: Int = 4, height: Int = 4) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.representation(using: .png, properties: [:])!
    }

    func testPicturesConvertBetweenPNGAndJPEG() throws {
        let png = pngData()
        let jpeg = try XCTUnwrap(ClipImageTools.convert(png, to: .jpeg))
        XCTAssertEqual(Array(jpeg.prefix(2)), [0xFF, 0xD8], "a JPEG starts FF D8")
        let back = try XCTUnwrap(ClipImageTools.convert(jpeg, to: .png))
        XCTAssertEqual(Array(back.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
        XCTAssertNil(ClipImageTools.convert(Data("not a picture".utf8), to: .png))
        XCTAssertNotNil(ClipImageTools.cgImage(from: png))
    }

    func testAPictureWithNoCodeOrWordsGivesNothing() {
        XCTAssertTrue(ClipImageTools.qrPayloads(in: pngData()).isEmpty)
        XCTAssertTrue(ClipImageTools.qrPayloads(in: Data()).isEmpty)
        XCTAssertNil(ClipImageTools.text(in: Data()), "no picture, no text")
    }
}
