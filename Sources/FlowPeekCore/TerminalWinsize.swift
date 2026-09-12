import CoreGraphics
import Foundation

/// A terminal's grid as the terminal itself reports it: the cell, the columns, and where the first
/// row starts inside the pane. Every length is in points, because points are what the rest of
/// FlowPeek draws in and what the per-app remembered height is stored in.
public struct TerminalCellGrid: Equatable, Sendable {
    /// Rows on screen. Taken whole from the pty rather than divided out of anything.
    public let rows: Int
    /// Columns on screen, likewise taken whole.
    public let columns: Int
    /// How tall one row is, in points.
    public let rowHeight: CGFloat
    /// How wide one cell is, in points.
    public let cellWidth: CGFloat
    /// How far below the top of the pane the first row starts, in points.
    public let topPadding: CGFloat

    public init(rows: Int, columns: Int, rowHeight: CGFloat, cellWidth: CGFloat, topPadding: CGFloat) {
        self.rows = rows
        self.columns = columns
        self.rowHeight = rowHeight
        self.cellWidth = cellWidth
        self.topPadding = topPadding
    }
}

/// What a terminal writes into its pty about its own grid, and the grid that falls out of it.
///
/// `TerminalRowMetrics` solves the row height from two readings of a scrolling buffer, which is the
/// only thing a terminal will answer when it answers nothing about where a character is drawn. A
/// full-screen program answers even less: its buffer fits its viewport exactly, so
/// `AXContentSize.height == AXFrame.height` and the equation has no content in it at all. That is
/// every coding agent's interface and every vim session -- the two cases the outline has to work in.
///
/// The terminal has already published the answer elsewhere. `ioctl(TIOCGWINSZ)` on the pty returns
/// `ws_row` and `ws_col`, which are the grid, and `ws_ypixel` and `ws_xpixel`, which are the size of
/// the area those cells are drawn in, in DEVICE pixels, with the window's padding already removed.
/// Measured live on Ghostty 1.3.1, macOS 26, backing scale 2:
///
///     /dev/ttys000   ws_row 40   ws_col 140   ws_ypixel 1280   ws_xpixel 2250
///
/// and 1280/40 is 32 device pixels, which is 16.000 points at scale 2 -- exactly the row height that
/// three readings of `AXContentSize` had previously been needed to solve. Its cell is 16 device
/// pixels wide, or 8.000 points; dividing 2250 by 140 instead gives 16.07 pixels, which is the same
/// kind of drift the bracket exists to remove.
///
/// The reason this is arithmetic rather than a division is that `ws_ypixel` is not `rows * cell`.
/// Ghostty's cell size is a `u32` of device pixels and its row count is `@intFromFloat(screen/cell)`,
/// so the leftover sub-cell strip stays in `ws_ypixel` and sits below the last row. Measured on one
/// surface at four window heights: `ws_ypixel` 228, 528, 928 and 1328 against 7, 16, 29 and 41 rows,
/// and 1328 is not 41 * 32. What is exact is the bracket: the cell is the one integer `c` with
/// `ws_ypixel/(rows + 1) < c <= ws_ypixel/rows`. At 1328 and 41 rows that is `(31.62, 32.39]`, so 32.
///
/// The bracket is only narrow enough to hold a single integer once there are enough rows -- roughly
/// `rows >= cell - 1`, which is about 31 rows at a 32-pixel cell and about 15 at a 16-pixel one. A
/// live 7-row pane measured `(28.5, 32.571]`, four candidates, and four candidates is a guess. Those
/// refuse. So does a reading whose pixels cannot be squared with the pane that was measured, which
/// is what keeps one Ghostty process's other surfaces -- it owns one pty per split and per tab, and
/// nothing in the accessibility tree names which -- from answering for this one.
public struct TerminalWinsize: Hashable, Sendable {
    public let rows: Int
    public let columns: Int
    /// `ws_ypixel`, in DEVICE pixels. Not points. Treating it as points is a silent doubling that
    /// would be remembered and then applied to every later window, so it is never divided by a scale
    /// until the guard below has passed.
    public let heightInPixels: Int
    /// `ws_xpixel`, in device pixels.
    public let widthInPixels: Int

