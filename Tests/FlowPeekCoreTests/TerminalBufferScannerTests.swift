import Foundation
import XCTest
@testable import FlowPeekCore

/// Finding a diagram in terminal output, which is not a document: there is a shell prompt above it,
/// often no fence at all, and whatever ran next printed underneath.
final class TerminalBufferScannerTests: XCTestCase {
    private static let diagram = """
    flowchart TD
        A[Start] --> B{Is it Mermaid?}
        B -- yes --> C[Preview]
        B -- no --> D[Ignore]
    """

    private func buffer(_ parts: String...) -> String { parts.joined(separator: "\n") }

    // MARK: - Finding blocks

    /// `cat design.mmd` is the whole point of this route: no fence, a prompt above, a prompt below.
    func testAnUnfencedDiagramBetweenTwoPromptsIsFound() throws {
        let window = buffer("➜  ~ cat design.mmd", Self.diagram, "➜  ~ ")
        let blocks = TerminalBufferScanner.blocks(in: window)
        XCTAssertEqual(blocks.count, 1)
        let block = try XCTUnwrap(blocks.first)
        XCTAssertFalse(block.isFenced)
        XCTAssertEqual(block.lines, 1...4)
        XCTAssertEqual(block.detection.diagramKeyword, "flowchart")
        // The prompt underneath is not part of the diagram.
        XCTAssertFalse(block.text.contains("➜"))
    }

    func testAFencedDiagramIsFoundWithItsFences() throws {
        let window = buffer("➜  ~ cat README.md", "# Title", "", "```mermaid", Self.diagram, "```", "prose", "➜  ~ ")
        let block = try XCTUnwrap(TerminalBufferScanner.blocks(in: window).first)
        XCTAssertTrue(block.isFenced)
        XCTAssertEqual(block.lines, 3...8)
        XCTAssertTrue(block.text.hasPrefix("```mermaid"))
    }

    func testTheRangeNamesWhereTheBlockSatInTheWindow() throws {
        let window = buffer("➜  ~ cat design.mmd", Self.diagram, "➜  ~ ")
        let block = try XCTUnwrap(TerminalBufferScanner.blocks(in: window).first)
        let slice = (window as NSString).substring(with: block.range)
        XCTAssertEqual(slice, Self.diagram)
    }

    /// The last row is carried separately because a terminal cannot be trusted to measure a whole
    /// block: it is what the vertical extent's lower edge is read from.
    func testTheLastRowRangeNamesTheBlocksFinalLine() throws {
        let window = buffer("➜  ~ cat README.md", "```mermaid", Self.diagram, "```", "➜  ~ ")
        let block = try XCTUnwrap(TerminalBufferScanner.blocks(in: window).first)
        XCTAssertEqual((window as NSString).substring(with: block.lastRow), "```")
        XCTAssertEqual(
            (window as NSString).substring(with: NSRange(location: block.range.location, length: 10)),
            "```mermaid"
        )
    }

    func testTheLastRowOfAnUnfencedBlockIsItsFinalStatement() throws {
        let window = buffer("➜  ~ cat design.mmd", Self.diagram, "➜  ~ ")
        let block = try XCTUnwrap(TerminalBufferScanner.blocks(in: window).first)
        XCTAssertEqual(
            (window as NSString).substring(with: block.lastRow),
            "    B -- no --> D[Ignore]"
        )
    }

    func testOrdinaryOutputYieldsNothing() {
        let window = buffer(
            "➜  ~ ls -l",
            "total 24",
            "-rw-r--r--  1 tim  staff   8655 Sep  8 10:49 sample.txt",
            "➜  ~ git log --oneline",
            "f91d8a8 Initial commit",
            "➜  ~ "
        )
        XCTAssertEqual(TerminalBufferScanner.blocks(in: window), [])
    }

    /// A line that merely mentions a word mermaid also uses is prose, and the detector's confidence
    /// floor is what keeps an outline off it.
    func testALineThatOnlyMentionsAGraphIsNotADiagram() {
        let window = buffer("➜  ~ echo hi", "graph of dependencies rendered above", "➜  ~ ")
        XCTAssertEqual(TerminalBufferScanner.blocks(in: window), [])
    }

