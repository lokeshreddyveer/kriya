import XCTest
import CoreGraphics
import ImageIO
@testable import Kriya

final class SRGBConversionTests: XCTestCase {
    private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    private let displayP3 = CGColorSpace(name: CGColorSpace.displayP3)!

    /// A small solid picture in a wide-gamut colour space.
    private func wide(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, size: Int = 6) -> CGImage {
        let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: displayP3, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(colorSpace: displayP3, components: [r, g, b, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        return context.makeImage()!
    }

    /// The colour of a solid picture as numbers in the given colour space.
    private func sample(_ image: CGImage, in space: CGColorSpace) -> [Int] {
        var bytes = [UInt8](repeating: 0, count: 4)
        bytes.withUnsafeMutableBytes { raw in
            let context = CGContext(data: raw.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return bytes.prefix(3).map(Int.init)
    }

    private func decode(_ data: Data) -> CGImage? {
        CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
    }

    private func isSRGB(_ image: CGImage) -> Bool { (image.colorSpace?.name as String?) == (CGColorSpace.sRGB as String) }

    private func assertClose(_ a: [Int], _ b: [Int], within tolerance: Int, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.count, b.count, file: file, line: line)
        for (x, y) in zip(a, b) { XCTAssertLessThanOrEqual(abs(x - y), tolerance, "\(a) vs \(b) \(message)", file: file, line: line) }
    }

    // MARK: Wide-gamut input

    func testAWideGamutPictureComesBackInSRGB() {
        let input = wide(0.8, 0.4, 0.2)
        XCTAssertFalse(isSRGB(input), "the test picture is wide gamut")
        let out = CaptureRenderer.srgb(input)
        XCTAssertTrue(isSRGB(out))
        XCTAssertEqual(out.width, input.width)
        XCTAssertEqual(out.height, input.height)
    }

    func testTheColoursAreConvertedNotJustRelabelled() {
        let input = wide(0.8, 0.4, 0.2)
        let out = CaptureRenderer.srgb(input)
        let raw = [204, 102, 51]   // the numbers the picture holds in Display P3
        let inSRGB = sample(out, in: sRGB)
        XCTAssertGreaterThanOrEqual(zip(inSRGB, raw).map { abs($0 - $1) }.max() ?? 0, 4, "the numbers changed, because the colour space did")
        // It is the same colour: drawn back into Display P3 it is what it was.
        assertClose(sample(out, in: displayP3), raw, within: 3, "round trip")
        // And the numbers are what colour management gives for the original in sRGB.
        assertClose(inSRGB, sample(input, in: sRGB), within: 1)
    }

    func testAColourOutsideSRGBIsHeldInsideIt() {
        let out = CaptureRenderer.srgb(wide(0, 1, 0))
        for value in sample(out, in: sRGB) { XCTAssertTrue((0...255).contains(value)) }
        XCTAssertTrue(isSRGB(out))
    }

    // MARK: Output and the original

    func testThePictureGivenIsLeftUntouched() {
        let input = wide(0.8, 0.4, 0.2)
        let before = sample(input, in: displayP3)
        let out = CaptureRenderer.srgb(input)
        XCTAssertFalse(out === input, "a new picture was made")
        XCTAssertEqual((input.colorSpace?.name as String?), CGColorSpace.displayP3 as String)
        XCTAssertEqual(sample(input, in: displayP3), before)
    }

    func testAPictureAlreadyInSRGBIsReturnedAsItIs() {
        let once = CaptureRenderer.srgb(wide(0.3, 0.5, 0.7))
        XCTAssertTrue(CaptureRenderer.srgb(once) === once)
    }

    func testTransparencyIsKept() {
        let context = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0, space: displayP3, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(colorSpace: displayP3, components: [0.5, 0.2, 0.9, 0.5])!)
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        let out = CaptureRenderer.srgb(context.makeImage()!)
        XCTAssertNotEqual(out.alphaInfo, .none)
        XCTAssertNotEqual(out.alphaInfo, .noneSkipLast)
    }

    // MARK: Every format

    private func expected(_ input: CGImage) -> [Int] { sample(CaptureRenderer.srgb(input), in: sRGB) }

    func testPNGAndTIFFAreWrittenFromTheConvertedPicture() throws {
        let input = wide(0.8, 0.4, 0.2)
        for format in [CaptureFormat.png, .tiff] {
            let data = try XCTUnwrap(input.data(as: format, convertToSRGB: true), "\(format)")
            let back = try XCTUnwrap(decode(data), "\(format)")
            assertClose(sample(back, in: sRGB), expected(input), within: 2, "\(format)")
        }
    }

    func testJPEGIsWrittenFromTheConvertedPicture() throws {
        let input = wide(0.8, 0.4, 0.2, size: 16)
        let data = try XCTUnwrap(input.data(as: .jpeg, convertToSRGB: true))
        assertClose(sample(try XCTUnwrap(decode(data)), in: sRGB), expected(input), within: 10, "jpeg is lossy")
    }

    func testHEICAndPDFAreWrittenToo() throws {
        let input = wide(0.8, 0.4, 0.2, size: 32)
        XCTAssertNotNil(input.data(as: .heic, convertToSRGB: true))
        let pdf = try XCTUnwrap(input.data(as: .pdf, convertToSRGB: true))
        XCTAssertEqual(String(decoding: pdf.prefix(4), as: UTF8.self), "%PDF")
    }

    func testTheFlagChangesWhatIsWrittenAndOffLeavesItAsItWas() throws {
        let input = wide(0.8, 0.4, 0.2)
        let off = try XCTUnwrap(input.data(as: .png))
        let on = try XCTUnwrap(input.data(as: .png, convertToSRGB: true))
        XCTAssertNotEqual(off, on)
        XCTAssertEqual(off, input.data(as: .png, convertToSRGB: false), "off is the default")
        XCTAssertEqual(off, input.pngData)
    }

    func testAnSRGBPictureWrittenWithTheFlagIsTheSameColours() throws {
        let plain = CaptureRenderer.srgb(wide(0.3, 0.5, 0.7))
        let back = try XCTUnwrap(decode(try XCTUnwrap(plain.data(as: .png, convertToSRGB: true))))
        assertClose(sample(back, in: sRGB), sample(plain, in: sRGB), within: 1)
    }

    // MARK: The setting

    func testTheSwitchIsOffByDefaultAndKept() throws {
        XCTAssertFalse(OutputPolicy().convertToSRGB)
        var policy = CaptureDeliveryPolicy()
        policy.output.convertToSRGB = true
        let back = try JSONDecoder().decode(CaptureDeliveryPolicy.self, from: JSONEncoder().encode(policy))
        XCTAssertTrue(back.output.convertToSRGB)
        XCTAssertFalse(try JSONDecoder().decode(CaptureDeliveryPolicy.self, from: Data("{}".utf8)).output.convertToSRGB)
    }
}
