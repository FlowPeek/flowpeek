import CoreGraphics
import Foundation

/// Where the whole diagram sits on screen when only the caret's own line can be measured.
///
/// Editors that answer through text markers give the focused element a frame, and that frame is the
/// caret's line -- which is why an outline anchored on the caret frames one line of a diagram that
/// may be twenty. The ranges that would give the real rectangle are not answerable: measured in VS
/// Code, `AXTextMarkerForPosition` is advertised and returns nil, `AXBoundsForRange` answers 0x0,
/// and `AXTextMarkerRangeForLine` returns the caret's line rectangle whichever line is asked for.
///
/// What is answerable is exact. Clicking down five consecutive lines put the caret line at y 147,
/// 165, 183, 201 and 219 -- a line height of 18 with no drift, so the offset from the caret's line
/// to any other line is a multiplication. The line numbers come from the document text, which the
/// caret route already holds.
///
/// The arithmetic assumes each document line occupies one row, which soft wrapping and folded
/// regions break. It is checked against the editor rather than trusted: the caller confirms the
/// editor agrees about which text is on the first line, and falls back to the caret's line when it
/// does not.
public enum CaretBlockGeometry {
    /// Beyond this the block is longer than any editor shows at once, so the estimate would be
    /// mostly off-screen and the clip would refuse it anyway.
    public static let maximumLines = 400

    /// The rectangle covering `firstLine ... lastLine`, in AppKit coordinates, or nil when the
    /// inputs cannot describe one.
    ///
    /// - Parameters:
    ///   - caretLine: the caret's own line rectangle. Its height is the line height and its x and
    ///     width are the text column, both of which every line shares.
    ///   - caretLineNumber: which document line the caret is on, counting from 1.
    ///   - firstLine: the diagram's first line, counting from 1.
    ///   - lastLine: the diagram's last line, counting from 1.
    public static func rectangle(
        caretLine: CGRect,
        caretLineNumber: Int,
        firstLine: Int,
        lastLine: Int
    ) -> CGRect? {
        let lineHeight = caretLine.height
        guard lineHeight > 0, caretLine.width > 0,
              caretLine.origin.x.isFinite, caretLine.origin.y.isFinite,
              firstLine >= 1, lastLine >= firstLine,
              firstLine <= caretLineNumber, caretLineNumber <= lastLine else { return nil }
        let lines = lastLine - firstLine + 1
        guard lines <= maximumLines else { return nil }
        // AppKit's y grows upward, so an earlier line sits higher: the top of the block is the top
        // of the caret's line plus one line height for every line between them.
        let top = caretLine.maxY + CGFloat(caretLineNumber - firstLine) * lineHeight
        let height = CGFloat(lines) * lineHeight
        let rect = CGRect(x: caretLine.origin.x, y: top - height, width: caretLine.width, height: height)
        guard rect.origin.y.isFinite, rect.height.isFinite else { return nil }
        return rect
    }

    /// Which line a character offset falls on, counting from 1.
    ///
    /// Counted in UTF-16 units because that is what the accessibility APIs measure in, and a
    /// document with an emoji in it would otherwise put the caret on the wrong line.
    public static func lineNumber(of offset: Int, in document: String) -> Int? {
        let units = Array(document.utf16)
        guard offset >= 0, offset <= units.count else { return nil }
        var line = 1
        var index = 0
        let newline = UInt16(UInt8(ascii: "\n"))
        while index < offset {
            if units[index] == newline { line += 1 }
            index += 1
        }
        return line
    }

    /// The first and last lines a range covers, counting from 1.
    public static func lines(of range: NSRange, in document: String) -> (first: Int, last: Int)? {
        guard range.location >= 0, range.length >= 0,
              let first = lineNumber(of: range.location, in: document) else { return nil }
        // A range ending on a newline belongs to the line it ends, not the one after: a fenced block
        // whose last character is the closing fence's newline must not claim the blank line below.
        let end = range.location + range.length
        let units = Array(document.utf16)
        guard end <= units.count else { return nil }
        let newline = UInt16(UInt8(ascii: "\n"))
        let lastIndex = end > range.location && units[end - 1] == newline ? end - 1 : end
        guard let last = lineNumber(of: lastIndex, in: document) else { return nil }
        return (first, max(first, last))
    }
}
