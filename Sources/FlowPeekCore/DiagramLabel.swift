import Foundation

/// A name for a diagram, taken from the diagram itself.
///
/// The history needs one row per diagram that the person who made it can recognise a week later.
/// What the routes hand over is the name of the route -- "Copied Diagram", the same three words on
/// every row -- so the list has to read the source instead. Nothing here is translated: the words
/// it returns are the user's own, and the one case where it would have to invent language of its
/// own is exactly the case where it answers `nil` and lets the caller keep its generic title.
///
/// Deliberately conservative. A line that does not obviously carry a label is skipped rather than
/// guessed at, because a wrong name is worse than a plain one: it sends the reader to the wrong
/// diagram.
public enum DiagramLabel {
    /// How many labels are strung together. Three is enough to tell two flowcharts apart and short
    /// enough to stay inside a menu row.
    private static let fragmentLimit = 3
    /// Per-label and whole-line caps. A node whose text is a paragraph must not push the menu to the
    /// width of the screen.
    private static let fragmentLength = 24
    private static let totalLength = 48

    /// The name to show, or nil when the source says nothing worth reading.
    public static func describe(_ source: String) -> String? {
        let lines = source.components(separatedBy: .newlines)
        let body = lines[strippingFrontMatter(lines)...]
        // A `title:` in the front matter is the author saying what this is. Nothing beats it.
        if let declared = frontMatterTitle(lines) { return clean(declared) }
        // `title Quarterly Revenue` is the same statement in the body, and it is how pie, gantt,
        // journey, timeline and the xy chart all name themselves.
        for line in body {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("%%") else { continue }
            guard let rest = titleStatement(trimmed) else { continue }
            if let cleaned = clean(rest) { return cleaned }
        }

        var fragments: [String] = []
        for line in body {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("%%") else { continue }
            for fragment in labels(in: trimmed) where !fragments.contains(fragment) {
                fragments.append(fragment)
                if fragments.count == fragmentLimit { return join(fragments) }
            }
        }
        return fragments.isEmpty ? nil : join(fragments)
    }

