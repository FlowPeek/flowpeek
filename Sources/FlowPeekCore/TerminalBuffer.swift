import Foundation

/// One diagram found in a slice of a terminal's buffer, and where it sits in that slice.
public struct TerminalDiagramBlock: Equatable, Sendable {
    public let detection: MermaidDetection
    /// The block's own text, fences included -- the detector strips those, so that work stays in
    /// one place.
    public let text: String
    /// Zero-based line numbers inside the window that was scanned, both ends inclusive.
    public let lines: ClosedRange<Int>
    /// Where `text` came from inside the window, in UTF-16 code units: the unit an accessibility
    /// character range is counted in, because the value it indexes is an `NSString`.
    public let range: NSRange
    /// The last row's own range inside the window.
    ///
    /// Carried because a terminal cannot be trusted to answer for the whole block at once: asked
    /// for the bounds of a six-row range, iTerm2 measured 21 points wide -- a strip, not the block
    /// -- while Terminal.app measured the enclosing 560x84. One row at a time is answered correctly
    /// by both, so the vertical extent is taken from the first row and this one.
    public let lastRow: NSRange
    /// Whether a fence marked the block, rather than a diagram starter alone. A fenced block knows
    /// exactly where it ends; an unfenced one is bounded by a guess about blank lines.
    public let isFenced: Bool

    /// The offset of the block's last character, for measuring where the block ends on screen.
    ///
    /// The last *character*, not the start of the last row, because a row longer than the terminal
    /// is wide occupies more than one row of screen. Terminal.app answered `AXBoundsForRange` for
    /// a 180-character line in an 80-column window with a 42-point rectangle -- three rows of 14 --
    /// while the row's first character alone measured 14. Asking about the first character puts the
    /// bottom of the outline two rows above the text it is meant to enclose.
    public var lastCharacter: Int {
        lastRow.location + max(0, lastRow.length - 1)
    }

    public init(
        detection: MermaidDetection,
        text: String,
        lines: ClosedRange<Int>,
        range: NSRange,
        lastRow: NSRange,
        isFenced: Bool
    ) {
        self.detection = detection
        self.text = text
        self.lines = lines
        self.range = range
        self.lastRow = lastRow
        self.isFenced = isFenced
    }
}

/// Finds the diagrams in a window of terminal output.
///
/// Different job from `DocumentCaretSlicer`, which answers "which block is the cursor in". A
/// terminal has no cursor to anchor on -- the diagram is wherever it happened to be printed -- so
/// this finds every block and lets the caller choose by what is on screen. It also has to cope
/// with output that was never a document: a `cat` of a `.mmd` file arrives with no fence at all,
/// under a shell prompt, which is the one case the slicer's fence-free branch refuses because the
/// window's first line is not the diagram's.
public enum TerminalBufferScanner {
    /// How much buffer one scan will look at, in UTF-16 code units. The window a caller reads is
    /// the viewport plus a margin, so this is a backstop against a terminal that answers with far
    /// more than it was asked for rather than a limit anyone is expected to reach.
    public static let maximumWindowCharacters = 96_000

    /// How far an unfenced block may run. Terminal output is not a document and nothing closes the
    /// block, so without a limit a diagram starter printed above ten thousand lines of log would
    /// swallow all of them and then be refused on size, which reads as "no diagram here".
    public static let maximumUnfencedLines = 400

