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