    func testTwoDiagramsInOneWindowAreBothFound() {
        let window = buffer(
            "➜  ~ cat a.mmd",
            Self.diagram,
            "➜  ~ cat b.mmd",
            "sequenceDiagram",
            "    Alice->>Bob: Hello",
            "    Bob-->>Alice: Hi",
            "➜  ~ "
        )
        XCTAssertEqual(TerminalBufferScanner.blocks(in: window).count, 2)
    }

    // MARK: - Where an unfenced block ends

    func testABlankLineEndsAnUnfencedBlock() throws {
        let window = buffer("➜  ~ cat design.mmd", Self.diagram, "", "unrelated log line", "➜  ~ ")
        let block = try XCTUnwrap(TerminalBufferScanner.blocks(in: window).first)
        XCTAssertEqual(block.lines, 1...4)
    }

    /// A blank line inside a diagram is ordinary -- a styling section or a subgraph body is
    /// separated from the statements above it -- and what follows is indented, which is the signal
    /// that the block continues.
    func testABlankLineFollowedByIndentedTextDoesNotEndTheBlock() throws {
        let window = buffer(
            "➜  ~ cat design.mmd",
            "flowchart TD",
            "    A --> B",
            "",
            "    classDef done fill:#bbf",
            "➜  ~ "
        )
        let block = try XCTUnwrap(TerminalBufferScanner.blocks(in: window).first)
        XCTAssertEqual(block.lines, 1...4)
    }

    /// A terse diagram writes its body flush left. The arrow is what says the line belongs to it.
    func testAnUnindentedBodyContinuesOnItsArrows() throws {
        let window = buffer("➜  ~ cat terse.mmd", "graph TD", "A-->B", "B-->C", "➜  ~ ")
        let block = try XCTUnwrap(TerminalBufferScanner.blocks(in: window).first)
        XCTAssertEqual(block.lines, 1...3)
    }

    func testACommentLineContinuesTheBlock() throws {
        let window = buffer("➜  ~ cat design.mmd", "flowchart TD", "%% the happy path", "    A --> B", "➜  ~ ")
        let block = try XCTUnwrap(TerminalBufferScanner.blocks(in: window).first)
        XCTAssertEqual(block.lines, 1...3)
    }

    /// The line after a diagram is a prompt far more often than it is blank, and a prompt carrying
    /// a command with double-dashed flags must not read as a link.
    func testAPromptWithFlagsDoesNotContinueTheBlock() throws {
        let window = buffer("flowchart TD", "    A --> B", "➜  ~ git log --oneline --graph", "f91d8a8 Initial commit")
        let block = try XCTUnwrap(TerminalBufferScanner.blocks(in: window).first)
        XCTAssertEqual(block.lines, 0...1)
    }

    /// A rule of dashes contains `---`, which is in the arrow table, and is a separator in
    /// somebody's output rather than a link.
    func testARuleOfDashesDoesNotContinueTheBlock() throws {
        let window = buffer("flowchart TD", "    A --> B", "--------------------", "totals below")
        let block = try XCTUnwrap(TerminalBufferScanner.blocks(in: window).first)
        XCTAssertEqual(block.lines, 0...1)
    }

    func testAnUnfencedBlockCannotRunPastItsLineLimit() throws {
        let filler = (0..<(TerminalBufferScanner.maximumUnfencedLines + 200))
            .map { "    A\($0) --> B\($0)" }
            .joined(separator: "\n")
        let block = try XCTUnwrap(TerminalBufferScanner.blocks(in: "flowchart TD\n" + filler).first)
        XCTAssertEqual(block.lines.count, TerminalBufferScanner.maximumUnfencedLines)
    }

    /// An unclosed fence is what a terminal shows while a file is still printing.
    func testAnUnclosedFenceRunsToTheEndOfTheWindow() throws {
        let window = buffer("```mermaid", Self.diagram)
        let block = try XCTUnwrap(TerminalBufferScanner.blocks(in: window).first)
        XCTAssertTrue(block.isFenced)
        XCTAssertEqual(block.lines, 0...4)
    }

    // MARK: - Windows that open mid-block

