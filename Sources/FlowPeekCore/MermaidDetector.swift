import Foundation

public struct MermaidDetection: Equatable, Sendable {
    public enum Confidence: Int, Comparable, Sendable {
        case none = 0, weak = 1, likely = 2, certain = 3

        public static func < (lhs: Confidence, rhs: Confidence) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public let confidence: Confidence
    public let diagramKeyword: String?
    public let expectedType: String?
    public let extractedSource: String
    public let droppedPrefixLines: Int
}

/// Recognizes Mermaid inside a raw text selection: normalizes it, lifts it out of code fences and
/// editor chrome, then matches the first diagram starter against mermaid 11.17.2's own registry order.
public enum MermaidDetector {
    /// Lines examined by the starter scan once comments, directives and front matter are skipped.
    public static let starterWindow = 12

    /// The most raw text worth looking at, in UTF-16 code units. Detection is linear in the input
    /// and runs on the main actor: 4.4 MB measured 248 ms debug and 182 ms release, of which
    /// normalisation alone was 175 ms. Select-all in a log file or a long chat transcript is an
    /// ordinary thing to do, and the answer for anything this size can only ever be "too large" —
    /// `MermaidSource.maximumCharacters` is 100_000 — so the work is not done at all. 1 MB (~55 ms)
    /// leaves the real case, a big page with one diagram in it, working.
    public static let maximumInputCharacters = 1_000_000

    public static func detect(_ raw: String) -> MermaidDetection {
        guard raw.utf16.count <= maximumInputCharacters else {
            return MermaidDetection(
                confidence: .none,
                diagramKeyword: nil,
                expectedType: nil,
                extractedSource: "",
                droppedPrefixLines: 0
            )
        }
        var lines = normalize(raw).components(separatedBy: "\n")
        var dropped = dropLeadingLabels(&lines)
        var noise = false

        let fence = extractFence(&lines)
        dropped += fence.dropped
        noise = noise || fence.noise

        let chrome = stripChrome(&lines)
        dropped += chrome.dropped
        noise = noise || chrome.changed

        truncateAtResidualFence(&lines)

        let source = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

        guard let hit = scan(lines) else {
            return MermaidDetection(
                confidence: .none,
                diagramKeyword: nil,
                expectedType: nil,
                extractedSource: source,
                droppedPrefixLines: dropped
            )
        }

        // Hand the renderer the diagram only. mermaid reads from the first line, so prose that the
        // window scanned past would make it report an unknown diagram type.
        //
        // It also reads to the *last* line, so anything that gathers text from a region rather than
        // from one block can hand over the same diagram twice, or two diagrams in a row. A repeat of
        // this diagram's own starter is the boundary: a body never restarts with its own type
        // keyword, so cutting there yields exactly the one diagram that was pointed at.
        let end = lines.indices
            .dropFirst(hit.lineIndex + 1)
            .first { match(trimmed(lines[$0]))?.id == hit.id } ?? lines.count
        let diagram = lines[hit.sourceStartIndex..<end]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let body = lines[(hit.lineIndex + 1)..<end].filter { !trimmed($0).isEmpty }
        let confidence: MermaidDetection.Confidence
        if body.isEmpty {
            confidence = .weak
        } else if hit.survivingIndex == 0, !noise, body.contains(where: hasEdgeToken) {
            confidence = .certain
        } else {
            confidence = .likely
        }

        return MermaidDetection(
            confidence: confidence,
            diagramKeyword: hit.keyword,
            expectedType: hit.id,
            extractedSource: diagram,
            droppedPrefixLines: dropped + hit.sourceStartIndex
        )
    }

    /// Convenience gate used by `AppState.receive`.
    public static func looksLikeMermaid(_ raw: String) -> Bool { detect(raw).confidence >= .likely }

    // MARK: - Stage 1, normalisation

    public static func normalize(_ raw: String) -> String {
        var scalars = String.UnicodeScalarView()
        var afterReturn = false
        for scalar in raw.unicodeScalars {
            switch scalar {
            case "\u{FEFF}", "\u{200B}", "\u{200C}", "\u{200D}":
                continue
            case "\u{00A0}", "\u{2000}"..."\u{200A}", "\u{202F}", "\u{205F}", "\u{3000}":
                scalars.append(" ")
                afterReturn = false
            case "\r":
                scalars.append("\n")
                afterReturn = true
            case "\n":
                if !afterReturn { scalars.append("\n") }
                afterReturn = false
            case "\u{2028}", "\u{2029}":
                scalars.append("\n")
                afterReturn = false
            default:
                scalars.append(scalar)
                afterReturn = false
            }
        }
        return String(scalars)
            .components(separatedBy: "\n")
            .map { line in
                var slice = Substring(line)
                while let last = slice.last, last == " " || last == "\t" { slice = slice.dropLast() }
                return String(slice)
            }
            .joined(separator: "\n")
    }

