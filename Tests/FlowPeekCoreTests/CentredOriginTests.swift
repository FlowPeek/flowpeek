import XCTest
@testable import FlowPeekCore

/// Where a preview opens. Every number here was measured on the display the placement was reported
/// wrong on: 2560x1440, visible area 2560x1410 once the menu bar is taken off.
final class CentredOriginTests: XCTestCase {
    private static let visible = CGRect(x: 0, y: 0, width: 2_560, height: 1_410)

    /// The free space above the window equals the free space below it. This is the whole point, and
    /// it is what `NSWindow.center()` deliberately does not do.
    func testAWindowSitsInTheMiddleOfWhatIsLeft() {
        for size in [CGSize(width: 1_730, height: 908), CGSize(width: 900, height: 640), CGSize(width: 320, height: 220)] {
            let origin = ScreenGeometry.centredOrigin(size: size, in: Self.visible)
            let above = Self.visible.maxY - (origin.y + size.height)
            let below = origin.y - Self.visible.minY
            XCTAssertEqual(above, below, accuracy: 1, "\(size) sat \(above) above and \(below) below")
            XCTAssertEqual(origin.x, (Self.visible.width - size.width) / 2, accuracy: 1)
        }
    }

    /// What the bug looked like, in numbers. AppKit splits the free space one part above to three
    /// below, so its answer is a quarter of the free height higher than the middle -- 125 points
    /// for the preview window, 192 for the quick panel, both measured.
    func testItDiffersFromAppKitByTheAmountThatWasReported() {
        for (size, reported) in [(CGSize(width: 1_730, height: 908), CGFloat(125)),
                                 (CGSize(width: 900, height: 640), CGFloat(192))] {
            let free = Self.visible.height - size.height
            let appKit = Self.visible.minY + free * 3 / 4
            let ours = ScreenGeometry.centredOrigin(size: size, in: Self.visible).y
            XCTAssertEqual(appKit - ours, reported, accuracy: 1, "\(size)")
        }
    }

    /// The screen is an argument, so a second display centres on itself rather than on the main
    /// one. `center()` cannot: a panel is placed before it is ordered front, so it belongs to no
    /// screen yet and AppKit falls back to the main screen -- measured, it answered x=415 for a
    /// window on the display at x=-2560.
    func testASecondDisplayCentresOnItself() {
        let left = CGRect(x: -2_560, y: 0, width: 2_560, height: 1_410)
        let origin = ScreenGeometry.centredOrigin(size: CGSize(width: 1_730, height: 908), in: left)
        XCTAssertEqual(origin.x, -2_145, accuracy: 1)
        XCTAssertTrue(left.contains(CGRect(origin: origin, size: CGSize(width: 1_730, height: 908))))
    }

    /// A window taller than the screen has nowhere to be centred, so the answer is negative and
    /// says so plainly rather than being quietly pinned. Keeping it reachable is the caller's job,
    /// and clamping does it: the top-left corner ends up on the screen.
    func testAWindowLargerThanTheScreenAnswersHonestlyAndClampsBack() {
        let size = CGSize(width: 3_000, height: 2_000)
        let origin = ScreenGeometry.centredOrigin(size: size, in: Self.visible)
        XCTAssertEqual(origin.y, (1_410 - 2_000) / 2, accuracy: 1)
        XCTAssertLessThan(origin.y, Self.visible.minY, "it really is off the bottom before clamping")

        let clamped = ScreenGeometry.clamp(origin: origin, size: size, visibleFrames: [Self.visible])
        XCTAssertGreaterThanOrEqual(clamped.y + size.height, Self.visible.maxY,
                                    "the top edge is at or above the top of the screen, so the title bar is reachable")
        XCTAssertGreaterThanOrEqual(clamped.x, Self.visible.minX - 1)
    }
}