    /// A window into a terminal's buffer routinely starts in the middle of something. Measured in
    /// Terminal.app: two rows of the previous diagram's tail, its closing fence among them, above
    /// the block actually on screen. That closing fence reads exactly like an opening one, and
    /// skipping to its partner swallowed the real block.
    func testAStrayClosingFenceDoesNotSwallowTheBlockBelowIt() throws {
        let window = buffer(
            "    C --> E[Done]",
            "```",
            "below 01 .....",
            "➜  ~ clear; cat small.md",
            "",
            "above 01 .....",
            "```mermaid",
            Self.diagram,
            "```",
            "➜  ~ "
        )
        let block = try XCTUnwrap(TerminalBufferScanner.blocks(in: window).first)
        XCTAssertEqual(block.lines, 6...11)
        XCTAssertTrue(block.text.hasPrefix("```mermaid"))
    }

    /// The same rule must not re-enter a fence that did hold a diagram, or the diagram's own body
    /// would be scanned again as if it were loose output.
    func testAFenceThatHeldADiagramIsNotScannedAgain() {
        let window = buffer("```mermaid", Self.diagram, "```", "```", "tail", "➜  ~ ")
        XCTAssertEqual(TerminalBufferScanner.blocks(in: window).count, 1)
    }

    /// A fenced block of something else is stepped over one line at a time now, so its contents
    /// have to stand on their own -- and shell script does not.
    func testAFencedBlockOfOtherCodeStillYieldsNothing() {
        let window = buffer(
            "```sh",
            "for f in *.mmd; do",
            "  echo \"$f\"",
            "done",
            "```",
            "➜  ~ "
        )
        XCTAssertEqual(TerminalBufferScanner.blocks(in: window), [])
    }

    // MARK: - Choosing by what is on screen

    func testABlockWithNothingOnScreenIsNotOffered() {
        let window = buffer("➜  ~ cat design.mmd", Self.diagram, "➜  ~ ", "later output", "more output")
        XCTAssertEqual(TerminalBufferScanner.blocks(in: window, visible: 5...7), [])
    }

    func testABlockHalfOnScreenIsStillOffered() throws {
        let window = buffer("➜  ~ cat design.mmd", Self.diagram, "➜  ~ ")
        // The viewport starts inside the diagram: rows 3 down.
        let block = try XCTUnwrap(TerminalBufferScanner.blocks(in: window, visible: 3...5).first)
        XCTAssertEqual(block.lines, 1...4)
    }

    /// The whole diagram is handed over even when only part of it is on screen. Detecting inside the
    /// viewport alone would find half a diagram, and half a `flowchart` still parses -- so FlowPeek
    /// would offer to open a picture the terminal is not showing.
    func testAHalfVisibleBlockIsStillWholeWhenOffered() throws {
        let window = buffer("➜  ~ cat design.mmd", Self.diagram, "➜  ~ ")
        let block = try XCTUnwrap(TerminalBufferScanner.blocks(in: window, visible: 4...6).first)
        XCTAssertEqual(block.text, Self.diagram)
        XCTAssertTrue(block.text.contains("B -- no --> D[Ignore]"))
    }

    func testOnlyTheBlocksWithRowsOnScreenAreOffered() throws {
        let window = buffer(
            "flowchart TD",           // 0
            "    A --> B",            // 1
            "",                       // 2
            "➜  ~ cat b.mmd",         // 3
            "sequenceDiagram",        // 4
            "    Alice->>Bob: Hello", // 5
            "    Bob-->>Alice: Hi",   // 6
            "➜  ~ "                   // 7
        )
        XCTAssertEqual(
            TerminalBufferScanner.blocks(in: window, visible: 5...7).map(\.detection.diagramKeyword),
            ["sequenceDiagram"]
        )
        XCTAssertEqual(
            TerminalBufferScanner.blocks(in: window, visible: 0...4).map(\.detection.diagramKeyword),
            ["flowchart", "sequenceDiagram"]
        )
    }