    // MARK: - Stage 2, fence extraction

    private static func dropLeadingLabels(_ lines: inout [String]) -> Int {
        var dropped = 0
        while let index = firstNonBlankIndex(lines) {
            let line = trimmed(lines[index])
            if line.lowercased() == "mermaid" {
                lines.removeSubrange(0...index)
                dropped += index + 1
                continue
            }
            if line == "---", !lines.dropFirst(index + 1).contains(where: { trimmed($0) == "---" }) {
                lines.removeSubrange(0...index)
                dropped += index + 1
            }
            break
        }
        return dropped
    }

    private struct FenceOutcome {
        var found = false
        var dropped = 0
        var noise = false
    }

    private static func extractFence(_ lines: inout [String]) -> FenceOutcome {
        var outcome = FenceOutcome()
        let start = firstNonBlankIndex(lines)
        var index = 0
        while index < lines.count {
            guard let open = parseFenceOpen(trimmed(lines[index])) else {
                index += 1
                continue
            }
            let close = closingFenceIndex(lines, after: index, marker: open.marker)
            guard open.isMermaid else {
                index = (close ?? lines.count - 1) + 1
                continue
            }
            let body = Array(lines[(index + 1)..<(close ?? lines.count)])
            let trailing = close.map { lines.dropFirst($0 + 1).contains { !trimmed($0).isEmpty } } ?? false
            outcome.found = true
            outcome.dropped = index + 1
            outcome.noise = index != start || close == nil || open.hasAttributes || trailing
            lines = body
            return outcome
        }
        return outcome
    }

    private struct FenceOpen {
        let marker: Character
        let length: Int
        let isMermaid: Bool
        let hasAttributes: Bool
    }

    private static func parseFenceOpen(_ line: String) -> FenceOpen? {
        guard let marker = line.first, marker == "`" || marker == "~" else { return nil }
        let run = line.prefix { $0 == marker }
        guard run.count >= 3 else { return nil }
        let rest = line.dropFirst(run.count).trimmingCharacters(in: .whitespaces)
        let info = rest.prefix { !$0.isWhitespace }
        let clean = rest.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
        let name = info.lowercased()
        return FenceOpen(
            marker: marker,
            length: run.count,
            isMermaid: name.isEmpty || name == "mermaid" || name == "mmd",
            hasAttributes: !clean
        )
    }

    private static func closingFenceIndex(_ lines: [String], after index: Int, marker: Character) -> Int? {
        lines.indices.dropFirst(index + 1).first { position in
            let line = trimmed(lines[position])
            return line.count >= 3 && line.allSatisfy { $0 == marker }
        }
    }

    private static func truncateAtResidualFence(_ lines: inout [String]) {
        if let index = lines.firstIndex(where: { line in
            let text = trimmed(line)
            return text.hasPrefix("```") || text.hasPrefix("~~~")
        }) {
            lines = Array(lines.prefix(index))
        }
    }

    // MARK: - Stage 3, chrome and gutter stripping

    private static let chromeLabels: Set<String> = [
        "copy", "copy code", "복사", "コピー", "复制", "kopieren", "copier",
        "share", "edit", "run", "preview", "raw", "blame", "wrap lines",
        // Trailing affordances a documentation page puts under a runnable snippet. Reading a block
        // by its enclosing element picks these up, and mermaid then fails on them.
        "run ▶", "▶", "mermaid", "|", "⌘ + enter", "ctrl + enter", "open editor", "try it"
    ]

    /// Chrome also appears *after* a snippet, and it only became reachable once a block could be
    /// read by its enclosing element rather than by the exact line under the pointer.
    private static func dropTrailingChrome(_ lines: inout [String]) {
        while let last = lines.last {
            let trimmed = last.trimmingCharacters(in: .whitespaces)
            guard trimmed.isEmpty || chromeLabels.contains(trimmed.lowercased()) else { break }
            lines.removeLast()
        }
    }

    private struct ChromeOutcome {
        var dropped = 0
        var changed = false
    }

    private static func stripChrome(_ lines: inout [String]) -> ChromeOutcome {
        var outcome = ChromeOutcome()
        dropLeadingChrome(&lines, into: &outcome)
        // Deliberately does not mark the outcome as changed: what follows the diagram says nothing
        // about how confidently its opening line was recognised, and counting it downgraded a
        // clean block with a trailing "Copy" -- or merely a trailing blank line -- from certain.
        dropTrailingChrome(&lines)
        if stripGutter(&lines) { outcome.changed = true }
        dropLeadingChrome(&lines, into: &outcome)
        return outcome
    }

