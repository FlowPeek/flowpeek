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
        // A brace that opens a block is not a label a wrap has broken, and neither is the brace in
        // an erDiagram's cardinality mark.
        XCTAssertFalse(RowContinuation.isUnterminated("      SURFACE {"))
        XCTAssertFalse(RowContinuation.isUnterminated("      SURFACE ||--o{ READING : accumulates"))
        XCTAssertFalse(RowContinuation.isUnterminated("      A }o--|| B : has"))
        // But a real open brace still is.
        XCTAssertTrue(RowContinuation.isUnterminated("    A --> B{\"is it cach"))
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
        // And it is fixed without the grid too, because the fault was never the width: a brace
        // that opens a block, and the brace inside an `erDiagram` cardinality mark, are not labels
        // a wrap has broken.
        let blind = try XCTUnwrap(TerminalBufferScanner.blocks(in: window).first)
        XCTAssertEqual(blind.detection.extractedSource.split(separator: "\n").count, 5)
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


/// The blank row a wrapping program prints when a word will not fit under its own indentation.
///
/// Every row here came off Claude Code 2.1.269 driven in a pty at a hundred columns, with a
/// 97-character identifier eight spaces deep. What the renderer produced is a blank row in the
/// middle of the diagram followed by the word at the margin -- and a blank row ends an unfenced
/// block, so a six-line diagram came back as two lines at a confidence that passes, framed and
/// previewed as though that were all of it.
final class WrapPaddingTests: XCTestCase {
    /// The measured rows, verbatim.
    private static let rows = [
        "  flowchart TD",
        "      subgraph S[\"a scope\"]",
        "",
        "  VeryLongSubgraphScopedIdentifierThatNobodyWouldTypeButAnAgentHappilyGeneratesXXXXXXXXXXXXXXXXXXXX",
        "  --> B",
        "          B --> C",
        "      end",
        "      C --> D[Done]",
    ]

    func testTheBlankRowIsRecognisedAsLayout() {
        XCTAssertTrue(
            RowContinuation.isPadding(Self.rows[2], after: Self.rows[1], before: Self.rows[3], columns: 100)
        )
        XCTAssertEqual(
            RowContinuation.roles(in: Self.rows, columns: 100)[2], .padding
        )
    }

    /// The whole diagram, not the two lines above the blank row.
    func testTheWholeDiagramSurvivesTheBlankRow() throws {
        let window = Self.rows.joined(separator: "\n")
        let block = try XCTUnwrap(TerminalBufferScanner.blocks(in: window, columns: 100).first)
        let source = block.detection.extractedSource
        XCTAssertEqual(source.split(separator: "\n").count, 6, "six lines in, six lines out: \(source)")
        XCTAssertTrue(
            source.contains("XXXXXXXXXXXXXXXXXXXX --> B"),
            "the line the padding broke has to come back whole: \(source)"
        )
        XCTAssertTrue(source.contains("C --> D[Done]"), "and the block must not end at the blank row")
        XCTAssertFalse(source.contains("\n\n"), "the row nobody typed must not be in the text")
    }

    /// And the bug, still there when nothing says how wide the grid is, because a blank row cannot
    /// be told from a blank line without it.
    func testWithoutTheWidthItIsStillTwoLines() throws {
        let window = Self.rows.joined(separator: "\n")
        let block = try XCTUnwrap(TerminalBufferScanner.blocks(in: window).first)
        XCTAssertEqual(block.detection.extractedSource.split(separator: "\n").count, 2)
    }

    // MARK: - What must not be mistaken for it

    /// A blank line an author wrote, which is ordinary between a diagram's statements and its
    /// styling section. Nothing here is near the width and the indentation did not move.
    func testAnOrdinaryBlankLineIsLeftAlone() {
        let rows = [
            "  flowchart TD",
            "      A --> B",
            "",
            "      style A fill:#0a84ff",
        ]
        XCTAssertFalse(RowContinuation.isPadding(rows[2], after: rows[1], before: rows[3], columns: 100))
        XCTAssertEqual(RowContinuation.roles(in: rows, columns: 100)[2], .line)
    }

