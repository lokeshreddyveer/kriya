import XCTest
@testable import Kriya

final class PointerCompensationTests: XCTestCase {
    private func comp(cpi: Int? = nil, reference: Int? = nil, enabled: Bool = true) -> DeviceCompensation {
        var d = DeviceCompensation(); d.enabled = enabled; d.cpi = cpi; d.referenceCPI = reference; return d
    }

    func testPollingRatePrefersMeasuredThenDeclaredThenAGuess() {
        XCTAssertEqual(PollingRateInfo.resolve(declaredHz: 1000, measuredHz: 500, connection: .wired), PollingRateInfo(hz: 500, source: .measured))
        XCTAssertEqual(PollingRateInfo.resolve(declaredHz: 1000, measuredHz: nil, connection: .wired), PollingRateInfo(hz: 1000, source: .declared))
        let wired = PollingRateInfo.resolve(declaredHz: nil, measuredHz: nil, connection: .wired)
        XCTAssertEqual(wired, PollingRateInfo(hz: 125, source: .assumed))
        XCTAssertTrue(wired.isEstimated)
        XCTAssertEqual(PollingRateInfo.resolve(declaredHz: nil, measuredHz: nil, connection: .wireless).hz, 90)
    }

    func testOnlyADeclaredRateIsNotAnEstimate() {
        XCTAssertFalse(PollingRateSource.declared.isEstimated)
        XCTAssertTrue(PollingRateSource.measured.isEstimated)
        XCTAssertTrue(PollingRateInfo(hz: 1000, source: .measured).text.contains("measured"))
    }

    func testThePollingRateIsNotPartOfTheSum() {
        // The result depends on the two resolutions typed in and nothing else.
        let r = PointerCompensation.result(for: comp(cpi: 3200, reference: 800))
        XCTAssertEqual(r?.raw ?? 0, 0.5, accuracy: 0.0001)
    }

    func testNoReferenceMeansNoAdjustment() {
        XCTAssertNil(PointerCompensation.result(for: comp(cpi: 3200, reference: nil)))
        XCTAssertEqual(PointerCompensation.adjusted(2.0, for: comp(cpi: 3200, reference: nil)), 2.0)
        XCTAssertNil(PointerCompensation.result(for: comp(cpi: nil, reference: 800)))
        XCTAssertNil(PointerCompensation.result(for: comp(cpi: 3200, reference: 800, enabled: false)))
    }

    func testTheFormulaAndNumbersAreShown() {
        let r = PointerCompensation.result(for: comp(cpi: 1600, reference: 400))!
        XCTAssertEqual(r.multiplier, 0.5, accuracy: 0.0001)
        XCTAssertEqual(r.cap, .none)
        XCTAssertTrue(r.formula.contains("√(400 ÷ 1600)"))
        XCTAssertTrue(PointerCompensation.explanation(comp(cpi: 1600, reference: 400)).contains("0.500"))
        XCTAssertTrue(PointerCompensation.label.contains("does not change the mouse’s CPI"))
    }

    func testTheCapIsReportedWhenItIsActive() {
        let low = PointerCompensation.result(for: comp(cpi: 32_000, reference: 100))!
        XCTAssertEqual(low.cap, .atLeast)
        XCTAssertEqual(low.multiplier, PointerCompensation.multiplierRange.lowerBound)
        XCTAssertLessThan(low.raw, low.multiplier)
        let high = PointerCompensation.result(for: comp(cpi: 100, reference: 32_000))!
        XCTAssertEqual(high.cap, .atMost)
        XCTAssertEqual(high.multiplier, PointerCompensation.multiplierRange.upperBound)
        XCTAssertTrue(PointerCompensation.explanation(comp(cpi: 100, reference: 32_000)).contains("highest allowed"))
        XCTAssertEqual(PointerCompensation.result(for: comp(cpi: 800, reference: 800))?.cap, PointerCompensation.Cap.none)
    }

    func testOutOfRangeResolutionsAreRefused() {
        XCTAssertNil(PointerCompensation.result(for: comp(cpi: 5, reference: 800)))
        XCTAssertNil(PointerCompensation.result(for: comp(cpi: 800, reference: 99_999)))
        XCTAssertTrue(PointerCompensation.explanation(comp(cpi: 5, reference: 800)).contains("expected"))
    }

    func testAdjustedStaysOnTheSystemScaleAndLeavesOffAlone() {
        let c = comp(cpi: 3200, reference: 800)
        XCTAssertEqual(PointerCompensation.adjusted(2.0, for: c), 1.0, accuracy: 0.0001)
        XCTAssertEqual(PointerCompensation.adjusted(-1, for: c), -1, "acceleration off is kept")
        XCTAssertLessThanOrEqual(PointerCompensation.adjusted(3.0, for: comp(cpi: 100, reference: 32_000)), 3.0)
        XCTAssertTrue(PointerCompensation.adjusted(.nan, for: c).isNaN)
    }

    func testSettingsRoundTripResetAndBadData() {
        let defaults = UserDefaults(suiteName: "comp.\(UUID().uuidString)")!
        let store = PointerCompensationStore(defaults: defaults)
        XCTAssertTrue(store.settings.devices.isEmpty)
        var s = PointerCompensationSettings()
        s["a"] = comp(cpi: 1600, reference: 800)
        s["b"] = DeviceCompensation()
        store.settings = s
        XCTAssertEqual(store.settings.devices.count, 1)
        XCTAssertEqual(store.settings["a"].referenceCPI, 800)
        // Reset is writing the default back, which removes the device.
        var after = store.settings
        after["a"] = DeviceCompensation()
        store.settings = after
        XCTAssertTrue(store.settings.devices.isEmpty)
        defaults.set(Data("bad".utf8), forKey: PointerCompensationStore.key)
        XCTAssertTrue(store.settings.devices.isEmpty)
    }

    func testExplanationWalksThroughWhatIsMissing() {
        XCTAssertTrue(PointerCompensation.explanation(comp(enabled: false)).hasPrefix("Off"))
        XCTAssertTrue(PointerCompensation.explanation(comp()).contains("resolution"))
        XCTAssertTrue(PointerCompensation.explanation(comp(cpi: 800)).contains("match"))
    }
}
