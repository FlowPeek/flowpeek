import XCTest

@testable import FlowPeekCore

/// The numbers in these tests were measured on Ghostty 1.3.1, in one 1129x818 window, by printing
/// buffers of known length and reading `AXContentSize` back. They are here so that the next time a
/// terminal changes what it reports, this fails before anybody sees a frame in the wrong place.
final class TerminalRowMetricsTests: XCTestCase {
    private func sample(_ lines: Int, _ content: CGFloat, viewport: CGFloat = 786) -> TerminalRowMetrics.Sample {
        .init(lineCount: lines, contentHeight: content, viewportHeight: viewport)
    }

    // MARK: - Measured on Ghostty 1.3.1

    /// The whole point. Two readings give the row height exactly, and it is a round 16 rather than
    /// the 16.34 to 16.57 that dividing the height by the line count produces.
    func testTwoReadingsSolveGhosttysRowHeightExactly() throws {
        let height = try XCTUnwrap(TerminalRowMetrics.rowHeight(sample(60, 994), sample(100, 1634)))
        XCTAssertEqual(height, 16, accuracy: 0.001)

        // And the same height explains a third reading the solver never saw.
        let residual = try XCTUnwrap(TerminalRowMetrics.residual(of: sample(65, 1074), rowHeight: height))
        XCTAssertEqual(residual, 34, accuracy: 0.001)
    }

    /// What the old path did, kept here as the thing being fixed: dividing is out by half a point a
    /// row, which is a row and a half by the bottom of a full screen.
    func testDividingTheHeightByTheLineCountDrifts() {
        let byDivision = 1074.0 / 65.0
        XCTAssertEqual(byDivision, 16.523, accuracy: 0.001)
        let driftAcrossAScreen = (byDivision - 16) * 45
        XCTAssertGreaterThan(driftAcrossAScreen, 20, "a frame placed this way lands over the wrong rows")
    }

    /// The residual moves with the viewport while the row height does not. Measured on one 100-line
    /// buffer at three window heights. This is why the height is what gets remembered.
    func testTheRowHeightHoldsAcrossViewportsWhileTheResidualDoesNot() throws {
        let readings: [(viewport: CGFloat, content: CGFloat, residual: CGFloat)] = [
            (786, 1634, 34), (668, 1628, 28), (568, 1624, 24),
        ]
        for reading in readings {
            let residual = try XCTUnwrap(
                TerminalRowMetrics.residual(
                    of: sample(100, reading.content, viewport: reading.viewport), rowHeight: 16
                ),
                "viewport \(reading.viewport)"
            )
            XCTAssertEqual(residual, reading.residual, accuracy: 0.001, "viewport \(reading.viewport)")
        }
    }

    /// Ghostty 1.3.1 leaves 34 points over at a full-size window. The inference sieve used to cap
    /// that at 12, measured on Ghostty 1.2, and everything it might have solved was thrown away.
    func testAResidualTheOldLimitWouldHaveRefusedIsAccepted() {
        XCTAssertNotNil(TerminalRowMetrics.residual(of: sample(100, 1634), rowHeight: 16))
        XCTAssertGreaterThan(34, TerminalGridInference.paddingLimit, "this is the limit that was wrong")
    }

    // MARK: - What it refuses

    /// Two readings taken at different window heights do not share a residual, so it does not
    /// cancel and the difference between them is not a row height.
    func testReadingsFromDifferentViewportsAreNotCombined() {
        XCTAssertNil(
            TerminalRowMetrics.rowHeight(sample(60, 994, viewport: 786), sample(100, 1624, viewport: 568))
        )
    }

    /// A buffer that fits its viewport is reported as exactly the viewport's height, which says
    /// nothing about the grid.
    func testAReadingOfABufferThatFitsSaysNothing() {
        let fits = sample(5, 786, viewport: 786)
        XCTAssertFalse(fits.isUsable)
        XCTAssertNil(TerminalRowMetrics.residual(of: fits, rowHeight: 16))
        XCTAssertNil(TerminalRowMetrics.rowHeight(fits, sample(100, 1634)))
    }

    func testTwoReadingsOfTheSameBufferSolveNothing() {
        XCTAssertNil(TerminalRowMetrics.rowHeight(sample(100, 1634), sample(100, 1634)))
    }

    /// An answer outside the range of a legible row is not the row height, whatever the arithmetic.
    func testAnImplausibleHeightIsRefused() {
        XCTAssertNil(TerminalRowMetrics.rowHeight(sample(10, 1000), sample(11, 1200)), "200 points a row")
        XCTAssertNil(TerminalRowMetrics.rowHeight(sample(100, 1000), sample(300, 1200)), "one point a row")
    }

    /// A height that would need more of the pane than there is, or that leaves a quarter of the
    /// window unaccounted for, is refused rather than drawn from.
    func testAHeightThatCannotExplainTheReadingIsRefused() {
        XCTAssertNil(
            TerminalRowMetrics.residual(of: sample(100, 1634), rowHeight: 17),
            "100 rows of 17 is taller than the content the pane reported"
        )
        XCTAssertNil(
            TerminalRowMetrics.residual(of: sample(100, 1634), rowHeight: 8),
            "half the pane would be residual"
        )
    }

    func testTheFirstRowSitsBelowHalfTheResidual() {
        XCTAssertEqual(TerminalRowMetrics.topPadding(residual: 34), 17, accuracy: 0.001)
        XCTAssertEqual(TerminalRowMetrics.topPadding(residual: 0), 0, accuracy: 0.001)
    }
}