    public init(rows: Int, columns: Int, heightInPixels: Int, widthInPixels: Int) {
        self.rows = rows
        self.columns = columns
        self.heightInPixels = heightInPixels
        self.widthInPixels = widthInPixels
    }

    // MARK: - Bands

    /// Backing scales worth believing. macOS scaled display modes do not produce a fractional
    /// factor: the framebuffer is one or two device pixels to the point and the downsample to the
    /// panel happens after compositing, so it never reaches the pty. Measured here over all 210
    /// display modes of this Mac's screen, the pixel-to-point ratios were exactly `{1.000, 2.000}`.
    /// The band is still a band rather than the number 2, because a non-Retina display is real.
    public static let scaleRange: ClosedRange<CGFloat> = 1...3

    /// How large a cell may be, in device pixels. Below four pixels nothing is legible at any scale,
    /// and 256 pixels is a 128-point row at scale 2, which is twice what `rowHeightRange` allows.
    /// The band exists to bound the candidate set: with one row the bracket would otherwise be half
    /// the pane.
    public static let cellPixelRange = 4...256

    /// How far below zero the padding may fall before the reading is refused, in device pixels.
    ///
    /// Accessibility answers geometry as `Double` points and the pty answers whole pixels, so the
    /// two disagree by a fraction of a pixel at the point where they should be equal. Half a pixel
    /// covers that and nothing else: the errors this guard exists to catch are tens of rows wide.
    public static let paddingSlackInPixels: CGFloat = 0.5

    // MARK: - The bracket

    /// Every whole cell size, in device pixels, that could have produced `cells` cells across
    /// `span` device pixels.
    ///
    /// The terminal truncates: `cells = floor(span / cell)`, so `cell * cells <= span` and
    /// `cell * (cells + 1) > span`. Returned as a set because the count is the answer -- one member
    /// is a measurement and two members are a guess, and there is nothing in a reading that would
    /// let a caller choose between them.
    public static func cellPixels(spanning span: Int, cells: Int) -> Set<Int> {
        guard span > 0, cells > 0 else { return [] }
        // Integer division floors, and `span / (cells + 1) + 1` is the first integer strictly above
        // `span / (cells + 1)` whether or not that quotient is whole.
        let low = max(cellPixelRange.lowerBound, span / (cells + 1) + 1)
        let high = min(cellPixelRange.upperBound, span / cells)
        guard low <= high else { return [] }
        return Set(low...high)
    }

    /// The cell height in device pixels, when the bracket holds exactly one.
    public var cellHeightInPixels: Int? {
        let candidates = Self.cellPixels(spanning: heightInPixels, cells: rows)
        return candidates.count == 1 ? candidates.first : nil
    }

    /// Every cell height the reading allows, as a range in device pixels.
    ///
    /// The bracket is the whole of what one reading knows, and it is worth having even when it
    /// holds more than one integer, for two reasons. It bounds the answer -- a bracket two pixels
    /// wide puts the row within half a point at a Retina scale, which is a frame nobody can see is
    /// wrong -- and, more importantly, it *rules out* answers that came from somewhere else. A row
    /// height remembered from a different font is not a near miss; measured on a 22-row pane whose
    /// bracket was 56 to 58 pixels, the remembered one was 32, and the frame it drew covered a
    /// little over half the diagram and started a row above it.
    public var cellHeightBracket: ClosedRange<Int>? {
        let candidates = Self.cellPixels(spanning: heightInPixels, cells: rows)
        guard let low = candidates.min(), let high = candidates.max() else { return nil }
        return low...high
    }

