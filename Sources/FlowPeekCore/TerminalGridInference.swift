import CoreGraphics

/// A terminal's grid: how tall a row is, how many columns fit, and how much padding sits above and
/// below the rows inside the pane.
public struct TerminalGrid: Hashable, Sendable {
    public let columns: Int
    public let rowHeight: CGFloat
    /// Total padding, top and bottom together, inside the pane.
    public let padding: CGFloat

    public init(columns: Int, rowHeight: CGFloat, padding: CGFloat) {
        self.columns = columns
        self.rowHeight = rowHeight
        self.padding = padding
    }

    /// The padding above the first row. Terminals pad symmetrically, so half.
    public var topPadding: CGFloat { padding / 2 }
}

/// Works out a terminal's grid from what it will answer, for the terminals that answer nothing
/// about where a character is drawn.
///
/// Ghostty is the one this exists for. It keeps whole lines in `AXValue` and counts whole lines in
/// `AXLineForIndex`, so neither says anything about wrapping, and it implements none of the
/// geometry attributes -- the `AXGroup` above its text area lists `AXBoundsForRange` among its
/// parameterized attributes and returns an error for every range asked of it. Without the column
/// count, a line wider than the pane is one line to FlowPeek and several rows to the reader, and the
/// outline is that many rows too short.
///
/// What it does answer is arithmetic. Measured on Ghostty 1.2 in a 1115-point pane:
///
///     printed      lines in AXValue    AXContentSize.height
///     100          101                 1622
///     1200         1201                19222
///     3000         3001                48022
///     20000        5424 (capped)       86790
///
/// Every one of those is `rows * 16 + 6`, and the 982-point viewport is `61 * 16 + 6`. So the pane
/// reports `rows * rowHeight + padding`, and -- this is the part that makes the whole thing work --
/// the rows it counts are the rows of exactly the lines `AXValue` exposes, capped buffer included.
/// The height is therefore an equation about the text, and the unknowns are the grid.
///
/// One look does not solve it. The diagram this was written for gave 48 candidate grids in two
/// families: the true `16.0 / 6.0` for 137 to 174 columns, and a `15.45 / 8.76` for 97 to 106 that
/// fits that one height just as well. Three looks at different heights left two candidates, both
/// `16.0 / 6.0`, at 137 and 138 columns -- and both put every line on the same row, which is all
/// the outline needs. So candidates are generated once and then sieved: a grid that cannot explain
/// a later height is not the grid.
public enum TerminalGridInference {
    /// The column counts worth considering. Narrower than 20 is not a terminal anyone reads a
    /// diagram in, and wider than 500 columns at a legible size is wider than any display.
    public static let columnRange = 20...500

    /// Row heights worth considering, in points. A 6-point font is unreadable and a 60-point row is
    /// a presentation.
    public static let rowHeightRange: ClosedRange<CGFloat> = 8...60

    /// How much padding a pane may hold, top and bottom together, when nothing else is known about
    /// the grid. Ghostty's 1.2 default measured 6 points. A window padded more than this drops out
    /// of the sieve and the caller falls back, which is the intended outcome: a wrong grid is worse
    /// than the imprecision it replaces.
    ///
    /// It has to stay tight. Raising it to cover Ghostty 1.3 admitted grids that are not the grid --
    /// a 15.61-point row with 45 points of padding explains one look as neatly as the true 16 and 34
    /// -- and a sieve that cannot narrow to one answer draws nothing at all.
    public static let paddingLimit: CGFloat = 12

    /// The same limit for a pane whose row height is already known, in rows.
    ///
    /// Knowing the row is what makes a loose limit safe: it is the row height that the extra
    /// candidates get wrong, and pinning it throws them out before the padding is even looked at.
    /// Ghostty 1.3.1 leaves two rows over -- measured 34 points against a 16-point row, and 28 and
    /// 24 at shorter viewports -- where 1.2 left well under one.
    public static let paddingLimitRows: CGFloat = 4

    /// How far a candidate's row may sit from a height solved elsewhere and still be that height.
    private static let rowHeightTolerance: CGFloat = 0.01

    /// Width over height for one cell. A monospaced face is about half as wide as its line is tall
    /// -- Ghostty measured 8.08 over 16.0, or 0.505 -- and this band is what rules out the families
    /// that fit the arithmetic with an implausible font.
    public static let aspectRange: ClosedRange<CGFloat> = 0.4...0.75

