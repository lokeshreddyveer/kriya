import XCTest
import AppKit
@testable import Kriya

final class PinStyleTests: XCTestCase {
    private func image() -> NSImage { NSImage(size: NSSize(width: 120, height: 80)) }

    // MARK: The settings

    func testTheDefaultLooksAsPinsAlwaysDid() {
        let look = PinPolicy()
        XCTAssertTrue(look.roundedCorners)
        XCTAssertTrue(look.shadow)
        XCTAssertTrue(look.border)
        XCTAssertEqual(look.opacity, 1)
        XCTAssertNil(look.background)
        XCTAssertEqual(look.cornerRadius, 8)
        XCTAssertEqual(look.borderWidth, 1)
        XCTAssertEqual(look.alpha, 1)
    }

    func testTheStyleHoldsAppearanceOnlyNothingAboutPositionOrSize() {
        let names = Set(Mirror(reflecting: PinPolicy()).children.compactMap(\.label))
        XCTAssertEqual(names, ["roundedCorners", "shadow", "border", "opacity", "background"])
        XCTAssertTrue(names.isDisjoint(with: ["frame", "origin", "size", "width", "height", "x", "y", "position"]))
    }

    func testEachSettingTurnsTheLookOff() {
        var look = PinPolicy()
        look.roundedCorners = false
        look.border = false
        XCTAssertEqual(look.cornerRadius, 0)
        XCTAssertEqual(look.borderWidth, 0)
    }

    func testOpacityIsKeptToWhatCanBeSet() {
        var look = PinPolicy()
        look.opacity = 0
        XCTAssertEqual(look.alpha, 0.2, accuracy: 0.0001, "never fully invisible")
        look.opacity = 5
        XCTAssertEqual(look.alpha, 1)
        look.opacity = .nan
        XCTAssertEqual(look.alpha, 1, "a damaged value is solid")
        look.opacity = 0.5
        XCTAssertEqual(look.sanitized().opacity, 0.5)
        look.opacity = 0.01
        XCTAssertEqual(look.sanitized().opacity, 0.2, accuracy: 0.0001)
    }