    private static func dropLeadingChrome(_ lines: inout [String], into outcome: inout ChromeOutcome) {
        while let index = firstNonBlankIndex(lines) {
            let line = trimmed(lines[index])
            if chromeLabels.contains(line.lowercased()) || isHeading(line) || isShellPrompt(line) {
                lines.removeSubrange(0...index)
                outcome.dropped += index + 1
                outcome.changed = true
                continue
            }
            if line.hasPrefix(">") {
                var rest = Substring(line).dropFirst()
                if rest.first == " " { rest = rest.dropFirst() }
                lines[index] = String(rest)
                outcome.changed = true
                continue
            }
            break
        }
    }

    private static func isHeading(_ line: String) -> Bool {
        let hashes = line.prefix { $0 == "#" }
        guard (1...6).contains(hashes.count) else { return false }
        return line.dropFirst(hashes.count).first.map { $0 == " " || $0 == "\t" } ?? false
    }

    private static func isShellPrompt(_ line: String) -> Bool {
        var slice = Substring(line).drop {
            $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." || $0 == "@" || $0 == "~" || $0 == "/" || $0 == "-"
        }
        guard let prompt = slice.first, "$%#>".contains(prompt) else { return false }
        slice = slice.dropFirst()
        guard let space = slice.first, space == " " || space == "\t" else { return false }
        return slice.drop { $0 == " " || $0 == "\t" }.first != nil
    }

    /// A uniform line-number gutter needs at least three consecutive leading rows with increasing
    /// numbers; a single numbered line is real content (`1 --> 2`) and must survive untouched.
    private static func stripGutter(_ lines: inout [String]) -> Bool {
        var run: [(index: Int, number: Int, rest: String)] = []
        for (index, line) in lines.enumerated() {
            if trimmed(line).isEmpty, run.isEmpty { continue }
            guard let parsed = parseGutter(line) else { break }
            if let previous = run.last, parsed.number <= previous.number { break }
            run.append((index, parsed.number, parsed.rest))
        }
        guard run.count >= 3 else { return false }
        for entry in run { lines[entry.index] = entry.rest }
        for index in lines.indices where index > run[run.count - 1].index {
            if let parsed = parseGutter(lines[index]) { lines[index] = parsed.rest }
        }
        return true
    }

    private static func parseGutter(_ line: String) -> (number: Int, rest: String)? {
        var slice = Substring(line).drop { $0 == " " || $0 == "\t" }
        let digits = slice.prefix { $0.isASCII && $0.isNumber }
        guard let number = Int(digits) else { return nil }
        slice = slice.dropFirst(digits.count)
        var piped = slice.drop { $0 == " " || $0 == "\t" }
        if piped.first == "|" {
            piped = piped.dropFirst().drop { $0 == " " || $0 == "\t" }
            return (number, String(piped))
        }
        var spaces = 0
        while let next = slice.first, next == " " || next == "\t", spaces < 8 {
            slice = slice.dropFirst()
            spaces += 1
        }
        guard spaces >= 1 else { return nil }
        return (number, String(slice))
    }

    // MARK: - Stage 4, starter scan

    private struct Hit {
        let id: String
        let keyword: String
        let lineIndex: Int
        let survivingIndex: Int
        /// Where the diagram itself begins. Front matter, `%%{init}%%` directives and `%%` comments
        /// ahead of the starter belong to the source and are kept; prose ahead of them does not and
        /// is dropped, because mermaid reads from the very first line and would fail on it.
        let sourceStartIndex: Int
    }

    /// Arrow-shaped tokens only: a bare `:` corroborates a diagram body but is far too common to
    /// promote a match to `.certain`.
    private static let edgeTokens = ["-.->", "-->>", "-->", "->>", "==>", "<|--", "||--", "|>", "---"]

    private static func hasEdgeToken(_ line: String) -> Bool {
        edgeTokens.contains { line.contains($0) }
    }