    /// A viewport shows at least this many rows, which rules out solutions that explain the height
    /// with a handful of enormous rows.
    public static let minimumVisibleRows = 5

    /// How far from a whole number a row count may fall and still be believed.
    private static let tolerance: CGFloat = 0.001

    /// How many rows a line of this length occupies. A blank line still occupies one.
    public static func rows(ofLineLength length: Int, columns: Int) -> Int {
        guard columns > 0, length > columns else { return 1 }
        return (length + columns - 1) / columns
    }

    /// The row each line begins on, as a running total, plus one final entry for the row after the
    /// last line -- so the rows of line `i` are `starts[i] ..< starts[i + 1]`.
    public static func rowStarts(_ lineLengths: [Int], columns: Int) -> [Int] {
        var starts = [Int](repeating: 0, count: lineLengths.count + 1)
        var row = 0
        for (index, length) in lineLengths.enumerated() {
            starts[index] = row
            row += rows(ofLineLength: length, columns: columns)
        }
        starts[lineLengths.count] = row
        return starts
    }

    /// The rows a run of lines occupies, both ends inclusive.
    public static func rowSpan(
        ofLines lines: ClosedRange<Int>,
        lineLengths: [Int],
        columns: Int
    ) -> ClosedRange<Int>? {
        guard lines.lowerBound >= 0, lines.upperBound < lineLengths.count else { return nil }
        let starts = rowStarts(lineLengths, columns: columns)
        let top = starts[lines.lowerBound]
        let bottom = starts[lines.upperBound + 1] - 1
        guard bottom >= top else { return nil }
        return top...bottom
    }

