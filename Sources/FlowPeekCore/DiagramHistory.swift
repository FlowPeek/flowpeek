import Foundation

/// Where a remembered diagram came from. Kept with the entry because "I made this with AI" and "I
/// copied this from a pull request" are the two facts that tell two rows with similar titles apart
/// a week later.
public enum DiagramOrigin: String, Codable, Sendable, CaseIterable {
    case ai
    case selection
    case clipboard
    case ambient
    /// An origin a later version of FlowPeek wrote and this one has no name for. Kept as a case
    /// rather than as a decoding failure: the diagram is still the user's work, and losing the row
    /// because we cannot label it is the worse of the two outcomes.
    case unknown

    public var titleKey: String.LocalizationValue {
        switch self {
        case .ai: "history.origin.ai"
        case .selection: "history.origin.selection"
        case .clipboard: "history.origin.clipboard"
        case .ambient: "history.origin.ambient"
        case .unknown: "history.origin.unknown"
        }
    }

    /// The same glyph the route wears elsewhere in the app, so a row is recognisable before it is
    /// read: the tutorial's lesson symbols, and the wand the AI window is titled with.
    public var symbol: String {
        switch self {
        case .ai: "wand.and.stars"
        case .selection: "hand.draw"
        case .clipboard: "doc.on.clipboard"
        case .ambient: "viewfinder"
        case .unknown: "clock"
        }
    }

    /// Every key this enum can ask the catalogue for, so the catalogue test can check all of them.
    public static let localizationKeys: [String] = allCases.map { "history.origin." + $0.rawValue }

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = DiagramOrigin(rawValue: raw) ?? .unknown
    }
}

/// One diagram the user made, kept so they can come back to it.
public struct DiagramHistoryEntry: Identifiable, Equatable, Sendable, Codable {
    public let id: UUID
    /// What the diagram was called when it was recorded. May be empty — a caller with nothing to
    /// call it is better served by a row with a fallback title than by no row.
    public var title: String
    /// The Mermaid itself, trimmed of trailing blank lines and nothing else. The user's own work:
    /// it is never logged, and it is what a preview is rebuilt from.
    public var source: String
    public var recordedAt: Date
    public var origin: DiagramOrigin

    public init(
        id: UUID = UUID(),
        title: String,
        source: String,
        recordedAt: Date = .now,
        origin: DiagramOrigin
    ) {
        self.id = id
        self.title = title
        self.source = source
        self.recordedAt = recordedAt
        self.origin = origin
    }

    /// The word the diagram opens with -- "flowchart", "erDiagram" -- shown as a tag the way the
    /// clipboard badge shows it. Read off the first significant line rather than through
    /// `MermaidDetector`, because a list draws every row at once and the detector is priced for one
    /// selection at a time.
    public var keyword: String? {
        guard let line = source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .lazy
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty })
        else { return nil }
        // Anchored on a letter: an arrow or a comment marker is punctuation the row would show as
        // a tag saying nothing.
        guard let first = line.first, first.isLetter else { return nil }
        let word = line.prefix(while: { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        guard word.count >= 2, word.count <= 24 else { return nil }
        return String(word)
    }

    /// The diagram this row stands for, ready for `PreviewCoordinator.openWindow(document:)`.
    ///
    /// Deliberately not asking the detector to recognise it again: this text was a diagram when it
    /// was recorded, and history is not the place to re-litigate that. What is still enforced is
    /// the size envelope the renderer can survive, so a hand-edited file cannot hand the engine
    /// something it will choke on.
    public func document(fallbackTitle: String) -> DiagramDocument? {
        guard let source = try? MermaidSource(rawValue: source, requireRecognizedDiagram: false) else { return nil }
        return DiagramDocument(title: title.isEmpty ? fallbackTitle : title, source: source)
    }

    /// Whether this is worth keeping at all. Applied to what comes off disk as well as to what is
    /// recorded, so a truncated or hand-edited row cannot survive as a blank line in the list.
    public var isUsable: Bool {
        !source.isEmpty && source.utf16.count <= MermaidSource.maximumCharacters
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case id, title, source, recordedAt, origin
    }

    /// Every field except the diagram itself has an answer for "it was not there". A file written
    /// by a later version, or edited by hand, loses a field rather than the whole history.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Normalised on the way in as well as on the way through `record`, so a row someone typed
        // into the file by hand is compared against the rest on the same terms -- and a row that is
        // only whitespace is recognisably nothing.
        source = DiagramHistory.normalize(try container.decode(String.self, forKey: .source))
        id = (try? container.decodeIfPresent(UUID.self, forKey: .id)).flatMap { $0 } ?? UUID()
        title = (try? container.decodeIfPresent(String.self, forKey: .title)).flatMap { $0 } ?? ""
        origin = (try? container.decodeIfPresent(DiagramOrigin.self, forKey: .origin)).flatMap { $0 } ?? .unknown
        // The far past rather than now: a row whose date we cannot read sorts to the bottom, where
        // an unknown age belongs, instead of jumping to the top of the list on every launch.
        recordedAt = (try? container.decodeIfPresent(Date.self, forKey: .recordedAt)).flatMap { $0 } ?? .distantPast
    }
}

