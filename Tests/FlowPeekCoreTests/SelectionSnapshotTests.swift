import CoreGraphics
import XCTest
@testable import FlowPeekCore

final class SelectionSnapshotTests: XCTestCase {
    private func candidate(_ kind: SelectionCandidateKind, _ text: String, _ bounds: CGRect? = nil) -> SelectionCandidate {
        SelectionCandidate(kind: kind, text: text, bounds: bounds)
    }

    // MARK: - Snapshot

    func testAnchorPointDefaultsToZeroSoTheMemberwiseInitStaysSourceCompatible() {
        let snapshot = SelectionSnapshot(
            text: "graph TD",
            screenBounds: nil,
            applicationName: "TextEdit",
            processIdentifier: 42
        )
        XCTAssertEqual(snapshot.anchorPoint, .zero)
    }

    func testAnchorPointIsCarried() {
        let snapshot = SelectionSnapshot(
            text: "graph TD",
            screenBounds: nil,
            applicationName: "TextEdit",
            processIdentifier: 42,
            anchorPoint: CGPoint(x: 120, y: 640)
        )
        XCTAssertEqual(snapshot.anchorPoint, CGPoint(x: 120, y: 640))
    }

    // MARK: - Candidate scoring

    func testEmptyCandidatesAreNeverSelected() {
        XCTAssertNil(SelectionCandidateScoring.best(from: [], mouseLocation: .zero))
        XCTAssertNil(SelectionCandidateScoring.best(from: [candidate(.hitTest, "")], mouseLocation: .zero))
    }

    func testLongerTextWinsWhenNeitherCandidateHasBounds() {
        let best = SelectionCandidateScoring.best(
            from: [candidate(.hitTest, "ab"), candidate(.focused, "graph TD; A-->B")],
            mouseLocation: .zero
        )
        XCTAssertEqual(best?.kind, .focused)
    }

    func testBoundsContainingTheMouseBeatSlightlyLongerText() {
        let mouse = CGPoint(x: 50, y: 50)
        let best = SelectionCandidateScoring.best(
            from: [
                candidate(.focused, String(repeating: "x", count: 120)),
                candidate(.hitTest, String(repeating: "y", count: 40), CGRect(x: 0, y: 0, width: 100, height: 100)),
            ],
            mouseLocation: mouse
        )
        XCTAssertEqual(best?.kind, .hitTest)
    }

    func testMuchLongerTextStillBeatsATinyContainingFragment() {
        let mouse = CGPoint(x: 50, y: 50)
        let best = SelectionCandidateScoring.best(
            from: [
                candidate(.hitTest, "yy", CGRect(x: 0, y: 0, width: 100, height: 100)),
                candidate(.focused, String(repeating: "x", count: 900)),
            ],
            mouseLocation: mouse
        )
        XCTAssertEqual(best?.kind, .focused)
    }

    func testKindOnlyBreaksExactTies() {
        let best = SelectionCandidateScoring.best(
            from: [candidate(.application, "same text"), candidate(.hitTest, "same text")],
            mouseLocation: .zero
        )
        XCTAssertEqual(best?.kind, .hitTest)
    }

    func testHitTestOutranksFocusedWhichOutranksApplication() {
        XCTAssertLessThan(SelectionCandidateKind.hitTest, SelectionCandidateKind.focused)
        XCTAssertLessThan(SelectionCandidateKind.focused, SelectionCandidateKind.application)
        let text = "graph TD"
        XCTAssertGreaterThan(
            SelectionCandidateScoring.score(candidate(.hitTest, text), mouseLocation: .zero),
            SelectionCandidateScoring.score(candidate(.application, text), mouseLocation: .zero)
        )
    }

    func testDegenerateBoundsNeverCountAsContainingTheMouse() {
        XCTAssertFalse(SelectionCandidateScoring.contains(nil, .zero))
        XCTAssertFalse(SelectionCandidateScoring.contains(.zero, .zero))
        XCTAssertFalse(SelectionCandidateScoring.contains(CGRect(x: 10, y: 10, width: 0, height: 40), CGPoint(x: 10, y: 20)))
        XCTAssertFalse(SelectionCandidateScoring.contains(.infinite, CGPoint(x: 1, y: 1)))
        XCTAssertFalse(SelectionCandidateScoring.contains(.null, CGPoint(x: 1, y: 1)))
    }

