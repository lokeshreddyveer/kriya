import XCTest
import CoreGraphics
@testable import Kriya

final class RetinaOutputTests: XCTestCase {
    private func oneX() -> OutputPolicy { var o = OutputPolicy(); o.scale = .oneX; return o }

    private func picture(_ width: Int, _ height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    // MARK: The scale setting

    func testNativeIsTheDefaultAndNothingChanges() {
        let output = OutputPolicy()
        XCTAssertEqual(output.scale, .native)
        XCTAssertTrue(output.isIdentity)
        let pixels = CGSize(width: 2880, height: 1800)
        XCTAssertEqual(output.outputSize(pixels: pixels, backingScale: 2), pixels)
        XCTAssertEqual(OutputScale.allCases, [.native, .oneX])
        XCTAssertFalse(oneX().isIdentity)
    }

    func testOneXBringsARetinaPictureToItsSizeInPoints() {
        let output = oneX()
        XCTAssertEqual(output.outputSize(pixels: CGSize(width: 2880, height: 1800), backingScale: 2), CGSize(width: 1440, height: 900))
        XCTAssertEqual(output.outputSize(pixels: CGSize(width: 1000, height: 500), backingScale: 2), CGSize(width: 500, height: 250))
        XCTAssertEqual(output.outputSize(pixels: CGSize(width: 900, height: 600), backingScale: 3), CGSize(width: 300, height: 200))
    }

    func testAOneXScreenIsLeftAlone() {
        let pixels = CGSize(width: 1920, height: 1080)
        XCTAssertEqual(oneX().outputSize(pixels: pixels, backingScale: 1), pixels, "already one pixel to a point")
        XCTAssertEqual(oneX().outputSize(pixels: pixels, backingScale: 0.5), pixels, "a scale below 1 is not a screen")
    }

    func testTheShapeIsKeptWhenTheSizeDoesNotDivideEvenly() {
        let output = oneX()
        let sizes = [CGSize(width: 2881, height: 1801), CGSize(width: 1001, height: 333), CGSize(width: 333, height: 1001), CGSize(width: 7, height: 5), CGSize(width: 2, height: 2_000)]
        for pixels in sizes {
            let out = output.outputSize(pixels: pixels, backingScale: 2)
            let shape = pixels.width / pixels.height
            // The longer side is rounded; the other follows the exact shape, so it is within half a pixel of what the shape asks for.
            if pixels.width >= pixels.height {
                XCTAssertLessThanOrEqual(abs(out.height - out.width / shape), 0.5 + 1e-9, "\(pixels)")
            } else {
                XCTAssertLessThanOrEqual(abs(out.width - out.height * shape), 0.5 + 1e-9, "\(pixels)")
            }
            XCTAssertGreaterThanOrEqual(out.width, 1)
            XCTAssertGreaterThanOrEqual(out.height, 1)
        }
    }

    func testATinyPictureNeverShrinksToNothing() {
        XCTAssertEqual(oneX().outputSize(pixels: CGSize(width: 1, height: 1), backingScale: 2), CGSize(width: 1, height: 1))
        XCTAssertEqual(oneX().outputSize(pixels: CGSize(width: 1, height: 400), backingScale: 2), CGSize(width: 1, height: 200))
        XCTAssertEqual(oneX().outputSize(pixels: .zero, backingScale: 2), .zero)
    }

    // MARK: The picture is resized before it is written

    func testTheResizedPictureHasThePointDimensionsAndKeepsItsShape() {
        let out = CaptureRenderer.written(picture(2880, 1800), output: oneX(), backingScale: 2)
        XCTAssertEqual(out.width, 1440)
        XCTAssertEqual(out.height, 900)
        XCTAssertEqual(Double(out.width) / Double(out.height), 2880.0 / 1800.0, accuracy: 0.0001)
    }

    func testTheOriginalPictureIsNotChangedByResizing() {
        let input = picture(400, 300)
        _ = CaptureRenderer.written(input, output: oneX(), backingScale: 2)
        XCTAssertEqual(input.width, 400)
        XCTAssertEqual(input.height, 300)
    }

    func testAOneXScreenReturnsTheSamePictureRatherThanACopy() {
        let input = picture(400, 300)
        XCTAssertTrue(CaptureRenderer.written(input, output: oneX(), backingScale: 1) === input)
    }

    func testResizingKeepsTheColourSpaceAndTheColours() throws {
        let input = picture(40, 40)
        let out = CaptureRenderer.written(input, output: oneX(), backingScale: 2)
        XCTAssertEqual(out.width, 20)
        var pixel = [UInt8](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { raw in
            let c = CGContext(data: raw.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            c.draw(out, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        XCTAssertEqual(Int(pixel[0]), 51, accuracy: 3)
        XCTAssertEqual(Int(pixel[1]), 128, accuracy: 3)
        XCTAssertEqual(Int(pixel[2]), 204, accuracy: 3)
    }

    func testResizingAndSRGBTogetherGiveTheSmallerPictureInSRGB() {
        var output = oneX()
        output.convertToSRGB = true
        let out = CaptureRenderer.written(picture(200, 100), output: output, backingScale: 2)
        XCTAssertEqual(out.width, 100)
        XCTAssertEqual(out.height, 50)
        XCTAssertEqual(out.colorSpace?.name as String?, CGColorSpace.sRGB as String)
    }

    // MARK: The written scale

    func testAPictureKeptAtOneXIsNotARetinaPicture() {
        XCTAssertEqual(oneX().writtenScale(backingScale: 2), 1)
        XCTAssertEqual(OutputPolicy().writtenScale(backingScale: 2), 2)
        XCTAssertEqual(oneX().writtenScale(backingScale: 2, untouched: true), 2, "the original kept beside an edit is never resized")
        XCTAssertEqual(OutputPolicy().writtenScale(backingScale: 0.3), 1)
    }

    // MARK: The @2x name

    private func named(_ stem: String, _ output: OutputPolicy, scale: CGFloat, untouched: Bool = false) -> String {
        CaptureNaming.fileName(pattern: stem, date: Date(timeIntervalSince1970: 1_800_000_000), app: nil, mode: "capture", ext: "png",
                               suffix: { output.retinaSuffix(for: $0, backingScale: scale, untouched: untouched) })
    }

    private func suffixOn() -> OutputPolicy { var o = OutputPolicy(); o.includeRetinaSuffix = true; return o }

    func testTheSuffixIsOffByDefault() {
        XCTAssertFalse(OutputPolicy().includeRetinaSuffix)
        XCTAssertEqual(OutputPolicy().retinaSuffix(for: "shot", backingScale: 2), "")
        XCTAssertEqual(named("shot {time}", OutputPolicy(), scale: 2).hasSuffix("@2x.png"), false)
    }

    func testARetinaPictureAtNativeSizeGetsAtTwoXBeforeTheExtension() {
        let name = named("shot {n}", suffixOn(), scale: 2)
        XCTAssertEqual(name, "shot 1@2x.png")
        XCTAssertEqual(named("shot {n}", suffixOn(), scale: 3), "shot 1@3x.png")
    }

    func testNoSuffixOnAOneXScreen() {
        XCTAssertEqual(named("shot {n}", suffixOn(), scale: 1), "shot 1.png")
        XCTAssertEqual(named("shot {n}", suffixOn(), scale: 0.5), "shot 1.png", "an image scale that is not above 1")
    }

    func testNoSuffixWhenThePictureWasBroughtDownToOneX() {
        var output = suffixOn()
        output.scale = .oneX
        XCTAssertEqual(named("shot {n}", output, scale: 2), "shot 1.png", "it is not an @2x picture any more")
    }

    func testTheOriginalKeptBesideAnEditStillCountsAsNativeEvenAtOneX() {
        var output = suffixOn()
        output.scale = .oneX
        XCTAssertEqual(named("shot {n}", output, scale: 2, untouched: true), "shot 1@2x.png")
    }

    func testNoSecondSuffixWhenTheNameAlreadyHasOne() {
        XCTAssertEqual(named("icon@2x {n}", suffixOn(), scale: 2), "icon@2x 1.png")
        XCTAssertEqual(named("icon@3x {n}", suffixOn(), scale: 2), "icon@3x 1.png", "another scale suffix counts too")
        XCTAssertEqual(named("price @ 2x {n}", suffixOn(), scale: 2), "price @ 2x 1@2x.png", "only the real thing is recognised")
    }

    func testTheSuffixStaysAtTheEndWhenAClashAddsACounter() {
        let name = CaptureNaming.fileName(pattern: "shot {n}", date: Date(timeIntervalSince1970: 0), app: nil, mode: "capture", ext: "png",
                                          existing: { $0 == "shot 1@2x.png" }, suffix: { suffixOn().retinaSuffix(for: $0, backingScale: 2) })
        XCTAssertEqual(name, "shot 2@2x.png", "unique with the suffix on, and the suffix still last")
    }

    func testNamesAreUnchangedWhenNoSuffixIsGiven() {
        // The older callers pass no suffix, so every existing name is unchanged.
        XCTAssertEqual(CaptureNaming.fileName(pattern: "shot {n}", date: Date(), app: nil, mode: "m", ext: "png"), "shot 1.png")
    }

    func testTheSettingsAreKeptAndOlderOnesGetTheDefaults() throws {
        var policy = CaptureDeliveryPolicy()
        policy.output.scale = .oneX
        policy.output.includeRetinaSuffix = true
        let back = try JSONDecoder().decode(CaptureDeliveryPolicy.self, from: JSONEncoder().encode(policy))
        XCTAssertEqual(back.output.scale, .oneX)
        XCTAssertTrue(back.output.includeRetinaSuffix)
        let old = try JSONDecoder().decode(CaptureDeliveryPolicy.self, from: Data(#"{"output":{"convertToSRGB":true}}"#.utf8))
        XCTAssertEqual(old.output.scale, .native)
        XCTAssertFalse(old.output.includeRetinaSuffix)
    }
}
