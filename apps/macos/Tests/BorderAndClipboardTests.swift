import XCTest
import CoreGraphics
import AppKit
@testable import Kriya

final class BorderTests: XCTestCase {
    private func solid(_ width: Int, _ height: Int, red: CGFloat = 0.2, green: CGFloat = 0.6, blue: CGFloat = 0.9) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    /// RGBA of one pixel, counted from the top left of the picture.
    private func pixel(_ image: CGImage, x: Int, y: Int) -> [Int] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { raw in
            let c = CGContext(data: raw.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            c.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        let i = (y * image.width + x) * 4
        return [Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]), Int(bytes[i + 3])]
    }

    private func borderOnly(_ width: Double, color: CodableColor = CodableColor(red: 1, green: 0, blue: 0)) -> CaptureBeautify {
        var style = CaptureBeautify(background: .none, padding: 0, corners: 0, shadow: false)
        style.borderEnabled = true
        style.borderWidth = width
        style.borderColor = color
        return style
    }

    // MARK: The settings

    func testTheBorderIsOffByDefaultWithAOnePixelSoftDarkLine() {
        let style = CaptureBeautify()
        XCTAssertFalse(style.borderEnabled)
        XCTAssertEqual(style.borderWidth, 1)
        XCTAssertEqual(style.borderColor, CodableColor(red: 0, green: 0, blue: 0, alpha: 0.28))
        XCTAssertFalse(style.needsCanvas)
        XCTAssertEqual(style.border.reserved, 0)
    }

    func testTheBorderAndItsColourAreSavedAndOldStylesGetTheDefaults() throws {
        var style = CaptureBeautify(background: .ocean)
        style.borderEnabled = true
        style.borderWidth = 6
        style.borderColor = CodableColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 0.4)
        let back = try JSONDecoder().decode(CaptureBeautify.self, from: JSONEncoder().encode(style))
        XCTAssertEqual(back, style)
        let old = try JSONDecoder().decode(CaptureBeautify.self, from: Data(#"{"background":"ocean"}"#.utf8))
        XCTAssertFalse(old.borderEnabled)
    }

    func testAColourIsKeptInRangeAndADamagedOneLoadsAsTheDefault() throws {
        let c = CodableColor(red: -3, green: 7, blue: .nan, alpha: 2)
        XCTAssertEqual([c.red, c.green, c.blue, c.alpha], [0, 1, 0, 1])
        XCTAssertEqual(try JSONDecoder().decode(CodableColor.self, from: Data(#"{"red":"x","green":0.5}"#.utf8)), CodableColor(red: 0, green: 0.5, blue: 0, alpha: 0.28))
        XCTAssertEqual(try JSONDecoder().decode(CodableColor.self, from: Data("{}".utf8)), .border)
    }

    func testTheWidthIsHeldToWhatCanBeDrawn() {
        XCTAssertEqual(CaptureBorder(enabled: true, width: 0).drawnWidth, 0.5)
        XCTAssertEqual(CaptureBorder(enabled: true, width: 9_999).drawnWidth, 64)
        XCTAssertEqual(CaptureBorder(enabled: true, width: .nan).drawnWidth, 0.5)
        XCTAssertEqual(CaptureBorder(enabled: true, width: 2.2).reserved, 3, "whole pixels, rounded up")
        XCTAssertEqual(CaptureBorder(enabled: false, width: 40).reserved, 0)
    }

    // MARK: Room for the border

    func testTheCanvasAlwaysHasRoomForTheBorderOnEverySide() {
        let size = CGSize(width: 200, height: 100)
        for width in [1.0, 4.0, 10.0, 33.0] {
            var style = borderOnly(width)
            XCTAssertEqual(style.layout(for: size).canvas, CGSize(width: 200 + 2 * width.rounded(.up), height: 100 + 2 * width.rounded(.up)), "no backdrop: the picture and its border")
            style.background = .ocean
            style.padding = 0
            let withBackdrop = style.layout(for: size)
            XCTAssertGreaterThanOrEqual(withBackdrop.picture.minX, width.rounded(.up), "room on the left, even with no padding chosen")
            XCTAssertGreaterThanOrEqual(withBackdrop.canvas.width - withBackdrop.picture.maxX, width.rounded(.up))
            XCTAssertGreaterThanOrEqual(withBackdrop.picture.minY, width.rounded(.up))
            XCTAssertGreaterThanOrEqual(withBackdrop.canvas.height - withBackdrop.picture.maxY, width.rounded(.up))
        }
    }

    func testPaddingWiderThanTheBorderIsKept() {
        var style = CaptureBeautify(background: .ocean, padding: 0.1)
        style.borderEnabled = true
        style.borderWidth = 2
        let plain = CaptureBeautify(background: .ocean, padding: 0.1)
        XCTAssertEqual(style.layout(for: CGSize(width: 300, height: 200)).canvas, plain.layout(for: CGSize(width: 300, height: 200)).canvas)
    }

    func testTheLayoutOfAStyleWithNoBorderIsWhatItWas() {
        let size = CGSize(width: 300, height: 200)
        XCTAssertEqual(CaptureBeautify().layout(for: size).canvas, size)
        XCTAssertEqual(CaptureBeautify(background: .ocean).layout(for: size).picture.origin, CGPoint(x: 16, y: 16))
    }

    // MARK: Drawing it

    func testABorderAloneGrowsThePictureByItsWidthAndTouchesNoPictureCorner() throws {
        let picture = solid(20, 10, red: 0, green: 1, blue: 0)
        let out = try XCTUnwrap(CaptureRenderer.beautified(picture, borderOnly(3)))
        XCTAssertEqual(out.width, 26)
        XCTAssertEqual(out.height, 16)
        XCTAssertEqual(pixel(out, x: 0, y: 8), [255, 0, 0, 255], "the border at the very edge of the canvas: not clipped")
        XCTAssertEqual(pixel(out, x: 25, y: 8), [255, 0, 0, 255])
        XCTAssertEqual(pixel(out, x: 12, y: 0), [255, 0, 0, 255])
        XCTAssertEqual(pixel(out, x: 12, y: 15), [255, 0, 0, 255])
        XCTAssertEqual(pixel(out, x: 3, y: 3), [0, 255, 0, 255], "the picture's own corner pixel is not covered")
        XCTAssertEqual(pixel(out, x: 22, y: 12), [0, 255, 0, 255])
        XCTAssertEqual(pixel(out, x: 13, y: 8), [0, 255, 0, 255])
    }

    func testTheBorderHasTheChosenColourAndOpacity() throws {
        let out = try XCTUnwrap(CaptureRenderer.beautified(solid(10, 10), borderOnly(2, color: CodableColor(red: 0, green: 0, blue: 1, alpha: 0.5))))
        let edge = pixel(out, x: 0, y: 5)
        XCTAssertEqual(edge[3], 128, accuracy: 3, "half opaque")
        XCTAssertEqual(edge[2], 128, accuracy: 3, "premultiplied blue at half opacity")
        XCTAssertEqual(edge[0], 0)
    }

    func testABorderOnABackdropSitsBetweenThePictureAndTheBackdrop() throws {
        var style = CaptureBeautify(background: .black, padding: 0.5, corners: 0, shadow: false)
        style.borderEnabled = true
        style.borderWidth = 2
        style.borderColor = CodableColor(red: 1, green: 1, blue: 1)
        let picture = solid(40, 40, red: 0, green: 0, blue: 1)
        let out = try XCTUnwrap(CaptureRenderer.beautified(picture, style))
        let origin = style.layout(for: CGSize(width: 40, height: 40)).picture.origin
        let x = Int(origin.x), y = Int(origin.y)
        XCTAssertEqual(pixel(out, x: x + 10, y: y + 10), [0, 0, 255, 255], "the picture")
        XCTAssertEqual(pixel(out, x: x - 1, y: y + 10), [255, 255, 255, 255], "the border, one pixel outside the picture")
        XCTAssertEqual(pixel(out, x: x - 2, y: y + 10), [255, 255, 255, 255])
        XCTAssertNotEqual(pixel(out, x: x - 4, y: y + 10), [255, 255, 255, 255], "beyond the width it is the backdrop")
    }

    func testNoBorderMeansNothingChangesForAPlainStyle() throws {
        let picture = solid(30, 20)
        let style = CaptureBeautify(background: .none)
        XCTAssertTrue(try XCTUnwrap(CaptureRenderer.beautified(picture, style)) === picture)
        let out = try XCTUnwrap(CaptureRenderer.beautified(picture, CaptureBeautify(background: .ocean)))
        XCTAssertEqual(out.width, 30 + 2 * 2, "8% of the shorter side, 20 pixels, is 2 (rounded)")
    }

    func testTheOriginalPictureIsNotChangedByDrawingABorder() throws {
        let picture = solid(30, 20)
        _ = try XCTUnwrap(CaptureRenderer.beautified(picture, borderOnly(5)))
        XCTAssertEqual(picture.width, 30)
        XCTAssertEqual(picture.height, 20)
        XCTAssertEqual(pixel(picture, x: 0, y: 0), [51, 153, 230, 255])
    }

    func testTheSameBorderSettingServesPlainScreenshots() {
        var policy = OutputPolicy()
        XCTAssertFalse(policy.border.enabled)
        XCTAssertTrue(policy.isIdentity)
        policy.border = CaptureBorder(enabled: true, width: 2, color: .white)
        XCTAssertFalse(policy.isIdentity)
        var style = CaptureBeautify(background: .ocean)
        style.border = policy.border
        XCTAssertTrue(style.borderEnabled)
        XCTAssertEqual(style.borderWidth, 2)
        XCTAssertEqual(style.borderColor, .white)
    }
}

final class ClipboardOutputTests: XCTestCase {
    private var board: NSPasteboard!
    private var folder: URL!

    override func setUpWithError() throws {
        board = NSPasteboard(name: NSPasteboard.Name("kriya-clip-\(UUID().uuidString)"))
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("kriya-clip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        board.releaseGlobally()
        try? FileManager.default.removeItem(at: folder)
    }

    private let png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
    private let tiff = Data([0x49, 0x49, 0x2A, 0x00, 4, 5])

    private func file() throws -> URL {
        let url = folder.appendingPathComponent("shot.png")
        try png.write(to: url)
        return url
    }

    // MARK: What each mode puts on the clipboard

    func testTheDefaultIsTheImageAsItHasAlwaysBeen() {
        XCTAssertEqual(OutputPolicy().clipboard, .image)
        XCTAssertEqual(ClipboardOutput.allCases, [.file, .image, .fileAndImage])
        XCTAssertEqual(ClipboardOutput.image.title, "Image (default)")
    }

    func testImageModeWritesPNGAndTIFFAndNoFile() throws {
        let outcome = ClipboardPlan.plan(.image, png: png, tiff: tiff, file: try file())
        XCTAssertNil(outcome.note)
        XCTAssertEqual(outcome.payload, ClipboardPayload(fileURL: nil, png: png, tiff: tiff), "a file that exists is not copied in image mode")
        XCTAssertTrue(ClipboardWriter.write(try XCTUnwrap(outcome.payload), to: board))
        XCTAssertEqual(board.data(forType: .png), png)
        XCTAssertEqual(board.data(forType: .tiff), tiff)
        XCTAssertNil(board.string(forType: .fileURL))
    }

    func testFileModeWritesTheFileURLAndNoImageData() throws {
        let url = try file()
        let outcome = ClipboardPlan.plan(.file, png: png, tiff: tiff, file: url)
        XCTAssertEqual(outcome.payload, ClipboardPayload(fileURL: url, png: nil, tiff: nil))
        XCTAssertTrue(ClipboardWriter.write(try XCTUnwrap(outcome.payload), to: board))
        let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        XCTAssertEqual(urls?.map(\.path), [url.path])
        XCTAssertNil(board.data(forType: .png))
        XCTAssertNil(board.data(forType: .tiff))
    }

    func testFileAndImageWritesBothOnOneItem() throws {
        let url = try file()
        let outcome = ClipboardPlan.plan(.fileAndImage, png: png, tiff: tiff, file: url)
        XCTAssertNil(outcome.note)
        XCTAssertTrue(ClipboardWriter.write(try XCTUnwrap(outcome.payload), to: board))
        XCTAssertEqual(board.data(forType: .png), png)
        XCTAssertEqual(board.data(forType: .tiff), tiff)
        XCTAssertEqual((board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])?.map(\.path), [url.path])
        XCTAssertEqual(board.pasteboardItems?.count, 1, "one item holding every form, so an app takes the one it prefers")
    }

    // MARK: A copy that cannot be made leaves the clipboard alone

    func testWithoutAFileTheFileModeWritesNothingAndSaysSo() {
        let outcome = ClipboardPlan.plan(.file, png: png, tiff: tiff, file: nil)
        XCTAssertNil(outcome.payload)
        XCTAssertEqual(outcome.note, "The picture could not be written to a file, so the clipboard was left as it was.")
    }

    func testAFailedCopyLeavesWhatWasOnTheClipboard() throws {
        board.clearContents()
        board.setString("what I copied before", forType: .string)
        let outcome = ClipboardPlan.plan(.file, png: png, tiff: tiff, file: nil)
        if let payload = outcome.payload { ClipboardWriter.write(payload, to: board) }
        XCTAssertEqual(board.string(forType: .string), "what I copied before")
        XCTAssertFalse(ClipboardWriter.write(ClipboardPayload(), to: board), "an empty payload writes nothing")
        XCTAssertEqual(board.string(forType: .string), "what I copied before", "and does not clear it either")
    }

    func testImageModeWithNoPictureDataWritesNothing() {
        let outcome = ClipboardPlan.plan(.image, png: nil, tiff: nil, file: nil)
        XCTAssertNil(outcome.payload)
        XCTAssertNotNil(outcome.note)
    }

    func testFileAndImageWithOnlyOnePartWritesThatPartAndSaysSo() throws {
        let url = try file()
        let onlyFile = ClipboardPlan.plan(.fileAndImage, png: nil, tiff: nil, file: url)
        XCTAssertEqual(onlyFile.payload, ClipboardPayload(fileURL: url, png: nil, tiff: nil))
        XCTAssertEqual(onlyFile.note, "Only the file was copied: the picture could not be prepared.")
        let onlyImage = ClipboardPlan.plan(.fileAndImage, png: png, tiff: tiff, file: nil)
        XCTAssertEqual(onlyImage.payload, ClipboardPayload(fileURL: nil, png: png, tiff: tiff))
        XCTAssertEqual(onlyImage.note, "Only the image was copied: the file could not be written.")
        let nothing = ClipboardPlan.plan(.fileAndImage, png: nil, tiff: nil, file: nil)
        XCTAssertNil(nothing.payload)
        XCTAssertEqual(nothing.note, "Nothing could be prepared to copy, so the clipboard was left as it was.")
    }

    func testTheNewCopyReplacesTheOldOnlyWhenThereIsOne() throws {
        board.clearContents()
        board.setString("old text", forType: .string)
        ClipboardWriter.write(ClipboardPayload(fileURL: nil, png: png, tiff: tiff), to: board)
        XCTAssertNil(board.string(forType: .string), "replaced by the new copy")
        XCTAssertEqual(board.data(forType: .png), png)
    }

    // MARK: The service

    private func picture() -> CGImage {
        let context = CGContext(data: nil, width: 6, height: 6, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 6, height: 6))
        return context.makeImage()!
    }

    private func service() -> ScreenCaptureService {
        let s = ScreenCaptureService(settings: CaptureSettingsStore(defaults: UserDefaults(suiteName: "kriya-clipboard-\(UUID().uuidString)")!))
        s.pasteboard = board
        return s
    }

    func testTheServiceCopiesTheSavedFileInFileMode() throws {
        let url = try file()
        XCTAssertNil(service().copyToClipboard(picture(), mode: .file, savedFile: url))
        XCTAssertEqual((board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])?.map(\.path), [url.path])
    }

    func testTheServiceWritesAFileJustForTheCopyWhenNothingWasSaved() throws {
        XCTAssertNil(service().copyToClipboard(picture(), mode: .file, savedFile: nil))
        let url = try XCTUnwrap((board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])?.first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(url.path.contains("kriya-clipboard"))
        try? FileManager.default.removeItem(at: url)
    }

    func testTheServiceUsesAFreshFileWhenTheSavedOneIsGone() throws {
        let gone = folder.appendingPathComponent("moved.png")
        XCTAssertNil(service().copyToClipboard(picture(), mode: .fileAndImage, savedFile: gone))
        let url = try XCTUnwrap((board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])?.first)
        XCTAssertNotEqual(url.path, gone.path)
        XCTAssertNotNil(board.data(forType: .png))
        try? FileManager.default.removeItem(at: url)
    }

    func testTheServicesImageModeIsUnchanged() {
        XCTAssertNil(service().copyToClipboard(picture(), mode: .image, savedFile: nil))
        XCTAssertNotNil(board.data(forType: .png))
        XCTAssertNotNil(board.data(forType: .tiff))
        XCTAssertNil(board.string(forType: .fileURL))
    }

    func testTheModeIsKeptWithTheOutputSettings() throws {
        var policy = CaptureDeliveryPolicy()
        policy.output.clipboard = .fileAndImage
        let back = try JSONDecoder().decode(CaptureDeliveryPolicy.self, from: JSONEncoder().encode(policy))
        XCTAssertEqual(back.output.clipboard, .fileAndImage)
        let unknown = try JSONDecoder().decode(CaptureDeliveryPolicy.self, from: Data(#"{"output":{"clipboard":"smoke-signal"}}"#.utf8))
        XCTAssertEqual(unknown.output.clipboard, .image, "a mode from a later version is the default, not a crash")
    }

    func testTemporaryCopyFilesAreCleanedUp() throws {
        let first = try XCTUnwrap(ClipboardWriter.temporaryFile(png: png, now: Date(timeIntervalSinceNow: -3_600)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        // An hour later a new file is written, and the old one goes.
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3_600)], ofItemAtPath: first.path)
        let second = try XCTUnwrap(ClipboardWriter.temporaryFile(png: png))
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
        XCTAssertNil(ClipboardWriter.temporaryFile(png: nil))
        try? FileManager.default.removeItem(at: second)
    }
}
