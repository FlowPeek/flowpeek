import XCTest
@testable import FlowPeekCore

/// Putting an editor's rows back where they came from.
///
/// The shape of every fixture here was measured on Ghostty: vim on a 240-line file in a window
/// showing 39 rows answered 3,236 characters and 39 lines, all of it the file, with
/// `AXVisibleCharacterRange` covering the whole value -- the viewport is all there is. The same
/// file printed with `cat` on the primary screen answered 19,892 characters and 241 lines. That
/// difference is why this exists.
final class EditorViewportAlignmentTests: XCTestCase {
    private static let file: [String] = {
        var lines = ["# notes", "", "```mermaid", "flowchart TD"]
        for i in 1...40 { lines.append("    N\(i) --> N\(i + 1)") }
        lines.append("```")
        lines.append("")
        lines.append("some prose after the diagram")
        return lines
    }()

    /// vim showing the file from line 10, with the tildes and status line it draws itself.
    private func viewport(from line: Int, rows: Int) -> [String] {
        var shown = Array(Self.file[line..<min(line + rows, Self.file.count)])
        while shown.count < rows { shown.append("~") }
        shown[rows - 1] = "\"notes.md\" 47L, 812B"
        return shown
    }

    func testTheRowsAreFoundInTheFile() {
        let rows = viewport(from: 10, rows: 20)
        XCTAssertEqual(EditorViewportAlignment.firstLine(ofRows: rows, in: Self.file), 10)
    }

    func testTheTopOfTheFileIsFound() {
        let rows = viewport(from: 0, rows: 20)
        XCTAssertEqual(EditorViewportAlignment.firstLine(ofRows: rows, in: Self.file), 0)
    }

    /// A terminal pads a row to the width it drew it at; the file does not.
    func testTrailingSpaceOnTheRowsDoesNotMatter() {
        let rows = viewport(from: 12, rows: 20).map { $0 + "    " }
        XCTAssertEqual(EditorViewportAlignment.firstLine(ofRows: rows, in: Self.file), 12)
    }

    // MARK: - What it refuses

    /// The whole point of the check: a candidate file that is not the one on screen does not align,
    /// so picking the wrong editor costs a refusal rather than a wrong frame.
    func testRowsFromAnotherFileAreRefused() {
        let other = (1...30).map { "unrelated line \($0) of something else entirely" }
        XCTAssertNil(EditorViewportAlignment.firstLine(ofRows: other, in: Self.file))
    }

    func testTooFewRowsToBeSureAreRefused() {
        let rows = Array(Self.file[10..<13])
        XCTAssertNil(
            EditorViewportAlignment.firstLine(ofRows: rows, in: Self.file),
            "three rows is reachable by accident in a file with repeated structure"
        )
    }

    /// A run that appears twice has not located anything, and either answer would be a guess.
    func testAnAmbiguousRunIsRefused() {
        let repeated = (0..<3).flatMap { _ in
            ["flowchart TD", "    A --> B", "    B --> C", "    C --> D", "    D --> E"]
        }
        let rows = ["flowchart TD", "    A --> B", "    B --> C", "    C --> D", "    D --> E"]
        XCTAssertNil(EditorViewportAlignment.firstLine(ofRows: rows, in: repeated))
    }

    func testAnEmptyFileAnswersNothing() {
        XCTAssertNil(EditorViewportAlignment.firstLine(ofRows: viewport(from: 0, rows: 20), in: []))
    }

    // MARK: - Which rows a block occupies

    func testABlockOnScreenMapsToItsRows() {
        XCTAssertEqual(
            EditorViewportAlignment.rowsOnScreen(ofLines: 12...20, firstLine: 10, rowCount: 20),
            2...10
        )
    }

    /// A block that starts above the viewport is clipped to it, not dropped: the reader can see
    /// part of it, so it gets a frame over the part they can see.
    func testABlockStartingAboveTheViewportIsClipped() {
        XCTAssertEqual(
            EditorViewportAlignment.rowsOnScreen(ofLines: 2...20, firstLine: 10, rowCount: 20),
            0...10
        )
    }

    func testABlockEntirelyOffScreenIsNotFramed() {
        XCTAssertNil(EditorViewportAlignment.rowsOnScreen(ofLines: 0...5, firstLine: 10, rowCount: 20))
        XCTAssertNil(EditorViewportAlignment.rowsOnScreen(ofLines: 40...50, firstLine: 10, rowCount: 20))
    }
}

/// How much of a pane is the file, which is not the same as how tall the pane is.
extension EditorViewportAlignmentTests {
    private static let notes: [String] = {
        var lines = ["# notes", "", "```mermaid", "flowchart TD"]
        for i in 1...10 { lines.append("    N\(i) --> N\(i + 1)") }
        lines.append("```")
        return lines
    }()

    /// vim on a file shorter than the window: the tildes and the status line are not the file, and
    /// a frame drawn over them would be a frame over rows the diagram does not occupy.
    func testTheEditorsOwnRowsAreNotCounted() throws {
        var rows = Self.notes
        rows.append(contentsOf: Array(repeating: "~", count: 6))
        rows.append("\"notes.md\" 15L, 240B")
        let placed = try XCTUnwrap(EditorViewportAlignment.placement(ofRows: rows, in: Self.notes))
        XCTAssertEqual(placed.firstLine, 0)
        XCTAssertEqual(placed.matchedRows, Self.notes.count, "the file's lines, not the pane's rows")
    }

    /// An unwritten edit stops the run where the change is, so what gets framed is what still
    /// agrees with the file rather than a saved copy shown as though it were the screen.
    func testAnEditedRowEndsTheRun() throws {
        var rows = Self.notes
        rows[8] = "    N5 --> N99   <- just typed, not written"
        let placed = try XCTUnwrap(EditorViewportAlignment.placement(ofRows: rows, in: Self.notes))
        XCTAssertEqual(placed.firstLine, 0)
        XCTAssertEqual(placed.matchedRows, 8)
    }
}
