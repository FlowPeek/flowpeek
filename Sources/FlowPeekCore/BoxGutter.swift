import Foundation

/// The vertical borders of a box drawn around terminal output.
///
/// A terminal user interface that frames what it prints -- Claude Code's prompt box, `gh`'s
/// summaries, anything built on a box-drawing widget -- puts a border and a space in front of every
/// row inside it. That is enough to hide a diagram completely: the row reads `│ ```mermaid` rather
/// than ` ```mermaid`, so no fence opens, no declaration is recognised, and a screen with a diagram
/// on it answers with nothing. Measured against a boxed fence in Ghostty: text was read, and zero
/// blocks came out of it.
///
/// Shared by the terminal scanner, which has to see through the border before it can find anything,
/// and by the detector, which has to hand mermaid source without borders down either side.
///
/// The three-row rule is the one the line-number gutter already uses, and for the same reason: one
/// line beginning with a pipe is content -- `|yes| B` is an edge label that got wrapped, and a
/// markdown table row is not a diagram either -- while three in a row with the same border
/// character is a frame.
enum BoxGutter {
    /// ASCII included. Plenty of programs still frame their output with pipes, and the run length
    /// is what keeps that from touching real content.
    static let borders: Set<Character> = ["│", "┃", "|"]

    /// Consecutive bordered rows needed before a border is believed to be one.
    static let minimumRun = 3

    /// The same lines with any box's borders removed, or nil when none of them is boxed.
    ///
    /// Same count out as in, and only qualifying runs are touched: a box surrounds part of a
    /// terminal's screen, not all of it, and the rows above and below it are somebody's output.
    static func strip(_ lines: [String]) -> [String]? {
        var stripped = lines
        var changed = false
        var index = 0
        while index < lines.count {
            guard let border = leadingBorder(lines[index]) else {
                index += 1
                continue
            }
            var end = index
            while end + 1 < lines.count, leadingBorder(lines[end + 1]) == border { end += 1 }
            if end - index + 1 >= minimumRun {
                for row in index...end { stripped[row] = withoutBorders(lines[row], border) }
                changed = true
            }
            index = end + 1
        }
        return changed ? stripped : nil
    }

    /// A box's top and bottom rows are corners and dashes, so they are not part of the run and do
    /// not have to be: the rows that hide the diagram are the ones down its sides.
    private static func leadingBorder(_ line: String) -> Character? {
        guard let first = line.drop(while: { $0 == " " || $0 == "\t" }).first, borders.contains(first) else {
            return nil
        }
        return first
    }

    private static func withoutBorders(_ line: String, _ border: Character) -> String {
        var slice = Substring(line).drop { $0 == " " || $0 == "\t" }
        guard slice.first == border else { return line }
        slice = slice.dropFirst()
        // One space, not all of them: what is left is the row's indentation inside the box, and a
        // diagram's own indentation is part of its source.
        if slice.first == " " { slice = slice.dropFirst() }
        var tail = slice
        while let last = tail.last, last == " " || last == "\t" { tail = tail.dropLast() }
        guard tail.last == border else { return String(slice) }
        tail = tail.dropLast()
        while let last = tail.last, last == " " || last == "\t" { tail = tail.dropLast() }
        return String(tail)
    }
}
