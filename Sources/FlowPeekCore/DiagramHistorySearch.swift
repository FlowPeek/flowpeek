import Foundation

/// Anything that can say how close two pieces of text are in meaning.
///
/// A protocol rather than a call into a framework, so the ranking below can be checked without one:
/// the interesting part of a search is which rows come back and in what order, and that is decided
/// here rather than by whoever computes the vectors.
public protocol DiagramSemanticIndex: Sendable {
    /// A distance from 0 (the same meaning) upward, or nil when there is no model for this text --
    /// which is the ordinary answer for a language the on-device embeddings do not cover.
    func distance(_ query: String, _ candidate: String) -> Double?
}

/// Finding a diagram again, by its words or by what it is about.
///
/// Two passes, kept apart on purpose. A literal match is an answer: `getUserToken` means nothing to
/// an embedding and everything to the person who wrote it, and a row that contains what was typed
/// is a row that was found. Meaning is a *suggestion*, and the difference is not stylistic --
/// measured against `NLEmbedding`'s own sentence distances over Mermaid diagrams:
///
///     "client server exchange" -> the HTTP sequence diagram   0.773   (right)
///     "database schema"        -> the HTTP sequence diagram   0.891   (wrong, and nearer than
///                                                                      several right answers)
///     "web request"            -> an editorial flowchart      0.994   (wrong, and nearer than the
///                                                                      HTTP diagram at 1.010)
///
/// There is no cut between those numbers, so a threshold pretending to be one would answer
/// "database schema" with an HTTP diagram and look certain about it. What the model can do is order
/// candidates: the nearest row is the right one more often than not. So meaning is used only when
/// nothing matched literally, only a few rows deep, and the caller is expected to say out loud that
/// these are guesses.
public enum DiagramHistorySearch {
    /// How many guesses are worth making. Three: enough that a good one is likely to be among them,
    /// few enough that a shelf of wrong answers does not look like a result.
    public static let relatedLimit = 3
    /// Past this the model itself is saying these two texts have nothing to do with each other.
    /// Not a precision boundary -- see above -- just a floor under the guessing.
    public static let farthest = 1.25

    public struct Results: Equatable, Sendable {
        /// Rows that contain what was typed. Answers.
        public let matched: [DiagramHistoryEntry]
        /// Rows that do not, offered nearest-first when nothing matched. Guesses.
        public let related: [DiagramHistoryEntry]

        public var isEmpty: Bool { matched.isEmpty && related.isEmpty }
    }

    public static func search(
        _ entries: [DiagramHistoryEntry],
        query: String,
        index: (any DiagramSemanticIndex)? = nil
    ) -> Results {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // An empty query is not a search: everything comes back, in the order the history has.
        guard !needle.isEmpty else { return Results(matched: entries, related: []) }

        var matched: [DiagramHistoryEntry] = []
        var rest: [DiagramHistoryEntry] = []
        for entry in entries {
            if matches(entry, needle) { matched.append(entry) } else { rest.append(entry) }
        }
        // Guesses are only ever offered instead of answers, never alongside them: a row that
        // contains the word is what was asked for, and padding it with near-misses buries it.
        guard matched.isEmpty, let index else { return Results(matched: matched, related: []) }

        let related = rest
            .compactMap { entry -> (entry: DiagramHistoryEntry, distance: Double)? in
                guard let distance = index.distance(needle, haystack(entry)),
                      distance <= farthest else { return nil }
                return (entry, distance)
            }
            .sorted { $0.distance < $1.distance }
            .prefix(relatedLimit)
            .map(\.entry)
        return Results(matched: [], related: Array(related))
    }

    /// Case- and diacritic-insensitive, over both the name and the diagram itself: the word being
    /// looked for is as likely to be a node in the source as it is to be in the title FlowPeek
    /// derived from it.
    private static func matches(_ entry: DiagramHistoryEntry, _ needle: String) -> Bool {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return entry.title.range(of: needle, options: options) != nil
            || entry.source.range(of: needle, options: options) != nil
    }

    /// The words a person wrote, without the syntax holding them together.
    ///
    /// Measured: embedding the raw source put the right answer at 0.873 where embedding the words
    /// alone put it at 0.773 -- arrows, `sequenceDiagram` and a hundred braces are a large part of
    /// what a short diagram is made of, and they mean the same thing in every diagram.
    static func haystack(_ entry: DiagramHistoryEntry) -> String {
        var seen = Set<String>()
        var words: [String] = []
        for token in entry.source.prefix(2000).split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            let word = String(token)
            guard !Self.syntax.contains(word), seen.insert(word.lowercased()).inserted else { continue }
            words.append(word)
            if words.count == 60 { break }
        }
        return ([entry.title] + words).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Mermaid's own vocabulary, which every diagram of a kind shares and which therefore says
    /// nothing about any one of them. Not exhaustive and does not need to be: a keyword left in
    /// dilutes the meaning a little, it does not break it.
    private static let syntax: Set<String> = [
        "flowchart", "graph", "sequenceDiagram", "classDiagram", "stateDiagram", "erDiagram",
        "journey", "gantt", "pie", "mindmap", "timeline", "gitGraph", "quadrantChart", "block",
        "architecture", "kanban", "requirement", "sankey", "xychart", "treemap", "radar",
        "title", "participant", "actor", "note", "over", "end", "subgraph", "direction",
        "section", "class", "state", "click", "style", "classDef", "linkStyle", "accTitle",
        "accDescr", "dateFormat", "axisFormat", "config", "theme", "LR", "RL", "TD", "TB", "BT",
    ]
}
