import CoreGraphics
import Foundation

/// The terminals FlowPeek watches for diagrams.
///
/// An allowlist rather than "any app with a text area", because this route polls: the cost is paid
/// while one of these is frontmost and nowhere else. How a terminal is *read* is decided from the
/// attributes it answers with, not from this list, so a terminal that changes its accessibility
/// support keeps working and adding another one is a single case.
///
/// Measured, and the reason there are two strategies at all:
///
/// | | `AXVisibleCharacterRange` | `AXRangeForPosition` | `AXBoundsForRange` |
/// |---|---|---|---|
/// | Terminal.app | narrows to the viewport | yes | yes |
/// | iTerm2 | whole buffer, useless | yes | yes |
/// | Ghostty | whole buffer, useless | no | no |
///
/// So Terminal.app and iTerm2 are read by character range and answer with the block's own
/// rectangle, and Ghostty is read by grid arithmetic off its scroll area.
///
/// Orca renders into a WebGL canvas, which exposes no text -- and was left off this list for that
/// reason until it turned out xterm.js can be asked to publish the visible rows as a DOM list
/// beside the canvas. When it is, Chromium exposes that list to accessibility clients and a third
/// reading strategy applies: one element per row, each with its own measured frame, which is the
/// most exact of the three. When it is not, the descent finds nothing and the poll costs a walk.
public enum TerminalApp: String, Sendable, CaseIterable {
    case appleTerminal
    case iTerm2
    case ghostty
    case orca

    /// Every identifier the app ships under. More than one because a terminal can install
    /// side by side with itself: Orca's development build carries its own identifier so it can run
    /// beside a release install, and FlowPeek should read whichever one is in front.
    public var bundleIdentifiers: [String] {
        switch self {
        case .appleTerminal: ["com.apple.Terminal"]
        case .iTerm2: ["com.googlecode.iterm2"]
        case .ghostty: ["com.mitchellh.ghostty"]
        case .orca: ["com.stablyai.orca", "com.stablyai.orca.dev"]
        }
    }

    /// Whether the terminal has to be *asked* for an accessibility tree before there is anything to
    /// read.
    ///
    /// Chromium hands out empty groups until an assistive client announces itself, and it is that
    /// announcement -- not a setting -- that makes a web-view terminal publish its rows at all. The
    /// native three need nothing: their text is there whether anyone is looking or not.
    public var needsAccessibilityWarmUp: Bool {
        switch self {
        case .appleTerminal, .iTerm2, .ghostty: false
        case .orca: true
        }
    }

    public init?(bundleIdentifier: String?) {
        guard let bundleIdentifier,
              let match = Self.allCases.first(where: { $0.bundleIdentifiers.contains(bundleIdentifier) })
        else { return nil }
        self = match
    }
}

/// The rules for the terminal watch: when to look, what counts, and the arithmetic that puts a
/// block of terminal rows back onto the screen.
///
/// Pure, so the geometry can be tested against the numbers a real terminal answered with rather
/// than against a running one.
public enum TerminalPeekPolicy {
    /// Four times a second. A poll over a terminal nothing is happening in measured 0.2-1.2 ms
    /// depending on the terminal, so this costs a tenth to a half of one per cent of a core, and
    /// only while a terminal is frontmost. Slower than this and the outline visibly lags what the
    /// terminal is showing, which is the one thing this route has to get right.
    public static let pollInterval: TimeInterval = 0.25

    /// Wall clock for one whole read, checked before every accessibility call. Far above what any
    /// of the three terminals costs; it exists so a wedged one cannot hold the main actor.
    public static let readBudget: TimeInterval = 0.15

    /// How many polls in a row may be answered by "the terminal looks the same as last time"
    /// before the buffer is read again anyway.
    ///
    /// The cheap half of a read -- a character count, the viewport rectangle, the scroll bar's
    /// value -- is what that comparison is made of, and none of those terms is derived from the
    /// text. A terminal that repaints its rows with rows of the same length holds all of them
    /// constant while showing something else entirely, which is not a corner case: measured against
    /// Claude Code's virtualised scrollback, twenty-two consecutive polls saw identical numbers
    /// while the diagram on screen changed five times, and no outline was ever drawn.
    ///
    /// Four polls is one second, and it costs a quarter of a full read per idle poll -- the state
    /// this exists to keep cheap, a terminal with nothing in it, is also the state where being a
    /// second late is invisible.
    public static let rescanInterval = 4

    /// Whether a poll has to read the buffer rather than trust matching fingerprints.
    ///
    /// An outline that is up always reads. A frame is drawn *around specific rows*, so one left
    /// behind by a repaint is pointing at whatever took their place -- the worst thing this route
    /// can do, and worth four reads a second for as long as one is on screen. With nothing drawn
    /// the cost of being stale is an outline that arrives late, which the interval bounds.
    public static func mustRescan(isShowing: Bool, shortcutsTaken: Int) -> Bool {
        isShowing || shortcutsTaken >= rescanInterval
    }