    /// Which line a row belongs to, for turning a range of rows on screen back into lines to scan.
    public static func line(ofRow row: Int, lineLengths: [Int], columns: Int) -> Int? {
        guard !lineLengths.isEmpty else { return nil }
        let starts = rowStarts(lineLengths, columns: columns)
        guard row >= 0, row < starts[lineLengths.count] else { return nil }
        // The last line whose first row is at or above `row`.
        var low = 0
        var high = lineLengths.count - 1
        var answer = 0
        while low <= high {
            let middle = low + (high - low) / 2
            if starts[middle] <= row {
                answer = middle
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        return answer
    }

    /// Every grid that explains this pane.
    ///
    /// For each column count the rows the text occupies are known, which fixes the total; the height
    /// and the viewport then fix the row height and the padding exactly, because
    /// `contentHeight - padding = rows * rowHeight` and `viewportHeight - padding = visibleRows *
    /// rowHeight` share their unknowns. Only the plausibility bands are left to check.
    /// - Parameter rowHeight: the row height if it is already known, from two readings of this pane
    ///   (see `TerminalRowMetrics`). Given one, only grids with that row are offered and the padding
    ///   is allowed to be as large as the pane really makes it; without one, nothing is assumed and
    ///   the tight padding limit does the narrowing instead.
    public static func candidates(
        contentHeight: CGFloat,
        viewportHeight: CGFloat,
        paneWidth: CGFloat,
        lineLengths: [Int],
        rowHeight known: CGFloat? = nil
    ) -> [TerminalGrid] {
        guard contentHeight > viewportHeight, viewportHeight > 0, paneWidth > 0,
              !lineLengths.isEmpty else { return [] }
        let scrollback = contentHeight - viewportHeight
        var grids: [TerminalGrid] = []
        // Only lines longer than the narrowest column count can wrap, and there are few of them in
        // a terminal, so the total is the line count plus their extra rows rather than a sum over
        // every line.
        let wrappable = lineLengths.filter { $0 > columnRange.lowerBound }
        for columns in columnRange {
            let total = lineLengths.count
                + wrappable.reduce(0) { $0 + rows(ofLineLength: $1, columns: columns) - 1 }
            let width = paneWidth / CGFloat(columns)
            // `padding >= 0` bounds the difference between the total rows and the visible rows from
            // below, so the search starts where the padding can first be zero and stops as soon as
            // it grows past what a pane can hold.
            var difference = max(1, Int((CGFloat(total) * scrollback / contentHeight).rounded(.up)))
            while difference < total - minimumVisibleRows {
                let rowHeight = scrollback / CGFloat(difference)
                guard rowHeight >= rowHeightRange.lowerBound else { break }
                defer { difference += 1 }
                guard rowHeight <= rowHeightRange.upperBound else { continue }
                if let known, abs(rowHeight - known) > rowHeightTolerance { continue }
                let visibleRows = total - difference
                let padding = viewportHeight - CGFloat(visibleRows) * rowHeight
                if padding < 0 { continue }
                let limit = known.map { $0 * paddingLimitRows } ?? paddingLimit
                if padding > limit { break }
                guard aspectRange.contains(width / rowHeight) else { continue }
                grids.append(TerminalGrid(columns: columns, rowHeight: rowHeight, padding: padding))
            }
        }
        return grids
    }

    /// Whether a grid still explains the pane. This is the sieve: a candidate from an earlier look
    /// has to account for the height this look reports, with the text this look holds.
    public static func explains(
        _ grid: TerminalGrid,
        contentHeight: CGFloat,
        viewportHeight: CGFloat,
        lineLengths: [Int]
    ) -> Bool {
        guard grid.rowHeight > 0, !lineLengths.isEmpty else { return false }
        let total = rowStarts(lineLengths, columns: grid.columns)[lineLengths.count]
        guard total > 0 else { return false }
        let rows = (contentHeight - grid.padding) / grid.rowHeight
        guard abs(rows - CGFloat(total)) <= tolerance else { return false }
        let visible = (viewportHeight - grid.padding) / grid.rowHeight
        return abs(visible - visible.rounded()) <= tolerance && visible >= CGFloat(minimumVisibleRows)
    }

    /// How long each line of a buffer is, in UTF-16 code units.
    ///
    /// Counted in code units rather than characters because that is what the row arithmetic needs
    /// to be cheap: `String.count` walks grapheme boundaries, which measured 5.5 ms over a
    /// terminal-sized window, and this runs on every poll. It is also why a line of wide characters
    /// -- CJK, emoji -- is measured shorter than the columns it fills: the grid then fails to
    /// explain the height and the caller falls back rather than placing an outline from a count it
    /// cannot trust.
    public static func lineLengths(of buffer: String) -> [Int] {
        var lengths: [Int] = []
        var run = 0
        for unit in buffer.utf16 {
            if unit == 0x0A {
                lengths.append(run)
                run = 0
            } else if unit != 0x0D {
                run += 1
            }
        }
        lengths.append(run)
        return lengths
    }

    /// Which rows the viewport shows, both ends inclusive.
    ///
    /// `offset` is how far the viewport has scrolled into the content, so the first row is the one
    /// the top edge falls inside once the pane's own padding is taken off.
    public static func visibleRows(
        offset: CGFloat,
        viewportHeight: CGFloat,
        grid: TerminalGrid,
        totalRows: Int
    ) -> ClosedRange<Int>? {
        guard grid.rowHeight > 0, viewportHeight > 0, totalRows > 0, offset.isFinite else { return nil }
        let top = (offset - grid.topPadding) / grid.rowHeight
        let bottom = (offset - grid.topPadding + viewportHeight) / grid.rowHeight
        let first = max(0, min(totalRows - 1, Int(top.rounded(.down))))
        let last = max(first, min(totalRows - 1, Int(bottom.rounded(.up)) - 1))
        return first...last
    }

    /// The grid to draw with, if every candidate left agrees about it.
    ///
    /// Agreement is about the answer, not the arithmetic: several column counts put every line on
    /// the same row -- 137 and 138 columns both wrap the same lines the same way when nothing is
    /// between 137 and 138 characters long -- and any of them will do. What must match is where the
    /// rows are, so the row height, the padding and the row of every line all have to agree.
    public static func agreed(_ candidates: [TerminalGrid], lineLengths: [Int]) -> TerminalGrid? {
        guard let first = candidates.first else { return nil }
        let starts = rowStarts(lineLengths, columns: first.columns)
        for candidate in candidates.dropFirst() {
            guard abs(candidate.rowHeight - first.rowHeight) <= tolerance,
                  abs(candidate.padding - first.padding) <= tolerance,
                  rowStarts(lineLengths, columns: candidate.columns) == starts else { return nil }
        }
        return first
    }
}
