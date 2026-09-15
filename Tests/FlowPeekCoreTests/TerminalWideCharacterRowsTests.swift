import XCTest

@testable import FlowPeekCore

/// A terminal draws a Hangul syllable two cells wide, and the row arithmetic has to agree with it.
///
/// This is the bug the whole file exists for. `lineLengths` counted UTF-16 code units, so a Korean
/// line was measured at about half the columns it really fills. Nothing about that failed loudly:
/// the sieve simply could not find a column count that explained the pane's own content height, gave
/// up, and left the caller placing outlines from line numbers as though nothing wrapped. Measured on
/// a 741-line Korean document in a 178-column Ghostty pane, every diagram was framed 43 rows out --
/// 645 points, most of a viewport -- with a working button on a frame around unrelated text.
final class TerminalWideCharacterRowsTests: XCTestCase {
    /// Hangul, CJK ideographs and the fullwidth forms are two cells; Latin is one.
    func testAWideCharacterIsMeasuredAsTwoCells() {
        XCTAssertEqual(TerminalGridInference.lineLengths(of: "abc"), [3])
        XCTAssertEqual(TerminalGridInference.lineLengths(of: "가나다"), [6], "Hangul is two cells each")
        XCTAssertEqual(TerminalGridInference.lineLengths(of: "漢字"), [4], "CJK ideographs are two cells each")
        XCTAssertEqual(TerminalGridInference.lineLengths(of: "ａｂ"), [4], "fullwidth forms are two cells each")
        XCTAssertEqual(TerminalGridInference.lineLengths(of: "네고 quote"), [10], "4 + 1 + 5")
    }

    /// A combining mark is drawn on the character before it and takes no cell of its own, which is
    /// what lets this be counted scalar by scalar instead of walking grapheme boundaries.
    func testACombiningMarkTakesNoCell() {
        XCTAssertEqual(TerminalGridInference.lineLengths(of: "e\u{0301}"), [1], "e + acute is one cell")
    }

    /// The count is per line, and the newline itself is not a cell.
    func testLinesAreCountedSeparately() {
        XCTAssertEqual(TerminalGridInference.lineLengths(of: "ab\n가\n"), [2, 2, 0])
    }

    /// The regression proper: a line of Hangul wide enough to wrap must occupy the rows it really
    /// occupies. Counted in code units this line is 60 long and fits a 100-column pane on one row;
    /// counted in cells it is 120 and takes two.
    func testAKoreanLineWrapsWhenItsCellsExceedTheColumns() {
        let korean = String(repeating: "가", count: 60)
        let lengths = TerminalGridInference.lineLengths(of: korean)
        XCTAssertEqual(lengths, [120])
        XCTAssertEqual(
            TerminalGridInference.rows(ofLineLength: lengths[0], columns: 100), 2,
            "60 Hangul syllables fill 120 cells and cannot fit one 100-column row"
        )
    }

    /// And the consequence the reader sees: a block below wrapped text starts further down the pane
    /// than its line number alone would say. The shape of the real failure, in miniature -- three
    /// wrapping Korean lines push the block that follows them three rows further down.
    func testABlockBelowWrappedTextIsPushedDownByTheWrapping() {
        let wrapping = String(repeating: "가", count: 60)   // 120 cells: two rows each at 100 columns
        let buffer = ([wrapping, wrapping, wrapping] + ["flowchart TD", "  A --> B"]).joined(separator: "\n")
        let lengths = TerminalGridInference.lineLengths(of: buffer)

        let span = try? XCTUnwrap(
            TerminalGridInference.rowSpan(ofLines: 3...4, lineLengths: lengths, columns: 100)
        )
        XCTAssertEqual(
            span, 6...7,
            "three lines of two rows each put the block on rows 6-7, not on lines 3-4"
        )
    }
}
