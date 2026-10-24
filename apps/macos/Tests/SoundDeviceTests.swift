import XCTest
@testable import Kriya

/// Choosing outputs as devices come and go, describing a device, and fitting headphone correction to ten bands.
final class SoundDeviceTests: XCTestCase {
    // MARK: Device priority

    private let order = ["desk", "airpods", "speakers"]

    func testWhenTheDeviceInUseGoesAwayTheBestOneLeftTakesOver() {
        let r = DevicePolicy.reaction(previous: ["desk", "airpods", "speakers"], now: ["airpods", "speakers"], current: "desk", priority: order, switchBack: false)
        XCTAssertEqual(r, DevicePolicy.Reaction(switchTo: "airpods", why: .inUseWentAway))
        let second = DevicePolicy.reaction(previous: ["airpods", "speakers"], now: ["speakers"], current: "airpods", priority: order, switchBack: false)
        XCTAssertEqual(second?.switchTo, "speakers")
        XCTAssertNil(DevicePolicy.reaction(previous: ["speakers", "hdmi"], now: ["hdmi"], current: "speakers", priority: order, switchBack: true), "none of what is left is ranked: macOS's choice stands")
    }

    func testABetterDeviceComingBackTakesOverOnlyIfAskedTo() {
        let on = DevicePolicy.reaction(previous: ["speakers"], now: ["speakers", "desk"], current: "speakers", priority: order, switchBack: true)
        XCTAssertEqual(on, DevicePolicy.Reaction(switchTo: "desk", why: .preferredReturned))
        XCTAssertNil(DevicePolicy.reaction(previous: ["speakers"], now: ["speakers", "desk"], current: "speakers", priority: order, switchBack: false))
        XCTAssertNil(DevicePolicy.reaction(previous: ["desk"], now: ["desk", "speakers"], current: "desk", priority: order, switchBack: true), "a worse one arriving changes nothing")
        let best = DevicePolicy.reaction(previous: ["speakers"], now: ["speakers", "airpods", "desk"], current: "speakers", priority: order, switchBack: true)
        XCTAssertEqual(best?.switchTo, "desk", "of two that arrive, the better one")
    }

    func testNothingHappensWhenTheDevicesDoNotChangeSoAHandChoiceStays() {
        XCTAssertNil(DevicePolicy.reaction(previous: ["desk", "speakers"], now: ["desk", "speakers"], current: "speakers", priority: order, switchBack: true))
        XCTAssertNil(DevicePolicy.reaction(previous: ["desk", "speakers"], now: ["desk", "speakers", "hdmi"], current: "speakers", priority: order, switchBack: true), "an unranked arrival")
    }

    func testTheListIsKeptInOrder() {
        XCTAssertEqual(DevicePolicy.adding("c", to: ["a", "b"]), ["a", "b", "c"])
        XCTAssertEqual(DevicePolicy.adding("a", to: ["a", "b"]), ["a", "b"])
        XCTAssertEqual(DevicePolicy.removing("a", from: ["a", "b"]), ["b"])
        XCTAssertEqual(DevicePolicy.moving("c", by: -1, in: ["a", "b", "c"]), ["a", "c", "b"])
        XCTAssertEqual(DevicePolicy.moving("a", by: -5, in: ["a", "b", "c"]), ["a", "b", "c"])
        XCTAssertEqual(DevicePolicy.moving("a", by: 9, in: ["a", "b", "c"]), ["b", "c", "a"])
        XCTAssertEqual(DevicePolicy.moving("z", by: 1, in: ["a", "b"]), ["a", "b"])
        XCTAssertEqual(DevicePolicy.rank(of: "b", in: ["a", "b"]), 2)
        XCTAssertNil(DevicePolicy.rank(of: "q", in: ["a"]))
    }

    // MARK: Device details

    private func details(transport: DeviceDetails.Transport = .usb, rate: Double = 48_000, buffer: Int = 512, latency: Int = 0, hardware: Bool = true) -> DeviceDetails {
        DeviceDetails(name: "Desk DAC", uid: "AppleUSB-1", transport: transport, isOutput: true, isInput: false, sampleRate: rate, availableRates: [44_100, 48_000, 96_000],
                      outputChannels: 2, inputChannels: 0, bufferFrames: buffer, deviceLatencyFrames: latency, streamLatencyFrames: 0, safetyOffsetFrames: 0,
                      hasHardwareVolume: hardware, hasHardwareMute: false, hasBalance: true, isHidden: false, manufacturer: "Acme")
    }

