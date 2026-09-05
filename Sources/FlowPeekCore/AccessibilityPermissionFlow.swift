import Foundation

public struct AccessibilityPermissionFlow: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case needsPermission
        case waitingForUser
        case granted
    }

    public private(set) var phase: Phase
    private var unconfirmedChecks = 0

    public init(isGranted: Bool) {
        phase = isGranted ? .granted : .needsPermission
    }

    public var shouldComplete: Bool { phase == .granted }
    /// Counted in one-second polls. Finding the FlowPeek row in the Accessibility list takes most
    /// people longer than the eight checks this used to allow, so the offer arrived while they were
    /// still scrolling and read as "something went wrong".
    public var shouldOfferRelaunch: Bool { phase == .waitingForUser && unconfirmedChecks >= 45 }

    public mutating func beginWaitingForSystemSettings() {
        guard phase != .granted else { return }
        phase = .waitingForUser
        unconfirmedChecks = 0
    }

    public mutating func recordUnconfirmedCheck() {
        guard phase == .waitingForUser else { return }
        unconfirmedChecks += 1
    }

    public mutating func update(isGranted: Bool) {
        if isGranted { phase = .granted; unconfirmedChecks = 0 }
        else if phase != .waitingForUser { phase = .needsPermission }
    }
}

/// Which processes have had `AXManualAccessibility` set, and which of them refused it recently.
///
/// Chromium and Electron expose a tree of empty groups until that switch is set, so both routes
/// into a preview send it before they read. A process that answers `.success` never needs it
/// again. The refusals are the half worth remembering: an app that is not Chromium answers
/// `.attributeUnsupported` every single time it is asked, and a wedged one answers by spending its
/// whole messaging timeout -- so a memo of successes alone leaves one doomed synchronous message
/// per read, on the main actor, for as long as the modifier is held.
///
/// Refusals are remembered for a window rather than for good, because the answer really does
/// change: an Electron app swaps its renderer over asynchronously, and the read after that is the
/// one that finds a tree.
public struct AccessibilityWarmUpMemo: Equatable, Sendable {
    /// The window only has to be long against the read rate, which is one per
    /// `AmbientPeekPolicy.debounce`: two seconds already collapses a whole hold's worth of reads
    /// into one message. Making it longer buys nothing and costs availability, because the app this
    /// most affects is the one whose renderer was still coming up -- it answers differently a
    /// moment later, and until it is asked again its tree is empty groups and ambient peek is dead.
    public static let retryInterval: TimeInterval = 2

    private var enabled: Set<pid_t> = []
    private var refused: [pid_t: Date] = [:]

    public init() {}

    /// Whether the switch is worth sending to this process now.
    public func shouldSend(pid: pid_t, now: Date) -> Bool {
        guard !enabled.contains(pid) else { return false }
        guard let last = refused[pid] else { return true }
        return now.timeIntervalSince(last) >= Self.retryInterval
    }

    public mutating func note(pid: pid_t, succeeded: Bool, now: Date) {
        if succeeded {
            enabled.insert(pid)
            refused[pid] = nil
        } else {
            refused[pid] = now
        }
    }

    /// A process that has gone away. Its pid is handed back out by the kernel, and a new process
    /// wearing it would otherwise be treated as already warm.
    public mutating func forget(pid: pid_t) {
        enabled.remove(pid)
        refused[pid] = nil
    }

    public func isEnabled(pid: pid_t) -> Bool { enabled.contains(pid) }

    /// The processes whose switch is still on, so it can be turned back off, and forgets
    /// everything: whatever is left after this is not FlowPeek's to undo.
    public mutating func drain() -> [pid_t] {
        let pids = Array(enabled)
        enabled.removeAll()
        refused.removeAll()
        return pids
    }
}
