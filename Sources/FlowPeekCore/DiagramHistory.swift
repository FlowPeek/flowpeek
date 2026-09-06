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
/// diagram or another go at one already here are the parts that are easy to get subtly wrong and
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

    public private(set) var entries: [DiagramHistoryEntry]
    public private(set) var limit: Int

    public init(entries: [DiagramHistoryEntry] = [], limit: Int = defaultLimit) {
        self.limit = Self.clamp(limit)
        // What comes in may be a hand-edited file: out of order, with the same diagram in it twice.
        // Sorted and folded here so everything downstream can assume newest-first and one row per
        // diagram.
        var seenSources = Set<String>()
        var seenIDs = Set<DiagramHistoryEntry.ID>()
        self.entries = entries
            .filter(\.isUsable)
            .sorted { $0.recordedAt > $1.recordedAt }
            // Identifiers are folded as well as diagrams. A list is drawn keyed on the identifier
            // and a row is removed by it, so two rows carrying the same one are a pair the app
            // cannot tell apart -- removing the one that was clicked would take the other. The
            // newer of each pair is the one kept.
            .filter { seenSources.insert($0.source).inserted && seenIDs.insert($0.id).inserted }
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
    /// Two recordings are the same diagram when one of exactly two things is true:
    ///  * the Mermaid is identical, wherever in the list it already sits -- opening the same
    ///    diagram again is not a second diagram, it is the same one, freshly used; or
    ///  * the caller named the row this one replaces. A window that is working on one diagram picks
    ///    an identifier once and hands it back with every recording, which is what stops five goes
    ///    at a diagram from leaving five near-identical rows.
    ///
    /// Nothing else folds, and in particular nothing folds because two diagrams *look* alike. Two
    /// recordings sharing a title, or most of their lines, are still two recordings: every answer an
    /// assistant writes carries a title the model chose and models repeat themselves, and a small
    /// diagram shares its declaration line with every other diagram of its kind. Being wrong in that
    /// direction costs the user a diagram they cannot get back -- there is no undo behind this list
    /// -- while being wrong the other way costs them a row they can delete.
    ///
    /// `revising` answers both halves of "which row is this": an identifier already in the list
    /// names the row this replaces, and one that is not becomes the identifier of the new row. So a
    /// caller can choose an identity at the start of an editing session and keep passing it, without
    /// having to know whether the first recording has happened yet.
    ///
    /// Returns the entry as it now stands, or nil when there was nothing to remember.
    @discardableResult
    public mutating func record(
        title: String,
        source: String,
        origin: DiagramOrigin,
        at date: Date = .now,
        revising identity: DiagramHistoryEntry.ID? = nil
    ) -> DiagramHistoryEntry? {
        let text = Self.normalize(source)
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = DiagramHistoryEntry(
            id: identity ?? UUID(),
            title: name,
            source: text,
            recordedAt: date,
            origin: origin
        )
        guard candidate.isUsable else { return nil }

        // The row the caller named first, and only then the row that already holds this exact text:
        // being told which diagram this is outranks recognising it, and an identifier that names
        // nothing yet falls through to become a new row rather than landing on someone else's.
        let match = identity.flatMap { id in entries.firstIndex { $0.id == id } }
            ?? entries.firstIndex { $0.source == text }

        guard let match else {
            insert(candidate)
            trim()
            return candidate
        }

        var existing = entries.remove(at: match)
        // The identifier survives, so a preview opened from this row and a later removal of it are
        // still talking about the same diagram.
        if !name.isEmpty { existing.title = name }
        existing.source = text
        existing.recordedAt = date
        existing.origin = origin
        insert(existing)
        return existing
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

    /// Placed by date rather than pushed onto the top. `record` remembers a diagram at whatever
    /// moment it is handed, and `Date.now` is not monotonic -- a clock correction, or a caller
    /// re-recording something from yesterday, would otherwise leave the list reading oldest-first
    /// until the next launch sorted it out. Ties keep the newer recording above, because a diagram
    /// recorded twice in the same instant is the second one.
    private mutating func insert(_ entry: DiagramHistoryEntry) {
        let index = entries.firstIndex { $0.recordedAt <= entry.recordedAt } ?? entries.count
        entries.insert(entry, at: index)
    }

    private mutating func trim() {
        guard entries.count > limit else { return }
        entries.removeLast(entries.count - limit)
    }
}
