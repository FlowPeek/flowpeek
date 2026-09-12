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

/// What the terminal's own column count adds to the rejoin.
///
/// Every fixture here was measured, not imagined: Claude Code 2.1.269 was driven in a pty of a
/// known width with `claude --resume` over a synthetic transcript, the screen reconstructed, and
/// these rows taken off it. Across 50 agent-style diagrams at 80, 100, 120 and 160 columns the
/// renderer produced 79 breaks, every one of them at a space -- 67 on a row short of the width and
/// 12 on a row at exactly it -- and three constructed over-long labels broke mid-word, all three on
/// a row at exactly the width. Feeding those 200 screens back through the scanner recovered the
/// source it was printed from 132 times without the column count and 200 times with it.
final class TerminalGridRejoinTests: XCTestCase {
    /// Measured at 100 columns. The row is short of the width and the label is left open, so the
    /// old rule already joined it -- and joined it wrong, running `4 *` into `cellHeight"}`.
    func testAWrapShortOfTheWidthPutsTheSpaceBack() throws {
        let rows = [
            "  flowchart TD",
            "      B[\"padding = viewportSize.height * scale - heightInPixels\"] --> C{\"-0.5 <= padding <= 4 *",
            "  cellHeight\"}",
        ]
        let window = rows.joined(separator: "\n")
        let block = try XCTUnwrap(TerminalBufferScanner.blocks(in: window, columns: 100).first)
        XCTAssertTrue(
            block.detection.extractedSource.contains("4 * cellHeight\"}"),
            "the space the wrap ate has to come back: \(block.detection.extractedSource)"
        )
        // And without the column count, exactly what it did before.
        let blind = try XCTUnwrap(TerminalBufferScanner.blocks(in: window).first)
        XCTAssertTrue(blind.detection.extractedSource.contains("4 *cellHeight\"}"))
    }

    /// Measured at 100 columns: the row is exactly 100 wide and the break is still at a space.
    /// Twelve of the 79 breaks looked like this, which is why "at the width" cannot mean "split
    /// mid-word" on its own.
    func testARowFilledToTheWidthCanStillHaveBeenBrokenAtASpace() throws {
        let previous = "      Note right of FlowPeek: nothing is read until the gesture is held, and nothing is written to a"
        XCTAssertEqual(RowContinuation.displayWidth(previous), 100, "the fixture has to sit on the edge")
        XCTAssertTrue(RowContinuation.wrapDestroyedASpace(before: "  log", after: previous, columns: 100))
    }

    /// Measured at 80 columns. A label with no space in it for 121 characters cannot be placed
    /// whole on any row of an 80-column grid, so the renderer split the word -- and putting a space
    /// back at that joint would invent one that was never typed.
    func testAWordTooLongToPlaceIsSplitAndKeepsNoSpace() throws {
        let previous = "      ROOT[\"back-office-front<br/>customer-tycoon-front<br/>generator-front<br/>"
        let tail = "  hauler-front<br/>official-zzapad-jira-connector\"]"
        XCTAssertEqual(RowContinuation.displayWidth(previous), 80)
        XCTAssertFalse(RowContinuation.wrapDestroyedASpace(before: tail, after: previous, columns: 80))

        let window = ["  flowchart TD", previous, tail, "      ROOT --> B[End]"].joined(separator: "\n")
        let block = try XCTUnwrap(TerminalBufferScanner.blocks(in: window, columns: 80).first)
        XCTAssertTrue(block.detection.extractedSource.contains("generator-front<br/>hauler-front"))
    }

    /// The break the syntax cannot see. Measured at 100 columns: the row closes every bracket it
    /// opened, so it reads as a whole statement, and the rest of the line is on the next row.
    func testAWidthBreakIsJoinedEvenWhenTheRowLooksFinished() throws {
        let rows = [
            "  flowchart TD",
            "      A[\"FlowPeek reads the terminal pane through the accessibility API and rejoins wrapped rows\"]",
            "  --> B[\"RowContinuation decides which rows are tails\"]",
        ]
        let window = rows.joined(separator: "\n")
        let block = try XCTUnwrap(TerminalBufferScanner.blocks(in: window, columns: 100).first)
        XCTAssertEqual(
            block.detection.extractedSource.split(separator: "\n").count, 2,
            "the declaration and the one statement it wraps to two rows"
        )
        XCTAssertTrue(block.detection.extractedSource.contains("wrapped rows\"] --> B["))
    }

    /// The other direction, and the one that cost the most: an `erDiagram` whose first statement
    /// opens a brace is unterminated forever, so the syntax rule swallowed the whole diagram into
    /// one line. Nothing here is near the width, so the grid says no wrap happened and the rows
    /// stay the lines they are. Measured at 160 columns.
    func testAJoinTheWidthRulesOutIsRefused() throws {
        let rows = [
            "  erDiagram",
            "      SURFACE ||--o{ READING : accumulates",
            "      SURFACE {",
            "          int processIdentifier",
            "      }",
        ]
        let window = rows.joined(separator: "\n")
        let block = try XCTUnwrap(TerminalBufferScanner.blocks(in: window, columns: 160).first)
        XCTAssertEqual(
            block.detection.extractedSource.split(separator: "\n").count, 5,
            "five rows in, five lines out: \(block.detection.extractedSource)"
        )
        // And the bug, still there when nothing says how wide the grid is.
        let blind = try XCTUnwrap(TerminalBufferScanner.blocks(in: window).first)
        XCTAssertEqual(blind.detection.extractedSource.split(separator: "\n").count, 2)
    }

    /// The regression the syntax rule was written to avoid, now with the width known as well. Two
    /// statements of equal length sit nowhere near an 80-column edge, and neither lost its
    /// indentation, so nothing joins.
    func testTwoStatementsOfEqualLengthStayTwoLinesWithTheWidthKnown() throws {
        let window = """
          graph TD
              Alpha --> Beta["one"]
              Gamma --> Delta["two"]
        """
        let block = try XCTUnwrap(TerminalBufferScanner.blocks(in: window, columns: 80).first)
        XCTAssertEqual(block.detection.extractedSource.split(separator: "\n").count, 3)
    }

    // MARK: - How wide a row is

    /// A Hangul syllable is two cells. Counting characters instead would put every row of a Korean
    /// diagram well short of the width and read every join as a word wrap.
    func testAHangulSyllableIsTwoCells() {
        XCTAssertEqual(RowContinuation.displayWidth("읽기 --> 판단"), 4 + 1 + 3 + 1 + 4)
        XCTAssertEqual(RowContinuation.displayWidth("abc"), 3)
    }

    /// A number that did not come from a terminal answers nothing, rather than answering wrongly.
    func testAColumnCountOutsideTheBandIsIgnored() {
        XCTAssertFalse(RowContinuation.couldNotHaveFit(after: "abc", next: "def", columns: 4))
        XCTAssertFalse(RowContinuation.wrapDestroyedASpace(before: "def", after: "abc", columns: 0))
        XCTAssertEqual(
            RowContinuation.flags(in: ["A[\"open", "  tail"], columns: 3),
            RowContinuation.flags(in: ["A[\"open", "  tail"]),
            "an unusable count leaves the old rule exactly as it was"
        )
    }

    /// A row wider than the grid did not come off a grid of that width, so it is left alone.
    func testARowWiderThanTheGridSaysNothing() {
        let long = String(repeating: "x", count: 200)
        XCTAssertFalse(RowContinuation.couldNotHaveFit(after: long, next: "  tail", columns: 100))
        XCTAssertFalse(RowContinuation.wrapDestroyedASpace(before: "  tail", after: long, columns: 100))
    }
}