    func testContainmentToleranceAcceptsAMouseUpJustOutsideTheSelectionRect() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 20)
        XCTAssertTrue(SelectionCandidateScoring.contains(rect, CGPoint(x: 102, y: 21)))
        XCTAssertFalse(SelectionCandidateScoring.contains(rect, CGPoint(x: 140, y: 21)))
    }

    func testLengthWeightIsCappedSoContainmentStillDecidesBetweenHugeSelections() {
        let mouse = CGPoint(x: 5, y: 5)
        let huge = String(repeating: "x", count: SelectionCandidateScoring.maximumLengthWeight + 5_000)
        let bigger = String(repeating: "y", count: SelectionCandidateScoring.maximumLengthWeight + 9_000)
        let best = SelectionCandidateScoring.best(
            from: [
                candidate(.focused, bigger),
                candidate(.hitTest, huge, CGRect(x: 0, y: 0, width: 10, height: 10)),
            ],
            mouseLocation: mouse
        )
        XCTAssertEqual(best?.kind, .hitTest)
    }

    // MARK: - Screen geometry

    func testFlipReferenceUsesTheZeroOriginScreenNotTheFirstOne() {
        let secondary = CGRect(x: -1440, y: 200, width: 1440, height: 900)
        let primary = CGRect(x: 0, y: 0, width: 1512, height: 982)
        XCTAssertEqual(ScreenGeometry.flipReference(screenFrames: [secondary, primary]), 982)
    }

    func testFlipReferenceFallsBackToTheUnionWhenNoScreenSitsAtTheOrigin() {
        let frames = [CGRect(x: 10, y: 10, width: 100, height: 100), CGRect(x: 10, y: 200, width: 100, height: 300)]
        XCTAssertEqual(ScreenGeometry.flipReference(screenFrames: frames), 500)
        XCTAssertNil(ScreenGeometry.flipReference(screenFrames: []))
    }

    func testCoordinateConversionRoundTrips() {
        let flip: CGFloat = 982
        let point = CGPoint(x: 120, y: 700)
        let ax = ScreenGeometry.appKitToAX(point, flipReference: flip)
        XCTAssertEqual(ax, CGPoint(x: 120, y: 282))
        XCTAssertEqual(ScreenGeometry.appKitToAX(ax, flipReference: flip), point)
    }

    func testAXRectOnANegativeOriginSecondaryScreenConvertsBackAboveThePrimary() {
        // AX y grows downward from the primary screen's top-left; a rect above the menu bar is negative.
        let converted = ScreenGeometry.axToAppKit(CGRect(x: -300, y: -400, width: 200, height: 40), flipReference: 982)
        XCTAssertEqual(converted, CGRect(x: -300, y: 1342, width: 200, height: 40))
    }

    func testAXToAppKitPlacesTheRectByItsBottomEdge() {
        let converted = ScreenGeometry.axToAppKit(CGRect(x: 10, y: 100, width: 200, height: 20), flipReference: 982)
        XCTAssertEqual(converted, CGRect(x: 10, y: 862, width: 200, height: 20))
    }

    func testIsUsableRejectsDegenerateRects() {
        XCTAssertTrue(ScreenGeometry.isUsable(CGRect(x: 0, y: 0, width: 1, height: 1)))
        XCTAssertFalse(ScreenGeometry.isUsable(.zero))
        XCTAssertFalse(ScreenGeometry.isUsable(CGRect(x: 5, y: 5, width: 40, height: 0)))
        XCTAssertFalse(ScreenGeometry.isUsable(.null))
        XCTAssertFalse(ScreenGeometry.isUsable(.infinite))
        XCTAssertFalse(ScreenGeometry.isUsable(CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10)))
    }

    // MARK: - Overlay clamping

    private let primary = CGRect(x: 0, y: 0, width: 1512, height: 950)
    private let leftSecondary = CGRect(x: -1440, y: 200, width: 1440, height: 860)
    private let size = CGSize(width: 38, height: 38)

    func testOriginInsideAScreenIsLeftAlone() {
        let origin = CGPoint(x: 400, y: 400)
        XCTAssertEqual(
            ScreenGeometry.clamp(origin: origin, size: size, visibleFrames: [primary, leftSecondary]),
            origin
        )
    }

    func testOriginPastTheRightEdgeIsPulledBackInside() {
        let clamped = ScreenGeometry.clamp(origin: CGPoint(x: 1500, y: 400), size: size, visibleFrames: [primary])
        XCTAssertEqual(clamped, CGPoint(x: 1512 - 38 - 8, y: 400))
    }

    func testOriginOnANegativeOriginSecondaryScreenClampsToThatScreenNotThePrimary() {
        let clamped = ScreenGeometry.clamp(
            origin: CGPoint(x: -1450, y: 1050),
            size: size,
            visibleFrames: [primary, leftSecondary]
        )
        XCTAssertEqual(clamped, CGPoint(x: -1440 + 8, y: 200 + 860 - 38 - 8))
    }

    func testAnOriginInDeadSpaceSnapsToTheNearestScreen() {
        let clamped = ScreenGeometry.clamp(
            origin: CGPoint(x: -1_000_000, y: -1_000_000),
            size: size,
            visibleFrames: [primary, leftSecondary]
        )
        XCTAssertTrue(leftSecondary.contains(CGRect(origin: clamped, size: size)))
    }

    func testClampIsAnIdentityWhenNoScreensAreReported() {
        let origin = CGPoint(x: 7, y: 9)
        XCTAssertEqual(ScreenGeometry.clamp(origin: origin, size: size, visibleFrames: []), origin)
    }

    /// A screen smaller than the window cannot honour the inset on both sides. Pinning to the screen's
    /// own corner overhangs by the size difference alone; keeping the inset would add it on top.
    func testClampDropsTheInsetOnAScreenSmallerThanTheButton() {
        let tiny = CGRect(x: 0, y: 0, width: 20, height: 20)
        let clamped = ScreenGeometry.clamp(origin: CGPoint(x: 500, y: 500), size: size, visibleFrames: [tiny])
        XCTAssertEqual(clamped, CGPoint(x: 0, y: 0))
        XCTAssertEqual(clamped.x + size.width - tiny.maxX, size.width - tiny.width)
    }

    // MARK: - Transient indicator placement

    func testIndicatorSitsInTheTopRightOfTheScreenItIsGiven() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1055)
        let size = CGSize(width: 268, height: 56)

        let origin = ScreenGeometry.indicatorOrigin(size: size, in: screen, inset: 16)

        XCTAssertEqual(origin.x, 1920 - 268 - 16)
        XCTAssertEqual(origin.y, 1055 - 56 - 16)
        XCTAssertTrue(screen.contains(CGRect(origin: origin, size: size)))
    }

    func testIndicatorStaysInsideAScreenTooSmallForItsInset() {
        let screen = CGRect(x: 0, y: 0, width: 280, height: 60)
        let size = CGSize(width: 268, height: 56)

        let origin = ScreenGeometry.indicatorOrigin(size: size, in: screen, inset: 16)

        XCTAssertGreaterThanOrEqual(origin.x, screen.minX)
        XCTAssertGreaterThanOrEqual(origin.y, screen.minY)
        XCTAssertLessThanOrEqual(origin.x + size.width, screen.maxX)
        XCTAssertLessThanOrEqual(origin.y + size.height, screen.maxY)
    }

    func testIndicatorFollowsTheScreenWithANegativeOrigin() {
        let secondary = CGRect(x: -1440, y: 200, width: 1440, height: 850)
        let size = CGSize(width: 268, height: 56)

        let origin = ScreenGeometry.indicatorOrigin(size: size, in: secondary, inset: 16)

        XCTAssertEqual(origin.x, -1440 + 1440 - 268 - 16)
        XCTAssertEqual(origin.y, 200 + 850 - 56 - 16)
    }

    func testVisibleFrameContainingPrefersTheScreenUnderThePoint() {
        let primary = CGRect(x: 0, y: 0, width: 1920, height: 1055)
        let secondary = CGRect(x: -1440, y: 200, width: 1440, height: 850)

        XCTAssertEqual(
            ScreenGeometry.visibleFrame(containing: CGPoint(x: -700, y: 500), visibleFrames: [primary, secondary]),
            secondary
        )
        XCTAssertEqual(
            ScreenGeometry.visibleFrame(containing: CGPoint(x: 900, y: 500), visibleFrames: [primary, secondary]),
            primary
        )
    }

    func testVisibleFrameContainingFallsBackToTheLargestScreenOffAllOfThem() {
        let primary = CGRect(x: 0, y: 0, width: 1920, height: 1055)
        let secondary = CGRect(x: -1440, y: 200, width: 1440, height: 850)

        XCTAssertEqual(
            ScreenGeometry.visibleFrame(containing: CGPoint(x: 9000, y: 9000), visibleFrames: [secondary, primary]),
            primary
        )
        XCTAssertNil(ScreenGeometry.visibleFrame(containing: .zero, visibleFrames: []))
    }
}