    /// Same floor as the pointer route: a `.weak` match is the kind of thing that fires on prose
    /// containing the word "graph", and an outline over ordinary output is worse than none.
    public static let minimumConfidence: MermaidDetection.Confidence = .likely

    /// How much buffer is read on either side of the viewport, in UTF-16 code units -- roughly a
    /// hundred rows of an eighty-column terminal each way.
    ///
    /// The viewport alone is the wrong window to detect in. A diagram scrolled half off the top
    /// arrives as half a diagram, and half a diagram still parses: `flowchart TD` with two of its
    /// six edges is a valid diagram, so FlowPeek would offer to open a picture the terminal is not
    /// showing. Reading past both edges finds the block whole, and whether any of it is *on screen*
    /// is then a question about rectangles rather than about text.
    public static let characterMargin = 8_000

    /// How many consecutive reads must agree before an outline appears.
    ///
    /// Output that is still arriving moves every row on every read, so the block's line numbers
    /// change and this never reaches two -- which is what keeps the outline from strobing down the
    /// screen while a long file is printing. When the output stops, the second read agrees with the
    /// first and the outline appears a quarter of a second later.
    public static let confirmations = 2

    /// Bounds on a row height derived from a scroll area's content size. Ghostty reports no cell
    /// metrics, so the height comes from dividing total content by line count -- which is only
    /// right while one buffer line occupies one row. Soft wrapping breaks that and is not
    /// announced, so an implausible answer is refused rather than drawn in the wrong place.
    public static let rowHeightRange: ClosedRange<CGFloat> = 6...64

    // MARK: - Windows

    /// The character range to read: the viewport plus `characterMargin` on each side, clamped to
    /// the buffer.
    public static func window(around visible: NSRange, in characters: Int) -> NSRange? {
        guard characters > 0, visible.location >= 0, visible.length >= 0 else { return nil }
        let start = max(0, min(visible.location, characters) - characterMargin)
        let end = min(characters, visible.upperBound + characterMargin)
        guard end > start else { return nil }
        return NSRange(location: start, length: end - start)
    }

    /// Which lines of `text` a UTF-16 range covers, zero-based and both ends inclusive.
    ///
    /// This is how a character range read from a terminal becomes the row numbers the scanner
    /// speaks in. A range that starts past the end of the text has no lines and answers nil.
    /// Counted over UTF-16 code units rather than `Character`s. Grapheme breaking is what made the
    /// same loop cost milliseconds on a terminal-sized window, and a code unit is the thing being
    /// counted anyway: a range from an accessibility API is expressed in them.
    public static func lineSpan(of range: NSRange, in text: String) -> ClosedRange<Int>? {
        guard range.location >= 0, range.length >= 0 else { return nil }
        var line = 0
        var first: Int?
        var offset = 0
        for unit in text.utf16 {
            if offset >= range.location, first == nil { first = line }
            if offset >= range.upperBound { break }
            if unit == 0x0A { line += 1 }
            offset += 1
        }
        guard offset >= range.location || first != nil else { return nil }
        guard let first else { return line...line }
        return first...max(first, line)
    }

    // MARK: - Grid arithmetic

    /// How much taller than its viewport a scroll area's content has to claim to be before it is
    /// believed to be reporting its own height. One point, against float noise in two numbers that
    /// are equal by construction whenever the buffer fits.
    public static let overflowTolerance: CGFloat = 1

    /// The height of one row, and whether this read is where it came from.
    public struct RowHeight: Equatable, Sendable {
        public let height: CGFloat
        /// Divided out of an overflowing buffer on this read, rather than carried over from an
        /// earlier one. Only a measured height is worth remembering.
        public let isMeasured: Bool

        public init(height: CGFloat, isMeasured: Bool) {
            self.height = height
            self.isMeasured = isMeasured
        }
    }

