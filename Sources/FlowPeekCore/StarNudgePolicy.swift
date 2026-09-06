import Foundation

/// What FlowPeek knows about whether it has earned the one favour it will ever ask for.
///
/// Two numbers rather than one. A count alone is satisfied by an afternoon of trying the app out —
/// forty diagrams is twenty minutes of pasting samples into the practice page — and somebody still
/// deciding whether to keep FlowPeek is exactly the person who should not be asked for anything.
/// Elapsed time alone is satisfied by an app that was installed and forgotten. Both together say
/// what neither says alone: this has been drawing diagrams for someone, for a while.
public struct StarNudgeLedger: Equatable, Sendable {
    /// Diagrams the user actually got on screen, by any of the three routes. Not launches, not
    /// selections FlowPeek noticed, not copies it badged — the ones where the app did its job.
    public var diagramsOpened: Int
    /// When the first of them was drawn. `nil` until there has been one.
    public var firstDiagramAt: Date?
    /// The question has been put. Set when the notice appears rather than when it is answered:
    /// the notice retires itself after a few seconds, so "dismissed" is not an event that reliably
    /// arrives, and a second appearance is the nag this whole type exists to prevent.
    public var asked: Bool

    public init(diagramsOpened: Int = 0, firstDiagramAt: Date? = nil, asked: Bool = false) {
        self.diagramsOpened = diagramsOpened
        self.firstDiagramAt = firstDiagramAt
        self.asked = asked
    }

    /// One more diagram drawn.
    ///
    /// Frozen once the question has been put, so the app stops writing to the store for the rest of
    /// its life the moment it has nothing left to ask.
    public func recordingDiagram(at now: Date) -> Self {
        guard !asked else { return self }
        var next = self
        // Saturating rather than wrapping: an overflow trap in the middle of opening a diagram
        // would be a crash caused entirely by a counter nobody is reading any more.
        next.diagramsOpened = diagramsOpened == Int.max ? Int.max : diagramsOpened + 1
        // The earliest of the two, so a clock that ran fast and was then corrected cannot leave a
        // start date in the future — which would hold the tenure at zero for as long as the error.
        next.firstDiagramAt = min(firstDiagramAt ?? now, now)
        return next
    }

    /// The question has been put and will not be put again.
    public func asking() -> Self {
        var next = self
        next.asked = true
        return next
    }
}

/// What is on screen when the question would be asked. Every one of these is somewhere the user is
/// reading or working, and a badge in the corner of the screen is an interruption of it.
public struct StarNudgeScreen: Equatable, Sendable {
    public var previewOnScreen: Bool
    public var onboardingOnScreen: Bool
    /// Any other FlowPeek window — Settings, the AI window, a preview promoted to a window of its
    /// own. Named as one thing because the rule is the same for all of them.
    public var otherWindowOnScreen: Bool

    public static let clear = StarNudgeScreen()

    public init(
        previewOnScreen: Bool = false,
        onboardingOnScreen: Bool = false,
        otherWindowOnScreen: Bool = false
    ) {
        self.previewOnScreen = previewOnScreen
        self.onboardingOnScreen = onboardingOnScreen
        self.otherWindowOnScreen = otherWindowOnScreen
    }

    public var isBusy: Bool { previewOnScreen || onboardingOnScreen || otherWindowOnScreen }
}

public enum StarNudgeDecision: Equatable, Sendable {
    case ask
    /// Already put, once, however it was answered. Terminal: nothing moves a ledger out of here.
    case alreadyAsked
    /// Not used enough, or not for long enough, for the app to have earned it yet.
    case notEarnedYet
    /// Earned, but the user is looking at something. Ask at the next quiet moment instead.
    case waitForAQuietMoment
}

/// The single ask, and everything that has to be true before it happens.
public enum StarNudgePolicy {
    public static let repository = "https://github.com/FlowPeek/flowpeek"

    /// Forty diagrams. "Dozens" in the plainest reading, and far enough past the handful somebody
    /// draws while working out what the app is that the question can only reach a user who already
    /// knows the answer. It is also past the point where the three routes have all been used at
    /// least once by anyone who is going to use them at all.
    public static let diagramsBeforeAsking = 40

    /// Three days between the first diagram and the question, so the forty cannot all be one
    /// sitting. A trial that ends the same evening never sees the notice at all.
    public static let minimumTenure: TimeInterval = 3 * 24 * 60 * 60

    public static func decide(ledger: StarNudgeLedger, screen: StarNudgeScreen, now: Date) -> StarNudgeDecision {
        // First, and before anything else can be considered: this is the answer for the rest of
        // the app's life, and no count, screen or clock may reopen it.
        guard !ledger.asked else { return .alreadyAsked }
        guard ledger.diagramsOpened >= diagramsBeforeAsking else { return .notEarnedYet }
        // A ledger carrying a count but no start date is one that was counted by a build before
        // the date was kept. Treating that as "tenure unknown, ask anyway" would fire the notice
        // at the first launch after an update, at whichever moment a preview happened to close;
        // the next diagram writes the date and the wait is three days from there.
        guard let first = ledger.firstDiagramAt, now.timeIntervalSince(first) >= minimumTenure else {
            return .notEarnedYet
        }
        guard !screen.isBusy else { return .waitForAQuietMoment }
        return .ask
    }
}
