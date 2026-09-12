/// Which rows of a terminal buffer are the tail of the row above them rather than lines of their
/// own.
///
/// A terminal shows a long line on several rows, and so does a program that lays out its own
/// output: Claude Code wraps a diagram to its content width and prints each piece as a row with its
/// left margin, so what reaches the buffer is genuinely several lines. Measured on the diagram this
/// was written for -- 27 lines, four of them past the width -- the scanner stopped at the first
/// wrapped row and claimed 13 rows of 32, which is an outline around half a diagram and a source
/// ending mid-label that mermaid then refuses.
///
/// Nothing in the text says "this row was wrapped". The buffer knows, and does not tell: no
/// terminal exposes the flag, and the two that answer for geometry answer per line, not per row.
/// So the join is decided on mermaid's own syntax instead. A row that ends inside a quoted label,
/// or with a bracket still open, cannot be a whole statement -- whatever follows is the rest of it.
/// A row that closes everything it opened is a line, and the row after it starts a new one.
///
/// The alternative was to infer the width rows wrap at, from the longest row in the window. It is
/// wrong on ordinary diagrams: `Alpha --> Beta["one"]` and `Gamma --> Delta["two"]` are the same
/// length and the longest in their window, and reading that as a wrap width joins the second onto
/// the first and breaks a diagram that was rendering perfectly well. Syntax cannot make that
/// mistake -- both of those rows close their quotes.
public enum RowContinuation {
    /// How many rows one logical line may be spread over.
    ///
    /// A cap rather than a limit anyone should reach: a 400-character label wraps to five rows in a
    /// narrow terminal. It exists so a genuinely unterminated diagram -- a broken one, or one
    /// scrolled in half -- cannot swallow a screen of whatever followed it one row at a time.
    public static let maximumRows = 16

    /// Whether a row ends in the middle of something it opened, so the row after it is the rest of
    /// the same line.
    ///
    /// Quotes and the three bracket pairs mermaid builds labels out of. `|` is not counted: it
    /// delimits edge labels but is the same character at both ends, so an odd one is as likely to
    /// be a wrapped `-.->|` as an unclosed label, and guessing costs more than it pays. A `%%`
    /// comment is never unterminated -- brackets in prose are prose, and joining the row after a
    /// comment onto it would take that row out of the diagram.
    public static func isUnterminated(_ row: String) -> Bool {
        let trimmed = row.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("%%") else { return false }
        var quote: Character?
        var depth = 0
        for character in row {
            if let open = quote {
                if character == open { quote = nil }
                continue
            }
            switch character {
            case "\"", "'": quote = character
            case "[", "(", "{": depth += 1
            case "]", ")", "}": depth = max(0, depth - 1)
            default: break
            }
        }
        return quote != nil || depth > 0
    }

    // MARK: - What the grid says

    /// Column counts worth believing. Outside this band the number did not come from a terminal
    /// that is showing this text, and every question below is answered as if it were absent.
    public static let columnRange = 20...1000

    /// How wide a row is on screen, in cells.
    ///
    /// Not its character count. A Hangul syllable or a CJK ideograph occupies two cells, and a
    /// Korean diagram is an ordinary thing for this app to be pointed at, so counting characters
    /// would put every row of one well short of the width and make every join look like a word
    /// wrap. Combining marks occupy none. The width of a grapheme is taken from the scalar that
    /// starts it, which is what a terminal does with it.
    public static func displayWidth(_ row: String) -> Int {
        var width = 0
        for character in row {
            guard let scalar = character.unicodeScalars.first else { continue }
            width += cellWidth(of: scalar)
        }
        return width
    }

    private static func cellWidth(of scalar: Unicode.Scalar) -> Int {
        let value = scalar.value
        // Combining marks and the zero-width joiners sit on the character before them.
        if (0x0300...0x036F).contains(value) || value == 0x200B || value == 0x200D { return 0 }
        return wideRanges.contains { $0.contains(value) } ? 2 : 1
    }

    /// The blocks a terminal draws two cells wide: Hangul, the CJK ideographs and the kana around
    /// them, the fullwidth forms, and the emoji planes.
    private static let wideRanges: [ClosedRange<UInt32>] = [
        0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF,
        0x4E00...0x9FFF, 0xA000...0xA4CF, 0xA960...0xA97F, 0xAC00...0xD7A3,
        0xF900...0xFAFF, 0xFE10...0xFE19, 0xFE30...0xFE6F, 0xFF00...0xFF60,
        0xFFE0...0xFFE6, 0x1F300...0x1F64F, 0x1F900...0x1F9FF,
        0x20000...0x2FFFD, 0x30000...0x3FFFD,
    ]

