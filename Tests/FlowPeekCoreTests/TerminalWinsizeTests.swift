import XCTest

@testable import FlowPeekCore

/// The numbers here were read live from Ghostty 1.3.1 on macOS 26 at backing scale 2, by walking the
/// terminal's own process tree to its pty and asking it one `ioctl(TIOCGWINSZ)`. The pane they came
/// from was running a coding agent full screen, which is precisely the case `TerminalRowMetrics`
/// cannot solve: its buffer fits its viewport, so the scroll area reports no equation at all.
///
/// They are here so that a terminal changing what it reports fails before anybody sees a frame in
/// the wrong place.
final class TerminalWinsizeTests: XCTestCase {
    /// `/dev/ttys000`, the pane the whole thing was measured on.
    private let measured = TerminalWinsize(rows: 40, columns: 140, heightInPixels: 1280, widthInPixels: 2250)
    /// Its `AXFrame` size in points, padding included.
    private let viewport = CGSize(width: 1129, height: 644)

    // MARK: - Measured on Ghostty 1.3.1

    /// The whole point. One reading of a full-screen pane gives the row height outright, and it is
    /// the same round 16 points that three readings of `AXContentSize` had to be solved for.
    func testTheMeasuredPaneGivesASixteenPointRowAndTwoPointsAboveIt() throws {
        let grid = try XCTUnwrap(measured.grid(viewportSize: viewport, scale: 2))
        XCTAssertEqual(grid.rowHeight, 16.000, accuracy: 0.001)
        XCTAssertEqual(grid.topPadding, 2.0, accuracy: 0.001)
        XCTAssertEqual(grid.rows, 40)
        XCTAssertEqual(grid.columns, 140)

        // The cell is a whole 16 device pixels, so 8.000 points. Dividing `ws_xpixel` by `ws_col`
        // gives 16.07 pixels, or 8.036 points, because the sub-cell leftover is still in the span --
        // the same drift the bracket removes from the row height, a third of a point wide over 140
        // columns and four columns' worth by the right-hand edge.
        XCTAssertEqual(grid.cellWidth, 8.000, accuracy: 0.001)
        XCTAssertEqual(2250.0 / 140.0 / 2.0, 8.036, accuracy: 0.001)
        XCTAssertEqual((2250.0 / 140.0 / 2.0 - grid.cellWidth) * 140, 5.0, accuracy: 0.5)
    }

    /// 1280 over 40 rows is `(31.220, 32.000]`, and 2250 over 140 columns is `(15.957, 16.071]`.
    /// One integer each, so the cell is measured rather than chosen.
    func testTheBracketHoldsExactlyOneCellOnBothAxes() {
        XCTAssertEqual(TerminalWinsize.cellPixels(spanning: 1280, cells: 40), [32])
        XCTAssertEqual(TerminalWinsize.cellPixels(spanning: 2250, cells: 140), [16])
        XCTAssertEqual(measured.cellHeightInPixels, 32)
        XCTAssertEqual(measured.cellWidthInPixels, 16)
    }

    /// The grid the outline is drawn from, checked where it matters: the first row starts two points
    /// inside the pane and the last one ends inside it. The old model, half of a 34-point residual
    /// that contained two phantom rows, put the top padding at 17 and ran the last row fifteen points
    /// past the bottom edge -- the drift this replaces.
    func testEveryRowLandsInsideTheMeasuredPane() throws {
        let grid = try XCTUnwrap(measured.grid(viewportSize: viewport, scale: 2))
        let firstRowTop = grid.topPadding
        let lastRowBottom = grid.topPadding + CGFloat(grid.rows) * grid.rowHeight
        XCTAssertEqual(firstRowTop, 2.0, accuracy: 0.001)
        XCTAssertEqual(lastRowBottom, 642.0, accuracy: 0.001)
        XCTAssertLessThanOrEqual(lastRowBottom, viewport.height)

        let byTheOldResidual = TerminalRowMetrics.topPadding(residual: 34)
        XCTAssertEqual(byTheOldResidual, 17, accuracy: 0.001)
        XCTAssertGreaterThan(
            byTheOldResidual + CGFloat(grid.rows) * grid.rowHeight, viewport.height,
            "half the residual runs the last row off the bottom of the pane"
        )
    }