    /// Both diagrams on screen means both get a frame, in the order they sit in the buffer.
    func testEveryVisibleBlockIsOffered() throws {
        let window = buffer(
            "flowchart TD",           // 0
            "    A --> B",            // 1
            "",                       // 2
            "sequenceDiagram",        // 3
            "    Alice->>Bob: Hello", // 4
            "➜  ~ "                   // 5
        )
        let blocks = TerminalBufferScanner.blocks(in: window, visible: 0...5)
        XCTAssertEqual(blocks.map(\.detection.diagramKeyword), ["flowchart", "sequenceDiagram"])
        XCTAssertEqual(blocks.map(\.lines), [0...1, 3...4])
    }

    /// Buffer order, whatever their sizes: the order is what the frames are identified by from
    /// one poll to the next, and a block growing must not renumber its neighbours.
    func testBlocksComeBackInBufferOrder() {
        let window = buffer(
            "sequenceDiagram",        // 0
            "    Alice->>Bob: Hello", // 1
            "    Bob-->>Alice: Hi",   // 2
            "    Alice->>Bob: More",  // 3
            "",                       // 4
            "flowchart TD",           // 5
            "    A --> B",            // 6
            "➜  ~ "                   // 7
        )
        XCTAssertEqual(
            TerminalBufferScanner.blocks(in: window, visible: 0...7).map(\.lines),
            [0...3, 5...6]
        )
    }

    // MARK: - Limits

    func testAWindowLargerThanTheLimitIsRefusedBeforeItIsScanned() {
        let window = String(repeating: "flowchart TD\n    A --> B\n", count: 20_000)
        XCTAssertGreaterThan(window.utf16.count, TerminalBufferScanner.maximumWindowCharacters)
        XCTAssertEqual(TerminalBufferScanner.blocks(in: window), [])
    }

    func testAnEmptyWindowYieldsNothing() {
        XCTAssertEqual(TerminalBufferScanner.blocks(in: ""), [])
        XCTAssertEqual(TerminalBufferScanner.blocks(in: "", visible: 0...0), [])
    }

    /// Claude Code prints everything it says behind a two-space margin, which used to make every
    /// paragraph after a diagram look indented under it: the block ran to the end of the answer and
    /// mermaid's parse error was drawn over the prose. Measured, and it failed on line 5.
    func testAMarginDownTheLeftDoesNotMakeProseIntoDiagramBody() throws {
        let window = """
          Here is the flow you asked for:

          flowchart TD
              A[Start] --> B[Render]
              B --> C[Done]

          The renderer hands the SVG back to the panel, which
          sizes itself to it before it is shown.
        """
        let blocks = TerminalBufferScanner.blocks(in: window)
        XCTAssertEqual(blocks.count, 1)
        let block = try XCTUnwrap(blocks.first)
        XCTAssertEqual(block.lines, 2...4)
        XCTAssertFalse(block.text.contains("renderer hands"))
    }

    /// The same margin, and a diagram whose body sits at it rather than past it: an arrow still says
    /// the line belongs to the block.
    func testAnArrowStillContinuesABlockAtTheSameIndent() throws {
        let window = """
          flowchart TD
          A --> B
          B --> C
          The point of all this is that the renderer is lazy.
        """
        let block = try XCTUnwrap(TerminalBufferScanner.blocks(in: window).first)
        XCTAssertEqual(block.lines, 0...2)
    }

    /// Narrowing a Ghostty window from 100 columns to 70 reflowed a typed question so that
    /// `flowchart TD renderer handles` began a row. It scored `.certain` and drew a frame around
    /// the user's own prompt.
    func testAReflowedPromptIsNotADiagram() {
        let window = """
        > Explain how the
          flowchart TD renderer handles
          hard wraps in the middle of a
          declaration line
        """
        XCTAssertEqual(TerminalBufferScanner.blocks(in: window), [])
    }

    /// CRLF reaches a terminal from a Windows file read over a mount, and the offsets a rectangle
    /// is asked for are counted in UTF-16 code units.
    func testCarriageReturnsDoNotShiftTheRange() throws {
        let window = "➜  ~ cat design.mmd\r\n" + Self.diagram.replacingOccurrences(of: "\n", with: "\r\n")
        let block = try XCTUnwrap(TerminalBufferScanner.blocks(in: window).first)
        XCTAssertEqual((window as NSString).substring(with: NSRange(location: block.range.location, length: 12)), "flowchart TD")
    }
}