    /// Whether a row height worked out some other way is one this reading could have produced.
    ///
    /// This is the half that matters most. A pane where the bracket cannot be closed used to fall
    /// through to whatever was remembered for the terminal, and nothing checked that the two had
    /// anything to do with each other.
    public func admits(rowHeight: CGFloat, scale: CGFloat) -> Bool {
        guard let bracket = cellHeightBracket, scale > 0, rowHeight > 0 else { return true }
        let pixels = rowHeight * scale
        // A pixel of slack at each end: the bracket is whole pixels and a solved height is not.
        return pixels >= CGFloat(bracket.lowerBound) - 1 && pixels <= CGFloat(bracket.upperBound) + 1
    }

    /// The cell width in device pixels, when the bracket holds exactly one.
    ///
    /// Nearly always pinned, because there are far more columns than rows: 2250 over 140 columns
    /// gives `(15.957, 16.071]`, one integer, on the same pane whose height bracket needed 31 rows
    /// to close. It is still checked, because a width that cannot be pinned is a reading that cannot
    /// place a wrapped line.
    public var cellWidthInPixels: Int? {
        let candidates = Self.cellPixels(spanning: widthInPixels, cells: columns)
        return candidates.count == 1 ? candidates.first : nil
    }

    // MARK: - The grid

    /// The grid this reading describes, or nil when it cannot be trusted to describe the pane that
    /// was measured.
    ///
    /// - Parameters:
    ///   - viewportSize: the pane's `AXFrame` size, in points. It includes the window padding, which
    ///     `ws_ypixel` and `ws_xpixel` do not -- that difference is the padding, and it is also the
    ///     guard.
    ///   - scale: the backing scale of the screen the terminal's window is on. Not `NSScreen.main`:
    ///     scale is a property of the window, and a window on a second display of a different scale
    ///     has a different cell in pixels for the same font.
    ///
    /// The guard is stated in pixels, before anything is divided by a scale that might be wrong:
    ///
    ///     padding = viewportSize.height * scale - heightInPixels
    ///     -0.5 <= padding <= 4 * cellHeightInPixels
    ///
    /// On the measured pane -- 40 rows, 1280 pixels, a 644-point viewport at scale 2 -- that is
    /// `1288 - 1280 = 8` pixels, a quarter of a row, and the answer is a 16.000-point row with 2.0
    /// points above it. Read at scale 1 the same numbers give `644 - 1280 = -636`: the reading would
    /// be claiming 40 rows of 32 points inside a 644-point pane, and it is refused. The mirror error,
    /// a genuinely unscaled display read as Retina, gives `1288 - 640 = 648` pixels of padding, which
    /// is forty rows against a four-row limit. A scale wrong by a factor of k inflates the padding by
    /// about `rows * cell * (k - 1)`, and the bracket has already insisted that `rows` is at least
    /// about `cell`, so the false padding is always tens of rows wide. The band on the row height
    /// cannot do this work: 32 points is inside `TerminalPeekPolicy.rowHeightRange` and reads as a
    /// perfectly legal large font.
    ///
    /// Known limitation: the top padding is half the total, which is what Ghostty does while
    /// `window-padding-balance` is off, its default. With it on, the top is capped and the excess
    /// pushed to the bottom, and nothing in `ws_*` says so.
    /// The grid, taking the middle of the bracket rather than insisting it hold one integer.
    ///
    /// `grid` refuses anything it cannot pin exactly, which is right when there is another way to
    /// find out -- and there is, for a pane whose buffer overflows its viewport, or one the reader
    /// resizes. A full-screen program on the alternate screen offers neither: its buffer is exactly
    /// its viewport for ever, so nothing is ever solved and nothing narrows. Measured on such a pane
    /// -- 22 rows in 1280 pixels -- the bracket is 56 to 58 and closes only at about 57 rows.
    ///
    /// The middle is safe however wide the bracket is, and the reason is worth stating because it
    /// is not obvious. The bracket's width is about `cell / rows`: it is wide exactly when the pane
    /// has few rows. Picking the middle is at most half the width out per row, so the error at the
    /// bottom of the screen is at most `(cell / rows) / 2 * rows`, which is **half a row, whatever
    /// the numbers are**. Measured against the two panes that fail to close here -- 22 rows of a
    /// 57-pixel cell, and 16 rows of a 58-pixel one -- the drift at the last row is 0 and 16 device
    /// pixels against rows of 57 and 58.
    ///
    /// Half a row is a frame nobody reads as wrong, and it is bounded. The alternative on these
    /// panes was a row height remembered from another font, which was out by nearly half and drew a
    /// frame over the wrong rows.
    public func approximateGrid(viewportSize: CGSize, scale: CGFloat) -> TerminalCellGrid? {
        guard let bracket = cellHeightBracket else { return nil }
        let middle = (bracket.lowerBound + bracket.upperBound) / 2
        return grid(viewportSize: viewportSize, scale: scale, cellHeightInPixels: middle)
    }