    /// Every diagram in `window`, in the order they appear.
    /// - Parameter columns: the terminal's own column count, when it is known. It is what the
    ///   width of a row can be compared against, which decides both which rows were broken by the
    ///   width and whether the break destroyed a space. Absent, every rule below is exactly what it
    ///   was before the grid was ever read.
    public static func blocks(
        in window: String,
        columns: Int? = nil,
        minimumConfidence: MermaidDetection.Confidence = TerminalPeekPolicy.minimumConfidence
    ) -> [TerminalDiagramBlock] {
        guard !window.isEmpty, window.utf16.count <= maximumWindowCharacters else { return [] }
        let lines = self.lines(of: window)
        guard !lines.isEmpty else { return [] }

        // Which rows are the tail of the row above them, so a line the terminal or a program broke
        // across rows is read as the one line it is.
        let continuations = RowContinuation.flags(in: lines.map(\.text), columns: columns)

        var blocks: [TerminalDiagramBlock] = []
        var index = 0
        while index < lines.count {
            // A row that is the middle of somebody else's line starts nothing: the fence or the
            // declaration it appears to carry is text inside a label.
            if continuations[index] {
                index += 1
                continue
            }
            if let open = MarkdownFence.open(lines[index].text) {
                let close = closingFence(lines, after: index, marker: open.marker, continuations)
                let last = close ?? lines.count - 1
                let held = open.mayHoldMermaid
                    && append(
                        &blocks, lines, from: index, to: last, fenced: true, continuations,
                        columns, minimumConfidence
                    )
                if held {
                    // Past the whole block, closing fence included: a fence inside a fence is
                    // content, and treating it as an opener would start a block in the middle of a
                    // code sample.
                    index = last + 1
                } else {
                    // A fence that held no diagram is not evidence of where anything ends, and a
                    // window into a terminal's buffer routinely opens in the middle of one. Scrolled
                    // up two rows, Terminal.app's buffer began "    C --> E[Done]" then "```" --
                    // the tail of the previous diagram -- and that closing fence reads exactly like
                    // an opener. Skipping to its partner swallowed the twenty-five rows after it,
                    // the real block among them, and nothing was outlined. So a rejected fence
                    // costs one line, not a span.
                    index += 1
                }
                continue
            }
            if MermaidDetector.declaresDiagram(lines[index].text) {
                let last = unfencedEnd(lines, from: index, continuations)
                append(
                    &blocks, lines, from: index, to: last, fenced: false, continuations,
                    columns, minimumConfidence
                )
                index = last + 1
                continue
            }
            index += 1
        }
        return blocks
    }

    /// Every block with some of itself on screen, in the order they appear in the buffer.
    ///
    /// All of them, not the biggest one: a terminal showing two diagrams is showing two diagrams,
    /// and framing only one leaves the other with no way to be opened at all. Document order
    /// rather than most-visible-first, because the order is what the outlines are identified by
    /// from one poll to the next and a block growing or shrinking must not renumber its neighbours.
    ///
    /// Being on screen is the whole test. The user asked for frames that appear and disappear with
    /// the blocks, so a diagram scrolled entirely into the scrollback answers nothing.
    public static func blocks(
        in window: String,
        visible: ClosedRange<Int>,
        columns: Int? = nil,
        minimumConfidence: MermaidDetection.Confidence = TerminalPeekPolicy.minimumConfidence
    ) -> [TerminalDiagramBlock] {
        blocks(in: window, columns: columns, minimumConfidence: minimumConfidence).filter {
            $0.lines.upperBound >= visible.lowerBound && $0.lines.lowerBound <= visible.upperBound
        }
    }

    // MARK: - Blocks

    /// Appends the block those lines make, and reports whether they made one.
    @discardableResult
    private static func append(
        _ blocks: inout [TerminalDiagramBlock],
        _ lines: [Line],
        from first: Int,
        to last: Int,
        fenced: Bool,
        _ continuations: [Bool],
        _ columns: Int?,
        _ minimumConfidence: MermaidDetection.Confidence
    ) -> Bool {
        // Trailing blank lines are dropped: a block that ends in whitespace would claim rows the
        // diagram does not occupy, and the outline is drawn around exactly these rows.
        var end = last
        while end > first, lines[end].text.trimmingCharacters(in: .whitespaces).isEmpty { end -= 1 }
        let text = source(lines, from: first, to: end, continuations, columns)
        let detection = MermaidDetector.detect(text)
        guard detection.confidence >= minimumConfidence else { return false }
        blocks.append(
            TerminalDiagramBlock(
                detection: detection,
                text: text,
                lines: first...end,
                range: NSRange(
                    location: lines[first].start,
                    length: lines[end].contentEnd - lines[first].start
                ),
                lastRow: NSRange(
                    location: lines[end].start,
                    length: lines[end].contentEnd - lines[end].start
                ),
                isFenced: fenced
            )
        )
        return true
    }

