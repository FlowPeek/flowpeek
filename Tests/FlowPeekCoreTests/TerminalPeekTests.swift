import CoreGraphics
import XCTest
@testable import FlowPeekCore

/// The arithmetic that puts a run of terminal rows back onto the screen, checked against the
/// numbers three real terminals answered with rather than against invented ones.
final class TerminalPeekPolicyTests: XCTestCase {
    func testTheThreeTerminalsAreRecognisedByBundleIdentifier() {
        XCTAssertEqual(TerminalApp(bundleIdentifier: "com.apple.Terminal"), .appleTerminal)
        XCTAssertEqual(TerminalApp(bundleIdentifier: "com.googlecode.iterm2"), .iTerm2)
        XCTAssertEqual(TerminalApp(bundleIdentifier: "com.mitchellh.ghostty"), .ghostty)
    }

    /// Orca embeds Ghostty but paints it into a web view, so it exposes no text and must not be
    /// polled: a terminal is on the list because it can be read, not because of what is inside it.
    func testAnAppThatIsNotOneOfThemIsNotATerminal() {
        XCTAssertNil(TerminalApp(bundleIdentifier: "com.orcalabs.orca"))
        XCTAssertNil(TerminalApp(bundleIdentifier: "com.microsoft.VSCode"))
        XCTAssertNil(TerminalApp(bundleIdentifier: nil))
    }

    // MARK: - Windows

    func testTheReadWindowReachesPastTheViewportOnBothSides() throws {
        let window = try XCTUnwrap(
            TerminalPeekPolicy.window(around: NSRange(location: 20_000, length: 1_600), in: 50_000)
        )
        XCTAssertEqual(window.location, 20_000 - TerminalPeekPolicy.characterMargin)
        XCTAssertEqual(window.upperBound, 21_600 + TerminalPeekPolicy.characterMargin)
    }

    /// The viewport of a terminal that has just been cleared sits at the very start and end of a
    /// short buffer, and the margin must not run off either edge.
    func testTheReadWindowIsClampedToTheBuffer() throws {
        let window = try XCTUnwrap(
            TerminalPeekPolicy.window(around: NSRange(location: 0, length: 1_639), in: 1_639)
        )
        XCTAssertEqual(window.location, 0)
        XCTAssertEqual(window.length, 1_639)
    }

    func testAnEmptyBufferHasNoReadWindow() {
        XCTAssertNil(TerminalPeekPolicy.window(around: NSRange(location: 0, length: 0), in: 0))
    }

    // MARK: - Lines

    func testALineSpanCountsTheRowsARangeCovers() throws {
        let text = "one\ntwo\nthree\nfour\n"
        // "two\nthree" -- starts on row 1, ends on row 2.
        let span = try XCTUnwrap(TerminalPeekPolicy.lineSpan(of: NSRange(location: 4, length: 9), in: text))
        XCTAssertEqual(span, 1...2)
    }

    func testALineSpanInsideOneRowIsThatRowTwice() throws {
        let span = try XCTUnwrap(TerminalPeekPolicy.lineSpan(of: NSRange(location: 5, length: 1), in: "one\ntwo\n"))
        XCTAssertEqual(span, 1...1)
    }

    /// A terminal can answer with a range that reaches past what it then hands over; the span is
    /// still the rows the text has.
    func testALineSpanPastTheEndStopsAtTheLastRow() throws {
        let span = try XCTUnwrap(TerminalPeekPolicy.lineSpan(of: NSRange(location: 0, length: 999), in: "a\nb\n"))
        XCTAssertEqual(span, 0...2)
    }

    // MARK: - Grid arithmetic

    /// Ghostty, measured: a scroll area 2056 points tall over a 128-line buffer.
    func testARowHeightComesFromContentOverLines() throws {
        let height = try XCTUnwrap(TerminalPeekPolicy.rowHeight(contentHeight: 2_056, lineCount: 128))
        XCTAssertEqual(height, 16.0625, accuracy: 0.0001)
    }

