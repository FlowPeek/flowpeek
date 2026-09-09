import XCTest
@testable import FlowPeekCore

/// A long line reaches a terminal buffer as several rows, and the diagram is the line rather than
/// the rows. These pin which rows are joined, which are left alone, and that an ordinary diagram is
/// never rewritten.
final class RowContinuationTests: XCTestCase {
    /// The diagram this was written for, as reported: four of its lines run past the width. Laid
    /// out the way a program that wraps its own output does it -- a fixed content width, and every
    /// row carrying the same left margin, the declaration's included.
    private static let sourceLines = [
        "graph TD",
        "    ROOT[\"haulla<br/>(yarn@4.3.0 + turbo)\"]",
        "",
        "    ROOT --> APPS[\"apps/ (21)\"]",
        "    FE --> FE1[\"back-office-front<br/>customer-tycoon-front<br/>generator-front<br/>hauler-front<br/>official · zzapad · jira-connector\"]",
        "    BE --> BE1[\"core-api · customer-tycoon-api · payment-api<br/>event-pipeline · hubspot-adapter · call-analyzer<br/>hawk-eye · shawn · transcript-server<br/>prometheus-exporter\"]",
        "    FS1 -.-> UI"
    ]

    /// Breaks each line at `width` characters and prints `margin` down the left, which is what a
    /// wrapping program puts in the buffer.
    private func wrapped(_ lines: [String], width: Int, margin: String) -> [String] {
        var rows: [String] = []
        for line in lines {
            guard !line.isEmpty else { rows.append(""); continue }
            var rest = Substring(line)
            while rest.count > width {
                rows.append(margin + rest.prefix(width))
                rest = rest.dropFirst(width)
            }
            rows.append(margin + rest)
        }
        return rows
    }

    // MARK: - The block a wrapped diagram makes

    /// The whole diagram, not the part above the first wrap. The outline is drawn around
    /// `block.lines`, so every row the diagram occupies has to be in it.
    func testAWrappedDiagramKeepsAllItsRows() throws {
        let rows = wrapped(Self.sourceLines, width: 96, margin: "  ")
        XCTAssertGreaterThan(rows.count, Self.sourceLines.count, "the fixture has to actually wrap")
        let block = try XCTUnwrap(TerminalBufferScanner.blocks(in: rows.joined(separator: "\n")).first)
        XCTAssertEqual(block.lines, 0...(rows.count - 1))
    }

