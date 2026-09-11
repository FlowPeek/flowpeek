import CoreGraphics
import Foundation

/// How tall one row is, solved from what a terminal reports about its own content rather than
/// divided out of it.
///
/// A scroll area reports `rows * rowHeight + residual`, where the residual is the pane's padding
/// and whatever else it counts that is not a row. Dividing the content height by the line count
/// treats that residual as if it were rows, which makes every row slightly too tall and puts the
/// error at the bottom of the screen, where the newest output is. Measured on Ghostty 1.3.1 in a
/// 1129x818 window, three buffers in the same pane:
///
///     lines    AXContentSize.height    lines * 16 + 34    height by division
///     60       994                     994                16.567
///     65       1074                    1074               16.523
///     100      1634                    1634               16.340
///
/// The row is exactly 16 points and the residual is exactly 34. The division is out by half a point
/// per row, which is twenty-three points -- a row and a half -- by the forty-fifth row down.
///
/// Two readings of the same pane solve it outright: the residual is the same in both, so it cancels
/// and the row height falls out of the difference. A terminal that is printing produces those two
/// readings within seconds of each other.
public enum TerminalRowMetrics {
    /// One reading of a pane: how many lines its value held, how tall it said its content was, and
    /// the viewport that was measured against.
    ///
    /// The viewport is part of the reading because the residual moves with it. Measured on the same
    /// 100-line buffer: 34 points of residual at a 786-point viewport, 28 at 668, 24 at 568. The
    /// row height was exactly 16 at all three, which is why the height is worth remembering and the
    /// residual is not.
    public struct Sample: Equatable, Sendable {
        public let lineCount: Int
        public let contentHeight: CGFloat
        public let viewportHeight: CGFloat

        public init(lineCount: Int, contentHeight: CGFloat, viewportHeight: CGFloat) {
            self.lineCount = lineCount
            self.contentHeight = contentHeight
            self.viewportHeight = viewportHeight
        }

        /// Whether this reading says anything about the grid at all.
        ///
        /// A buffer that fits its viewport is reported as being exactly the viewport's height --
        /// measured on Ghostty, `AXContentSize.height == AXFrame.height` to the point -- so the
        /// equation has no content in it and a height divided out of it would be the viewport
        /// divided by however many lines happen to be painted.
        public var isUsable: Bool {
            lineCount > 0
                && contentHeight.isFinite
                && viewportHeight.isFinite
                && contentHeight > viewportHeight + TerminalPeekPolicy.overflowTolerance
        }
    }

    /// How much of a pane's height may be something other than rows. Generous on purpose: the point
    /// is to rule out an answer that is not a grid, not to encode any one terminal's padding, and
    /// the number that had been encoded -- six points, measured on Ghostty 1.2 -- was wrong by the
    /// time Ghostty 1.3 shipped.
    public static let maximumResidualRows: CGFloat = 4

    /// The row height two readings of the same pane agree on, or nil when they cannot say.
    public static func rowHeight(_ first: Sample, _ second: Sample) -> CGFloat? {
        guard first.isUsable, second.isUsable else { return nil }
        // The residual only cancels between readings that share it, and it moves with the viewport.
        guard abs(first.viewportHeight - second.viewportHeight) < 0.5 else { return nil }
        let lines = CGFloat(second.lineCount - first.lineCount)
        guard abs(lines) >= 1 else { return nil }
        let height = (second.contentHeight - first.contentHeight) / lines
        guard TerminalPeekPolicy.rowHeightRange.contains(height) else { return nil }
        // A height that leaves an impossible remainder in either reading is not the height, whatever
        // the arithmetic between them says.
        guard residual(of: first, rowHeight: height) != nil,
              residual(of: second, rowHeight: height) != nil else { return nil }
        return height
    }

    /// What is left of a pane's height once its rows are accounted for, or nil when the row height
    /// cannot explain the reading.
    public static func residual(of sample: Sample, rowHeight: CGFloat) -> CGFloat? {
        guard sample.isUsable, rowHeight > 0 else { return nil }
        let residual = sample.contentHeight - CGFloat(sample.lineCount) * rowHeight
        // Below zero means the rows do not fit in the height the pane reported, which is not a
        // rounding error but the wrong grid.
        guard residual > -0.5, residual <= maximumResidualRows * rowHeight else { return nil }
        return max(0, residual)
    }

    /// Where the first row starts, below whatever the pane puts above it.
    ///
    /// Half the residual, which is what a pane that pads both ends does. It is an assumption, and a
    /// wrong one costs half the residual: eight points out of a sixteen-point row on the numbers
    /// above, which moves the frame by half a line rather than by the row and a half the division
    /// was costing.
    public static func topPadding(residual: CGFloat) -> CGFloat {
        max(0, residual / 2)
    }
}
