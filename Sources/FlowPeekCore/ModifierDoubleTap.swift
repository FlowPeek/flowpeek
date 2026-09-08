import Foundation

/// Recognises a modifier key pressed and released twice in quick succession.
///
/// Pure, because this is the part that is easy to get subtly wrong and impossible to see going
/// wrong: it decides, from nothing but a sequence of events and their times, whether somebody meant
/// to do something. Everything about reading real events lives in the app.
///
/// A tap has to be *clean*. Option is held for a huge share of ordinary typing -- Option and an
/// arrow to jump a word, Option and a click, Option and a letter for a special character -- and
/// none of that is a tap. So anything at all happening between the press and the release
/// disqualifies it, and so does holding the key, which is a different gesture in this app
/// altogether: hold to peek.
public struct ModifierDoubleTap: Equatable, Sendable {
    /// What macOS uses for a double click, and the same figure reads as "twice, quickly" to a hand.
    /// Measured against synthesised taps: 350ms misses a comfortable double press, 500ms catches it.
    public static let defaultInterval: TimeInterval = 0.5

    /// Below 300ms a person has to hurry to be understood; above 800ms two unrelated presses start
    /// to fall inside the window by accident.
    public static let intervalRange: ClosedRange<TimeInterval> = 0.3...0.8

    /// Longer than this is a hold, and a hold belongs to the pointer gesture.
    public static let maximumHold: TimeInterval = 0.3

    /// How long the two releases may be apart.
    public private(set) var interval: TimeInterval

    private var pressedAt: TimeInterval?
    /// Something happened while the key was down, so this press is part of a combination.
    private var chorded = false
    private var lastTapAt: TimeInterval?

    public init(interval: TimeInterval = defaultInterval) {
        self.interval = ModifierDoubleTap.clamp(interval)
    }

    public static func clamp(_ interval: TimeInterval) -> TimeInterval {
        min(max(interval, intervalRange.lowerBound), intervalRange.upperBound)
    }

    public mutating func setInterval(_ value: TimeInterval) {
        interval = Self.clamp(value)
        // A half-finished gesture measured against the old number is not one the user asked for.
        forget()
    }

    /// The modifier went down. `alone` is false when another modifier came with it.
    public mutating func press(alone: Bool, at time: TimeInterval) {
        pressedAt = time
        chorded = !alone
    }

    /// The modifier came up. Answers true when this completes a double tap.
    public mutating func release(at time: TimeInterval) -> Bool {
        defer { pressedAt = nil; chorded = false }
        guard let pressedAt, !chorded, time - pressedAt <= Self.maximumHold else {
            // A hold, or a chord. Neither is a tap, and neither should leave a half-gesture behind
            // for the next press to complete: releasing Option after a word jump must not arm this.
            lastTapAt = nil
            return false
        }
        if let lastTapAt, time - lastTapAt <= interval {
            // Cleared rather than kept, so three taps in a row are one gesture and not two.
            self.lastTapAt = nil
            return true
        }
        lastTapAt = time
        return false
    }

    /// A key, a click, a scroll: anything that means the user is doing something else. Called
    /// whether or not the modifier is down, because a keystroke between two taps also ends them.
    public mutating func interrupt() {
        if pressedAt != nil { chorded = true }
        lastTapAt = nil
    }

    /// Drops any gesture in progress. For the moments where carrying one across would be wrong:
    /// the feature being switched off, the interval changing, the app losing the world it was
    /// watching.
    public mutating func forget() {
        pressedAt = nil
        chorded = false
        lastTapAt = nil
    }
}