    /// A row that kept its indentation was not moved left to make room, whatever its length.
    func testARowThatKeptItsIndentationIsNotPadding() {
        let deep = "        " + String(repeating: "x", count: 90)
        XCTAssertFalse(RowContinuation.isPadding("", after: "        A --> B", before: deep, columns: 100))
    }

    /// A row that would have fitted where it was does not need a blank row to explain it.
    func testARowThatWouldHaveFittedIsNotPadding() {
        XCTAssertFalse(
            RowContinuation.isPadding("", after: "      A --> B", before: "  C --> D", columns: 100)
        )
    }

    func testWithoutAColumnCountNothingIsPadding() {
        XCTAssertEqual(RowContinuation.roles(in: Self.rows).filter { $0 == .padding }.count, 0)
    }
}


/// What happens when the column count is a little wrong, which is the state a measured one is
/// always in.
///
/// The two directions the width is used in are not equally safe. Making a join the syntax cannot
/// see needs the width to be right. Refusing a join the syntax asked for needs it to be right *and*
/// destroys a block when it is not: measured on rows a terminal really printed at 80 columns, read
/// as 85, an eight-row block came back as three -- worse than having no column count at all,
/// because the refused join leaves a tail row carrying no arrow and no indentation and the block
/// ends there.
final class WidthToleranceTests: XCTestCase {
    /// Printed by a program wrapping its own output at 80 columns, with no margin on the tails.
    private static let rows = [
        "  mermaid",
        "  flowchart TD",
        "      A[\"FlowPeek reads the terminal pane through the accessibility API and",
        "rejoins the wrapped rows\"] --> B[\"RowContinuation decides which rows are tails",
        "of the row above them\"]",
        "      B --> C[\"The detector scores the reconstructed source for confidence",
        "before anything is drawn\"]",
    ]

    private func block(_ columns: Int?) throws -> TerminalDiagramBlock {
        try XCTUnwrap(
            TerminalBufferScanner.blocks(in: Self.rows.joined(separator: "\n"), columns: columns).first
        )
    }

    func testTheWholeBlockSurvivesAColumnCountThatIsOff() throws {
        for columns in [70, 75, 78, 79, 80, 81, 85] {
            let found = try block(columns)
            XCTAssertEqual(found.lines, 1...6, "at \(columns) columns the block was cut")
        }
    }

    /// And at the right width it is also correct, which is the point of having the number at all.
    func testTheSpacesComeBackAtTheRightWidth() throws {
        let source = try block(80).detection.extractedSource
        XCTAssertTrue(source.contains("API and rejoins"), source)
        XCTAssertTrue(source.contains("tails of the row"), source)
        XCTAssertTrue(source.contains("confidence before anything"), source)
    }

    /// Without it the rows still join -- the syntax can see these -- but the spaces are gone.
    func testWithoutTheWidthTheSpacesAreLost() throws {
        let source = try block(nil).detection.extractedSource
        XCTAssertTrue(source.contains("API andrejoins"), "the ate space is still gone: \(source)")
    }

    /// The refusal still does its job where it was needed: an `erDiagram` whose first statement
    /// opens a brace is unterminated for the rest of the diagram, and nothing here is near the edge.
    func testAJoinWithRoomToSpareIsStillRefused() throws {
        let rows = [
            "  erDiagram",
            "      SURFACE ||--o{ READING : accumulates",
            "      SURFACE {",
            "          int processIdentifier",
            "      }",
        ]
        let found = try XCTUnwrap(
            TerminalBufferScanner.blocks(in: rows.joined(separator: "\n"), columns: 160).first
        )
        XCTAssertEqual(found.detection.extractedSource.split(separator: "\n").count, 5)
    }

    func testWhatCountsAsRoomToSpare() {
        // 20 wide at 80 columns, next row starting with a 5-letter word: plainly room.
        XCTAssertTrue(RowContinuation.hadRoomToSpare(after: String(repeating: "x", count: 20), next: "hello", columns: 80))
        // 70 wide, same word: 70 + 1 + 5 + 8 is past 80, so the grid does not get to overrule.
        XCTAssertFalse(RowContinuation.hadRoomToSpare(after: String(repeating: "x", count: 70), next: "hello", columns: 80))
    }
}
