import CoreGraphics
import Foundation
import XCTest

@testable import FlowPeekCore

final class CaretBlockGeometryTests: XCTestCase {
    /// The measured shape: a caret line 18 points tall, at the text column of the editor.
    private let caretLine = CGRect(x: 703, y: 500, width: 1078, height: 18)

    func testACaretOnTheOnlyLineGivesThatLine() {
        XCTAssertEqual(
            CaretBlockGeometry.rectangle(caretLine: caretLine, caretLineNumber: 7, firstLine: 7, lastLine: 7),
            caretLine
        )
    }

    /// Four lines are four line heights tall, and the block reaches upward from the caret's line by
    /// exactly the number of lines above it.
    func testTheBlockGrowsUpwardAndDownwardFromTheCaret() throws {
        let rect = try XCTUnwrap(
            CaretBlockGeometry.rectangle(caretLine: caretLine, caretLineNumber: 5, firstLine: 3, lastLine: 6)
        )
        XCTAssertEqual(rect.height, 72, accuracy: 0.001)
        XCTAssertEqual(rect.maxY, caretLine.maxY + 36, accuracy: 0.001)
        XCTAssertEqual(rect.minY, caretLine.maxY + 36 - 72, accuracy: 0.001)
        XCTAssertEqual(rect.origin.x, caretLine.origin.x)
        XCTAssertEqual(rect.width, caretLine.width)
    }

    func testTheCaretLineIsAlwaysInsideTheBlock() throws {
        for caret in 3...6 {
            let rect = try XCTUnwrap(
                CaretBlockGeometry.rectangle(caretLine: caretLine, caretLineNumber: caret, firstLine: 3, lastLine: 6)
            )
            XCTAssertTrue(rect.contains(CGPoint(x: caretLine.midX, y: caretLine.midY)), "caret line \(caret) fell outside")
        }
    }

    func testNonsenseInputsAreRefused() {
        let zeroHeight = CGRect(x: 0, y: 0, width: 100, height: 0)
        XCTAssertNil(CaretBlockGeometry.rectangle(caretLine: zeroHeight, caretLineNumber: 1, firstLine: 1, lastLine: 1))
        // The caret has to be inside the block it is anchoring.
        XCTAssertNil(CaretBlockGeometry.rectangle(caretLine: caretLine, caretLineNumber: 9, firstLine: 3, lastLine: 6))
        XCTAssertNil(CaretBlockGeometry.rectangle(caretLine: caretLine, caretLineNumber: 1, firstLine: 3, lastLine: 6))
        // Reversed, and zero-based, are both nonsense.
        XCTAssertNil(CaretBlockGeometry.rectangle(caretLine: caretLine, caretLineNumber: 4, firstLine: 6, lastLine: 3))
        XCTAssertNil(CaretBlockGeometry.rectangle(caretLine: caretLine, caretLineNumber: 0, firstLine: 0, lastLine: 0))
    }

    /// A block taller than any editor shows would be almost entirely off-screen, and the clip would
    /// refuse it anyway.
    func testAnAbsurdlyLongBlockIsRefused() {
        XCTAssertNil(
            CaretBlockGeometry.rectangle(
                caretLine: caretLine,
                caretLineNumber: 1,
                firstLine: 1,
                lastLine: CaretBlockGeometry.maximumLines + 1
            )
        )
        XCTAssertNotNil(
            CaretBlockGeometry.rectangle(
                caretLine: caretLine,
                caretLineNumber: 1,
                firstLine: 1,
                lastLine: CaretBlockGeometry.maximumLines
            )
        )
    }

    // MARK: - Line numbers

    private let document = "# Title\n\n```mermaid\nflowchart LR\n  A --> B\n```\n\nprose\n"

    func testLineNumbersCountFromOne() {
        XCTAssertEqual(CaretBlockGeometry.lineNumber(of: 0, in: document), 1)
        XCTAssertEqual(CaretBlockGeometry.lineNumber(of: 8, in: document), 2)
        XCTAssertEqual(CaretBlockGeometry.lineNumber(of: 9, in: document), 3)
        XCTAssertNil(CaretBlockGeometry.lineNumber(of: -1, in: document))
        XCTAssertNil(CaretBlockGeometry.lineNumber(of: document.utf16.count + 1, in: document))
    }

    /// Offsets are UTF-16 units, which is what the accessibility APIs measure in. Counting
    /// characters instead puts the caret on the wrong line as soon as anything is outside the BMP.
    func testAnAstralCharacterDoesNotShiftTheLine() {
        let withEmoji = "a👍b\nsecond\n"
        XCTAssertEqual(CaretBlockGeometry.lineNumber(of: 4, in: withEmoji), 1)
        XCTAssertEqual(CaretBlockGeometry.lineNumber(of: 5, in: withEmoji), 2)
    }

    func testARangeReportsTheLinesItCovers() throws {
        let block = try XCTUnwrap(document.range(of: "```mermaid\nflowchart LR\n  A --> B\n```"))
        let range = NSRange(block, in: document)
        let lines = try XCTUnwrap(CaretBlockGeometry.lines(of: range, in: document))
        XCTAssertEqual(lines.first, 3)
        XCTAssertEqual(lines.last, 6)
    }

    /// A range that ends on a newline belongs to the line it ends, not the blank one below it.
    func testATrailingNewlineDoesNotClaimTheNextLine() throws {
        let block = try XCTUnwrap(document.range(of: "```mermaid\nflowchart LR\n  A --> B\n```\n"))
        let lines = try XCTUnwrap(CaretBlockGeometry.lines(of: NSRange(block, in: document), in: document))
        XCTAssertEqual(lines.last, 6)
    }

    func testASingleLineRangeIsOneLine() throws {
        let lines = try XCTUnwrap(CaretBlockGeometry.lines(of: NSRange(location: 0, length: 7), in: document))
        XCTAssertEqual(lines.first, 1)
        XCTAssertEqual(lines.last, 1)
    }

    /// The numbers this arithmetic was derived from, kept as a test so a change to it has to
    /// disagree with the editor that was measured rather than only with itself.
    ///
    /// Clicking down five consecutive lines in a Markdown file put the caret's line rectangle at
    /// 1078x18 with its top at 147, 165, 183, 201 and 219 -- an exact line height of 18. With the
    /// caret on line 5 of a fenced block spanning lines 3 to 6, the block's top is two line heights
    /// above the caret's, at 129, and it is four lines tall.
    func testTheMeasuredEditorReproduces() throws {
        // The measurement is in accessibility coordinates, whose y grows downward; the function
        // works in AppKit's, so the same rectangle is expressed with the origin flipped.
        let flip: CGFloat = 1080
        let caretLineAX = CGRect(x: 703, y: 165, width: 1078, height: 18)
        let caretLine = CGRect(
            x: caretLineAX.origin.x,
            y: flip - caretLineAX.maxY,
            width: caretLineAX.width,
            height: caretLineAX.height
        )
        let block = try XCTUnwrap(
            CaretBlockGeometry.rectangle(caretLine: caretLine, caretLineNumber: 5, firstLine: 3, lastLine: 6)
        )
        XCTAssertEqual(flip - block.maxY, 129, accuracy: 0.001)
        XCTAssertEqual(block.height, 72, accuracy: 0.001)
        XCTAssertEqual(block.origin.x, 703, accuracy: 0.001)
        XCTAssertEqual(block.width, 1078, accuracy: 0.001)
    }
}