    /// Soft wrapping puts two rows on one buffer line and is not announced, so an answer that is
    /// not a plausible row is refused rather than drawn somewhere wrong.
    func testAnImplausibleRowHeightIsRefused() {
        XCTAssertNil(TerminalPeekPolicy.rowHeight(contentHeight: 2_056, lineCount: 2))
        XCTAssertNil(TerminalPeekPolicy.rowHeight(contentHeight: 2_056, lineCount: 100_000))
        XCTAssertNil(TerminalPeekPolicy.rowHeight(contentHeight: 0, lineCount: 128))
        XCTAssertNil(TerminalPeekPolicy.rowHeight(contentHeight: 2_056, lineCount: 0))
    }

    func testTheScrollOffsetIsTheFractionOfWhatOverflows() {
        // Ghostty at the bottom of a 128-line buffer in a 1336-point viewport.
        XCTAssertEqual(
            TerminalPeekPolicy.scrollOffset(value: 1, contentHeight: 2_056, viewportHeight: 1_336),
            720
        )
        XCTAssertEqual(
            TerminalPeekPolicy.scrollOffset(value: 0, contentHeight: 2_056, viewportHeight: 1_336),
            0
        )
        XCTAssertEqual(
            TerminalPeekPolicy.scrollOffset(value: 0.5, contentHeight: 2_056, viewportHeight: 1_336),
            360
        )
    }

    /// Nothing has scrolled off, so wherever the bar claims to be there is no offset to apply.
    func testThereIsNoScrollOffsetWhenTheContentFits() {
        XCTAssertEqual(
            TerminalPeekPolicy.scrollOffset(value: 1, contentHeight: 1_300, viewportHeight: 1_336),
            0
        )
    }

    func testTheVisibleRowsAreTheOnesTheViewportCovers() throws {
        let visible = try XCTUnwrap(
            TerminalPeekPolicy.visibleLines(
                offset: 720,
                viewportHeight: 1_336,
                rowHeight: 16.0625,
                lineCount: 128
            )
        )
        // 720 / 16.0625 = row 44, and the viewport reaches the last row of the buffer.
        XCTAssertEqual(visible, 44...127)
    }

    func testAPartlyVisibleRowStillCounts() throws {
        // Half a row scrolled off the top: row 0 is cut in two and is still on screen.
        let visible = try XCTUnwrap(
            TerminalPeekPolicy.visibleLines(offset: 8, viewportHeight: 32, rowHeight: 16, lineCount: 10)
        )
        XCTAssertEqual(visible, 0...2)
    }

    func testAnUnscrolledBufferShowsFromTheTop() throws {
        let visible = try XCTUnwrap(
            TerminalPeekPolicy.visibleLines(offset: 0, viewportHeight: 1_336, rowHeight: 16.0625, lineCount: 83)
        )
        XCTAssertEqual(visible.lowerBound, 0)
        XCTAssertEqual(visible.upperBound, 82)
    }

    /// The rows the block occupies, placed against Ghostty's measured viewport: a diagram on rows
    /// 60-66 of a buffer scrolled 720 points down.
    func testRowsBecomeARectangleInTheViewport() throws {
        let rectangle = try XCTUnwrap(
            TerminalPeekPolicy.rowsRectangle(
                lines: 60...66,
                viewport: CGRect(x: 878, y: 62, width: 1_682, height: 1_336),
                rowHeight: 16.0625,
                offset: 720
            )
        )
        XCTAssertEqual(rectangle.minX, 878)
        XCTAssertEqual(rectangle.width, 1_682)
        XCTAssertEqual(rectangle.minY, 62 + 60 * 16.0625 - 720, accuracy: 0.001)
        XCTAssertEqual(rectangle.height, 7 * 16.0625, accuracy: 0.001)
    }

    // MARK: - Bands

    /// Terminal.app, measured: rows 27 to 32 of a small buffer came back as two 14-point rectangles
    /// 70 points apart, inside a text area running from x 1944 to 2524.
    func testABandSpansTheRowsItWasMeasuredFrom() throws {
        let band = try XCTUnwrap(
            TerminalPeekPolicy.band(
                from: CGRect(x: 1_954, y: 897, width: 7, height: 14),
                to: CGRect(x: 1_954, y: 967, width: 7, height: 14),
                across: 1_944...2_524
            )
        )
        XCTAssertEqual(band, CGRect(x: 1_944, y: 897, width: 580, height: 84))
    }