    private static func closingFence(
        _ lines: [Line],
        after index: Int,
        marker: Character,
        _ continuations: [Bool]
    ) -> Int? {
        lines.indices.dropFirst(index + 1).first {
            !continuations[$0] && MarkdownFence.closes(lines[$0].text, marker: marker)
        }
    }

    /// The block's text as its author wrote it: one line per line, with rows that are the tail of
    /// the row above them joined back on.
    ///
    /// The margin comes off the joined piece. A program that wraps its own output prints the same
    /// left margin on every row it emits -- Claude Code's is two spaces, the same two the diagram's
    /// declaration carries -- so the tail arrives with a margin in the middle of a label. Only that
    /// exact prefix is removed, and only when the row carries it: a terminal wrapping a line of its
    /// own adds nothing, and a tail that happens to begin with spaces of its own keeps them.
    private static func source(
        _ lines: [Line],
        from first: Int,
        to end: Int,
        _ continuations: [Bool],
        _ columns: Int?
    ) -> String {
        let margin = lines[first].text.prefix { $0 == " " || $0 == "\t" }
        var pieces: [String] = []
        for index in first...end {
            let text = lines[index].text
            // The block's own first row starts it, whatever it continues above.
            guard index > first, continuations[index], !pieces.isEmpty else {
                pieces.append(text)
                continue
            }
            let tail = !margin.isEmpty && text.hasPrefix(margin)
                ? String(text.dropFirst(margin.count))
                : text
            // The space the wrap ate. A program that breaks a line at a space does not keep it, so
            // joining the pieces back together with nothing between them runs the last word of one
            // row into the first word of the next -- `...source for` and `confidence` become
            // `forconfidence`, which mermaid draws without complaint and which is not what anybody
            // wrote. Only the grid can say whether there was a space there, so without it the join
            // stays exactly as tight as it has always been.
            let separator = columns.map {
                RowContinuation.wrapDestroyedASpace(before: text, after: lines[index - 1].text, columns: $0)
            } ?? false
            pieces[pieces.count - 1] += (separator ? " " : "") + tail
        }
        return pieces.joined(separator: "\n")
    }

    /// Where an unfenced block printed into a terminal stops.
    ///
    /// Nothing closes it. A fence says "the block ends here" and a document ends with its file, but
    /// terminal output just carries on into whatever ran next -- and the line that follows a
    /// diagram is almost always a shell prompt, which is not blank. So "run to the next blank line"
    /// is not the rule: it swallowed the prompt and every line after it.
    ///
    /// What a diagram's own lines have in common is one of three things, and a prompt has none of
    /// them: they are indented under the declaration, they are `%%` comments, or they carry an
    /// arrow. A blank line between them is ordinary -- a styling section or a subgraph body is
    /// separated from the statements above it -- so a blank line is crossed when the next line that
    /// has anything on it continues the block, and ends it otherwise.
    ///
    /// The cost of being wrong is asymmetric, which is why the rule leans towards stopping early:
    /// too short means the detector turns the block down and no outline appears, while too long
    /// means an outline around a prompt and a preview of somebody's shell session.
    private static func unfencedEnd(_ lines: [Line], from first: Int, _ continuations: [Bool]) -> Int {
        var index = first
        let limit = min(lines.count - 1, first + maximumUnfencedLines - 1)
        let base = indentWidth(lines[first].text)
        while index < limit {
            // The tail of the row above is the same line, and a line cannot end the block it is
            // part of. Without this the block stopped at the first row a wrap had broken: the tail
            // carries the wrapping program's margin rather than the diagram's indentation, so it
            // read as un-indented, and it holds a fragment of a label rather than an arrow.
            if continuations[index + 1] {
                index += 1
                continue
            }
            let next = lines[index + 1].text
            if next.trimmingCharacters(in: .whitespaces).isEmpty {
                guard let following = lines.indices.dropFirst(index + 2).first(where: {
                    !lines[$0].text.trimmingCharacters(in: .whitespaces).isEmpty
                }), following <= limit, continuesBlock(lines[following].text, deeperThan: base) else { break }
            } else if !continuesBlock(next, deeperThan: base) {
                break
            }
            index += 1
        }
        return index
    }

