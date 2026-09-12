import Foundation

/// Where the rows on screen sit inside the file they came from.
///
/// A full-screen editor paints on the terminal's alternate screen, and the alternate screen has no
/// scrollback. Measured on Ghostty: a 200-line file open in a 19-row pane answers 855 characters
/// and 19 lines, and `AXStringForRange` one character past that returns `kAXErrorNoValue`. Scrolled
/// to line 200 it still answers 19 lines, and the file's first line is simply not there. So there is
/// no window to widen and nothing further to read: what is on screen is the whole of what the
/// terminal has, and a diagram taller than the pane cannot be recovered from it at any price.
///
/// The file, though, is on disk, and the editor's own process says which one. What this does is the
/// other half of that: it puts the rows back where they came from, so the block can be taken from
/// the file while the frame is still drawn over the rows the reader is looking at.
///
/// It is also the check. Nothing here identifies which pane an editor belongs to -- one terminal
/// process owns every split and tab, and none of them says which pty is in front -- so the file is
/// a candidate rather than an answer, and the alignment is what accepts or refuses it. A file whose
/// lines are not on the screen does not align, and a candidate that does not align is not used.
public enum EditorViewportAlignment {
    /// How many rows have to match before an alignment is believed.
    ///
    /// Four, because three is reachable by accident in a file with repeated structure -- a run of
    /// `end`, a block of similar edges -- and because a diagram worth framing is taller than that
    /// anyway. Below it the route refuses and the reader gets what they get today.
    public static let minimumRun = 4

    /// How far ahead the best alignment has to be. A file that matches in two places has not been
    /// located, and picking either is a guess.
    public static let minimumLead = 2

    /// Rows an editor draws that are not in the file: the tildes vim prints past the end, and the
    /// status line it keeps at the bottom.
    static func isChrome(_ row: String) -> Bool {
        let trimmed = row.trimmingCharacters(in: .whitespaces)
        return trimmed == "~" || trimmed == "@" || trimmed.isEmpty
    }

    /// Where a pane's rows were found in the file, and how many of them are the file's.
    public struct Placement: Equatable, Sendable {
        /// The file line the first row is showing.
        public let firstLine: Int
        /// How many rows from the top are the file's own lines.
        ///
        /// Not the pane's height. An editor draws furniture the file does not contain -- vim's
        /// status line is always there and its tildes are there whenever the file ends above the
        /// bottom of the window -- and a row of furniture is not a row of the diagram. It is also
        /// where an unwritten edit stops the match: the changed row is not the file's, the run ends
        /// there, and what is framed is what still agrees.
        public let matchedRows: Int

        public init(firstLine: Int, matchedRows: Int) {
            self.firstLine = firstLine
            self.matchedRows = matchedRows
        }
    }

    /// Which file line the first row of `rows` is showing, or nil when the rows cannot be placed.
    ///
    /// - Parameters:
    ///   - rows: the pane's rows, top to bottom, exactly as the terminal reported them.
    ///   - fileLines: the file, split on newlines.
    public static func placement(ofRows rows: [String], in fileLines: [String]) -> Placement? {
        guard !fileLines.isEmpty else { return nil }
        // The editor's own furniture comes off the bottom: tildes past the end of the file, and the
        // status line, which is the one row that is never in the file.
        var body = rows
        while let last = body.last, isChrome(last) || body.count > fileLines.count + 1 { body.removeLast() }
        if let last = body.last, !last.isEmpty, !fileLines.contains(where: { $0.hasSuffix(last) }) {
            body.removeLast()
        }
        guard body.count >= minimumRun else { return nil }

        // Anchor on the first row that says something. A blank row or a lone brace is in a hundred
        // places; a line of a diagram is usually in one.
        let index = Self.index(of: fileLines)
        guard let anchorOffset = body.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).count > 3 })
        else { return nil }
        let anchor = normalise(body[anchorOffset])
        guard let starts = index[anchor] else { return nil }

        var best = (start: -1, run: 0)
        var runner = 0
        for start in starts {
            let first = start - anchorOffset
            guard first >= 0 else { continue }
            var run = 0
            while run < body.count, first + run < fileLines.count,
                  normalise(fileLines[first + run]) == normalise(body[run]) {
                run += 1
            }
            if run > best.run {
                runner = best.run
                best = (first, run)
            } else if run > runner {
                runner = run
            }
        }
        guard best.run >= minimumRun, best.run >= runner + minimumLead else { return nil }
        return Placement(firstLine: best.start, matchedRows: best.run)
    }

    /// Only the line, for callers that do not care how much of the pane was furniture.
    public static func firstLine(ofRows rows: [String], in fileLines: [String]) -> Int? {
        placement(ofRows: rows, in: fileLines)?.firstLine
    }

    /// Trailing space is not information: a terminal pads a row to the width it drew it at, and the
    /// file does not.
    public static func normalise(_ line: String) -> String {
        var text = Substring(line)
        while let last = text.last, last == " " || last == "\t" { text = text.dropLast() }
        return String(text)
    }

    private static func index(of fileLines: [String]) -> [String: [Int]] {
        var index: [String: [Int]] = [:]
        for (number, line) in fileLines.enumerated() {
            let key = normalise(line)
            guard key.trimmingCharacters(in: .whitespaces).count > 3 else { continue }
            index[key, default: []].append(number)
        }
        return index
    }

    /// Which of a block's file lines are on screen, as offsets from the first row.
    ///
    /// Returns nil when none of it is, which is how a diagram the reader has scrolled away from
    /// stops being framed.
    public static func rowsOnScreen(
        ofLines lines: ClosedRange<Int>,
        firstLine: Int,
        rowCount: Int
    ) -> ClosedRange<Int>? {
        let top = max(lines.lowerBound - firstLine, 0)
        let bottom = min(lines.upperBound - firstLine, rowCount - 1)
        guard top <= bottom, lines.upperBound >= firstLine, lines.lowerBound <= firstLine + rowCount - 1
        else { return nil }
        return top...bottom
    }
}
