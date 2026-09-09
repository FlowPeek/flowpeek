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

    /// For each row, whether it continues the row above it. Same count as `rows`; the first row
    /// never continues anything.
    ///
    /// The state carried forward is the joined line, not the previous row, so a label spread over
    /// three rows joins all three: the first two both end inside the quote. A blank row ends the
    /// run whatever came before it, because a wrap has more text by definition -- an empty row
    /// means the line really did end.
    public static func flags(in rows: [String]) -> [Bool] {
        var flags = [Bool](repeating: false, count: rows.count)
        var joined = ""
        var run = 0
        for index in rows.indices {
            let row = rows[index]
            let continues = index > 0
                && run < maximumRows
                && !row.trimmingCharacters(in: .whitespaces).isEmpty
                && isUnterminated(joined)
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
}
