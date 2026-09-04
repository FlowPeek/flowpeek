import Foundation

/// Whether this copy of FlowPeek should carry on running, or stand aside for one that is already
/// there. Two copies put two icons in the menu bar, badge one copied diagram twice, and draw two
/// overlay buttons over the same selection -- and the second copy's global hot keys are refused
/// outright, because the first copy already holds them, so half of it silently does nothing.
public enum SingleInstanceGuard {
    /// Passed to the copy that the permission relaunch starts, so it can tell itself apart from an
    /// accidental second launch.
    public static let replacementArgument = "--flowpeek-replacing-instance"

    /// One running application, reduced to what the decision needs. `NSRunningApplication` cannot be
    /// constructed outside AppKit's own bookkeeping, so the rule is written against this instead.
    public struct Instance: Equatable, Sendable {
        public let bundleIdentifier: String?
        public let processIdentifier: pid_t
        public let launchDate: Date?

        public init(bundleIdentifier: String?, processIdentifier: pid_t, launchDate: Date? = nil) {
            self.bundleIdentifier = bundleIdentifier
            self.processIdentifier = processIdentifier
            self.launchDate = launchDate
        }
    }

    public enum Decision: Equatable, Sendable {
        /// No other copy owns the menu bar: this one is the app.
        case run
        /// Another copy is already running. Bring that one forward and leave quietly.
        case deferTo(pid_t)
    }

    /// - Parameter isReplacingAnInstance: true for the copy started by the permission relaunch. That
    ///   relaunch deliberately starts a second copy and terminates the first one a moment later, so
    ///   the new copy must not stand aside for the copy that is on its way out -- doing so would
    ///   leave nothing running at all.
    public static func decide(
        own: Instance,
        running: [Instance],
        isReplacingAnInstance: Bool = false
    ) -> Decision {
        if isReplacingAnInstance { return .run }
        // Without a bundle identifier there is nothing to compare against: a test host, or the
        // binary run straight out of the build directory. Refusing to start would be worse than the
        // doubled icons this exists to prevent.
        guard let identifier = own.bundleIdentifier else { return .run }
        let peers = running.filter {
            $0.bundleIdentifier == identifier && $0.processIdentifier != own.processIdentifier
        }
        // Only a copy that started *strictly* before this one wins, so the answer is the same
        // whichever copy asks. "Any other copy wins" reads the same in the ordinary case but leaves
        // two copies launched at the same instant both standing aside, and then neither is running.
        guard let incumbent = peers.filter({ startedBefore($0, own) }).min(by: startedBefore) else {
            return .run
        }
        return .deferTo(incumbent.processIdentifier)
    }

    /// Launch dates order the copies; the pid is the tie-break, for the copies macOS reports without
    /// one and for two launches inside the same instant of the clock.
    private static func startedBefore(_ lhs: Instance, _ rhs: Instance) -> Bool {
        if let left = lhs.launchDate, let right = rhs.launchDate, left != right { return left < right }
        return lhs.processIdentifier < rhs.processIdentifier
    }
}