    /// And the source handed to mermaid is the diagram as it was written: the rows joined back into
    /// lines, with the wrapping program's margin taken off the joint rather than left inside a
    /// label.
    func testAWrappedDiagramIsHandedOverAsWhatWasWritten() throws {
        let rows = wrapped(Self.sourceLines, width: 96, margin: "  ")
        let block = try XCTUnwrap(TerminalBufferScanner.blocks(in: rows.joined(separator: "\n")).first)
        let recovered = block.detection.extractedSource
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.hasPrefix("  ") ? String($0.dropFirst(2)) : String($0) }
        XCTAssertEqual(recovered, Self.sourceLines)
    }

    /// A terminal wrapping a line of its own adds no margin, so nothing may be stripped from the
    /// joint either.
    func testATerminalWrapWithNoMarginJoinsExactly() throws {
        let rows = wrapped(Self.sourceLines, width: 96, margin: "")
        let block = try XCTUnwrap(TerminalBufferScanner.blocks(in: rows.joined(separator: "\n")).first)
        XCTAssertEqual(
            block.detection.extractedSource.split(separator: "\n", omittingEmptySubsequences: false).map(String.init),
            Self.sourceLines
        )
    }

    /// One label over three rows: the first two both end inside the quote, so all three are one
    /// line. The state carried forward is the joined line, which is what makes the third row join.
    func testALabelSpreadOverThreeRowsIsOneLine() throws {
        let long = "    A --> B[\"" + String(repeating: "x", count: 200) + "\"]"
        let rows = wrapped(["graph TD", long], width: 80, margin: "  ")
        XCTAssertEqual(rows.count, 4, "200 characters at 80 columns is three rows plus the declaration")
        let block = try XCTUnwrap(TerminalBufferScanner.blocks(in: rows.joined(separator: "\n")).first)
        XCTAssertEqual(block.lines, 0...3)
        XCTAssertTrue(block.detection.extractedSource.contains(String(repeating: "x", count: 200)))
    }

    // MARK: - What must not be joined

    /// The regression this rule exists to avoid. Two statements of the same length, the longest in
    /// their window: reading the longest row as a wrap width would join the second onto the first
    /// and break a diagram that was fine. Syntax does not, because both rows close their quotes.
    func testTwoStatementsOfEqualLengthAreTwoLines() throws {
        let window = """
        graph TD
            Alpha --> Beta["one"]
            Gamma --> Delta["two"]
        """
        let block = try XCTUnwrap(TerminalBufferScanner.blocks(in: window).first)
        XCTAssertEqual(block.lines, 0...2)
        XCTAssertEqual(
            block.detection.extractedSource.split(separator: "\n").count,
            3,
            "three lines in, three lines out"
        )
    }

    /// A blank row ends the run whatever came before it. A wrap has more text by definition, so an
    /// empty row means the line really did end -- and a diagram whose label is left open by a
    /// scrolled-off row must not swallow the paragraph after the gap.
    func testABlankRowEndsARun() {
        let flags = RowContinuation.flags(in: ["A[\"open", "", "  not a tail"])
        XCTAssertEqual(flags, [false, false, false])
    }

    /// One logical line may not run past the cap, so an unterminated diagram cannot absorb a screen
    /// of whatever followed it one row at a time.
    func testARunStopsAtTheCap() {
        let rows = ["A[\"open"] + Array(repeating: "more", count: RowContinuation.maximumRows + 4)
        let flags = RowContinuation.flags(in: rows)
        XCTAssertEqual(flags.filter { $0 }.count, RowContinuation.maximumRows)
        XCTAssertFalse(flags[RowContinuation.maximumRows + 1])
    }

    /// A row that is the tail of a label is text, even when the text is a fence marker. Closing
    /// the block there would end it one row into a label and leave the rest of the diagram outside.
    /// A closing fence is a row of nothing but the marker, so this is the shape that reaches it.
    func testAFenceMarkerThatIsATailDoesNotCloseTheBlock() throws {
        let window = """
        ```mermaid
        graph TD
            A --> B["wrapped
        ```
            B --> C
        ```
        """
        let block = try XCTUnwrap(TerminalBufferScanner.blocks(in: window).first)
        XCTAssertEqual(block.lines, 0...5, "the closing fence is the last row, not the tail on row 3")
        XCTAssertTrue(block.detection.extractedSource.contains("B --> C"))
    }

    // MARK: - Unterminated rows

    func testWhatCountsAsUnterminated() {
        // Closed: a whole statement, whatever it contains.
        XCTAssertFalse(RowContinuation.isUnterminated("    ROOT[\"haulla<br/>(yarn@4.3.0 + turbo)\"]"))
        XCTAssertFalse(RowContinuation.isUnterminated("graph TD"))
        XCTAssertFalse(RowContinuation.isUnterminated(""))
        // Open quote, then open bracket: the row cannot be a statement on its own.
        XCTAssertTrue(RowContinuation.isUnterminated("    FE --> FE1[\"back-office-front<br/>hauler"))
        XCTAssertTrue(RowContinuation.isUnterminated("    subgraph one ("))
        // A pipe is the same character at both ends, so an odd one says nothing.
        XCTAssertFalse(RowContinuation.isUnterminated("    FE1 -.->|workspace:^| UI"))
        XCTAssertFalse(RowContinuation.isUnterminated("    A -->|half"))
        // Brackets inside a closed quote are text.
        XCTAssertFalse(RowContinuation.isUnterminated("    A --> B[\"unbalanced ( inside\"]"))
        // A comment's brackets are prose, and joining the row after it would take that row out of
        // the diagram.
        XCTAssertFalse(RowContinuation.isUnterminated("    %% see figure ("))
    }
}
