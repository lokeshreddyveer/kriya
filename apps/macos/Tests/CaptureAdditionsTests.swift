import XCTest
@testable import Kriya

final class CaptureAdditionsTests: XCTestCase {
    // MARK: Signing (AWS's published example)

    /// The example from AWS's Signature Version 4 documentation: a GET of examplebucket's test.txt with a Range header.
    func testSignatureMatchesAWSsPublishedExample() {
        let signer = S3Signer(accessKey: "AKIAIOSFODNN7EXAMPLE", secretKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY", region: "us-east-1")
        let date = Date(timeIntervalSince1970: 1_369_353_600) // 20130524T000000Z
        XCTAssertEqual(S3Signer.amzDate(date), "20130524T000000Z")
        let empty = S3Signer.sha256Hex(Data())
        XCTAssertEqual(empty, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        let request = S3Signer.Request(method: "GET", path: "/test.txt", host: "examplebucket.s3.amazonaws.com",
                                       headers: [("range", "bytes=0-9"), ("x-amz-content-sha256", empty), ("x-amz-date", "20130524T000000Z")], payloadHash: empty)
        let (canonical, signedHeaders) = signer.canonical(request)
        XCTAssertEqual(signedHeaders, "host;range;x-amz-content-sha256;x-amz-date")
        XCTAssertEqual(S3Signer.sha256Hex(Data(canonical.utf8)), "7344ae5b7ee6c3e7e6b0fe0640412a37625d1fbfff95c48bbb2dc43964946972")
        XCTAssertEqual(signer.signature(canonicalRequest: canonical, date: date), "f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41")
    }

    /// The presigned URL example from the same documentation (expires 86400, GET /test.txt).
    func testPresignedURLMatchesAWSsPublishedExample() throws {
        let signer = S3Signer(accessKey: "AKIAIOSFODNN7EXAMPLE", secretKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY", region: "us-east-1")
        let url = try XCTUnwrap(signer.presignedGetURL(host: "examplebucket.s3.amazonaws.com", path: "/test.txt", expires: 86_400, date: Date(timeIntervalSince1970: 1_369_353_600)))
        XCTAssertTrue(url.absoluteString.hasSuffix("X-Amz-Signature=aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404"), url.absoluteString)
        XCTAssertTrue(url.absoluteString.contains("X-Amz-Expires=86400"))
        XCTAssertTrue(url.absoluteString.contains("X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20130524%2Fus-east-1%2Fs3%2Faws4_request"))
    }

    func testExpiryIsCappedAtSevenDays() throws {
        let signer = S3Signer(accessKey: "A", secretKey: "S", region: "auto")
        let url = try XCTUnwrap(signer.presignedGetURL(host: "h.example", path: "/b/k", expires: 10_000_000))
        XCTAssertTrue(url.absoluteString.contains("X-Amz-Expires=604800"))
    }

    func testPutHeadersCarryAHashOfTheBodyAndTheSignature() {
        let signer = S3Signer(accessKey: "AK", secretKey: "SK", region: "auto")
        let h = signer.putHeaders(host: "h.example", path: "/b/k.png", body: Data("hello".utf8), contentType: "image/png", date: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(h["x-amz-content-sha256"], "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
        XCTAssertTrue(h["Authorization"]?.hasPrefix("AWS4-HMAC-SHA256 Credential=AK/") == true)
        XCTAssertTrue(h["Authorization"]?.contains("SignedHeaders=content-type;host;x-amz-content-sha256;x-amz-date") == true)
        XCTAssertEqual(S3Signer.encode("a b/c+d", keepSlash: true), "a%20b/c%2Bd")
        XCTAssertEqual(S3Signer.encode("é"), "%C3%A9")
    }

    // MARK: Upload settings

    func testObjectKeysAreSafeAndAddressesFollowTheProviderStyle() {
        var c = CaptureUploadConfig(enabled: true, endpoint: "https://acct.r2.cloudflarestorage.com/", region: "auto", bucket: "shots", accessKey: "K", prefix: "/../captures//2/", publicBase: "https://files.example.com/", linkMinutes: 60, deleteLocalAfterUpload: false, usePathStyle: true)
        let key = c.objectKey(fileName: "a/b c.png", date: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(key, "captures/2/2027/01/a-b c.png", "a slash in the name and dots in the folder cannot escape")
        XCTAssertFalse(key.contains(".."))
        XCTAssertEqual(c.target(objectKey: key).host, "acct.r2.cloudflarestorage.com")
        XCTAssertEqual(c.target(objectKey: key).path, "/shots/captures/2/2027/01/a-b%20c.png")
        XCTAssertEqual(c.publicURL(objectKey: key), "https://files.example.com/captures/2/2027/01/a-b%20c.png")
        c.usePathStyle = false
        XCTAssertEqual(c.target(objectKey: "k.png").host, "shots.acct.r2.cloudflarestorage.com")
        XCTAssertEqual(c.target(objectKey: "k.png").path, "/k.png")
        c.publicBase = ""
        XCTAssertNil(c.publicURL(objectKey: "k"))
        XCTAssertTrue(c.isComplete)
        XCTAssertFalse(CaptureUploadConfig().isComplete)
    }

    // MARK: Links and formats

    func testLinksAreEscapedSoTheyCannotBreakOut() {
        XCTAssertEqual(CaptureLinks.markdown(url: "https://x.com/a b(1).png", alt: "My [shot]"), "![My shot](https://x.com/a%20b%281%29.png)")
        XCTAssertEqual(CaptureLinks.html(url: "https://x.com/a?b=1&c=\"2\"", alt: "<b>", width: 300), "<img src=\"https://x.com/a?b=1&amp;c=&quot;2&quot;\" alt=\"&lt;b&gt;\" width=\"300\">")
        XCTAssertEqual(CaptureLinks.dataURI(Data([1, 2, 3])), "data:image/png;base64,AQID")
        XCTAssertEqual(CaptureLinks.fileURL("/Users/me/a b.png"), "file:///Users/me/a%20b.png")
    }

    func testEveryFormatWritesItsOwnKindOfFile() throws {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let image = try XCTUnwrap(rep.cgImage)
        XCTAssertEqual(Array(try XCTUnwrap(image.data(as: .png)).prefix(4)), [0x89, 0x50, 0x4E, 0x47])
        XCTAssertEqual(Array(try XCTUnwrap(image.data(as: .jpeg)).prefix(2)), [0xFF, 0xD8])
        XCTAssertEqual(String(decoding: try XCTUnwrap(image.data(as: .pdf)).prefix(5), as: UTF8.self), "%PDF-")
        let tiff = Array(try XCTUnwrap(image.data(as: .tiff)).prefix(2))
        XCTAssertTrue(tiff == [0x49, 0x49] || tiff == [0x4D, 0x4D])
        XCTAssertEqual(CaptureFormat.jpeg.fileExtension, "jpg")
        XCTAssertFalse(CaptureFormat.allCases.map(\.rawValue).contains("webp"))
    }

    // MARK: Text cleanup

    private func line(_ words: [(String, CGFloat, CGFloat)], y: CGFloat) -> RecognizedLine {
        RecognizedLine(words: words.map { RecognizedWord(text: $0.0, box: CGRect(x: $0.1, y: y, width: $0.2, height: 0.02)) })
    }

    func testLinesJoinIntoOneParagraphAndHyphenatedEndsRejoin() {
        let lines = [line([("This", 0.1, 0.05), ("is", 0.2, 0.03)], y: 0.1), line([("a", 0.1, 0.02), ("conti-", 0.14, 0.08)], y: 0.13), line([("nuous", 0.1, 0.07), ("line.", 0.2, 0.05)], y: 0.16)]
        XCTAssertEqual(OCRText.joined(lines), "This is a continuous line.")
    }

    func testBigGapsStartNewParagraphsAndBulletsBecomeMarkdown() {
        let lines = [line([("First", 0.1, 0.05)], y: 0.10), line([("para", 0.1, 0.05)], y: 0.125), line([("• Item", 0.1, 0.06)], y: 0.30), line([("one", 0.1, 0.04)], y: 0.325)]
        XCTAssertEqual(OCRText.paragraphs(lines), ["First para", "• Item one"])
        XCTAssertEqual(OCRText.markdown(lines), "First para\n\n- Item one")
        XCTAssertTrue(OCRText.paragraphs([]).isEmpty)
    }

    func testATableSplitsAtWideGapsAndQuotesCommas() {
        let rows = [
            line([("Name", 0.10, 0.06), ("Qty", 0.50, 0.04), ("Price", 0.80, 0.05)], y: 0.10),
            line([("Red", 0.10, 0.04), ("apple", 0.15, 0.06), ("3", 0.50, 0.01), ("1,50", 0.80, 0.05)], y: 0.14),
        ]
        let table = OCRText.table(rows)
        XCTAssertEqual(table, [["Name", "Qty", "Price"], ["Red apple", "3", "1,50"]])
        XCTAssertEqual(OCRText.csv(table), "Name,Qty,Price\nRed apple,3,\"1,50\"")
    }

    // MARK: Presentation

    func testBeautifyKeepsThePictureUnscaledAndCentredOnTheCanvas() {
        let off = CaptureBeautify()
        XCTAssertEqual(off.layout(for: CGSize(width: 400, height: 300)).canvas, CGSize(width: 400, height: 300))
        var on = CaptureBeautify(); on.background = .ocean; on.padding = 0.1
        let l = on.layout(for: CGSize(width: 400, height: 300))
        XCTAssertEqual(l.canvas, CGSize(width: 460, height: 360), "30 points of space on every side")
        XCTAssertEqual(l.picture, CGRect(x: 30, y: 30, width: 400, height: 300))
        on.aspect = .square
        let sq = on.layout(for: CGSize(width: 400, height: 300))
        XCTAssertEqual(sq.canvas.width, sq.canvas.height)
        XCTAssertEqual(sq.picture.size, CGSize(width: 400, height: 300))
        XCTAssertEqual(sq.picture.midX, sq.canvas.width / 2, accuracy: 1)
        on.aspect = .wide
        XCTAssertEqual(on.layout(for: CGSize(width: 400, height: 300)).canvas.width / on.layout(for: CGSize(width: 400, height: 300)).canvas.height, 16.0 / 9, accuracy: 0.02)
    }

    func testRenderingPresentationsAndCropsMakeTheRightSizes() throws {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 100, pixelsHigh: 50, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let image = try XCTUnwrap(rep.cgImage)
        var style = CaptureBeautify(); style.background = .sunset; style.padding = 0.2
        let styled = try XCTUnwrap(CaptureRenderer.beautified(image, style))
        XCTAssertEqual(styled.width, 120); XCTAssertEqual(styled.height, 70)
        XCTAssertTrue(CaptureRenderer.beautified(image, CaptureBeautify()) === image || CaptureRenderer.beautified(image, CaptureBeautify())?.width == 100, "off leaves it alone")
        let cropped = CaptureRenderer.crop(image, to: CGRect(x: 0.25, y: 0.5, width: 0.5, height: 0.5))
        XCTAssertEqual(cropped.width, 50); XCTAssertEqual(cropped.height, 25)
        XCTAssertEqual(CaptureRenderer.crop(image, to: CGRect(x: 0, y: 0, width: 0.001, height: 0.001)).width, 100, "a speck is not a crop")
    }

    func testEveryKindOfMarkDrawsWithoutChangingTheSize() throws {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 200, pixelsHigh: 120, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let image = try XCTUnwrap(rep.cgImage)
        let a = CGPoint(x: 0.2, y: 0.2), b = CGPoint(x: 0.7, y: 0.6)
        let marks: [Annotation] = [Annotation(kind: .box, start: a, end: b), Annotation(kind: .ellipse, start: a, end: b), Annotation(kind: .line, start: a, end: b),
                                   Annotation(kind: .arrow, start: a, end: b), Annotation(kind: .number(3), start: a, end: a), Annotation(kind: .text("hi"), start: a, end: a),
                                   Annotation(kind: .pen, start: a, end: b, points: [a, CGPoint(x: 0.4, y: 0.5), b]), Annotation(kind: .blur, start: a, end: b), Annotation(kind: .hide, start: a, end: b, color: .black)]
        let out = try XCTUnwrap(CaptureRenderer.render(image, annotations: marks))
        XCTAssertEqual(out.width, 200); XCTAssertEqual(out.height, 120)
    }

    // MARK: Projects

    func testAProjectKeepsEveryMarkAndComesBackTheSame() throws {
        var style = CaptureBeautify(); style.background = .forest
        let marks = [Annotation(kind: .number(2), start: CGPoint(x: 0.1, y: 0.2), end: CGPoint(x: 0.1, y: 0.2), color: .blue),
                     Annotation(kind: .pen, start: CGPoint(x: 0.1, y: 0.1), end: CGPoint(x: 0.5, y: 0.5), color: .green, points: [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.3, y: 0.2), CGPoint(x: 0.5, y: 0.5)]),
                     Annotation(kind: .text("note"), start: CGPoint(x: 0.4, y: 0.4), end: CGPoint(x: 0.4, y: 0.4), color: .red)]
        let project = CaptureProject(image: Data([1, 2, 3]), marks: marks.map(\.mark), beautify: style, crop: [0.1, 0.1, 0.5, 0.5])
        let back = try XCTUnwrap(CaptureProject.decode(try XCTUnwrap(project.encoded())))
        XCTAssertEqual(back.marks, project.marks)
        XCTAssertEqual(back.beautify.background, .forest)
        XCTAssertEqual(back.crop, [0.1, 0.1, 0.5, 0.5])
        let restored = back.marks.compactMap(Annotation.init(mark:))
        XCTAssertEqual(restored.count, 3)
        XCTAssertEqual(restored[1].points.count, 3)
        if case .number(let n) = restored[0].kind { XCTAssertEqual(n, 2) } else { XCTFail("the step number is kept") }
        XCTAssertEqual(CaptureProject.nextStepNumber(after: project.marks), 3)
    }

    func testBadProjectsAreRefusedAndOutOfRangeValuesAreBroughtIn() throws {
        XCTAssertNil(CaptureProject.decode(Data("not json".utf8)))
        XCTAssertNil(CaptureProject.decode(try XCTUnwrap(CaptureProject(version: 99, image: Data([1])).encoded())), "from a newer version")
        XCTAssertNil(CaptureProject.decode(try XCTUnwrap(CaptureProject(image: Data()).encoded())), "no picture")
        let wild = CaptureProject(image: Data([1]), marks: [.init(kind: "box", text: nil, number: nil, points: [[-5, 9], [2, 0.5]], color: "red")], beautify: CaptureBeautify(background: .ocean, padding: 9, corners: 9), crop: [0, 0, 0, 0])
        let clean = try XCTUnwrap(CaptureProject.decode(try XCTUnwrap(wild.encoded())))
        XCTAssertEqual(clean.marks[0].points, [[0, 1], [1, 0.5]])
        XCTAssertEqual(clean.beautify.padding, 0.5); XCTAssertEqual(clean.beautify.corners, 0.1)
        XCTAssertNil(clean.crop)
        XCTAssertNil(Annotation(mark: .init(kind: "mystery", text: nil, number: nil, points: [[0, 0], [1, 1]], color: "red")))
    }

    // MARK: Privacy

    func testPasswordManagersAreNeverCapturedAndCaseDoesNotMatter() {
        XCTAssertTrue(CaptureExclusions.isExcluded("com.1password.1password", list: CaptureExclusions.defaults))
        XCTAssertTrue(CaptureExclusions.isExcluded("COM.BITWARDEN.DESKTOP", list: CaptureExclusions.defaults))
        XCTAssertFalse(CaptureExclusions.isExcluded("com.apple.Safari", list: CaptureExclusions.defaults))
        XCTAssertFalse(CaptureExclusions.isExcluded(nil, list: CaptureExclusions.defaults))
        XCTAssertFalse(CaptureExclusions.isExcluded("", list: [""]))
    }

    func testRedactionNowCoversKnownKeyShapesAndCardNumbers() {
        func covered(_ text: String) -> Bool { !Redaction.sensitiveRanges(in: text).isEmpty }
        XCTAssertTrue(covered("key AKIAIOSFODNN7EXAMPLE here"))
        XCTAssertTrue(covered("token ghp_" + String(repeating: "a1B2", count: 9)))
        XCTAssertTrue(covered("card 4242 4242 4242 4242 ok"))
        XCTAssertFalse(covered("just ordinary words in a sentence"))
        XCTAssertFalse(covered("version 1.2.3 released"))
    }

    func testNewTextCommandsExistAndEveryCommandNameIsUnique() {
        let names = CaptureSettings.commands.map(\.command)
        XCTAssertEqual(Set(names).count, names.count)
        for name in ["capture.text.joined", "capture.text.markdown", "capture.table"] { XCTAssertTrue(names.contains(name), name) }
    }
}