/// The remembered diagrams: an ordered list, newest first, capped at a maximum the user sets.
///
/// Pure on purpose. The ordering, the cap and the rule that decides whether a recording is a new
/// diagram or another go at the last one are the parts that are easy to get subtly wrong and
/// impossible to see going wrong, so none of them needs a window, a disk or a clock to be checked.
public struct DiagramHistory: Equatable, Sendable {
    /// Enough to cover the last week or two of work without becoming a list nobody scrolls to the
    /// bottom of.
    public static let defaultLimit = 20
    /// Below five the list stops being a history; above a hundred it stops being scrollable, and
    /// the file behind it stops being something we are willing to parse at once.
    public static let limitRange = 5...100
    /// The step the Settings control moves in. A person choosing "about twenty" does not want to
    /// press a button fifteen times to get there.
    public static let limitStep = 5

    /// How long the newest entry stays "the diagram being worked on". Long enough to cover an
    /// editing session with pauses in it, short enough that picking the work back up tomorrow
    /// starts a new row rather than overwriting yesterday's.
    public static let revisionWindow: TimeInterval = 30 * 60
    /// How alike two sources have to be, line for line, to count as revisions of each other.
    /// A rewritten node or three lands far above this; two different diagrams of the same type
    /// share only their declaration line and land far below it.
    public static let revisionSimilarity = 0.5
    /// Lines read when measuring that likeness. Recording happens on the main actor, and the size
    /// limit alone would allow five thousand of them per comparison.
    static let comparedLines = 200

    public private(set) var entries: [DiagramHistoryEntry]
    public private(set) var limit: Int

    public init(entries: [DiagramHistoryEntry] = [], limit: Int = defaultLimit) {
        self.limit = Self.clamp(limit)
        // What comes in may be a hand-edited file: out of order, with the same diagram in it twice.
        // Sorted and folded here so everything downstream can assume newest-first and one row per
        // diagram.
        var seen = Set<String>()
        self.entries = entries
            .filter(\.isUsable)
            .sorted { $0.recordedAt > $1.recordedAt }
            .filter { seen.insert($0.source).inserted }
        trim()
    }

    public static func clamp(_ limit: Int) -> Int {
        min(max(limit, limitRange.lowerBound), limitRange.upperBound)
    }

    /// Lowering the maximum takes effect immediately, not at the next recording: the number in
    /// Settings is a promise about what is on disk, and a promise that waits for the next diagram
    /// is one the user has no way to tell has been kept.
    public mutating func setLimit(_ value: Int) {
        limit = Self.clamp(value)
        trim()
    }

