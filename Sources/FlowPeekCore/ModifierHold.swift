import Foundation

/// Recognises a modifier key held down on its own for a long time, and decides how long what it
/// revealed should stay.
///
/// Pure, for the same reason `ModifierDoubleTap` is: this decides, from nothing but a sequence of
/// observations and their times, whether somebody meant something -- and it is the only way back to
/// an app that has taken its own icon out of the menu bar. Getting it wrong strands a user, and a
/// bug here is invisible until it does. Everything about reading real keys lives in the app.
///
/// A hold has to be *deliberate*. Five seconds is far longer than any modifier is held by accident
/// or in the course of a chord, which is the point: the gesture has to be impossible to perform
/// without meaning to, because what it does is make a hidden thing appear.
public struct ModifierHold: Equatable, Sendable {
    /// How long the key is held before anything appears.
    ///
    /// Long on purpose. Option is held constantly in ordinary use -- a word jump, a special
    /// character, a modified click -- but never for five seconds, so nothing a user does by habit
    /// can trip this.
    public static let defaultHold: TimeInterval = 5

    /// How long what appeared stays after the key comes up.
    ///
    /// Not zero, and this is the difference between a feature and a trap. An icon that vanishes on
    /// release can never be *clicked*: the hand that has to let go of the key is the hand that has
    /// to reach the menu bar. Measured against the distance from a keyboard to a menu bar item,
    /// eight seconds is unhurried without leaving the icon sitting there afterwards.
    public static let defaultGrace: TimeInterval = 8

    public let holdDuration: TimeInterval
    public let grace: TimeInterval

    /// Whether the thing this reveals is showing.
    public private(set) var isRevealed = false

    /// When the modifier went down, or nil if it is up.
    private var heldSince: TimeInterval?
    /// The last moment the reveal was being kept alive, by the key or by the pin.
    private var aliveAt: TimeInterval?
    /// Something is using what was revealed -- its menu is open -- so it may not be taken away.
    private var pinned = false

    public init(holdDuration: TimeInterval = defaultHold, grace: TimeInterval = defaultGrace) {
        self.holdDuration = max(0, holdDuration)
        self.grace = max(0, grace)
    }

    /// How far through the hold the key is, from 0 to 1. What a progress indicator follows, and the
    /// answer is 1 once the reveal has happened rather than when the key alone would say so.
    public func progress(at time: TimeInterval) -> Double {
        if isRevealed { return 1 }
        guard let heldSince, holdDuration > 0 else { return 0 }
        return min(1, max(0, (time - heldSince) / holdDuration))
    }

    /// One look at the keyboard. `alone` is whether the modifier is the only one down; a chord is
    /// somebody using the key rather than holding it.
    ///
    /// Answers whether the revealed thing should be showing now.
    @discardableResult
    public mutating func observe(alone: Bool, at time: TimeInterval) -> Bool {
        if alone {
            // A clock that has gone backwards -- a machine waking from sleep is the real case --
            // would otherwise make an arbitrarily old press look like a completed hold.
            if let heldSince, time < heldSince { self.heldSince = time }
            if heldSince == nil { heldSince = time }
            if let heldSince, time - heldSince >= holdDuration { isRevealed = true }
        } else {
            heldSince = nil
        }
        guard isRevealed else { return false }
        if alone || pinned {
            aliveAt = time
        } else if let aliveAt, time - aliveAt >= grace {
            isRevealed = false
            self.aliveAt = nil
            heldSince = nil
        } else if aliveAt == nil {
            aliveAt = time
        }
        return isRevealed
    }

    /// Whether what was revealed is in use. While it is, the grace period does not run: a menu that
    /// closed itself out from under the pointer would be worse than one that stayed too long.
    public mutating func setPinned(_ value: Bool, at time: TimeInterval) {
        pinned = value
        if isRevealed { aliveAt = time }
    }

    /// Show it now, without a gesture, for the usual grace.
    ///
    /// For the moment the setting is switched on: an icon that blinks out of the menu bar the
    /// instant the switch moves has not told the reader what happened to it, and this is what lets
    /// it fade instead.
    public mutating func prime(at time: TimeInterval) {
        isRevealed = true
        aliveAt = time
        heldSince = nil
    }

    /// Drops everything. For the feature being switched off, or the watch being torn down.
    public mutating func forget() {
        isRevealed = false
        heldSince = nil
        aliveAt = nil
        pinned = false
    }
}