    func testOlderAndDamagedSettingsLoad() throws {
        let old = try JSONDecoder().decode(PinPolicy.self, from: Data(#"{"roundedCorners":false,"shadow":true,"border":true}"#.utf8))
        XCTAssertFalse(old.roundedCorners)
        XCTAssertEqual(old.opacity, 1)
        XCTAssertNil(old.background)
        let damaged = try JSONDecoder().decode(PinPolicy.self, from: Data(#"{"opacity":"x","background":7,"shadow":"yes"}"#.utf8))
        XCTAssertEqual(damaged, PinPolicy())
    }

    func testTheColourBehindThePictureIsSavedAndKeptInRange() throws {
        var look = PinPolicy()
        look.background = CodableColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 0.9)
        let back = try JSONDecoder().decode(PinPolicy.self, from: JSONEncoder().encode(look))
        XCTAssertEqual(back, look)
        XCTAssertEqual(CodableColor(red: 9, green: -1, blue: 0.5, alpha: 3), CodableColor(red: 1, green: 0, blue: 0.5, alpha: 1))
    }

    func testTheStyleTravelsWithTheCaptureSettings() throws {
        var policy = CaptureDeliveryPolicy()
        policy.pin.opacity = 0.6
        policy.pin.background = .white
        let back = try JSONDecoder().decode(CaptureDeliveryPolicy.self, from: JSONEncoder().encode(policy))
        XCTAssertEqual(back.pin.opacity, 0.6)
        XCTAssertEqual(back.pin.background, .white)
        let damaged = try JSONDecoder().decode(CaptureDeliveryPolicy.self, from: Data(#"{"pin":{"opacity":42}}"#.utf8))
        XCTAssertEqual(damaged.pin.opacity, 1, "held to the largest that can be set")
    }

    // MARK: Applied in PinnedShots

    func testANewPinGetsTheStyle() throws {
        let pins = PinnedShots()
        var look = PinPolicy()
        look.roundedCorners = false
        look.shadow = false
        look.border = false
        look.opacity = 0.5
        look.background = CodableColor(red: 1, green: 0, blue: 0)
        pins.lookProvider = { look }
        pins.pin(image())
        defer { pins.closeAll() }
        let shown = pins.appearances
        XCTAssertEqual(shown.count, 1)
        XCTAssertFalse(shown[0].shadow)
        XCTAssertEqual(shown[0].alpha, 0.5, accuracy: 0.001)
        XCTAssertEqual(shown[0].cornerRadius, 0)
        XCTAssertEqual(shown[0].borderWidth, 0)
        XCTAssertEqual(shown[0].background?.count, 4)
        XCTAssertEqual(try XCTUnwrap(shown[0].background)[0], 1, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(shown[0].background)[1], 0, accuracy: 0.01)
    }

    func testTheDefaultStyleLooksLikeBefore() {
        let pins = PinnedShots()
        pins.lookProvider = { PinPolicy() }
        pins.pin(image())
        defer { pins.closeAll() }
        XCTAssertEqual(pins.appearances, [PinnedShots.Appearance(shadow: true, alpha: 1, cornerRadius: 8, borderWidth: 1, background: nil)])
    }

    func testChangingTheStyleRestylesPinsAlreadyOnTheScreen() {
        let pins = PinnedShots()
        var look = PinPolicy()
        pins.lookProvider = { look }
        pins.pin(image())
        pins.pin(image())
        defer { pins.closeAll() }
        look.shadow = false
        look.opacity = 0.4
        look.roundedCorners = false
        look.background = .white
        pins.restyle()
        for appearance in pins.appearances {
            XCTAssertFalse(appearance.shadow)
            XCTAssertEqual(appearance.alpha, 0.4, accuracy: 0.001)
            XCTAssertEqual(appearance.cornerRadius, 0)
            XCTAssertNotNil(appearance.background)
        }
        look.background = nil
        pins.restyle()
        XCTAssertTrue(pins.appearances.allSatisfy { $0.background == nil }, "the colour can be taken off again")
    }

    func testRestylingNeverMovesOrResizesAPin() {
        let pins = PinnedShots()
        var look = PinPolicy()
        pins.lookProvider = { look }
        pins.pin(image())
        pins.pin(image())
        defer { pins.closeAll() }
        let before = pins.frames
        XCTAssertEqual(before.count, 2)
        look.shadow = false; look.border = false; look.roundedCorners = false; look.opacity = 0.3; look.background = CodableColor(red: 0, green: 1, blue: 0)
        pins.restyle()
        XCTAssertEqual(pins.frames, before, "positions and sizes are the person's, not the style's")
        look = PinPolicy()
        pins.restyle()
        XCTAssertEqual(pins.frames, before)
    }

    func testRestylingLeavesWhichPinsExistAndWhetherTheyAreHidden() {
        let pins = PinnedShots()
        pins.lookProvider = { PinPolicy() }
        pins.pin(image())
        pins.pin(image())
        defer { pins.closeAll() }
        pins.toggleVisibility()
        pins.restyle()
        XCTAssertEqual(pins.count, 2)
        XCTAssertTrue(pins.isHidden, "still put away")
    }

    func testAnOpacitySetByHandIsReplacedByTheStylesWhenItChanges() {
        let pins = PinnedShots()
        var look = PinPolicy()
        look.opacity = 0.8
        pins.lookProvider = { look }
        pins.pin(image())
        defer { pins.closeAll() }
        XCTAssertEqual(pins.appearances[0].alpha, 0.8, accuracy: 0.001)
        look.opacity = 0.6
        pins.restyle()
        XCTAssertEqual(pins.appearances[0].alpha, 0.6, accuracy: 0.001)
    }

    func testAPinMadeLaterUsesTheStyleOfTheMoment() {
        let pins = PinnedShots()
        var look = PinPolicy()
        pins.lookProvider = { look }
        pins.pin(image())
        look.shadow = false
        pins.pin(image())
        defer { pins.closeAll() }
        XCTAssertEqual(pins.appearances.map(\.shadow), [true, false], "the first keeps its look until restyled; the second is made with the new one")
    }
}