    /// Remembers a diagram, or folds it into the row it is another go at.
    ///
    /// Two entries are the same thing when either:
    ///  * the Mermaid is identical, wherever in the list it already sits -- opening the same
    ///    diagram again is not a second diagram, it is the same one, freshly used; or
    ///  * it is a revision of the newest row: same origin, inside `revisionWindow`, and either the
    ///    same title or a source that is still mostly the same lines. This is what stops a diagram
    ///    edited five times from filling the list with five near-identical rows.
    ///
    /// Only the newest row is treated as revisable, because only one diagram is being worked on at
    /// a time; anything older is something the user came back to on purpose.
    ///
    /// Returns the entry as it now stands, or nil when there was nothing to remember.
    @discardableResult
    public mutating func record(
        title: String,
        source: String,
        origin: DiagramOrigin,
        at date: Date = .now,
        id: UUID = UUID()
    ) -> DiagramHistoryEntry? {
        let text = Self.normalize(source)
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = DiagramHistoryEntry(id: id, title: name, source: text, recordedAt: date, origin: origin)
        guard candidate.isUsable else { return nil }

        if let index = entries.firstIndex(where: { $0.source == text }) {
            var existing = entries.remove(at: index)
            // The identifier survives, so a preview opened from this row and a later removal of it
            // are still talking about the same diagram.
            if !name.isEmpty { existing.title = name }
            existing.recordedAt = date
            existing.origin = origin
            entries.insert(existing, at: 0)
            return existing
        }

        if var newest = entries.first, isRevision(of: newest, title: name, source: text, origin: origin, at: date) {
            if !name.isEmpty { newest.title = name }
            newest.source = text
            newest.recordedAt = date
            entries[0] = newest
            return newest
        }

        entries.insert(candidate, at: 0)
        trim()
        return candidate
    }

    @discardableResult
    public mutating func remove(_ id: DiagramHistoryEntry.ID) -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return false }
        entries.remove(at: index)
        return true
    }

    public mutating func removeAll() {
        entries.removeAll()
    }

    // MARK: - Sameness

    private func isRevision(
        of entry: DiagramHistoryEntry,
        title: String,
        source: String,
        origin: DiagramOrigin,
        at date: Date
    ) -> Bool {
        guard entry.origin == origin else { return false }
        // Absolute, so a clock that went backwards between two recordings cannot turn a revision
        // into a second row.
        guard abs(date.timeIntervalSince(entry.recordedAt)) <= Self.revisionWindow else { return false }
        if !title.isEmpty, title.compare(entry.title, options: [.caseInsensitive]) == .orderedSame { return true }
        return Self.similarity(entry.source, source) >= Self.revisionSimilarity
    }

    /// How much of two diagrams is the same lines: shared lines over all distinct lines. Blind to
    /// order and to where an edit happened, which is what an edit usually is.
    static func similarity(_ lhs: String, _ rhs: String) -> Double {
        let left = significantLines(lhs)
        let right = significantLines(rhs)
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        let shared = left.intersection(right).count
        let total = left.union(right).count
        guard total > 0 else { return 0 }
        return Double(shared) / Double(total)
    }

    private static func significantLines(_ source: String) -> Set<String> {
        var lines = Set<String>()
        for line in source.split(separator: "\n", omittingEmptySubsequences: true).prefix(comparedLines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { lines.insert(trimmed) }
        }
        return lines
    }

    /// Trailing blank lines and trailing spaces are the difference between "the same diagram" and
    /// "a new one" often enough to be worth removing before anything is compared.
    static func normalize(_ source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(trimmingTrailingSpaces)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Walked backwards rather than matched with a regular expression: this runs over every line of
    /// every recording, and a diagram is allowed five thousand of them.
    private static func trimmingTrailingSpaces(_ line: Substring) -> Substring {
        var end = line.endIndex
        while end > line.startIndex {
            let previous = line.index(before: end)
            // Carriage returns included, so text pasted from a Windows editor compares equal to the
            // same diagram typed here.
            guard line[previous] == " " || line[previous] == "\t" || line[previous] == "\r" else { break }
            end = previous
        }
        return line[line.startIndex..<end]
    }

    private mutating func trim() {
        guard entries.count > limit else { return }
        entries.removeLast(entries.count - limit)
    }
}