    func testTransportsAreNamedFromCoreAudiosCodes() {
        XCTAssertEqual(DeviceDetails.Transport(code: 0x626C746E), .builtIn)
        XCTAssertEqual(DeviceDetails.Transport(code: 0x75736220), .usb)
        XCTAssertEqual(DeviceDetails.Transport(code: 0x626C7565), .bluetooth)
        XCTAssertEqual(DeviceDetails.Transport(code: 0x68646D69), .hdmi)
        XCTAssertEqual(DeviceDetails.Transport(code: 0x61697270), .airPlay)
        XCTAssertEqual(DeviceDetails.Transport(code: 0x67727570), .aggregate)
        XCTAssertEqual(DeviceDetails.Transport(code: 0xDEADBEEF), .unknown)
        XCTAssertTrue(DeviceDetails.Transport.bluetooth.isWireless)
        XCTAssertFalse(DeviceDetails.Transport.usb.isWireless)
        for t in [DeviceDetails.Transport.builtIn, .usb, .bluetooth, .hdmi, .airPlay, .unknown] { XCTAssertFalse(t.title.isEmpty); XCTAssertFalse(t.symbol.isEmpty) }
    }

    func testDelayAddsEverythingTheDeviceReports() {
        XCTAssertEqual(details(buffer: 480, latency: 480).latencyMilliseconds, 20, accuracy: 0.001)
        XCTAssertEqual(details(rate: 0).latencyMilliseconds, 0)
        XCTAssertTrue(details(buffer: 256).latencyAdvice.contains("play along"))
        XCTAssertTrue(details(transport: .bluetooth, buffer: 512, latency: 8_000).latencyAdvice.contains("Wireless"))
        XCTAssertTrue(details(buffer: 480, latency: 480).latencyAdvice.contains("listening"))
    }

    func testTheInspectorLinesSayWhatIsAndIsNotThere() {
        let rows = Dictionary(uniqueKeysWithValues: details().rows.map { ($0.label, $0.value) })
        XCTAssertEqual(rows["Connection"], "USB")
        XCTAssertEqual(rows["Sample rate"], "48 kHz")
        XCTAssertEqual(rows["Channels"], "out: stereo")
        XCTAssertEqual(rows["Made by"], "Acme")
        XCTAssertEqual(rows["Other rates"], "44.1 kHz, 48 kHz, 96 kHz")
        XCTAssertTrue(rows["Volume"]?.contains("own volume") == true)
        XCTAssertTrue(Dictionary(uniqueKeysWithValues: details(hardware: false).rows.map { ($0.label, $0.value) })["Volume"]?.contains("software") == true)
        XCTAssertEqual(DeviceDetails.rate(44_100), "44.1 kHz")
        XCTAssertEqual(DeviceDetails.rate(800), "800 Hz")
    }

    // MARK: Headphone correction

    private let sample = """
    Preamp: -4.6 dB
    Filter 1: ON LSC Fc 105 Hz Gain 6.4 dB Q 0.70
    Filter 2: ON PK Fc 1000 Hz Gain -3.0 dB Q 1.20
    Filter 3: ON PK Fc 4800 Hz Gain 5.5 dB Q 2.10
    Filter 4: ON HSC Fc 10000 Hz Gain -4.0 dB Q 0.70
    Filter 5: OFF PK Fc 200 Hz Gain 9.9 dB Q 1.00
    """

    func testAParametricFileIsRead() throws {
        let profile = try XCTUnwrap(AutoEQ.parseParametric(sample))
        XCTAssertEqual(profile.preampDB, -4.6)
        XCTAssertEqual(profile.filters.count, 4, "the filter that is OFF is left out")
        XCTAssertEqual(profile.filters[0], AutoEQ.Filter(kind: .lowShelf, frequency: 105, gainDB: 6.4, q: 0.7))
        XCTAssertEqual(profile.filters[2].kind, .peak)
        XCTAssertEqual(profile.filters[3].kind, .highShelf)
        XCTAssertNil(AutoEQ.parseParametric("nothing useful here"))
        XCTAssertNil(AutoEQ.parseParametric("Filter 1: ON PK Fc 99999 Hz Gain 3 dB Q 1"), "a frequency no sound has")
    }