    /// `ws_ypixel` is not `rows * cell`: the sub-cell leftover stays in it and sits below the last
    /// row. Measured on one surface as it was resized -- 1328 pixels over 41 rows, where 41 * 32 is
    /// 1312. Dividing would give 32.39 and a row that is 0.2 points too tall; the bracket gives 32.
    func testThePixelSpanNeedNotBeAWholeNumberOfRows() throws {
        let tall = TerminalWinsize(rows: 41, columns: 140, heightInPixels: 1328, widthInPixels: 2250)
        XCTAssertNotEqual(tall.heightInPixels, tall.rows * 32)
        let grid = try XCTUnwrap(tall.grid(viewportSize: CGSize(width: 1129, height: 668), scale: 2))
        XCTAssertEqual(grid.rowHeight, 16.000, accuracy: 0.001)
        // The same two points above the first row at a different window height, measured at four.
        XCTAssertEqual(grid.topPadding, 2.0, accuracy: 0.001)
    }

    // MARK: - The refusals

    /// The reading believed at the wrong scale. The row height it produces, 32 points, is inside
    /// `TerminalPeekPolicy.rowHeightRange` and reads as a legal large font, so the plausibility band
    /// cannot catch it. The inequality can: 40 rows of 32 points do not fit in a 644-point pane, and
    /// the padding comes out at -636 pixels.
    func testTheSameReadingAtScaleOneIsRefusedByTheInequalityNotTheBand() {
        XCTAssertTrue(
            TerminalPeekPolicy.rowHeightRange.contains(32),
            "the band accepts the doubled row, which is why the guard is stated in pixels"
        )
        XCTAssertEqual(measured.cellHeightInPixels, 32, "the bracket is happy either way")
        XCTAssertNil(measured.grid(viewportSize: viewport, scale: 1))
    }

    /// And the mirror: a pane that really is unscaled, read as if it were Retina. The padding comes
    /// out at 648 pixels, forty rows, against a four-row limit.
    func testAnUnscaledPaneReadAsRetinaIsRefused() {
        let unscaled = TerminalWinsize(rows: 40, columns: 140, heightInPixels: 640, widthInPixels: 1125)
        XCTAssertNil(unscaled.grid(viewportSize: viewport, scale: 2))
    }

    /// The same font on a display that is not Retina. Identical arithmetic, half the pixels, and the
    /// answer is in points either way -- which is why a remembered height survives a window being
    /// dragged between displays.
    func testTheSameFontOnAnUnscaledDisplayGivesTheSamePointHeight() throws {
        let unscaled = TerminalWinsize(rows: 40, columns: 140, heightInPixels: 640, widthInPixels: 1125)
        let grid = try XCTUnwrap(
            unscaled.grid(viewportSize: CGSize(width: 1129, height: 644), scale: 1)
        )
        XCTAssertEqual(grid.rowHeight, 16.000, accuracy: 0.001)
        XCTAssertEqual(grid.topPadding, 2.0, accuracy: 0.001)
    }

    /// Too few rows and the bracket stops being a measurement. Twenty rows over 640 pixels is
    /// `(30.476, 32.000]`, which admits 31 and 32, and nothing in the reading chooses between them.
    func testATwentyRowPaneCannotPinTheCellAndIsRefused() {
        XCTAssertEqual(TerminalWinsize.cellPixels(spanning: 640, cells: 20), [31, 32])
        let short = TerminalWinsize(rows: 20, columns: 140, heightInPixels: 640, widthInPixels: 2250)
        XCTAssertNil(short.cellHeightInPixels)
        XCTAssertNil(short.grid(viewportSize: CGSize(width: 1129, height: 324), scale: 2))
    }

    /// A live seven-row pane, measured: `ws_row 7`, `ws_ypixel 228`, bracket `(28.5, 32.571]`, four
    /// candidates. Its width was still pinned, which is the usual shape of the ambiguity -- there
    /// are far more columns than rows.
    func testTheSevenRowPaneMeasuredHereRefuses() {
        let small = TerminalWinsize(rows: 7, columns: 140, heightInPixels: 228, widthInPixels: 2250)
        XCTAssertEqual(TerminalWinsize.cellPixels(spanning: 228, cells: 7), [29, 30, 31, 32])
        XCTAssertNil(small.cellHeightInPixels)
        XCTAssertEqual(small.cellWidthInPixels, 16)
        XCTAssertNil(small.grid(viewportSize: CGSize(width: 1129, height: 118), scale: 2))
    }

    /// Roughly `rows >= cell - 1`, so the threshold moves with the font rather than being the number
    /// 31. At scale 1 a 16-pixel cell closes the bracket at fifteen rows.
    func testTheBracketClosesOnceThereAreAboutAsManyRowsAsPixelsInACell() {
        XCTAssertEqual(TerminalWinsize.cellPixels(spanning: 992, cells: 31), [32])
        XCTAssertEqual(TerminalWinsize.cellPixels(spanning: 960, cells: 30), [31, 32])
        XCTAssertEqual(TerminalWinsize.cellPixels(spanning: 240, cells: 15), [16])
        XCTAssertEqual(TerminalWinsize.cellPixels(spanning: 224, cells: 14), [15, 16])
    }