    /// The band is drawn across the terminal, not around the characters: iTerm2 measured a
    /// six-row range as 21 points wide, so a width taken from the measured rows would be a strip.
    func testABandIgnoresTheMeasuredRowsWidth() throws {
        let band = try XCTUnwrap(
            TerminalPeekPolicy.band(
                from: CGRect(x: 1_850, y: 499, width: 7, height: 15),
                to: CGRect(x: 1_850, y: 574, width: 7, height: 15),
                across: 1_845...2_415
            )
        )
        XCTAssertEqual(band.minX, 1_845)
        XCTAssertEqual(band.width, 570)
        XCTAssertEqual(band.height, 90)
    }

    /// A block whose first row is above the viewport and last row below it comes back in either
    /// order, and the band is the same either way.
    func testABandDoesNotCareWhichRowWasMeasuredFirst() throws {
        let high = CGRect(x: 0, y: 100, width: 7, height: 14)
        let low = CGRect(x: 0, y: 300, width: 7, height: 14)
        XCTAssertEqual(
            try XCTUnwrap(TerminalPeekPolicy.band(from: high, to: low, across: 0...500)),
            try XCTUnwrap(TerminalPeekPolicy.band(from: low, to: high, across: 0...500))
        )
    }

    func testAOneRowBlockIsStillABand() throws {
        let row = CGRect(x: 10, y: 40, width: 7, height: 14)
        let band = try XCTUnwrap(TerminalPeekPolicy.band(from: row, to: row, across: 0...100))
        XCTAssertEqual(band.height, 14)
    }

    func testAnUnusableRowRectangleHasNoBand() {
        XCTAssertNil(
            TerminalPeekPolicy.band(
                from: .zero,
                to: CGRect(x: 0, y: 300, width: 7, height: 14),
                across: 0...500
            )
        )
        XCTAssertNil(
            TerminalPeekPolicy.band(
                from: CGRect(x: 0, y: 100, width: 7, height: 14),
                to: CGRect(x: 0, y: 300, width: 7, height: 14),
                across: 250...250
            )
        )
    }

    // MARK: - Staying on screen

    /// Terminal.app's text area measured 2145 points tall inside a 385-point window, so a
    /// rectangle from it runs far past what the terminal is showing.
    func testABlockIsTrimmedToWhatTheTerminalShows() throws {
        let content = CGRect(x: 1_944, y: 816, width: 597, height: 353)
        let block = CGRect(x: 1_954, y: 700, width: 560, height: 300)
        let visible = try XCTUnwrap(TerminalPeekPolicy.onScreenPortion(of: block, showing: content))
        XCTAssertEqual(visible.minY, 816)
        XCTAssertEqual(visible.maxY, 1_000)
    }

    func testABlockScrolledOffScreenIsRefused() {
        let content = CGRect(x: 0, y: 0, width: 600, height: 400)
        XCTAssertNil(
            TerminalPeekPolicy.onScreenPortion(of: CGRect(x: 0, y: 900, width: 600, height: 200), showing: content)
        )
    }

    /// One row of a block left at the edge of the window is a line under it, not a frame around
    /// readable text.
    func testASliverOfABlockIsRefused() {
        let content = CGRect(x: 0, y: 0, width: 600, height: 400)
        XCTAssertNil(
            TerminalPeekPolicy.onScreenPortion(of: CGRect(x: 0, y: 396, width: 600, height: 200), showing: content)
        )
    }

    // MARK: - Approach

    func testAPointerInsideTheOutlineRevealsTheButton() {
        let outline = CGRect(x: 100, y: 100, width: 400, height: 80)
        XCTAssertTrue(TerminalPeekPolicy.revealsButton(pointer: CGPoint(x: 300, y: 140), outline: outline))
    }

