import Foundation

/// Which of the three ways into a preview the user has actually exercised.
///
/// A lesson is only complete when a preview really opened by that route. Detection alone is
/// reported separately, because "FlowPeek noticed your text" and "you opened the diagram" are
/// different moments and the tutorial should acknowledge the first without claiming the second.
public struct TutorialProgress: Equatable, Sendable {
    public enum Lesson: String, CaseIterable, Sendable, Identifiable {
        case selection
        case clipboard
        case ambient

        public var id: String { rawValue }

        public var titleKey: String.LocalizationValue {
            switch self {
            case .selection: "tutorial.selection.title"
            case .clipboard: "tutorial.clipboard.title"
            case .ambient: "tutorial.ambient.title"
            }
        }

        public var detailKey: String.LocalizationValue {
            switch self {
            case .selection: "tutorial.selection.detail"
            case .clipboard: "tutorial.clipboard.detail"
            case .ambient: "tutorial.ambient.detail"
            }
        }

        public var symbol: String {
            switch self {
            case .selection: "hand.draw"
            case .clipboard: "doc.on.clipboard"
            case .ambient: "viewfinder"
            }
        }

        /// The one lesson whose instructions have to name the peek chord. That chord is rebindable,
        /// so its row in the catalogue carries a placeholder: spelled out in the string, the copy
        /// starts lying the moment somebody rebinds it.
        public var namesPeekShortcut: Bool { self == .ambient }

        /// The lesson's instructions, with the chord as it is bound right now written into them.
        public func detail(peekShortcut: String) -> String {
            let text = String(localized: detailKey)
            guard namesPeekShortcut else { return text }
            return String(format: text, peekShortcut)
        }

        /// Whether the gesture can fire at all right now. Pointing is an experiment that ships off,
        /// and a row waiting forever for a gesture nothing is listening for is indistinguishable
        /// from a row the user simply has not tried yet.
        public func canFire(ambientPeekEnabled: Bool) -> Bool {
            self == .ambient ? ambientPeekEnabled : true
        }

        /// What the practice page prints in place of the instructions when the gesture cannot fire.
        /// The page has no switch on it, so the sentence has to say where the switch is.
        public var switchedOffDetailKey: String.LocalizationValue? {
            self == .ambient ? "tutorial.ambient.blocked" : nil
        }

        /// What the checklist row says instead. Shorter than the page's version because the row
        /// carries the button itself.
        public var switchedOffReasonKey: String.LocalizationValue? {
            self == .ambient ? "tutorial.ambient.switched-off" : nil
        }

        /// What to say when the gesture was tried and FlowPeek could not use what it got.
        ///
        /// Only the drag route ever sees its own near misses: a copy that does not parse is dropped
        /// by `ClipboardMonitor` before anything records it, and pointing at text that is not a
        /// diagram produces no candidate at all — so those two rows would have nothing truthful to
        /// put here.
        public var missedKey: String.LocalizationValue? {
            self == .selection ? "tutorial.selection.missed" : nil
        }

        /// What to say when the gesture has produced nothing at all for a long while. Not a
        /// diagnosis — nothing was observed, which is exactly the problem — so it repeats the part
        /// of the instruction people get wrong.
        public var nudgeKey: String.LocalizationValue {
            switch self {
            case .selection: "tutorial.nudge.selection"
            case .clipboard: "tutorial.nudge.clipboard"
            case .ambient: "tutorial.nudge.ambient"
            }
        }

        /// Selecting reads the focused element and pointing walks the accessibility tree; copying
        /// does neither.
        public static let requiringAccessibility: [Self] = [.selection, .ambient]

        /// Which lessons can actually be passed. Copying is the whole tutorial for someone who
        /// declined the grant, and teaching a gesture that cannot produce an overlay — a drag whose
        /// button never appears — is worse than not offering it at all.
        public static func available(accessibilityGranted: Bool) -> [Self] {
            accessibilityGranted ? allCases : allCases.filter { !requiringAccessibility.contains($0) }
        }
    }

    /// Raw-valued because these names are written to disk. Renaming a case renames a stored value,
    /// so the strings are the contract and not just a spelling.
    public enum State: String, Equatable, Sendable {
        /// Nothing has happened for this lesson yet.
        case waiting
        /// FlowPeek saw the text but the user has not opened it.
        case detected
        /// The gesture happened and FlowPeek could not use what it got — the partial drag that lost
        /// the diagram's first line. Distinct from `waiting`, because "nothing appeared" and
        /// "something appeared and was refused" need different advice.
        case missed
        /// A preview opened by this route.
        case done

