import XCTest
@testable import FlowPeekCore

/// Ghostty answers nothing about where a character is drawn, so its grid is worked out from the
/// heights it does report. Every number here was measured on Ghostty 1.2 in a 1115-point pane whose
/// true grid is 138 columns of 16 points with 6 points of padding: `printf '\033[2J\033[3J\033[H'`
/// to wipe the scrollback, content printed, then `AXContentSize`, the scroll area's `AXFrame` and
/// the text area's `AXValue` read from another process.
final class TerminalGridInferenceTests: XCTestCase {
    private static let viewportHeight: CGFloat = 982
    private static let paneWidth: CGFloat = 1115
    private static let trueRowHeight: CGFloat = 16
    private static let truePadding: CGFloat = 6
    private static let trueColumns = 138

    private func lengths(_ runs: [(Int, Int)]) -> [Int] {
        runs.flatMap { Array(repeating: $0.0, count: $0.1) }
    }

    /// 60 numbered lines then the reported diagram, whose four long rows are 137, 180, 107 and 126
    /// characters. `AXContentSize.height` 1430.
    private var firstLook: (height: CGFloat, lengths: [Int]) {
        (1_430, lengths([
            (1, 9), (2, 51), (8, 1), (43, 1), (0, 1), (31, 1), (35, 1), (54, 1), (47, 1), (0, 1),
            (39, 1), (42, 1), (44, 1), (0, 1), (137, 1), (180, 1), (50, 1), (42, 1), (0, 1),
            (37, 1), (107, 1), (126, 1), (46, 1), (0, 1), (28, 1), (17, 1), (16, 1), (17, 1),
            (15, 1), (5, 1)
        ]))
    }

    /// `seq 1 25` after it. 1846.
    private var secondLook: (height: CGFloat, lengths: [Int]) {
        (1_846, firstLook.lengths.dropLast() + lengths([(13, 1), (1, 9), (2, 16), (5, 1)]))
    }

    /// A 141-character line and a 139-character line after that. 2070.
    private var thirdLook: (height: CGFloat, lengths: [Int]) {
        (2_070, secondLook.lengths.dropLast() + lengths([(141, 1), (139, 1), (1, 9), (2, 1), (5, 1)]))
    }

    private func candidates(_ look: (height: CGFloat, lengths: [Int])) -> [TerminalGrid] {
        TerminalGridInference.candidates(
            contentHeight: look.height,
            viewportHeight: Self.viewportHeight,
            paneWidth: Self.paneWidth,
            lineLengths: look.lengths
        )
    }

    // MARK: - One look is not enough

    /// The measurement that shaped this. One height leaves two families of grid, and the wrong one
    /// explains it as exactly as the right one does -- so a single look must not be acted on.
    func testOneLookLeavesMoreThanOneGrid() throws {
        let grids = candidates(firstLook)
        XCTAssertFalse(grids.isEmpty)
        let families = Set(grids.map { "\($0.rowHeight)/\($0.padding)" })
        XCTAssertEqual(families.count, 2, "\(families)")
        XCTAssertTrue(grids.contains { $0.columns == Self.trueColumns && $0.rowHeight == Self.trueRowHeight })
        XCTAssertNil(
            TerminalGridInference.agreed(grids, lineLengths: firstLook.lengths),
            "two families cannot agree, so nothing is drawn from them"
        )
    }

    // MARK: - The sieve

    /// Three looks at different heights leave one grid: 16 points, 6 points of padding, and column
    /// counts that all wrap this text the same way.
    func testThreeLooksLeaveTheRightGrid() throws {
        var surviving = candidates(firstLook)
        for look in [secondLook, thirdLook] {
            surviving = surviving.filter {
                TerminalGridInference.explains(
                    $0,
                    contentHeight: look.height,
                    viewportHeight: Self.viewportHeight,
                    lineLengths: look.lengths
                )
            }
        }
        XCTAssertFalse(surviving.isEmpty)
        for grid in surviving {
            XCTAssertEqual(grid.rowHeight, Self.trueRowHeight)
            XCTAssertEqual(grid.padding, Self.truePadding)
        }
        XCTAssertTrue(surviving.contains { $0.columns == Self.trueColumns })
        let agreed = try XCTUnwrap(
            TerminalGridInference.agreed(surviving, lineLengths: thirdLook.lengths),
            "the survivors put every line on the same row, so any of them will do"
        )
        XCTAssertEqual(agreed.rowHeight, Self.trueRowHeight)
        XCTAssertEqual(agreed.padding, Self.truePadding)
    }

    /// The true grid explains every look, which is what the sieve is asking of a candidate.
    func testTheTrueGridExplainsEveryLook() {
        let truth = TerminalGrid(
            columns: Self.trueColumns,
            rowHeight: Self.trueRowHeight,
            padding: Self.truePadding
        )
        for look in [firstLook, secondLook, thirdLook] {
            XCTAssertTrue(
                TerminalGridInference.explains(
                    truth,
                    contentHeight: look.height,
                    viewportHeight: Self.viewportHeight,
                    lineLengths: look.lengths
                ),
                "height \(look.height)"
            )
        }
    }

    /// A wrong column count changes how many rows the text needs, so the height stops adding up.
    /// This is the sieve's whole mechanism.
    func testAWrongColumnCountStopsExplainingTheHeight() {
        for columns in [100, 120, 137, 139, 160, 200] {
            let grid = TerminalGrid(columns: columns, rowHeight: 16, padding: 6)
            let explains = TerminalGridInference.explains(
                grid,
                contentHeight: thirdLook.height,
                viewportHeight: Self.viewportHeight,
                lineLengths: thirdLook.lengths
            )
            // 137 and 138 wrap this text identically; 139 does not, because a 139-character line is
            // in it.
            XCTAssertEqual(explains, columns == 137 || columns == 138, "columns \(columns)")
        }
    }

