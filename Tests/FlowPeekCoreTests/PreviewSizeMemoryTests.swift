import CoreGraphics
import XCTest

@testable import FlowPeekCore

final class PreviewSizeMemoryTests: XCTestCase {
    private let fallback = CGSize(width: 720, height: 520)
    private let minimum = CGSize(width: 360, height: 260)
    private let big = CGRect(x: 0, y: 0, width: 1920, height: 1080)

    func testFirstRunUsesTheDesignedSize() {
        XCTAssertEqual(
            PreviewSizeMemory.size(stored: nil, fallback: fallback, minimum: minimum, visibleFrame: big),
            fallback
        )
    }

    func testARememberedSizeIsRestored() {
        let stored = CGSize(width: 900, height: 640)
        XCTAssertEqual(
            PreviewSizeMemory.size(stored: stored, fallback: fallback, minimum: minimum, visibleFrame: big),
            stored
        )
    }

    /// The whole point of the feature: what the user dragged to is what comes back, not the default.
    func testARememberedSizeWinsOverTheDefaultEvenWhenSmaller() {
        let stored = CGSize(width: 420, height: 300)
        XCTAssertEqual(
            PreviewSizeMemory.size(stored: stored, fallback: fallback, minimum: minimum, visibleFrame: big),
            stored
        )
    }

    func testASizeBelowTheSurfaceMinimumIsRaisedToIt() {
        let restored = PreviewSizeMemory.size(
            stored: CGSize(width: 100, height: 80),
            fallback: fallback,
            minimum: minimum,
            visibleFrame: big
        )
        XCTAssertEqual(restored, minimum)
    }

    /// A size saved on a large display must not open off the edge of a small one.
    func testASizeSavedOnABigDisplayIsCappedOnASmallOne() {
        let laptop = CGRect(x: 0, y: 0, width: 1280, height: 800)
        let restored = PreviewSizeMemory.size(
            stored: CGSize(width: 1800, height: 1000),
            fallback: fallback,
            minimum: minimum,
            visibleFrame: laptop
        )
        XCTAssertEqual(restored.width, 1280 * PreviewSizeMemory.maximumScreenFraction, accuracy: 0.001)
        XCTAssertEqual(restored.height, 800 * PreviewSizeMemory.maximumScreenFraction, accuracy: 0.001)
    }

    /// The cap must never shrink a surface below the size it needs to work.
    func testTheCapYieldsToTheMinimumOnATinyDisplay() {
        let tiny = CGRect(x: 0, y: 0, width: 300, height: 200)
        let restored = PreviewSizeMemory.size(
            stored: CGSize(width: 900, height: 640),
            fallback: fallback,
            minimum: minimum,
            visibleFrame: tiny
        )
        XCTAssertEqual(restored, minimum)
    }

    func testGarbageIsIgnoredInFavourOfTheDesignedSize() {
        for bad in [CGSize(width: 0, height: 0), CGSize(width: CGFloat.nan, height: 400), CGSize(width: -10, height: -10)] {
            XCTAssertEqual(
                PreviewSizeMemory.size(stored: bad, fallback: fallback, minimum: minimum, visibleFrame: big),
                fallback,
                "\(bad) should not have been restored"
            )
        }
    }

    func testNothingDegenerateIsEverWritten() {
        XCTAssertFalse(PreviewSizeMemory.shouldRemember(.zero, minimum: minimum))
        XCTAssertFalse(PreviewSizeMemory.shouldRemember(CGSize(width: CGFloat.nan, height: 500), minimum: minimum))
        XCTAssertFalse(PreviewSizeMemory.shouldRemember(CGSize(width: 100, height: 500), minimum: minimum))
        XCTAssertTrue(PreviewSizeMemory.shouldRemember(CGSize(width: 900, height: 640), minimum: minimum))
    }

    func testTheTwoSurfacesRememberSeparately() {
        let keys = PreviewSizeMemory.Surface.allCases.flatMap { [$0.widthKey, $0.heightKey] }
        XCTAssertEqual(Set(keys).count, keys.count, "two surfaces must not share a defaults key")
    }

    func testAnUnknownDisplayStillRestoresTheSize() {
        let stored = CGSize(width: 900, height: 640)
        XCTAssertEqual(
            PreviewSizeMemory.size(stored: stored, fallback: fallback, minimum: minimum, visibleFrame: nil),
            stored
        )
    }
}