    private static func scan(_ lines: [String]) -> Hit? {
        var index = 0
        var frontMatterStart: Int?
        if let first = firstNonBlankIndex(lines), trimmed(lines[first]) == "---",
           let close = lines.indices.dropFirst(first + 1).first(where: { trimmed(lines[$0]) == "---" }) {
            frontMatterStart = first
            index = close + 1
        }
        var surviving = 0
        var insideDirective = false
        // The start of the run of comments and directives immediately before the starter. Prose
        // resets it, so only lines that really belong to the diagram survive ahead of the keyword.
        var preamble: Int? = frontMatterStart
        while index < lines.count, surviving < starterWindow {
            let line = trimmed(lines[index])
            defer { index += 1 }
            if line.isEmpty { continue }
            if insideDirective {
                if line.contains("}%%") { insideDirective = false }
                continue
            }
            if line.hasPrefix("%%{") {
                insideDirective = !line.contains("}%%")
                if preamble == nil { preamble = index }
                continue
            }
            if line.hasPrefix("%%") {
                if preamble == nil { preamble = index }
                continue
            }
            if let starter = match(line) {
                return Hit(
                    id: starter.id,
                    keyword: starter.keyword,
                    lineIndex: index,
                    survivingIndex: surviving,
                    sourceStartIndex: preamble ?? index
                )
            }
            surviving += 1
            // Prose: nothing before this line, comments included, can belong to the diagram.
            preamble = nil
        }
        return nil
    }

    // MARK: - Stage 5, the detector table (mermaid 11.17.2 registration order)

    private struct Starter: Sendable {
        enum Boundary: Sendable { case none, word, cynefin }

        let id: String
        let prefixes: [String]
        let caseSensitive: Bool
        let boundary: Boundary

        init(_ id: String, _ prefixes: [String], caseSensitive: Bool = true, boundary: Boundary = .none) {
            self.id = id
            self.prefixes = prefixes
            self.caseSensitive = caseSensitive
            self.boundary = boundary
        }
    }

    private static let table: [Starter] = [
        Starter("flowchart-elk", ["flowchart-elk"]),
        Starter("mindmap", ["mindmap"]),
        Starter("architecture", ["architecture"]),
        Starter("c4", ["C4Context", "C4Container", "C4Component", "C4Dynamic", "C4Deployment"]),
        Starter("kanban", ["kanban"]),
        Starter("classDiagram", ["classDiagram"]),
        Starter("er", ["erDiagram"]),
        Starter("gantt", ["gantt"]),
        Starter("info", ["info"]),
        Starter("pie", ["pie"]),
        Starter("requirement", ["requirement"]),
        Starter("sequence", ["sequenceDiagram"]),
        Starter("swimlane", ["swimlane-beta"], boundary: .word),
        Starter("flowchart-v2", ["flowchart", "graph"]),
        Starter("timeline", ["timeline"]),
        Starter("gitGraph", ["gitGraph"]),
        Starter("stateDiagram", ["stateDiagram"]),
        Starter("journey", ["journey"]),
        Starter("quadrantChart", ["quadrantChart"]),
        Starter("sankey", ["sankey"]),
        Starter("packet", ["packet"]),
        Starter("xychart", ["xychart"]),
        Starter("block", ["block"]),
        Starter("eventmodeling", ["eventmodeling"]),
        Starter("treeView", ["treeView-beta"]),
        Starter("radar", ["radar-beta"]),
        Starter("ishikawa", ["ishikawa"], caseSensitive: false, boundary: .word),
        Starter("treemap", ["treemap"]),
        Starter("railroad", ["railroad-beta"], caseSensitive: false),
        Starter("railroadEbnf", ["railroad-ebnf-beta"], caseSensitive: false),
        Starter("railroadAbnf", ["railroad-abnf-beta"], caseSensitive: false),
        Starter("railroadPeg", ["railroad-peg-beta"], caseSensitive: false),
        Starter("venn", ["venn-beta"]),
        Starter("wardley", ["wardley-beta"], caseSensitive: false),
        Starter("cynefin", ["cynefin-beta"], boundary: .cynefin)
    ]

    /// Every detector id this table can produce, in registration order. `Tests/Fixtures/detector_corpus.json`
    /// must carry at least one row per id; `Scripts/conformance.mjs` runs the same corpus through the
    /// vendored bundle's own `detectType()`.
    public static var tableIdentifiers: [String] { table.map(\.id) }

    private static func match(_ line: String) -> (id: String, keyword: String)? {
        for starter in table {
            for prefix in starter.prefixes {
                let head = String(line.prefix(prefix.count))
                guard head.count == prefix.count else { continue }
                let matches = starter.caseSensitive ? head == prefix : head.lowercased() == prefix.lowercased()
                guard matches else { continue }
                let next = line.dropFirst(prefix.count).first
                switch starter.boundary {
                case .none: break
                case .word:
                    if let next, next.isLetter || next.isNumber || next == "_" { continue }
                case .cynefin:
                    if let next, !next.isWhitespace, next != ":" { continue }
                }
                return (starter.id, head)
            }
        }
        return nil
    }

    // MARK: - Helpers

    private static func trimmed(_ line: String) -> String {
        line.trimmingCharacters(in: .whitespaces)
    }

    private static func firstNonBlankIndex(_ lines: [String]) -> Int? {
        lines.firstIndex { !trimmed($0).isEmpty }
    }
}