        /// Read aloud as the row's value. The states are told apart on screen by a stroke colour
        /// and, for two of them, a glyph — none of which VoiceOver can describe.
        public var titleKey: String.LocalizationValue {
            switch self {
            case .waiting: "tutorial.state.waiting"
            case .detected: "tutorial.state.detected"
            case .missed: "tutorial.state.missed"
            case .done: "tutorial.state.done"
            }
        }
    }

    private var states: [Lesson: State]

    public init(states: [Lesson: State] = [:]) {
        self.states = states
    }

    /// The shape written to disk: lesson identifier to state identifier, both stable strings.
    ///
    /// Deliberately not the synthesised `Codable` for `[Lesson: State]`. Swift encodes a dictionary
    /// whose key is neither `String` nor `Int` as a flat array of alternating keys and values, which
    /// is unreadable in `defaults read` and is positional rather than named — exactly the fragile
    /// shape to have baked into a file that outlives the build that wrote it.
    public var persisted: [String: String] {
        states.reduce(into: [:]) { result, entry in result[entry.key.rawValue] = entry.value.rawValue }
    }

    /// Anything unrecognised is dropped rather than rejected. A file left by a newer build, or by
    /// one that named a lesson differently, must not be able to stop the tutorial from opening: the
    /// worst honest outcome is a row that reads as untried.
    public init(persisted: [String: String]) {
        states = persisted.reduce(into: [:]) { result, entry in
            guard let lesson = Lesson(rawValue: entry.key), let state = State(rawValue: entry.value) else { return }
            result[lesson] = state
        }
    }

    public subscript(lesson: Lesson) -> State {
        states[lesson] ?? .waiting
    }

    public var isComplete: Bool {
        isComplete(among: Lesson.allCases)
    }

    public var completedCount: Int {
        completedCount(among: Lesson.allCases)
    }

    /// Completion measured against the lessons on offer, so a user without Accessibility can finish
    /// honestly instead of being told they gave up on two gestures that were never available.
    public func isComplete(among lessons: [Lesson]) -> Bool {
        lessons.allSatisfy { self[$0] == .done }
    }

    public func completedCount(among lessons: [Lesson]) -> Int {
        lessons.count { self[$0] == .done }
    }

    /// Records that FlowPeek noticed something. Never demotes a finished lesson: having opened a
    /// diagram once, seeing another one detected must not undo the tick.
    public mutating func noteDetected(_ lesson: Lesson) {
        guard self[lesson] != .done else { return }
        states[lesson] = .detected
    }

    /// Records that the user tried and FlowPeek refused what it was given. Only ever promotes out of
    /// `waiting`: a lesson already noticed or already passed has nothing to complain about, and a
    /// second sloppy drag must not take a tick away.
    public mutating func noteMissed(_ lesson: Lesson) {
        // Having the words is the gate: a row that cannot explain a miss must not be able to show
        // one, or the user gets an orange badge and no idea what to do differently.
        guard lesson.missedKey != nil, self[lesson] == .waiting else { return }
        states[lesson] = .missed
    }

    public mutating func noteOpened(_ lesson: Lesson) {
        states[lesson] = .done
    }

    public mutating func reset() {
        states.removeAll()
    }
}

/// Codable in terms of the same flat dictionary the tutorial stores, so a progress value carried
/// inside some larger document later cannot end up with a second, different on-disk shape.
extension TutorialProgress: Codable {
    public init(from decoder: any Decoder) throws {
        try self.init(persisted: [String: String](from: decoder))
    }

    public func encode(to encoder: any Encoder) throws {
        try persisted.encode(to: encoder)
    }
}

/// The diagram the practice page shows, and the one question the tutorial has to ask of a selection
/// FlowPeek rejected: was the user aiming at this?
///
/// Lives here rather than beside the page so the answer can be tested without AppKit, and so the
/// page and the checklist cannot end up matching against two different samples.
public enum TutorialSample {
    public static let text = """
    flowchart TD
      A[Copy or select this] --> B{FlowPeek notices}
      B -- overlay button --> C[Preview]
      B -- badge --> C
      B -- hold Option --> C
    """

    /// Matched line by line against the body, because the case worth catching is the partial drag:
    /// a selection that starts mid-diagram has lost the `flowchart TD` line detection needs, so
    /// whole-block equality would miss every failure this exists to explain. The starter line is
    /// not a signal on its own — it is two common words that appear in every flowchart on the web,
    /// and a stray match would have the tutorial comment on the user's own documents.
    public static func appearsIn(_ raw: String) -> Bool {
        let haystack = MermaidDetector.normalize(raw)
        guard !haystack.isEmpty else { return false }
        return bodyLines.contains { haystack.contains($0) }
    }

    private static let bodyLines: [String] = MermaidDetector.normalize(text)
        .components(separatedBy: "\n")
        .dropFirst()
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { $0.count >= 8 }
}
