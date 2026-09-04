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

    public enum State: Equatable, Sendable {
        /// Nothing has happened for this lesson yet.
        case waiting
        /// FlowPeek saw the text but the user has not opened it.
        case detected
        /// A preview opened by this route.
        case done
    }

    private var states: [Lesson: State]

    public init(states: [Lesson: State] = [:]) {
        self.states = states
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

    public mutating func noteOpened(_ lesson: Lesson) {
        states[lesson] = .done
    }

    public mutating func reset() {
        states.removeAll()
    }
}