    /// The height of one row, from a scroll area that reports how tall its content is.
    ///
    /// Dividing the content height by the line count only answers while the buffer is *taller* than
    /// the viewport. A buffer that fits reports the viewport's height instead of its own -- Ghostty
    /// answers `AXContentSize.height == AXFrame.height` exactly -- so the division then returns the
    /// viewport divided by however many rows happen to be painted, which is a row height only in
    /// the one case where the paint fills the window. Measured in Ghostty: 16 rows in a fresh window
    /// divided out to 63.6 points against a real 16, and every frame was drawn four times too tall;
    /// `cat` of a thirty-line file divided out to 32.8 and settled there, framing rows the diagram
    /// was thirty points above. Both were confident and both were wrong, which is worse than
    /// refusing.
    ///
    /// So the division is only trusted while the buffer overflows, its answer is `remembered` by the
    /// caller, and a buffer that fits is placed with that remembered height. With none to hand there
    /// is no way to know how tall a row is and this answers nothing: no outline is worse than an
    /// outline somewhere else.
    ///
    /// A remembered height is cross-checked against the one thing a fitting buffer does say. Its
    /// content height *is* the viewport, and the painted rows fit inside the viewport by
    /// construction, so `lineCount * height` may not exceed it -- which is what catches a height
    /// remembered before the font grew. Nothing bounds it from below, so a height remembered before
    /// the font *shrank* is accepted for as long as the buffer keeps fitting, and corrects itself on
    /// the first read that overflows again.
    /// - Parameters:
    ///   - lineCount: rows the buffer has painted, which is the whole buffer -- both callers count
    ///     it off the last character.
    ///   - remembered: the height last measured off an overflowing buffer in this terminal.
    public static func rowHeight(
        contentHeight: CGFloat,
        viewportHeight: CGFloat,
        lineCount: Int,
        remembered: CGFloat?
    ) -> RowHeight? {
        guard lineCount > 0, contentHeight.isFinite, contentHeight > 0, viewportHeight.isFinite else {
            return nil
        }
        guard contentHeight > viewportHeight + overflowTolerance else {
            guard viewportHeight > 0, let remembered, rowHeightRange.contains(remembered) else { return nil }
            // One row of slack: the last row of a paint that fills the window is routinely a
            // fraction of a row past its bottom edge.
            guard CGFloat(lineCount) * remembered <= viewportHeight + remembered else { return nil }
            return RowHeight(height: remembered, isMeasured: false)
        }
        let height = contentHeight / CGFloat(lineCount)
        guard rowHeightRange.contains(height) else { return nil }
        return RowHeight(height: height, isMeasured: true)
    }

    /// How far the buffer is scrolled, in points. A scroll bar's value is the fraction of the
    /// overflow that is above the viewport, so zero is the top of the scrollback and one is the
    /// live prompt at the bottom.
    public static func scrollOffset(value: Double, contentHeight: CGFloat, viewportHeight: CGFloat) -> CGFloat {
        guard value.isFinite, contentHeight.isFinite, viewportHeight.isFinite else { return 0 }
        let overflow = max(0, contentHeight - viewportHeight)
        return CGFloat(min(max(value, 0), 1)) * overflow
    }

    /// The rows the viewport is showing, both ends inclusive. Partly visible rows at either edge
    /// count: a diagram whose first row is half cut off is still on screen.
    public static func visibleLines(
        offset: CGFloat,
        viewportHeight: CGFloat,
        rowHeight: CGFloat,
        lineCount: Int
    ) -> ClosedRange<Int>? {
        guard lineCount > 0, rowHeight > 0, viewportHeight > 0, offset.isFinite else { return nil }
        let first = max(0, min(lineCount - 1, Int((offset / rowHeight).rounded(.down))))
        let last = max(first, min(lineCount - 1, Int(((offset + viewportHeight) / rowHeight).rounded(.up)) - 1))
        return first...last
    }

    /// The band a pair of measured row rectangles spans, given the width the terminal's text
    /// occupies. Accessibility coordinates throughout.
    ///
    /// The width is the terminal's, not the diagram's. No terminal reports a cell width, a ragged
    /// buffer gives no column count to divide by, and the one attribute that could answer for a
    /// whole block cannot be trusted to -- iTerm2 measured a six-row range as 21 points wide. So
    /// the rows are what is known and the frame says so by running the width of the terminal, which
    /// is also what makes the two reading strategies draw the same shape.
    public static func band(from first: CGRect, to last: CGRect, across width: ClosedRange<CGFloat>) -> CGRect? {
        guard ScreenGeometry.isUsable(first), ScreenGeometry.isUsable(last) else { return nil }
        let top = min(first.minY, last.minY)
        let bottom = max(first.maxY, last.maxY)
        let rectangle = CGRect(
            x: width.lowerBound,
            y: top,
            width: width.upperBound - width.lowerBound,
            height: bottom - top
        )
        guard ScreenGeometry.isUsable(rectangle) else { return nil }
        return rectangle
    }