    /// Whether a wrap could have put `next` where it is: whatever starts it would not have fitted
    /// on the end of `row`.
    ///
    /// This is the half of the question syntax cannot answer, and it answers in both directions. A
    /// row that ends well short of the width with room to spare for the next row's first word was
    /// not broken by the width, so the two rows are two lines however unterminated the first one
    /// looks -- which is what stops an `erDiagram` whose first statement opens a brace from
    /// swallowing the rest of itself. And a row that has no room left was broken by the width, even
    /// when it ends on a closing bracket that makes it read like a whole statement.
    public static func couldNotHaveFit(after row: String, next: String, columns: Int) -> Bool {
        guard columnRange.contains(columns) else { return false }
        let width = displayWidth(row)
        // Wider than the grid: this row did not come off a terminal of this width, so the grid has
        // nothing to say about it.
        guard width <= columns else { return false }
        return width + 1 + displayWidth(firstToken(of: next)) > columns
    }

    /// Whether the wrap that broke `row` before `next` destroyed the space between them.
    ///
    /// A wrapping program breaks at a space and consumes it, which is why the naive join reads
    /// `...source forconfidence`. It only splits a word when the word does not fit on a line of its
    /// own, and it fills the row to the last cell when it does -- so a row short of the width was
    /// certainly broken at a space, and a row at the width was broken at one unless the two halves
    /// either side of the break make a word too long to have been placed whole.
    ///
    /// Measured against Claude Code 2.1.269 driven in a pty at 80, 100, 120 and 160 columns: 79
    /// breaks, every one of them at a space, 67 of them on a row short of the width and 12 on a row
    /// at it; and three constructed over-long labels, every one broken mid-word on a row at exactly
    /// the width. The rule is right on all 82.
    public static func wrapDestroyedASpace(before next: String, after row: String, columns: Int) -> Bool {
        guard columnRange.contains(columns) else { return false }
        let width = displayWidth(row)
        guard width <= columns else { return false }
        guard width == columns else { return true }
        // The word that would have had to be split, if this was a split rather than a break at a
        // space. A line of its own is the grid less the margin the wrapping program prints, which
        // is the indentation the tail arrived with.
        let word = lastToken(of: row) + firstToken(of: next)
        let indent = next.prefix { $0 == " " || $0 == "\t" }.count
        return displayWidth(word) <= columns - indent
    }

    private static func firstToken(of row: String) -> String {
        String(row.drop { $0 == " " || $0 == "\t" }.prefix { $0 != " " && $0 != "\t" })
    }

    private static func lastToken(of row: String) -> String {
        String(row.reversed().prefix { $0 != " " && $0 != "\t" }.reversed())
    }

    // MARK: - Which rows are tails

    /// For each row, whether it continues the row above it. Same count as `rows`; the first row
    /// never continues anything.
    ///
    /// The state carried forward is the joined line, not the previous row, so a label spread over
    /// three rows joins all three: the first two both end inside the quote. A blank row ends the
    /// run whatever came before it, because a wrap has more text by definition -- an empty row
    /// means the line really did end.
    ///
    /// `columns` is the terminal's own column count, from `ioctl(TIOCGWINSZ)`, and it is what turns
    /// the syntax guess into a measurement. Without it the rule is exactly what it was: a row is a
    /// tail when the row above it is unterminated. With it, a join has to be possible as well as
    /// plausible, and a row the width plainly broke is a tail whether or not the syntax can see it.
    public static func flags(in rows: [String], columns: Int? = nil) -> [Bool] {
        let grid = columns.flatMap { columnRange.contains($0) ? $0 : nil }
        var flags = [Bool](repeating: false, count: rows.count)
        var joined = ""
        var run = 0
        for index in rows.indices {
            let row = rows[index]
            var continues = index > 0
                && run < maximumRows
                && !row.trimmingCharacters(in: .whitespaces).isEmpty
            if continues, let grid {
                let previous = rows[index - 1]
                let broken = couldNotHaveFit(after: previous, next: row, columns: grid)
                // A tail carries the wrapping program's margin rather than the line's own
                // indentation, so it sits to the left of the row it continues. A sibling statement
                // does not: it is indented like its siblings. That is what keeps the width from
                // joining two short lines that happen to sit near the edge.
                let lostItsIndent = indent(of: row) < indent(of: previous)
                continues = broken && (isUnterminated(joined) || lostItsIndent)
            } else if continues {
                continues = isUnterminated(joined)
            }
            flags[index] = continues
            if continues {
                joined += row
                run += 1
            } else {
                joined = row
                run = 0
            }
        }
        return flags
    }

    private static func indent(of row: String) -> Int {
        row.prefix { $0 == " " || $0 == "\t" }.count
    }
}
