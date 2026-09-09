import Foundation
import XCTest
@testable import FlowPeekCore

/// A diagram printed inside a box-drawing frame. Measured in Ghostty against Claude Code's output:
/// text was read off the pane and zero blocks came out of it, because every row began with a border
/// and a space.
final class BoxGutterTests: XCTestCase {
    private let boxedFence = """
    ╭──────────────────────╮
    │ ```mermaid           │
    │ flowchart TD         │
    │   A[Start] --> B[Go] │
    │ ```                  │
    ╰──────────────────────╯
    """

    func testABoxedFenceIsFound() throws {
        let blocks = TerminalBufferScanner.blocks(in: boxedFence)
        XCTAssertEqual(blocks.count, 1)
        let block = try XCTUnwrap(blocks.first)
        XCTAssertTrue(block.isFenced)
        XCTAssertEqual(block.text, "```mermaid\nflowchart TD\n  A[Start] --> B[Go]\n```")
    }

    /// The offsets are the row's, not the text's: they are what maps the block back onto the screen,
    /// and a row is in the same place whether or not it has a border down its side.
    func testTheBorderDoesNotMoveTheRows() throws {
        let block = try XCTUnwrap(TerminalBufferScanner.blocks(in: boxedFence).first)
        XCTAssertEqual(block.lines, 1...4)
        let window = boxedFence as NSString
        XCTAssertEqual(window.substring(with: block.lastRow), "│ ```                  │")
    }

    /// The one indentation that survives is the diagram's own.
    func testIndentationInsideTheBoxIsKept() throws {
        let boxed = """
        │ flowchart TD      │
        │     A --> B       │
        │     B --> C       │
        """
        let stripped = try XCTUnwrap(BoxGutter.strip(boxed.components(separatedBy: "\n")))
        XCTAssertEqual(stripped, ["flowchart TD", "    A --> B", "    B --> C"])
    }

    /// Pipes are in the border set, so the run length is the whole of what keeps them off content:
    /// a wrapped edge label begins with one, and so does every row of a markdown table.
    func testASingleLeadingPipeIsContent() {
        XCTAssertNil(BoxGutter.strip(["flowchart TD", "  A -->", "|yes| B", "  B --> C"]))
    }

    /// Only the boxed run is touched. A box frames part of a screen; the rows around it are output.
    func testOutputAroundTheBoxIsUntouched() throws {
        let lines = [
            "$ claude",
            "│ flowchart TD",
            "│   A --> B",
            "│   B --> C",
            "$ ",
        ]
        XCTAssertEqual(
            try XCTUnwrap(BoxGutter.strip(lines)),
            ["$ claude", "flowchart TD", "  A --> B", "  B --> C", "$ "]
        )
    }

    /// A box with no right-hand border is still a box.
    func testAOneSidedBoxIsStripped() throws {
        let lines = ["┃ flowchart TD", "┃   A --> B", "┃   B --> C"]
        XCTAssertEqual(try XCTUnwrap(BoxGutter.strip(lines)), ["flowchart TD", "  A --> B", "  B --> C"])
    }

    /// Two rows are not a frame, whatever they start with.
    func testTwoRowsAreNotABox() {
        XCTAssertNil(BoxGutter.strip(["│ flowchart TD", "│   A --> B"]))
    }

    /// Mixed border characters are two things that happen to look alike, not one frame.
    func testARunNeedsTheSameBorder() {
        XCTAssertNil(BoxGutter.strip(["│ flowchart TD", "┃   A --> B", "| B --> C"]))
    }

    /// The clipboard route reads a boxed diagram as text, so the detector has to see through the
    /// frame too -- mermaid would fail on a border down either side.
    func testTheDetectorReadsThroughABox() {
        let detection = MermaidDetector.detect("""
        │ flowchart TD         │
        │   A[Start] --> B[Go] │
        │   B --> C[Done]      │
        """)
        XCTAssertGreaterThanOrEqual(detection.confidence, .likely)
        XCTAssertEqual(detection.extractedSource, "flowchart TD\n  A[Start] --> B[Go]\n  B --> C[Done]")
    }
}
