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

    /// Ghostty 1.3.1 leaves 34 points over at a full-size window; 1.2 left 6. The blind limit stays
    /// tight, because loosening it admits grids that are not the grid. What covers both versions is
    /// the limit that applies once the row height is known.
    func testBothVersionsFitOnceTheRowIsKnown() {
        XCTAssertNotNil(TerminalRowMetrics.residual(of: sample(100, 1634), rowHeight: 16))
        XCTAssertLessThan(6, TerminalGridInference.paddingLimit, "Ghostty 1.2 fits blind")
        XCTAssertGreaterThan(
            16 * TerminalGridInference.paddingLimitRows, 34,
            "Ghostty 1.3.1 fits once the 16-point row is known"
        )
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

/// The sieve that solves the grid properly, against the versions of Ghostty that have reported
/// their content height two different ways.
final class TerminalGridInferenceVersionTests: XCTestCase {
    /// Ghostty 1.3.1, measured: a 100-line buffer of short lines in a 1129x818 window.
    private let lines = Array(repeating: 8, count: 100)

    /// With the row height pinned, which is what a pane gives up after two readings.
    private func grid(content: CGFloat, viewport: CGFloat) -> TerminalGrid? {
        TerminalGridInference.candidates(
            contentHeight: content, viewportHeight: viewport, paneWidth: 1129,
            lineLengths: lines, rowHeight: 16
        ).first
    }

    /// The grid that is actually there. It was being discarded: 34 points of residual against a
    /// limit of 12.
    func testTheGridGhostty13ReportsIsAmongTheCandidates() throws {
        let found = try XCTUnwrap(grid(content: 1634, viewport: 786), "no 16-point row was offered")
        XCTAssertEqual(found.padding, 34, accuracy: 0.001)
    }

    /// And at the other two window heights, where the residual is different. The candidates are
    /// regenerated when a resize makes the old ones stop explaining the pane, so each has to stand
    /// on its own.
    func testTheSameRowIsFoundAtEveryWindowHeightMeasured() throws {
        for (content, viewport, padding) in [(1634.0, 786.0, 34.0), (1628.0, 668.0, 28.0), (1624.0, 568.0, 24.0)] {
            let found = try XCTUnwrap(grid(content: content, viewport: viewport), "viewport \(viewport)")
            XCTAssertEqual(found.padding, padding, accuracy: 0.001, "viewport \(viewport)")
            XCTAssertTrue(
                TerminalGridInference.explains(
                    found, contentHeight: content, viewportHeight: viewport, lineLengths: lines
                )
            )
        }
    }

    /// The version this was written against still works. Ghostty 1.2 measured `rows * 16 + 6`, and
    /// raising the limit must not have cost the case it was raised from.
    func testTheGridGhostty12ReportedIsStillFound() throws {
        // 100 lines at 16 points with 6 of padding, in a viewport showing 61 rows.
        let found = try XCTUnwrap(grid(content: 1606, viewport: 982))
        XCTAssertEqual(found.padding, 6, accuracy: 0.001)
    }

    /// Without a known row height nothing is loosened, which is what keeps the sieve able to
    /// narrow to one answer at all: a 15.61-point row with 45 points of padding explains Ghostty
    /// 1.2's one look as neatly as the true 16 and 6 do.
    func testTheLooseLimitIsNotAppliedBlind() {
        let blind = TerminalGridInference.candidates(
            contentHeight: 1634, viewportHeight: 786, paneWidth: 1129, lineLengths: lines
        )
        XCTAssertFalse(
            blind.contains { abs($0.rowHeight - 16) < 0.01 },
            "the true grid is out of reach blind, which is what the row height is solved for"
        )
    }

    /// A pane whose height is mostly padding is not a grid, whatever arithmetic fits it.
    func testAnAnswerThatIsMorePaddingThanTextIsStillRefused() {
        XCTAssertNil(grid(content: 1634, viewport: 1400), "half the viewport would be padding")
    }
}