    func testAGraphicFileIsRead() throws {
        let points = try XCTUnwrap(AutoEQ.parseGraphic("GraphicEQ: 20 -1.0; 100 2.5; 1000 0; 10000 -3; 20000 -6"))
        XCTAssertEqual(points.count, 5)
        XCTAssertEqual(points[1].frequency, 100); XCTAssertEqual(points[1].gainDB, 2.5)
        XCTAssertNil(AutoEQ.parseGraphic("GraphicEQ: 20 1"))
        XCTAssertNil(AutoEQ.parseGraphic("no colon"))
        XCTAssertEqual(AutoEQ.interpolate([(100, 0), (10_000, 6)], at: 1000), 3, accuracy: 0.001, "halfway in pitch is halfway in gain")
        XCTAssertEqual(AutoEQ.interpolate([(100, 1), (200, 2)], at: 10), 1, "flat beyond the ends")
    }

    func testAFilterRaisesTheSoundWhereItIsCentredAndLittleFarAway() {
        let f = AutoEQ.Filter(kind: .peak, frequency: 1000, gainDB: 6, q: 1)
        XCTAssertEqual(AutoEQ.magnitudeDB(f, at: 1000), 6, accuracy: 0.05)
        XCTAssertEqual(AutoEQ.magnitudeDB(f, at: 30), 0, accuracy: 0.2)
        let low = AutoEQ.Filter(kind: .lowShelf, frequency: 200, gainDB: 8, q: 0.7)
        XCTAssertEqual(AutoEQ.magnitudeDB(low, at: 40), 8, accuracy: 0.6)
        XCTAssertEqual(AutoEQ.magnitudeDB(low, at: 8000), 0, accuracy: 0.3)
        let high = AutoEQ.Filter(kind: .highShelf, frequency: 4000, gainDB: -6, q: 0.7)
        XCTAssertEqual(AutoEQ.magnitudeDB(high, at: 15_000), -6, accuracy: 0.6)
        XCTAssertEqual(AutoEQ.magnitudeDB(high, at: 100), 0, accuracy: 0.3)
    }

    func testTenBandsFollowAPeakAndStayQuietElsewhere() {
        let profile = AutoEQ.Profile(preampDB: -3, filters: [AutoEQ.Filter(kind: .peak, frequency: 1000, gainDB: 6, q: 1.1)])
        let c = AutoEQ.correction(for: profile)
        XCTAssertEqual(c.gains.count, 10)
        XCTAssertEqual(Double(c.gains[5]), 6, accuracy: 1.0, "the 1 kHz band")
        for i in [0, 1, 8, 9] { XCTAssertEqual(Double(c.gains[i]), 0, accuracy: 1.5, "band \(i)") }
        XCTAssertLessThan(c.errorDB, 0.6, "ten bands follow a single peak closely")
        XCTAssertLessThanOrEqual(c.preampDB, -3)
        XCTAssertLessThanOrEqual(Double(c.preampDB), -5.5, "lowered further so a 6 dB boost cannot clip")
    }

    func testTenBandsFollowARealisticHeadphoneCurve() throws {
        let c = AutoEQ.correction(for: try XCTUnwrap(AutoEQ.parseParametric(sample)))
        XCTAssertLessThan(c.errorDB, 2.0, "a bass shelf, a dip, a presence peak and a treble shelf, within a couple of decibels")
        XCTAssertGreaterThan(c.gains[0] + c.gains[1] + c.gains[2], 6, "the bass is lifted")
        XCTAssertLessThan(c.gains[9], -1.5, "the top is lowered")
        for g in c.gains { XCTAssertLessThanOrEqual(abs(g), Float(EQBands.limit)) }
    }

    func testAFlatTargetGivesAFlatEqualiser() {
        let c = AutoEQ.correction(for: AutoEQ.Profile(preampDB: 0, filters: [AutoEQ.Filter(kind: .peak, frequency: 1000, gainDB: 0, q: 1)]))
        for g in c.gains { XCTAssertEqual(g, 0, accuracy: 0.05) }
        XCTAssertEqual(c.errorDB, 0, accuracy: 0.05)
    }

    func testAnImpossiblyLargeTargetIsLimited() {
        let c = AutoEQ.correction(for: AutoEQ.Profile(preampDB: 0, filters: [AutoEQ.Filter(kind: .peak, frequency: 1000, gainDB: 30, q: 1)]))
        XCTAssertLessThanOrEqual(c.largestGainDB, Double(EQBands.limit) + 0.001)
        XCTAssertGreaterThan(c.errorDB, 3, "and the error says it could not be matched")
    }

