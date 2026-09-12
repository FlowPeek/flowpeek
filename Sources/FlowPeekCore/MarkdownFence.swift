import Foundation

/// A fence delimiter on one line of text.
///
/// Shared by the caret slicer and the terminal scanner. Both have to agree on what opens a block
/// and what closes it -- the caret slicer to find the block the cursor is in, the terminal scanner
/// to find every block on screen -- and two copies of these rules would drift the first time one
/// of them learned about a new info string.
enum MarkdownFence {
    struct Open {
        let marker: Character
        /// Whether the fence's info string leaves room for a diagram. An untagged fence does: a
        /// diagram pasted into a plain block is ordinary, and the detector's confidence gate is
        /// what turns down a block of shell script.
        let mayHoldMermaid: Bool
    }

    /// Indentation is tolerated: a fenced block inside a list item is indented and is still a
    /// fenced block.
    static func open(_ line: String) -> Open? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let marker = trimmed.first, marker == "`" || marker == "~" else { return nil }
        let run = trimmed.prefix { $0 == marker }
        guard run.count >= 3 else { return nil }
        let info = trimmed.dropFirst(run.count)
            .trimmingCharacters(in: .whitespaces)
            .prefix { !$0.isWhitespace }
            .lowercased()
        return Open(marker: marker, mayHoldMermaid: info.isEmpty || info == "mermaid" || info == "mmd")
    }

    static func closes(_ line: String, marker: Character) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count >= 3 && trimmed.allSatisfy { $0 == marker }
    }
}

/// Pulling fenced Mermaid out of a piece of markdown.
///
/// Separate from `MarkdownFence` above, which answers about one line at a time for a scanner walking
/// a terminal buffer. This answers about a whole document, which is the shape a coding agent's own
/// record of what it wrote arrives in.
public enum MermaidFences {
    /// The most fences looked at in one document, so a pathological line cannot be walked forever.
    public static let maximumBlocks = 64

    /// The one candidate that is unmistakably the same diagram as `recovered`, or nil.
    ///
    /// Compared with every space removed, because whitespace is exactly what the screen loses: a
    /// program that lays out its own output eats the space it breaks a line at and prints a margin
    /// the text never had. Everything else -- identifiers, brackets, quotes, arrows -- survives the
    /// screen intact, so two sources that agree once whitespace is gone are the same source. Two
    /// candidates that both agree are not an answer, and a very short one could agree by accident,
    /// so both refuse.
    public static func matching(_ recovered: String, in candidates: [String]) -> String? {
        let key = squashed(recovered)
        guard key.count > 16 else { return nil }
        var found: String?
        for candidate in candidates where squashed(candidate) == key {
            guard found == nil else { return nil }
            found = candidate
        }
        return found
    }

    private static func squashed(_ text: String) -> String { text.filter { !$0.isWhitespace } }

    /// Every fenced Mermaid block in `markdown`, in the order they appear, fences removed.
    ///
    /// Deliberately strict about the opener: an info string of exactly `mermaid`, nothing else. A
    /// block labelled anything else is somebody's code sample, and a block labelled nothing at all
    /// is far more often a shell transcript than a diagram.
    public static func blocks(in markdown: String) -> [String] {
        guard markdown.contains("```") else { return [] }
        var blocks: [String] = []
        var body: [String]?
        var marker: Character = "`"
        for line in markdown.components(separatedBy: "\n") {
            if body == nil {
                guard let open = MarkdownFence.open(line), open.mayHoldMermaid,
                      line.trimmingCharacters(in: .whitespaces)
                          .drop(while: { $0 == open.marker })
                          .trimmingCharacters(in: .whitespaces)
                          .lowercased() == "mermaid"
                else { continue }
                marker = open.marker
                body = []
                continue
            }
            if MarkdownFence.closes(line, marker: marker) {
                if let text = body?.joined(separator: "\n"),
                   !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    blocks.append(text)
                }
                body = nil
                if blocks.count >= maximumBlocks { break }
                continue
            }
            body?.append(line)
        }
        return blocks
    }
}
