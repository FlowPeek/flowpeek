import XCTest
@testable import FlowPeekCore

/// What the scanner says about the window it was given, so a caller that can read further knows
/// whether to.
///
/// The numbers these pin were measured on a real Ghostty buffer: a 351-line diagram printed by
/// Claude Code 2.1.269 inside a seven-turn transcript, 1,200 rows, the diagram occupying rows
/// 41 to 391. Over the 380 scroll positions that show any part of it, the window this path has
/// always cut -- the viewport plus 120 lines either side -- recovered the whole diagram 0 times,
/// a fragment 150 times and nothing 230 times. Opening both cut ends and rescanning recovered it
/// 380 times, with no fragments and no silence.
final class TerminalWindowEdgeTests: XCTestCase {
    /// A row the way Claude Code prints one: a two-space margin down everything it says.
    private func printed(_ lines: [String]) -> [String] { lines.map { "  " + $0 } }

    // MARK: - A block that ran off the bottom

    func testABlockRunningToTheWindowsLastRowSaysSo() throws {
        let rows = printed(["mermaid", "flowchart TD", "    A --> B", "    B --> C"])
        let block = try XCTUnwrap(TerminalBufferScanner.blocks(in: rows.joined(separator: "\n")).first)
        XCTAssertTrue(block.reachedWindowEnd, "the diagram's last row is the window's last row")
    }

    /// The other side of it, and the one that keeps the flag from meaning nothing: a block that
    /// stopped because the diagram stopped is not cut, however close to the edge it ends.
    func testABlockThatEndedOnItsOwnDoesNot() throws {
        let rows = printed(["mermaid", "flowchart TD", "    A --> B", "", "$ "])
        let block = try XCTUnwrap(TerminalBufferScanner.blocks(in: rows.joined(separator: "\n")).first)
        XCTAssertFalse(block.reachedWindowEnd)
        XCTAssertEqual(block.lines, 1...2)
    }

    /// A closing fence landing on the window's last row is proof of an ending, not a cut. This is
    /// `cat` of a file whose last line is the fence.
    func testAClosingFenceOnTheLastRowIsAnEnding() throws {
        let window = """
        ```mermaid
        graph TD
            A --> B
        ```
        """
        let block = try XCTUnwrap(TerminalBufferScanner.blocks(in: window).first)
        XCTAssertTrue(block.isFenced)
        XCTAssertFalse(block.reachedWindowEnd)
    }

    /// And a fence whose partner never arrived is a cut, while still being a block: refusing it
    /// would take away an outline the reader can already see.
    func testAFenceWithNoPartnerIsABlockAndIsCut() throws {
        let window = """
        ```mermaid
        graph TD
            A --> B
        """
        let block = try XCTUnwrap(TerminalBufferScanner.blocks(in: window).first)
        XCTAssertTrue(block.reachedWindowEnd)
        XCTAssertTrue(block.detection.extractedSource.contains("A --> B"))
    }

    /// Stopping at the line cap is a limit of the scanner's own. Reporting it as a cut would have a
    /// caller read further forever and never get past it.
    func testStoppingAtTheLineCapIsNotACut() throws {
        let body = (0..<(TerminalBufferScanner.maximumUnfencedLines + 40)).map { "    N\($0) --> N\($0 + 1)" }
        let rows = printed(["mermaid", "flowchart TD"] + body)
        let block = try XCTUnwrap(TerminalBufferScanner.blocks(in: rows.joined(separator: "\n")).first)
        XCTAssertEqual(block.lines.count, TerminalBufferScanner.maximumUnfencedLines)
        XCTAssertFalse(block.reachedWindowEnd, "reading further would never reach an end that is not there")
    }

    // MARK: - A block that ran off the top

    /// The head cut leaves nothing to put a flag on: the scanner only ever starts a block at a
    /// fence or a declaration, and a body row is neither, so a window opening mid-diagram returns
    /// no blocks at all. The evidence has to come from the rows above it.
    func testAWindowOpeningInsideADiagramReturnsNothing() {
        let rows = printed(["    A --> B", "    B --> C", "    C --> D"])
        XCTAssertEqual(TerminalBufferScanner.blocks(in: rows.joined(separator: "\n")), [])
    }

    func testTheDeclarationAboveTheWindowIsFound() {
        let above = printed(["some prose", "mermaid", "flowchart TD", "    A --> B"])
        XCTAssertEqual(TerminalBufferScanner.rowsBackToDeclaration(above), 2, "two rows back to the declaration")
    }

    /// A fence opens a block too, and in a terminal it is often the only thing that does: a file
    /// `cat` into the window carries its fence, where a coding agent prints none.
    func testAFenceAboveTheWindowCountsToo() {
        let above = printed(["prose", "```mermaid"])
        XCTAssertEqual(TerminalBufferScanner.rowsBackToDeclaration(above), 1)
    }

    func testOrdinaryOutputAboveTheWindowAsksForNothing() {
        let above = printed([
            "$ git diff --stat",
            " README.md | 17 ++-",
            " 1 file changed",
            "| a | b |",
            "|---|---|",
        ])
        XCTAssertNil(
            TerminalBufferScanner.rowsBackToDeclaration(above),
            "a table rule and a diff header are not a diagram"
        )
    }

    /// Only as far back as a block could run anyway: past that the declaration cannot belong to
    /// what is on screen, and reading to it would be reading somebody else's scrollback.
    func testADeclarationTooFarAboveIsOutOfReach() {
        let far = printed(["flowchart TD"])
            + printed((0..<(TerminalBufferScanner.maximumUnfencedLines + 10)).map { "line \($0)" })
        XCTAssertNil(TerminalBufferScanner.rowsBackToDeclaration(far))
    }

    func testNothingAboveAsksForNothing() {
        XCTAssertNil(TerminalBufferScanner.rowsBackToDeclaration([]))
    }

    // MARK: - The ceiling a terminal block is held to

    /// A diagram a coding agent prints is routinely past the limit a document block is held to, and
    /// it was being found, rebuilt, and then thrown away at the last step.
    func testATerminalBlockIsAllowedToBeBigger() {
        XCTAssertGreaterThan(AmbientPeekPolicy.maximumTerminalCharacters, AmbientPeekPolicy.maximumCharacters)
        XCTAssertLessThanOrEqual(
            AmbientPeekPolicy.maximumTerminalCharacters, MermaidSource.maximumCharacters,
            "nothing may be admitted here that the preview would then refuse"
        )
        // Measured: a 260-line dependency graph recovers whole at 17,076 characters, a 380-line one
        // at 25,102. Both were refused by the document limit.
        XCTAssertGreaterThan(AmbientPeekPolicy.maximumTerminalCharacters, 25_102)
    }
}