    func testACurveFileIsFitted() throws {
        let points = try XCTUnwrap(AutoEQ.parseGraphic("GraphicEQ: 20 6; 100 6; 1000 0; 10000 -4; 20000 -4"))
        let c = AutoEQ.correction(forCurve: points)
        XCTAssertGreaterThan(c.gains[1], 3, "the bass is lifted")
        XCTAssertLessThan(c.gains[9], -2, "the top is lowered")
        XCTAssertLessThan(c.errorDB, 1.5)
        XCTAssertLessThanOrEqual(Double(c.preampDB), -4, "room for the 6 dB lift")
    }
}

final class DeviceIconStateTests: XCTestCase {
    func testWhatAnIconSaysFollowsTheDevice() {
        func s(_ c: Bool, _ u: Bool = false, _ m: Bool = false, _ r: Bool = false, _ o: Bool = false) -> DeviceIconState { .resolve(connected: c, inUse: u, muted: m, reconnecting: r, replacedBy: o) }
        XCTAssertEqual(s(true, true), .active)
        XCTAssertEqual(s(true), .connected)
        XCTAssertEqual(s(true, true, true), .muted)
        XCTAssertEqual(s(true, false, true), .muted)
        XCTAssertEqual(s(false), .disconnected)
        XCTAssertEqual(s(false, false, false, true), .reconnecting)
        XCTAssertEqual(s(false, false, false, false, true), .fallback)
        XCTAssertEqual(s(false, false, false, true, true), .reconnecting, "trying to get it back comes before saying it was replaced")
        XCTAssertTrue(DeviceIconState.disconnected.slashed); XCTAssertFalse(DeviceIconState.active.slashed)
        XCTAssertLessThan(DeviceIconState.disconnected.opacity, DeviceIconState.connected.opacity)
        for status in [DeviceIconState.active, .connected, .muted, .disconnected, .reconnecting, .fallback] { XCTAssertFalse(status.title.isEmpty) }
    }

    func testPinnedDevicesAreKeptOncePerDirection() {
        let out = PinnedDevice(uid: "a", name: "A", input: false)
        let inn = PinnedDevice(uid: "a", name: "A", input: true)
        XCTAssertEqual(PinnedDevice.adding(out, to: [out]), [out])
        XCTAssertEqual(PinnedDevice.adding(inn, to: [out]), [out, inn], "a device that is both an output and an input can be pinned for each")
        XCTAssertEqual(PinnedDevice.removing(out.id, from: [out, inn]), [inn])
    }

    func testClicksAreTold() {
        XCTAssertEqual(StatusClick.classify(rightMouse: false, modifiers: []), .primary)
        XCTAssertEqual(StatusClick.classify(rightMouse: true, modifiers: []), .secondary)
        XCTAssertEqual(StatusClick.classify(rightMouse: false, modifiers: .control), .secondary)
        XCTAssertEqual(StatusClick.classify(rightMouse: false, modifiers: .option), .option)
        XCTAssertEqual(StatusClick.classify(rightMouse: true, modifiers: .option), .secondary, "a right click is a right click")
    }

    func testAMenuOpensUnderTheIconAndStaysOnTheDisplay() {
        let icon = NSRect(x: 1_200, y: 1_080, width: 24, height: 24)
        XCTAssertEqual(StatusMenu.anchor(forIconFrame: icon), NSPoint(x: 1_200, y: 1_078))
        let screen = NSRect(x: 0, y: 0, width: 1_440, height: 1_105)
        XCTAssertEqual(StatusMenu.fitted(NSPoint(x: 1_420, y: 1_078), menuWidth: 240, in: screen).x, 1_196, "pulled back so it fits")
        XCTAssertEqual(StatusMenu.fitted(NSPoint(x: 100, y: 1_078), menuWidth: 240, in: screen).x, 100)
        let second = NSRect(x: 1_440, y: 0, width: 1_920, height: 1_080)
        XCTAssertEqual(StatusMenu.fitted(NSPoint(x: 1_300, y: 1_050), menuWidth: 240, in: second).x, 1_440, "never left of its own display")
    }
}

final class AutoEQPlanTests: XCTestCase {
    private let c = AutoEQ.Correction(gains: [Float](repeating: 1, count: 10), preampDB: -1, errorDB: 0.2)