    /// The index the body starts at: past a `---` front-matter block when there is one, 0 otherwise.
    private static func strippingFrontMatter(_ lines: [String]) -> Int {
        guard let first = lines.first?.trimmingCharacters(in: .whitespaces), first == "---" else { return 0 }
        guard let close = lines.dropFirst().firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "---"
        }) else { return 0 }
        return close + 1
    }

    private static func frontMatterTitle(_ lines: [String]) -> String? {
        let end = strippingFrontMatter(lines)
        guard end > 0 else { return nil }
        for line in lines[0..<end] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.lowercased().hasPrefix("title:") else { continue }
            return String(trimmed.dropFirst("title:".count))
        }
        return nil
    }

    /// `title Something`, and `pie title Something` -- pie, gantt, journey, the xy chart and the
    /// quadrant chart all write the statement after their own keyword. Not `titleCase`, which is a
    /// node, and not a bare `title`, which names nothing.
    private static func titleStatement(_ line: String) -> String? {
        var rest = Substring(line)
        for attempt in 0..<2 {
            if let found = keyword("title", at: rest) { return String(found) }
            // Step over one leading word and try again, but no further: `title` deeper into a line
            // is a word in a sentence, not a statement.
            guard attempt == 0, let space = rest.firstIndex(where: { $0 == " " || $0 == "\t" }) else { return nil }
            rest = rest[space...].drop(while: { $0 == " " || $0 == "\t" })
        }
        return nil
    }

    /// What follows `word` when the text opens with it and it stands on its own.
    private static func keyword(_ word: String, at text: Substring) -> Substring? {
        guard text.lowercased().hasPrefix(word) else { return nil }
        let rest = text.dropFirst(word.count)
        guard let first = rest.first, first == " " || first == "\t" || first == ":" else { return nil }
        return rest.dropFirst()
    }

    /// The labels a single line carries, in the order they are written.
    ///
    /// An edge splits the line first, and each side is then read for its own words: `A[Collect] -->
    /// B` is two labels, "Collect" and "B", and taking only the bracketed one would lose half the
    /// edge. A line with no edge is read whole, which is what `root((Big Idea))` needs. Anything
    /// with neither -- `participant Alice as A. Smith`, a `classDef`, a bare `sequenceDiagram` --
    /// yields nothing, and that is what keeps mermaid\'s own vocabulary out of the name.
    private static func labels(in line: String) -> [String] {
        guard let pieces = operandPieces(in: line) else { return bracketedLabels(in: line) }
        return pieces.compactMap { piece in
            let named = messageStripped(piece)
            return bracketedLabels(in: named).first ?? clean(cardinalityStripped(named))
        }
    }

    private static let openers: [Character: Character] = ["[": "]", "(": ")", "{": "}", "\"": "\""]

    private static func bracketedLabels(in line: String) -> [String] {
        var found: [String] = []
        let characters = Array(line)
        var index = 0
        while index < characters.count {
            guard let closer = openers[characters[index]] else { index += 1; continue }
            // Innermost first: `A[[Sub]]` and `root((Big))` both wrap the words twice, and the text
            // is what sits inside the last opener before the first closer.
            var start = index
            while start + 1 < characters.count, openers[characters[start + 1]] != nil { start += 1 }
            guard let end = characters[(start + 1)...].firstIndex(of: closer) else { break }
            if let cleaned = clean(String(characters[(start + 1)..<end])), !found.contains(cleaned) {
                found.append(cleaned)
            }
            index = end + 1
        }
        return found
    }

    /// The characters mermaid draws its edges from. Two or more in a row is an operator: `-->`,
    /// `->>`, `-.->`, `==>`, `---`, `<-->`, `..>`, `~~~`, `||--` and the rest all fall out of this
    /// without a table of every arrow in the language.
    private static let edgeCharacters = Set("-=.<>|~")

    /// The sides of the edges on this line, or nil when the line holds no edge at all.
    private static func operandPieces(in line: String) -> [String]? {
        var pieces: [String] = []
        var current = ""
        var run = ""
        for character in line {
            if edgeCharacters.contains(character) {
                run.append(character)
                continue
            }
            if run.count >= 2 {
                pieces.append(current)
                current = ""
            } else {
                current += run
            }
            run = ""
            current.append(character)
        }
        if run.count >= 2 {
            pieces.append(current)
            current = ""
        } else {
            current += run
        }
        pieces.append(current)
        // One piece means no operator was ever found, so the line is a statement rather than an
        // edge and has no sides to read.
        return pieces.count > 1 ? pieces : nil
    }

    /// Drops the crow\'s foot an entity line hangs on its operator: `o{ ORDER` is the ORDER entity,
    /// and `||--o{` is where the operator really ended. Only ever removes a cardinality letter that
    /// is holding hands with a brace or a pipe, so `other` keeps its `o`.
    private static func cardinalityStripped(_ piece: String) -> String {
        var text = piece
        for pattern in ["^\\s*[oxOX]?[|{}]+", "[|{}]+[oxOX]?\\s*$"] {
            if let found = text.range(of: pattern, options: .regularExpression) {
                text.removeSubrange(found)
            }
        }
        return text
    }

    /// `Bob: Hello there` is a message sent to Bob. The name is the label; the message is not.
    private static func messageStripped(_ piece: String) -> String {
        guard let colon = piece.firstIndex(of: ":") else { return piece }
        return String(piece[piece.startIndex..<colon])
    }

    /// Trims the punctuation that holds a diagram together but says nothing: brackets, quotes,
    /// pipes and stray whitespace. Letters are never trimmed -- an earlier version dropped a
    /// leading `o` to deal with `o{` on an entity line and turned `other` into `ther`.
    private static func clean(_ raw: some StringProtocol) -> String? {
        let stripped = raw.trimmingCharacters(in: CharacterSet(charactersIn: " \t[](){}<>\"'|*+/\\"))
        // Collapse newlines and runs of spaces: a node label may be written over two lines with a
        // `<br/>`, and a menu row is one line whatever the diagram does.
        let collapsed = stripped
            .replacingOccurrences(of: "<br/>", with: " ")
            .replacingOccurrences(of: "<br>", with: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return truncate(collapsed, to: fragmentLength)
    }

    private static func join(_ fragments: [String]) -> String {
        truncate(fragments.joined(separator: " → "), to: totalLength)
    }

    private static func truncate(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        return text.prefix(limit - 1).trimmingCharacters(in: .whitespaces) + "…"
    }
}