    /// Which rows a block occupies, asked of the terminal rather than counted off the text.
    ///
    /// A buffer's lines and a screen's rows stop being the same thing as soon as a line is longer
    /// than the terminal is wide, and the two terminals measured disagree about which one they
    /// report. Terminal.app, 80 columns: the `AXValue` keeps a 180-character line whole, so the
    /// scanner counts it as one line, while `AXLineForIndex` answers 59 for the line the string
    /// puts 56th -- the drift being every wrap above it. Ghostty: `AXLineForIndex` answers 2 for
    /// both ends of a 320-character line that is drawn on three rows, so it counts lines, like its
    /// value does.
    ///
    /// So the terminal is asked instead of the newlines being counted: where the answer is rows it
    /// is the right answer, and where it is lines it is at least the same numbering the rest of the
    /// grid arithmetic uses. Converting lines to rows for a terminal of the second kind needs the
    /// column count, which neither of Ghostty's geometry attributes reports; that conversion is
    /// still missing, and shows up as an outline one row short per wrap inside the block.
    ///
    /// `last` is the block's last character rather than the start of its last row, so a terminal
    /// that does answer in rows counts every row a wrapped final line occupies.
    public static func rows(
        ofBlockFrom first: Int,
        to last: Int,
        line: (Int) -> Int?
    ) -> ClosedRange<Int>? {
        guard first >= 0, last >= first, let top = line(first), let bottom = line(last),
              top >= 0, bottom >= top else { return nil }
        return top...bottom
    }

    /// Where a run of rows sits on screen, in accessibility coordinates -- the same top-left origin
    /// the frames these numbers came from are expressed in.
    ///
    /// The rectangle spans the viewport's full width, for the same reason `band` does.
    public static func rowsRectangle(
        lines: ClosedRange<Int>,
        viewport: CGRect,
        rowHeight: CGFloat,
        offset: CGFloat
    ) -> CGRect? {
        guard rowHeight > 0, ScreenGeometry.isUsable(viewport) else { return nil }
        let top = viewport.minY + CGFloat(lines.lowerBound) * rowHeight - offset
        let height = CGFloat(lines.count) * rowHeight
        let rectangle = CGRect(x: viewport.minX, y: top, width: viewport.width, height: height)
        guard ScreenGeometry.isUsable(rectangle) else { return nil }
        return rectangle
    }

    /// How far outside the outline the pointer may sit and still ask for the button.
    ///
    /// Generous rather than exact. The frame the terminal watch draws runs the width of the
    /// terminal, so approaching a diagram at all puts the pointer within a couple of rows of it,
    /// and a margin means the button is already there by the time the pointer arrives instead of
    /// appearing under it.
    public static let revealMargin: CGFloat = 28

    /// Whether the pointer is close enough to an outline for its button to be worth showing.
    public static func revealsButton(pointer: CGPoint, outline: CGRect) -> Bool {
        guard ScreenGeometry.isUsable(outline) else { return false }
        return outline.insetBy(dx: -revealMargin, dy: -revealMargin).contains(pointer)
    }

    // MARK: - Showing

    /// Whether a block's rectangle has enough of itself inside the terminal's own content to be
    /// worth outlining.
    ///
    /// A rectangle computed from rows keeps growing past the top and bottom of the viewport as the
    /// buffer scrolls, and the accessibility frames of the ranged terminals do the same -- Terminal
    /// app's text area measured 2145 points tall for a 385-point window, most of it off screen. So
    /// the block is trimmed to what the terminal is actually showing, and a sliver is refused: the
    /// outline is a frame around readable text, and a two-point frame is a line under the window's
    /// edge.
    public static func onScreenPortion(of block: CGRect, showing content: CGRect) -> CGRect? {
        guard ScreenGeometry.isUsable(block), ScreenGeometry.isUsable(content) else { return nil }
        let visible = block.intersection(content)
        guard ScreenGeometry.isUsable(visible),
              visible.height >= AmbientPeekPolicy.minimumSize.height,
              visible.width >= AmbientPeekPolicy.minimumSize.width else { return nil }
        return visible
    }

    /// Counts how many reads in a row have agreed about the same blocks.
    ///
    /// Identity is each block's rows and its size, never its text: what the user has on screen is
    /// not something FlowPeek keeps, and rows plus length separate two diagrams as well as a copy
    /// of one would. The whole set is one identity, so a diagram arriving next to another restarts
    /// the count -- which costs nothing, because a set already on screen is let through by the
    /// caller regardless.
    public struct Settle: Equatable, Sendable {
        private var identity: String?
        private var agreements = 0

        public init() {}

        /// Reports whether these blocks may be shown now. An empty set is nothing to confirm.
        public mutating func confirm(_ blocks: [TerminalDiagramBlock]) -> Bool {
            guard !blocks.isEmpty else {
                identity = nil
                agreements = 0
                return false
            }
            let identity = blocks
                .map { "\($0.lines.lowerBound)-\($0.lines.upperBound)-\($0.range.length)" }
                .joined(separator: ",")
            if identity == self.identity {
                agreements = min(agreements + 1, TerminalPeekPolicy.confirmations)
            } else {
                self.identity = identity
                agreements = 1
            }
            return agreements >= TerminalPeekPolicy.confirmations
        }

        public mutating func forget() {
            identity = nil
            agreements = 0
        }
    }
}