    /// Measured with nothing on screen wide enough to wrap: `seq 1 100` after a wiped scrollback,
    /// 101 lines none longer than 5 characters, height 1622. The row height comes out exactly, and
    /// every plausible column count fits because there is no wrapping to disagree about -- which is
    /// fine, since they all put every line on its own row.
    func testAScreenWithNoWrapsPinsTheRowHeight() throws {
        let lengths = self.lengths([(1, 9), (2, 90), (3, 1), (5, 1)])
        XCTAssertEqual(lengths.count, 101)
        let grids = TerminalGridInference.candidates(
            contentHeight: 1_622,
            viewportHeight: Self.viewportHeight,
            paneWidth: Self.paneWidth,
            lineLengths: lengths
        )
        XCTAssertFalse(grids.isEmpty)
        for grid in grids {
            XCTAssertEqual(grid.rowHeight, Self.trueRowHeight)
            XCTAssertEqual(grid.padding, Self.truePadding)
        }
        let agreed = try XCTUnwrap(TerminalGridInference.agreed(grids, lineLengths: lengths))
        XCTAssertEqual(agreed.rowHeight, Self.trueRowHeight)
    }

    /// A capped buffer is still an equation. Ghostty stops exposing text at about 32,000
    /// characters: 20,000 lines printed, 5,424 in `AXValue`, height 86,790 -- which is
    /// `5424 * 16 + 6`, so the height describes what is exposed rather than what was printed.
    func testACappedBufferStillAddsUp() {
        let lengths = self.lengths([(21, 1), (1, 9), (2, 90), (3, 900), (4, 4_423), (5, 1)])
        XCTAssertEqual(lengths.count, 5_424)
        let truth = TerminalGrid(columns: Self.trueColumns, rowHeight: 16, padding: 6)
        XCTAssertTrue(
            TerminalGridInference.explains(
                truth,
                contentHeight: 86_790,
                viewportHeight: Self.viewportHeight,
                lineLengths: lengths
            )
        )
    }

    // MARK: - Rows

    func testRowsPerLine() {
        XCTAssertEqual(TerminalGridInference.rows(ofLineLength: 0, columns: 138), 1)
        XCTAssertEqual(TerminalGridInference.rows(ofLineLength: 138, columns: 138), 1)
        XCTAssertEqual(TerminalGridInference.rows(ofLineLength: 139, columns: 138), 2)
        XCTAssertEqual(TerminalGridInference.rows(ofLineLength: 276, columns: 138), 2)
        XCTAssertEqual(TerminalGridInference.rows(ofLineLength: 277, columns: 138), 3)
        XCTAssertEqual(TerminalGridInference.rows(ofLineLength: 320, columns: 138), 3)
    }

    /// The reported diagram, at the width it was reported at: 27 lines occupying 31 rows, and the
    /// outline has to cover the rows.
    func testABlockSpansTheRowsItsLinesOccupy() throws {
        let lengths = [8, 43, 0, 31, 35, 54, 47, 0, 39, 42, 44, 0, 137, 180, 50, 42, 0, 37, 107, 126, 46,
                       0, 28, 17, 16, 17, 15]
        let span = try XCTUnwrap(
            TerminalGridInference.rowSpan(ofLines: 0...26, lineLengths: lengths, columns: 100)
        )
        XCTAssertEqual(span.lowerBound, 0)
        // 137, 180, 107 and 126 characters each need two rows at 100 columns.
        XCTAssertEqual(span.count, lengths.count + 4)
        // At 138 columns only the 180 wraps, which is what the reported pane did.
        let wider = try XCTUnwrap(
            TerminalGridInference.rowSpan(ofLines: 0...26, lineLengths: lengths, columns: 138)
        )
        XCTAssertEqual(wider.count, lengths.count + 1)
    }

    func testARowMapsBackToItsLine() {
        let lengths = [10, 300, 10]
        // 300 characters at 138 columns is three rows, so line 1 owns rows 1, 2 and 3.
        XCTAssertEqual(TerminalGridInference.line(ofRow: 0, lineLengths: lengths, columns: 138), 0)
        XCTAssertEqual(TerminalGridInference.line(ofRow: 1, lineLengths: lengths, columns: 138), 1)
        XCTAssertEqual(TerminalGridInference.line(ofRow: 3, lineLengths: lengths, columns: 138), 1)
        XCTAssertEqual(TerminalGridInference.line(ofRow: 4, lineLengths: lengths, columns: 138), 2)
        XCTAssertNil(TerminalGridInference.line(ofRow: 5, lineLengths: lengths, columns: 138))
        XCTAssertNil(TerminalGridInference.line(ofRow: -1, lineLengths: lengths, columns: 138))
    }

    /// A buffer that fits its viewport says nothing about the row height -- there is no scrollback
    /// to divide -- so nothing is guessed from it.
    func testAPaneWithNoScrollbackAnswersNothing() {
        XCTAssertTrue(TerminalGridInference.candidates(
            contentHeight: 982,
            viewportHeight: 982,
            paneWidth: Self.paneWidth,
            lineLengths: [10, 20, 30]
        ).isEmpty)
        XCTAssertTrue(TerminalGridInference.candidates(
            contentHeight: 1_430,
            viewportHeight: 982,
            paneWidth: Self.paneWidth,
            lineLengths: []
        ).isEmpty)
    }
}