    /// The margin exists so the button is already there when the pointer arrives rather than
    /// appearing under it.
    func testAPointerApproachingTheOutlineRevealsTheButton() {
        let outline = CGRect(x: 100, y: 100, width: 400, height: 80)
        XCTAssertTrue(
            TerminalPeekPolicy.revealsButton(
                pointer: CGPoint(x: 300, y: 100 - TerminalPeekPolicy.revealMargin + 1),
                outline: outline
            )
        )
    }

    func testAPointerAwayFromTheOutlineLeavesItQuiet() {
        let outline = CGRect(x: 100, y: 100, width: 400, height: 80)
        XCTAssertFalse(
            TerminalPeekPolicy.revealsButton(
                pointer: CGPoint(x: 300, y: 100 - TerminalPeekPolicy.revealMargin - 1),
                outline: outline
            )
        )
        XCTAssertFalse(TerminalPeekPolicy.revealsButton(pointer: CGPoint(x: 900, y: 140), outline: outline))
    }

    func testAnUnusableOutlineRevealsNothing() {
        XCTAssertFalse(TerminalPeekPolicy.revealsButton(pointer: .zero, outline: .zero))
    }

    // MARK: - Settling

    private func block(lines: ClosedRange<Int>, length: Int = 100) -> TerminalDiagramBlock {
        TerminalDiagramBlock(
            detection: MermaidDetector.detect("flowchart TD\n  A --> B"),
            text: "flowchart TD\n  A --> B",
            lines: lines,
            range: NSRange(location: 0, length: length),
            lastRow: NSRange(location: max(0, length - 8), length: 8),
            isFenced: false
        )
    }

    func testABlockIsShownOnlyOnceTwoReadsAgree() {
        var settle = TerminalPeekPolicy.Settle()
        XCTAssertFalse(settle.confirm([block(lines: 10...16)]))
        XCTAssertTrue(settle.confirm([block(lines: 10...16)]))
        XCTAssertTrue(settle.confirm([block(lines: 10...16)]))
    }

    /// Several blocks are one answer: they were read together and they appear together.
    func testASetOfBlocksSettlesTogether() {
        var settle = TerminalPeekPolicy.Settle()
        let pair = [block(lines: 4...9), block(lines: 20...26)]
        XCTAssertFalse(settle.confirm(pair))
        XCTAssertTrue(settle.confirm(pair))
    }

    /// A second diagram arriving is a different answer, so the count starts again. The caller lets
    /// it through anyway while frames are already up, which is what keeps the first from blinking.
    func testASecondBlockRestartsTheCount() {
        var settle = TerminalPeekPolicy.Settle()
        XCTAssertFalse(settle.confirm([block(lines: 4...9)]))
        XCTAssertTrue(settle.confirm([block(lines: 4...9)]))
        XCTAssertFalse(settle.confirm([block(lines: 4...9), block(lines: 20...26)]))
    }

    /// Output that is still arriving moves every row on every read, which is what must not put an
    /// outline on screen.
    func testAMovingBlockNeverSettles() {
        var settle = TerminalPeekPolicy.Settle()
        for first in 10...20 {
            XCTAssertFalse(settle.confirm([block(lines: first...(first + 6))]), "row \(first)")
        }
    }

    func testFindingNothingForgetsWhatWasCounted() {
        var settle = TerminalPeekPolicy.Settle()
        XCTAssertFalse(settle.confirm([block(lines: 10...16)]))
        XCTAssertFalse(settle.confirm([]))
        XCTAssertFalse(settle.confirm([block(lines: 10...16)]))
    }

    /// Two diagrams can occupy the same rows one read apart -- the first scrolls off as the second
    /// is printed -- so the length is part of the identity as well as the rows.
    func testTwoDifferentBlocksOnTheSameRowsDoNotAgree() {
        var settle = TerminalPeekPolicy.Settle()
        XCTAssertFalse(settle.confirm([block(lines: 10...16, length: 100)]))
        XCTAssertFalse(settle.confirm([block(lines: 10...16, length: 240)]))
    }
}
