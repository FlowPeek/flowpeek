import Foundation

/// A looping explanation of one mechanic, written as data rather than as animation code.
///
/// The settings cards used to explain themselves in five sentences each -- 573 characters for the
/// terminal watch, 520 for hold to peek -- and a paragraph is the wrong shape for "hold this key
/// and point at that". A small drawing that performs the mechanic on a skeleton of the interface
/// says it in a second, and the words that remain can be one line.
///
/// What lives here is the order and the timings, because that is the part worth testing -- a step
/// that lasts no time, a loop whose stages cannot all be reached, a script that never returns to
/// its beginning -- and the part two surfaces share: Settings and the tutorial teach the same
/// mechanics at different sizes and must not drift into teaching them differently.
///
/// Generic over its stages so each scene names its own. A single enum covering every mechanic would
/// carry a case for every other scene's steps, and every scene would have to ignore most of it.
public struct SkeletonScript<Stage: Equatable & Sendable>: Equatable, Sendable {
    public struct Step: Equatable, Sendable {
        public let stage: Stage
        public let duration: TimeInterval

        public init(_ stage: Stage, _ duration: TimeInterval) {
            self.stage = stage
            self.duration = duration
        }
    }

    public let steps: [Step]
    /// What to draw instead of playing, for a reader who has asked the system to reduce motion.
    /// The stage that shows the mechanic having happened, which is the one frame worth keeping.
    public let resting: Stage?

    /// Steps that would last no time are dropped rather than kept: a zero-length step is
    /// unreachable by any clock, and leaving it in means a stage that is in the script and never on
    /// screen -- which is exactly the kind of thing nobody notices until the drawing looks wrong.
    public init(_ steps: [Step], resting: Stage? = nil) {
        let usable = steps.filter { $0.duration > 0 && $0.duration.isFinite }
        self.steps = usable
        self.resting = resting ?? usable.last?.stage
    }

    public var total: TimeInterval { steps.reduce(0) { $0 + $1.duration } }

    public var isEmpty: Bool { steps.isEmpty }

    /// The stage at `time`, which loops. Nil only when there is nothing to play.
    ///
    /// Negative time is as valid as any other: a scene can be started from a clock that has not
    /// reached its own origin yet, and wrapping backwards is the same wrap.
    public func stage(at time: TimeInterval) -> Stage? {
        step(at: time)?.stage
    }

    /// How far through its own step `time` sits, from 0 to 1. What a stage that moves -- a pointer
    /// crossing to a block, a badge sliding in -- interpolates along.
    public func progress(at time: TimeInterval) -> Double {
        guard let position = position(at: time) else { return 0 }
        return min(max(position.offset / position.step.duration, 0), 1)
    }

    public func step(at time: TimeInterval) -> Step? {
        position(at: time)?.step
    }

    private func position(at time: TimeInterval) -> (step: Step, offset: TimeInterval)? {
        let total = total
        guard total > 0, time.isFinite else { return steps.first.map { ($0, 0) } }
        // `truncatingRemainder` keeps the sign, and a negative offset would read as being before
        // the first step rather than inside the last one.
        var remaining = time.truncatingRemainder(dividingBy: total)
        if remaining < 0 { remaining += total }
        for step in steps {
            if remaining < step.duration { return (step, remaining) }
            remaining -= step.duration
        }
        // Only reachable through floating-point drift at the very end of the loop.
        return steps.last.map { ($0, $0.duration) }
    }
}