    /// Whether a line is still part of the diagram above it.
    ///
    /// Indented *further than the declaration*, rather than indented at all. A terminal user
    /// interface that prints a margin down the left of everything it says makes "indented at all"
    /// true of its prose as well as of the diagram inside it: measured against Claude Code, whose
    /// margin is two spaces, a diagram declared at that margin swallowed every paragraph after it
    /// and mermaid's parse error was drawn over the lot. The declaration's own indentation is the
    /// margin, so the diagram's body is what sits past it.
    private static func continuesBlock(_ line: String, deeperThan base: Int) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("%%") { return true }
        if !trimmed.isEmpty, indentWidth(line) > base { return true }
        // A rule of dashes is a separator in someone's output, not a link, and `---` is in the
        // arrow table. Everything else with an arrow in it belongs to the diagram.
        guard !trimmed.allSatisfy({ $0 == "-" }) else { return false }
        return MermaidDetector.hasEdgeToken(trimmed)
    }

    /// Leading spaces and tabs, counted in characters. A terminal has already expanded its own
    /// tabs, so a tab that survives came from the text and one column is as good a guess as eight.
    private static func indentWidth(_ line: String) -> Int {
        line.prefix { $0 == " " || $0 == "\t" }.count
    }

    // MARK: - Lines

    private struct Line {
        let text: String
        /// UTF-16 offset of the line's first character.
        let start: Int
        /// UTF-16 offset just past the line's last character, before its terminator.
        let contentEnd: Int
    }

    /// Splits into lines while counting UTF-16 offsets, because those offsets are what an
    /// accessibility character range is expressed in and what maps a block back onto the screen.
    ///
    /// Split in bulk rather than walked character by character. This runs on every poll over a
    /// window the size of a terminal's viewport plus its margins, and a `Character` loop -- which
    /// has to find grapheme boundaries and sum scalar widths for each one -- measured 5.5 ms over
    /// 8660 characters, four times the cost of every accessibility message in the read put
    /// together. In bulk it is 0.2 ms.
    ///
    /// A CRLF buffer leaves the carriage return at the end of each piece. It counts towards the
    /// offsets, because a range has to name real code units, and it is not part of the text.
    private static func lines(of window: String) -> [Line] {
        var lines: [Line] = []
        var start = 0
        for piece in window.components(separatedBy: "\n") {
            let units = piece.utf16.count
            let text = piece.hasSuffix("\r") ? String(piece.dropLast()) : piece
            lines.append(Line(text: text, start: start, contentEnd: start + text.utf16.count))
            start += units + 1
        }
        // A box drawn around the output hides everything inside it -- `│ ```mermaid` opens no fence
        // -- so the borders come off before anything is looked for. The offsets do not move with
        // the text: they name where the row is in the buffer, which is what puts the outline on
        // screen, and a row is in the same place whether or not it has a border down its side.
        guard let stripped = BoxGutter.strip(lines.map(\.text)) else { return lines }
        return zip(lines, stripped).map { Line(text: $1, start: $0.start, contentEnd: $0.contentEnd) }
    }
}