    func testACorrectionFollowsTheOutput() {
        XCTAssertEqual(AutoEQ.plan(applied: nil, current: "hp", corrections: ["hp": c]), .apply("hp", c))
        XCTAssertNil(AutoEQ.plan(applied: "hp", current: "hp", corrections: ["hp": c]), "already on")
        XCTAssertEqual(AutoEQ.plan(applied: "hp", current: "speakers", corrections: ["hp": c]), .clear, "taken off for a device without one")
        XCTAssertNil(AutoEQ.plan(applied: nil, current: "speakers", corrections: ["hp": c]), "nothing of ours to take off")
        XCTAssertEqual(AutoEQ.plan(applied: "a", current: "b", corrections: ["a": c, "b": c]), .apply("b", c))
        XCTAssertEqual(AutoEQ.plan(applied: "hp", current: nil, corrections: ["hp": c]), .clear)
    }

    func testACorrectionSurvivesBeingSaved() throws {
        let data = try JSONEncoder().encode(c)
        XCTAssertEqual(try JSONDecoder().decode(AutoEQ.Correction.self, from: data), c)
    }
}

final class SoundMixerLookTests: XCTestCase {
    func testDensityFollowsTheChoiceOrTheOlderSwitch() {
        XCTAssertEqual(SoundDensity.resolve(stored: "spacious", legacyCompact: true), .spacious)
        XCTAssertEqual(SoundDensity.resolve(stored: nil, legacyCompact: true), .compact)
        XCTAssertEqual(SoundDensity.resolve(stored: nil, legacyCompact: false), .comfortable)
        XCTAssertEqual(SoundDensity.resolve(stored: "bogus", legacyCompact: false), .comfortable)
        XCTAssertLessThan(SoundDensity.compact.rowPadding, SoundDensity.comfortable.rowPadding)
        XCTAssertLessThan(SoundDensity.comfortable.rowPadding, SoundDensity.spacious.rowPadding)
        XCTAssertFalse(SoundDensity.compact.showsChips); XCTAssertTrue(SoundDensity.spacious.showsChips)
        XCTAssertEqual(SoundAppearance.resolve("light"), .light)
        XCTAssertEqual(SoundAppearance.resolve(nil), .dark, "the mixer has always been dark")
        XCTAssertEqual(SoundAppearance.resolve("nonsense"), .dark)
    }

    func testSearchNeedsEveryWordAndIgnoresCaseAndAccents() {
        XCTAssertTrue(SoundMixerLookTests.m("spot", "Spotify"))
        XCTAssertTrue(SoundMixerLookTests.m("  ", "Anything"), "nothing typed shows everything")
        XCTAssertTrue(SoundMixerLookTests.m("mac speak", "MacBook Pro Speakers"))
        XCTAssertFalse(SoundMixerLookTests.m("mac usb", "MacBook Pro Speakers"))
        XCTAssertTrue(SoundMixerLookTests.m("cafe", "Café Radio"))
        XCTAssertFalse(SoundMixerLookTests.m("zoom", "Safari"))
    }
    private static func m(_ q: String, _ t: String) -> Bool { SoundSearch.matches(q, in: t) }

    func testAKeyMovesTheVolumeByTheStepAndStaysInRange() {
        XCTAssertEqual(VolumeStep.next(0.50, up: true, step: 0.05), 0.55, accuracy: 1e-9)
        XCTAssertEqual(VolumeStep.next(0.50, up: false, step: 0.05), 0.45, accuracy: 1e-9)
        XCTAssertEqual(VolumeStep.next(0.98, up: true, step: 0.05), 1.0)
        XCTAssertEqual(VolumeStep.next(0.02, up: false, step: 0.05), 0)
        XCTAssertEqual(VolumeStep.next(1.9, up: true, step: 0.1, range: 0...2), 2.0)
        XCTAssertEqual(VolumeStep.next(0.333, up: true, step: 0.01), 0.34, accuracy: 1e-9, "lands on a whole percent")
    }

    func testAHeldKeyRampsOnlyWhenAsked() {
        XCTAssertEqual(VolumeStep.step(base: 0.02, repeats: 20, ramp: false), 0.02)
        XCTAssertEqual(VolumeStep.step(base: 0.02, repeats: 0, ramp: true), 0.02)
        XCTAssertEqual(VolumeStep.step(base: 0.02, repeats: 8, ramp: true), 0.04, accuracy: 1e-9)
        XCTAssertEqual(VolumeStep.step(base: 0.02, repeats: 16, ramp: true), 0.06, accuracy: 1e-9)
        XCTAssertEqual(VolumeStep.step(base: 0.02, repeats: 500, ramp: true), 0.08, accuracy: 1e-9, "never more than four times")
        XCTAssertEqual(VolumeStep.step(base: 0.02, repeats: -3, ramp: true), 0.02)
    }