    /// The worst the middle of the bracket can be out by, at the last row of the pane, in points.
    ///
    /// Carried so a caller can say what it is drawing from rather than only that it drew.
    public func approximateDrift(scale: CGFloat) -> CGFloat? {
        guard let bracket = cellHeightBracket, scale > 0 else { return nil }
        let half = CGFloat(bracket.upperBound - bracket.lowerBound) / 2
        return half * CGFloat(rows) / scale
    }

    public func grid(viewportSize: CGSize, scale: CGFloat) -> TerminalCellGrid? {
        guard let pinned = cellHeightInPixels else { return nil }
        return grid(viewportSize: viewportSize, scale: scale, cellHeightInPixels: pinned)
    }

    private func grid(
        viewportSize: CGSize,
        scale: CGFloat,
        cellHeightInPixels cellHeight: Int
    ) -> TerminalCellGrid? {
        // An unset winsize. Terminals that never report a pixel size answer zeroes, and zeroes have
        // no grid in them.
        guard rows > 0, columns > 0, heightInPixels > 0, widthInPixels > 0 else { return nil }
        guard scale.isFinite, Self.scaleRange.contains(scale) else { return nil }
        guard viewportSize.height.isFinite, viewportSize.width.isFinite,
              viewportSize.height > 0, viewportSize.width > 0 else { return nil }

        // The width is still pinned exactly: there are far more columns than rows, so its bracket
        // closes where the height's does not.
        guard let cellWidth = cellWidthInPixels else { return nil }

        // The guard, in device pixels, on both axes. Vertically it catches the scale errors;
        // horizontally it catches a reading that belongs to another of this process's surfaces.
        let verticalPadding = viewportSize.height * scale - CGFloat(heightInPixels)
        let horizontalPadding = viewportSize.width * scale - CGFloat(widthInPixels)
        guard verticalPadding >= -Self.paddingSlackInPixels,
              horizontalPadding >= -Self.paddingSlackInPixels else { return nil }
        guard verticalPadding <= TerminalGridInference.paddingLimitRows * CGFloat(cellHeight),
              horizontalPadding <= TerminalGridInference.paddingLimitRows * CGFloat(cellWidth)
        else { return nil }

        // Only now are pixels points.
        let rowHeight = CGFloat(cellHeight) / scale
        let width = CGFloat(cellWidth) / scale
        guard TerminalPeekPolicy.rowHeightRange.contains(rowHeight) else { return nil }
        // A monospaced cell is about half as wide as it is tall. A pair that is not is a reading
        // whose two axes came from different surfaces.
        guard TerminalGridInference.aspectRange.contains(width / rowHeight) else { return nil }

        return TerminalCellGrid(
            rows: rows,
            columns: columns,
            rowHeight: rowHeight,
            cellWidth: width,
            topPadding: max(0, verticalPadding / (2 * scale))
        )
    }
}
