import XCTest
@testable import Kriya

final class DeviceCapabilitiesTests: XCTestCase {
    private func element(_ page: Int, _ usage: Int, feature: Bool = false) -> HIDElementInfo {
        HIDElementInfo(usagePage: page, usage: usage, logicalMin: 0, logicalMax: 1, isFeature: feature)
    }

    private func mouse(buttons: Int, wheel: Bool = true, fine: Bool = false, pan: Bool = false, touch: Bool = false) -> HIDDeviceInfo {
        var info = HIDDeviceInfo()
        info.vendorID = 0x046D; info.productID = 0xC52B; info.manufacturer = "Logitech"; info.product = "USB Receiver"; info.transport = "USB"
        info.elements = [element(0x01, 0x30), element(0x01, 0x31)] + (1...max(buttons, 1)).map { element(0x09, $0) }.prefix(buttons)
        if wheel { info.elements.append(element(0x01, 0x38)) }
        if fine { info.elements.append(element(0x01, 0x48, feature: true)) }
        if pan { info.elements.append(element(0x0C, 0x238)) }
        if touch { info.elements.append(element(0x0D, 0x22)) }
        return info
    }

    func testButtonsAndIdentity() {
        let c = DeviceCapabilityAnalyzer.analyze(mouse(buttons: 5))
        XCTAssertEqual(c.buttonCount, 5)
        XCTAssertEqual(c.highestButton, 5)
        XCTAssertEqual(c.idText, "046D:C52B")
        XCTAssertEqual(c.manufacturer, "Logitech")
    }

    func testWheelKinds() {
        XCTAssertEqual(DeviceCapabilityAnalyzer.analyze(mouse(buttons: 3)).wheel, .notched)
        XCTAssertEqual(DeviceCapabilityAnalyzer.analyze(mouse(buttons: 3, fine: true)).wheel, .highResolution)
        XCTAssertEqual(DeviceCapabilityAnalyzer.analyze(mouse(buttons: 2, wheel: false)).wheel, .none)
        XCTAssertEqual(DeviceCapabilityAnalyzer.analyze(mouse(buttons: 1, wheel: false, touch: true)).wheel, .touch)
    }

    func testTiltIsTheSidewaysWheel() {
        XCTAssertTrue(DeviceCapabilityAnalyzer.analyze(mouse(buttons: 3, pan: true)).hasTilt)
        XCTAssertFalse(DeviceCapabilityAnalyzer.analyze(mouse(buttons: 3)).hasTilt)
    }

    func testFeatureElementsAreNotInputs() {
        var info = mouse(buttons: 2)
        info.elements.append(element(0x09, 9, feature: true))
        XCTAssertEqual(DeviceCapabilityAnalyzer.analyze(info).buttonCount, 2)
    }

    func testDeclaredRate() {
        var info = mouse(buttons: 2)
        info.reportIntervalMicroseconds = 1000
        XCTAssertEqual(DeviceCapabilityAnalyzer.analyze(info).declaredRateHz, 1000)
        info.reportIntervalMicroseconds = 0
        XCTAssertNil(DeviceCapabilityAnalyzer.analyze(info).declaredRateHz)
        info.reportIntervalMicroseconds = nil
        XCTAssertNil(DeviceCapabilityAnalyzer.analyze(info).declaredRateHz)
    }

    func testInterfacesAreDescribedTogether() {
        var a = mouse(buttons: 2, wheel: false)
        a.serial = nil
        var b = HIDDeviceInfo()
        b.serial = "ABC"; b.elements = [element(0x01, 0x38), element(0x0C, 0x238)]; b.reportIntervalMicroseconds = 1000
        a.merge(b)
        let c = DeviceCapabilityAnalyzer.analyze(a)
        XCTAssertEqual(c.serial, "ABC")
        XCTAssertTrue(c.hasVerticalWheel); XCTAssertTrue(c.hasTilt)
        XCTAssertEqual(c.declaredRateHz, 1000)
    }

    // MARK: Rate

    private func estimate(everyMs ms: Double, count: Int, jitterEvery: Int = 0) -> Int? {
        var e = PollingRateEstimator()
        var t: UInt64 = 1_000_000_000
        for i in 0..<count {
            e.record(nanoseconds: t)
            t += UInt64(ms * 1_000_000) + (jitterEvery > 0 && i % jitterEvery == 0 ? 3_000_000 : 0)
        }
        return e.estimate()
    }

    func testCommonRatesAreRecognised() {
        XCTAssertEqual(estimate(everyMs: 1, count: 300), 1000)
        XCTAssertEqual(estimate(everyMs: 8, count: 300), 125)
        XCTAssertEqual(estimate(everyMs: 2, count: 300), 500)
        XCTAssertEqual(estimate(everyMs: 0.125, count: 300), 8000)
    }

    func testAFewLateReportsDoNotChangeTheAnswer() {
        XCTAssertEqual(estimate(everyMs: 1, count: 400, jitterEvery: 7), 1000)
    }

    func testRestGapsAreIgnoredAndTooLittleMovementGivesNothing() {
        XCTAssertNil(estimate(everyMs: 1, count: 10))
        var e = PollingRateEstimator()
        var t: UInt64 = 0
        for _ in 0..<100 { e.record(nanoseconds: t); t += 500_000_000 }   // half a second apart: a mouse at rest
        XCTAssertNil(e.estimate())
    }

    func testSnapping() {
        XCTAssertEqual(PollingRateEstimator.snapped(985), 1000)
        XCTAssertEqual(PollingRateEstimator.snapped(333), 333)
        XCTAssertEqual(PollingRateEstimator.snapped(.nan), 0)
    }
}
