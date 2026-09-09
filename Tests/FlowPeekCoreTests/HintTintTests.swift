import Foundation
import XCTest
@testable import FlowPeekCore

/// The hint box's colour, which a user with colour-vision deficiency may have to choose themselves
/// for the frame and the chip to be visible at all.
final class HintTintTests: XCTestCase {
    func testAHexRoundTripsThroughTheStoredForm() throws {
        for entry in HintTintPalette.entries {
            let stored = HintTintChoice.fixed(entry.tint).storedValue
            XCTAssertEqual(HintTintChoice(storedValue: stored), .fixed(entry.tint), entry.id)
        }
    }

    /// A value somebody typed into `defaults write` should work, and one written back should read
    /// the same every time.
    func testHexParsingIsTolerantAndFormattingIsNot() {
        let expected = HintTint(red: 1, green: 0.4, blue: 0)
        for spelling in ["#FF6600", "ff6600", "  #Ff6600  "] {
            XCTAssertEqual(HintTint(hex: spelling)?.hex, expected.hex, spelling)
        }
        XCTAssertEqual(HintTint(hex: "#FF6600")?.hex, "#FF6600")
    }

    func testAnUnusableHexIsRefused() {
        for spelling in ["", "#", "#FFF", "#FF66000", "#GGGGGG", "rebeccapurple", "0x00FF00"] {
            XCTAssertNil(HintTint(hex: spelling), spelling)
        }
    }

    /// Nothing about a colour is worth refusing to draw a hint over: a value from a newer build or
    /// a hand-edited plist falls back to the accent the app has always used.
    func testAnythingUnrecognisedFollowsTheSystemAccent() {
        for stored in [nil, "", "system", "not a colour", "#GGGGGG", "#FFF"] {
            XCTAssertEqual(HintTintChoice(storedValue: stored), .systemAccent, stored ?? "nil")
        }
    }

    func testTheSystemAccentIsNotStoredAsAColour() {
        XCTAssertEqual(HintTintChoice.systemAccent.storedValue, "system")
        XCTAssertNil(HintTint(hex: HintTintChoice.systemAccent.storedValue))
    }

    /// Channels are clamped rather than trusted: a colour picker hands back extended-range values
    /// on a wide-gamut display, and a hex has to come back out of them.
    func testChannelsOutsideTheRangeAreClamped() {
        let tint = HintTint(red: 1.4, green: -0.2, blue: 0.5)
        XCTAssertEqual(tint.red, 1)
        XCTAssertEqual(tint.green, 0)
        XCTAssertEqual(tint.hex, "#FF0080")
    }

    /// The palette is offered because it has been checked against the common deficiencies, so it
    /// has to stay the published one: seven colours, all distinct, none of them the accent
    /// sentinel.
    func testThePaletteIsTheCheckedOne() {
        XCTAssertEqual(HintTintPalette.entries.count, 7)
        XCTAssertEqual(
            HintTintPalette.entries.map(\.tint.hex),
            ["#E69F00", "#56B4E9", "#009E73", "#F0E442", "#0072B2", "#D55E00", "#CC79A7"]
        )
        XCTAssertEqual(Set(HintTintPalette.entries.map(\.id)).count, 7)
        XCTAssertEqual(Set(HintTintPalette.entries.map(\.tint.hex)).count, 7)
    }

    /// The settings row shows which swatch is selected, and a colour picked freely is not one.
    func testAPaletteEntryIsRecognisedAndACustomColourIsNot() throws {
        let blue = try XCTUnwrap(HintTintPalette.entries.first { $0.id == "blue" })
        XCTAssertEqual(HintTintPalette.entry(for: .fixed(blue.tint))?.id, "blue")
        XCTAssertNil(HintTintPalette.entry(for: .systemAccent))
        XCTAssertNil(HintTintPalette.entry(for: .fixed(HintTint(red: 0.5, green: 0.5, blue: 0.5))))
    }
}
