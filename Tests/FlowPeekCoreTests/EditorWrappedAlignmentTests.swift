import XCTest

@testable import FlowPeekCore

/// An editor wraps a line too wide for its window, and until this the alignment did not know.
///
/// `EditorViewportAlignment` matched the pane's rows against the file's lines one to one, so the
/// first soft-wrapped line ended the run: `matchedRows` stopped there and every diagram below it on
/// screen was unreachable. Where the wrap fell in the pane's first rows there were fewer than
/// `minimumRun` rows left to agree on and the file was refused outright, which is a reader scrolled
/// to a diagram in vim and shown nothing at all.
///
/// Swept over a real 741-line Korean document in a 178-column pane -- every scroll position that
/// shows a diagram, 251 of them -- the one-to-one alignment framed 231 and missed 20. Wrapped, it
/// frames all 251. That sweep needs a file this suite does not carry, so what is kept here is the
/// mechanism it found, in the smallest arrangement that still shows it.
final class EditorWrappedAlignmentTests: XCTestCase {
    /// A file whose fourth line is too wide for the pane, with a diagram underneath it.
    private static let file = [
        "# Title",
        "",
        "Some ordinary prose about the design.",
        String(repeating: "가", count: 60),   // 120 cells: two rows at 100 columns
        "",
        "```mermaid",
        "flowchart TD",
        "    Ingest[Ingest] --> Parse[Parse]",
        "    Parse --> Store[(Store)]",
        "```",
        "",
        "Trailing prose that follows the diagram.",
    ]

    private static let columns = 100

    /// The pane, as the editor would paint it from `first`: every line broken into the rows it
    /// needs, then vim's tildes and status line.
    private func screen(from first: Int, rows count: Int) -> [String] {
        var rows: [String] = []
        for line in Self.file[first...] {
            for piece in EditorWrappedFile.wrap(line, columns: Self.columns) where rows.count < count {
                rows.append(piece)
            }
        }
        while rows.count < count { rows.append("~") }
        rows.append("\"notes.md\" 12L, 400B")
        return rows
    }

    /// The wrapping itself: a wide line takes the rows its cells need, an ordinary one takes one.
    func testAWideLineIsDrawnOverTheRowsItNeeds() {
        XCTAssertEqual(EditorWrappedFile.wrap("short", columns: 100), ["short"])
        XCTAssertEqual(EditorWrappedFile.wrap("", columns: 100), [""])
        XCTAssertEqual(
            EditorWrappedFile.wrap(String(repeating: "가", count: 60), columns: 100).count, 2,
            "120 cells cannot fit one 100-column row"
        )
        // Unknown width: the editor's wrapping is not modelled and the line is one row, which is
        // what every caller assumed before there was a column count to pass.
        XCTAssertEqual(EditorWrappedFile.wrap(String(repeating: "가", count: 60), columns: nil).count, 1)
    }

    /// The rows of the file line up with the lines they came from.
    func testTheWrappingKnowsWhichLineEachRowCameFrom() {
        let wrapped = EditorWrappedFile(lines: Self.file, columns: Self.columns)
        XCTAssertEqual(wrapped.rows.count, Self.file.count + 1, "one line is drawn over two rows")
        XCTAssertEqual(wrapped.firstRowOfLine[3], 3, "the wide line starts on row 3")
        XCTAssertEqual(wrapped.firstRowOfLine[4], 5, "and the line after it has been pushed down one")
        XCTAssertEqual(wrapped.lineOfRow[4], 3, "row 4 is the second half of line 3")
    }

    /// The regression: a screen with a wrapped line above the diagram still reaches the diagram.
    ///
    /// One to one, the run ends at row 3 -- the first half of the wide line matches, the second half
    /// is not line 4 -- so `matchedRows` is 3, the diagram at lines 5-9 is past the end of it, and
    /// nothing is framed.
    func testADiagramBelowAWrappedLineIsStillFramed() throws {
        let rows = screen(from: 0, rows: 20)
        let wrapped = EditorWrappedFile(lines: Self.file, columns: Self.columns)

        let placed = try XCTUnwrap(
            EditorViewportAlignment.placement(ofRows: rows, in: wrapped),
            "the screen could not be placed in the file at all"
        )
        XCTAssertEqual(placed.firstLine, 0)
        XCTAssertEqual(placed.firstRow, 0)
        XCTAssertGreaterThanOrEqual(
            placed.matchedRows, 10,
            "the match stopped at the wrapped line instead of carrying past it"
        )

        let span = try XCTUnwrap(
            EditorViewportAlignment.rowsOnScreen(ofLines: 5...9, placement: placed, in: wrapped),
            "the diagram was placed off the screen"
        )
        // Lines 5-9 are rows 6-10: one row of wrapping sits above them.
        XCTAssertEqual(span, 6...10)
        for row in span {
            XCTAssertEqual(
                EditorViewportAlignment.normalise(rows[row]),
                EditorViewportAlignment.normalise(wrapped.rows[placed.firstRow + row]),
                "row \(row) of the pane is not the row the frame would be drawn over"
            )
        }
    }

    /// And a screen that opens part way through the wrapped line: the anchor is a fragment, which
    /// matches nothing in the file's own lines and refused the whole file before.
    func testAScreenStartingOnAWrappedLineIsStillPlaced() throws {
        let wrapped = EditorWrappedFile(lines: Self.file, columns: Self.columns)
        // Drop the first three rows, so the pane opens on the second half of the wide line.
        let rows = Array(screen(from: 0, rows: 20).dropFirst(4))
        let placed = try XCTUnwrap(
            EditorViewportAlignment.placement(ofRows: rows, in: wrapped),
            "a pane opening on the tail of a wrapped line could not be placed"
        )
        XCTAssertEqual(placed.firstRow, 4, "the pane starts on the second row of the wide line")
        XCTAssertEqual(placed.firstLine, 3, "which is still line 3 of the file")
        XCTAssertNotNil(
            EditorViewportAlignment.rowsOnScreen(ofLines: 5...9, placement: placed, in: wrapped),
            "the diagram below it has to still be reachable"
        )
    }

    /// With no column count nothing is modelled and the old arithmetic is what runs, so a caller
    /// that cannot say how wide the pane is keeps exactly the behaviour it had.
    func testWithoutAColumnCountTheWrappingIsTheIdentity() {
        let wrapped = EditorWrappedFile(lines: Self.file, columns: nil)
        XCTAssertEqual(wrapped.rows, Self.file)
        XCTAssertEqual(wrapped.lineOfRow, Array(0..<Self.file.count))
    }
}