    /// More pixels than the pane has room for. The pty is describing a different surface, or it is
    /// describing this one from before a resize the accessibility frame has already caught up with.
    /// Either way it is not this pane, and there is no half-answer worth giving.
    func testAPtyTallerThanThePaneIsRefused() {
        let taller = TerminalWinsize(rows: 40, columns: 140, heightInPixels: 1300, widthInPixels: 2250)
        XCTAssertEqual(taller.cellHeightInPixels, 32, "the bracket still closes, so the guard is what refuses")
        XCTAssertNil(taller.grid(viewportSize: viewport, scale: 2))
    }

    /// One Ghostty process owns one pty per split and per tab, and the accessibility tree names none
    /// of them. A pane that is nothing like the reading is refused rather than matched.
    func testAWinsizeFromAnotherSurfaceIsRefused() {
        XCTAssertNil(measured.grid(viewportSize: CGSize(width: 1129, height: 900), scale: 2))
        XCTAssertNil(measured.grid(viewportSize: CGSize(width: 700, height: 644), scale: 2))
    }

    /// Terminals that never report a pixel size answer zeroes.
    func testAnUnsetWinsizeIsRefused() {
        let unset = TerminalWinsize(rows: 0, columns: 0, heightInPixels: 0, widthInPixels: 0)
        XCTAssertNil(unset.grid(viewportSize: viewport, scale: 2))
        XCTAssertEqual(TerminalWinsize.cellPixels(spanning: 0, cells: 40), [])
        XCTAssertEqual(TerminalWinsize.cellPixels(spanning: 1280, cells: 0), [])

        let rowsOnly = TerminalWinsize(rows: 40, columns: 140, heightInPixels: 0, widthInPixels: 0)
        XCTAssertNil(rowsOnly.grid(viewportSize: viewport, scale: 2))
    }

    /// A scale nobody has. Read from the window's own screen, never hardcoded, and refused outside
    /// the band rather than used.
    func testAnImplausibleScaleIsRefused() {
        XCTAssertNil(measured.grid(viewportSize: viewport, scale: 0))
        XCTAssertNil(measured.grid(viewportSize: viewport, scale: 4))
        XCTAssertNil(measured.grid(viewportSize: viewport, scale: .nan))
    }

    /// Accessibility answers points as doubles and the pty answers whole pixels, so the two can
    /// disagree by a fraction of a pixel where they ought to be equal. That is slack, not a negative
    /// padding, and the first row starts at the top of the pane.
    func testASubPixelDisagreementBecomesNoPaddingRatherThanNegativePadding() throws {
        let grid = try XCTUnwrap(
            measured.grid(viewportSize: CGSize(width: 1129, height: 639.8), scale: 2)
        )
        XCTAssertEqual(grid.topPadding, 0)
        XCTAssertEqual(grid.rowHeight, 16.000, accuracy: 0.001)
    }

    /// The cell is about half as wide as it is tall, 8.000 over 16.000 once both come off the
    /// bracket. A pair that is not is a reading whose two axes came from different surfaces.
    func testTheCellIsAPlausibleMonospacedShape() throws {
        let grid = try XCTUnwrap(measured.grid(viewportSize: viewport, scale: 2))
        XCTAssertTrue(TerminalGridInference.aspectRange.contains(grid.cellWidth / grid.rowHeight))
        XCTAssertEqual(grid.cellWidth / grid.rowHeight, 0.500, accuracy: 0.001)
    }

    // MARK: - Against the path it replaces

    /// Why this file exists. The full-screen pane it was measured on says nothing solvable: the
    /// buffer fits the viewport, so the sample carries no equation and the inference finds nothing.
    func testTheFullScreenPaneThisReplacesCarriesNoEquation() {
        let sample = TerminalRowMetrics.Sample(lineCount: 40, contentHeight: 644, viewportHeight: 644)
        XCTAssertFalse(sample.isUsable)
        XCTAssertNil(TerminalRowMetrics.rowHeight(sample, sample))
        XCTAssertTrue(
            TerminalGridInference.candidates(
                contentHeight: 644,
                viewportHeight: 644,
                paneWidth: 1129,
                lineLengths: [Int](repeating: 80, count: 40)
            ).isEmpty
        )
        XCTAssertNotNil(measured.grid(viewportSize: viewport, scale: 2), "the pty answers where none of that can")
    }
}
