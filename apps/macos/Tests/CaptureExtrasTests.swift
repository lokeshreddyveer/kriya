import XCTest
import CoreImage
@testable import Kriya

final class CaptureExtrasTests: XCTestCase {
    func testOverlapFindsTheRepeatedRows() {
        let page: [UInt64] = Array(1...100)
        let next: [UInt64] = Array(61...160)   // scrolled by 60 rows, so 40 repeat
        XCTAssertEqual(ScrollStitch.overlap(rows: page, next: next), 40)
    }

    func testNoOverlapAndTooSmallOverlapAreRejected() {
        XCTAssertEqual(ScrollStitch.overlap(rows: Array(1...100), next: Array(500...600)), 0)
        let tiny: [UInt64] = Array(1...100)
        XCTAssertEqual(ScrollStitch.overlap(rows: tiny, next: Array(95...150)), 0, "six matching rows could be a coincidence")
    }

    func testAPageThatDidNotMoveIsAFullOverlap() {
        let page: [UInt64] = Array(1...80)
        XCTAssertEqual(ScrollStitch.overlap(rows: page, next: page), 80)
    }

    func testJoinStacksStripsWithoutTheRepeatedRows() throws {
        func strip(_ height: Int) -> CGImage {
            let c = CGContext(data: nil, width: 4, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            c.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 4, height: height))
            return c.makeImage()!
        }
        let joined = try XCTUnwrap(ScrollingCapture.join([(strip(100), 0), (strip(100), 40), (strip(100), 40)]))
        XCTAssertEqual(joined.height, 100 + 60 + 60)
        XCTAssertEqual(joined.width, 4)
    }

    func testRowHashesAreEqualForEqualPictures() throws {
        func solid(_ r: CGFloat) -> CGImage {
            let c = CGContext(data: nil, width: 20, height: 5, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            c.setFillColor(CGColor(red: r, green: 0, blue: 0, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 20, height: 5))
            return c.makeImage()!
        }
        XCTAssertEqual(ScrollingCapture.rowHashes(solid(1)), ScrollingCapture.rowHashes(solid(1)))
        XCTAssertNotEqual(ScrollingCapture.rowHashes(solid(1)), ScrollingCapture.rowHashes(solid(0.5)))
    }

    func testQRCodeRoundTrip() throws {
        let filter = CIFilter(name: "CIQRCodeGenerator")!
        filter.setValue(Data("https://example.com/kriya".utf8), forKey: "inputMessage")
        let small = try XCTUnwrap(filter.outputImage)
        let scaled = small.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let image = try XCTUnwrap(CIContext().createCGImage(scaled, from: scaled.extent))
        XCTAssertEqual(QRCodeReader.read(image), ["https://example.com/kriya"])
    }

    func testGIFWritesAFile() throws {
        let c = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let frame = c.makeImage()!
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kriya-\(UUID().uuidString).gif")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(GIFExporter.write(frames: [frame, frame], delay: 0.1, to: url))
        XCTAssertGreaterThan((try? Data(contentsOf: url).count) ?? 0, 20)
        XCTAssertFalse(GIFExporter.write(frames: [], delay: 0.1, to: url))
    }
}