    func testScrollingChangesTheVolumeByAnAmountThatSuitsTheDevice() {
        XCTAssertEqual(VolumeStep.scrollChange(delta: 4, precise: true, fine: false, inverted: false), 0.01, accuracy: 1e-9)
        XCTAssertEqual(VolumeStep.scrollChange(delta: 1, precise: false, fine: false, inverted: false), 0.02, accuracy: 1e-9)
        XCTAssertEqual(VolumeStep.scrollChange(delta: 1, precise: false, fine: true, inverted: false), 0.005, accuracy: 1e-9)
        XCTAssertEqual(VolumeStep.scrollChange(delta: 1, precise: false, fine: false, inverted: true), -0.02, accuracy: 1e-9)
        XCTAssertEqual(VolumeStep.scrollChange(delta: 0, precise: true, fine: false, inverted: false), 0)
    }
}

final class SoundHealthTests: XCTestCase {
    func testTheSummarySaysTheWorstThing() {
        XCTAssertEqual(SoundHealth.report(problems: 0, slowestMilliseconds: 12, slowestName: "Desk").level, .good)
        XCTAssertEqual(SoundHealth.report(problems: 0, slowestMilliseconds: 80, slowestName: "AirPods").level, .noticeable)
        let late = SoundHealth.report(problems: 0, slowestMilliseconds: 200, slowestName: "AirPods")
        XCTAssertEqual(late.level, .problem)
        XCTAssertEqual(late.headline, "AirPods is about 200 ms behind")
        XCTAssertEqual(SoundHealth.report(problems: 1, slowestMilliseconds: 10, slowestName: nil).headline, "1 app could not be changed")
        XCTAssertEqual(SoundHealth.report(problems: 3, slowestMilliseconds: 500, slowestName: "x").headline, "3 apps could not be changed", "a failure outranks a delay")
        XCTAssertTrue(SoundHealth.report(problems: 0, slowestMilliseconds: 99, slowestName: nil).headline.hasPrefix("A device"))
    }

    func testProcessingDelayIsOneBuffer() {
        XCTAssertEqual(SoundHealth.processingMilliseconds(bufferFrames: 480, sampleRate: 48_000) ?? 0, 10, accuracy: 1e-9)
        XCTAssertNil(SoundHealth.processingMilliseconds(bufferFrames: 0, sampleRate: 48_000))
        XCTAssertNil(SoundHealth.processingMilliseconds(bufferFrames: 512, sampleRate: 0))
    }
}

final class HiddenDeviceTests: XCTestCase {
    private func device(_ id: UInt32, _ uid: String, out: Bool = true) -> AudioDevice { AudioDevice(id: id, uid: uid, name: uid, isOutput: out, isInput: !out) }

    func testHiddenDevicesLeaveTheListsButTheOneInUseStays() {
        let all = [device(1, "a"), device(2, "b"), device(3, "c")]
        XCTAssertEqual(DeviceNaming.visible(all, hidden: ["b"], inUse: 1).map(\.uid), ["a", "c"])
        XCTAssertEqual(DeviceNaming.visible(all, hidden: ["b"], inUse: 2).map(\.uid), ["a", "b", "c"], "the device in use cannot be hidden")
        XCTAssertEqual(DeviceNaming.visible(all, hidden: [], inUse: nil).count, 3)
    }

    func testHidingIsSavedWithTheLabelAndAnEmptyLabelIsDropped() {
        var label = DeviceLabel(); label.hidden = true
        XCTAssertFalse(label.isEmpty)
        let labels = DeviceNaming.setting(label, for: "x", in: [:])
        XCTAssertEqual(DeviceNaming.hiddenUIDs(labels), ["x"])
        label.hidden = nil
        XCTAssertTrue(DeviceNaming.setting(label, for: "x", in: labels).isEmpty, "shown again with no name or icon: nothing left to keep")
        let old = try? JSONDecoder().decode(DeviceLabel.self, from: Data(#"{"nickname":"Desk"}"#.utf8))
        XCTAssertEqual(old?.nickname, "Desk"); XCTAssertNil(old?.hidden, "labels saved before hiding existed still load")
    }
}
