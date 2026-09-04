import Foundation

/// What the login item is really doing, as opposed to what the user asked for. `SMAppService` can
/// accept a registration and still park it in "requires approval", where nothing launches until the
/// user confirms it under Login Items — and it reports a refusal as a bare OSStatus that means
/// nothing to anyone. Both cases have to be rendered from the status, never from the switch.
public enum LaunchAtLoginState: Equatable, Sendable {
    case off
    case on
    case needsApproval
    /// Asked for and not delivered: refused outright, or disallowed by a management profile.
    case failed

    public static func resolve(
        registered: Bool,
        requiresApproval: Bool,
        requestedOn: Bool
    ) -> LaunchAtLoginState {
        if registered { return .on }
        // macOS reports requires-approval for two situations its API does not separate: a
        // registration this run has just made and is waiting on a single confirmation for, and an
        // item the user switched off themselves under Login Items, which stays registered-and-
        // refused indefinitely. Only the first is worth keeping the switch on for and explaining;
        // reading the second the same way claims a setting the user never chose and nags them to
        // undo their own decision. `requestedOn` is what separates them, because it is true only
        // in the run where the request was actually made.
        if requiresApproval { return requestedOn ? .needsApproval : .off }
        return requestedOn ? .failed : .off
    }

    /// `needsApproval` keeps the switch on: the registration this run asked for really was accepted,
    /// and flipping it back would contradict what System Settings shows the user in the next breath.
    public var isOn: Bool {
        switch self {
        case .on, .needsApproval: true
        case .off, .failed: false
        }
    }

    /// Neither unhappy state can be fixed from inside the app, so both carry the door out to it:
    /// wherever this notice is drawn, the Login Items button is drawn beside it.
    public var noticeKey: String.LocalizationValue? {
        switch self {
        case .off, .on: nil
        case .needsApproval: "settings.launch-at-login.needs-approval"
        case .failed: "settings.launch-at-login.failed"
        }
    }
}

/// The two halves a login-item switch is drawn from, kept in one value because either of them
/// moving changes what has to be on screen. The system status is only half of it: for the two
/// statuses `register()`/`unregister()` hand straight back — an item macOS is already holding at
/// requires-approval, and one that never registered at all — the click is the *only* thing that
/// moves, and the amber notice beneath the switch has to appear and disappear with it. So the
/// halves travel together, and whatever publishes this publishes both.
public struct LaunchAtLoginAnswer: Equatable, Sendable {
    /// What the system reports: the login item is live.
    public let registered: Bool
    /// What the system reports: registered, and waiting on a confirmation under Login Items.
    public let requiresApproval: Bool
    /// Whether the login item was asked for during this run, which is the only thing that tells a
    /// pending approval apart from an item the user switched off themselves. Not persisted, for the
    /// reason `resolve` gives. Immutable like the rest: it moves by replacing the whole answer, so
    /// there is no way to move it without whatever holds the answer noticing.
    public let requestedOn: Bool

    public init(registered: Bool, requiresApproval: Bool, requestedOn: Bool = false) {
        self.registered = registered
        self.requiresApproval = requiresApproval
        self.requestedOn = requestedOn
    }

    public var state: LaunchAtLoginState {
        .resolve(registered: registered, requiresApproval: requiresApproval, requestedOn: requestedOn)
    }

    /// The answer after the user works the switch. Its own step, and a whole new answer, because
    /// this is the half the system cannot report: ask a requires-approval item to register and the
    /// status comes back exactly as it went in, so a re-read has nothing to offer and the click is
    /// all the change there is.
    public func requesting(_ enabled: Bool) -> LaunchAtLoginAnswer {
        LaunchAtLoginAnswer(
            registered: registered,
            requiresApproval: requiresApproval,
            requestedOn: enabled
        )
    }

    /// The answer after re-reading the system, or `nil` when there is nothing new to draw. Settings
    /// and the onboarding card both re-read on every activation and most of those find the same
    /// thing twice, so the no-change case is worth spotting — but only this way round. A re-read
    /// carries `requestedOn` over rather than re-deriving it, because only the app knows it: the
    /// system reports the same requires-approval whether this run asked for the registration or the
    /// user switched the item off themselves. What the switch was set to is `requesting(_:)`'s to
    /// move, and it must not be guarded by the status sitting still.
    public func rereading(registered: Bool, requiresApproval: Bool) -> LaunchAtLoginAnswer? {
        let next = LaunchAtLoginAnswer(
            registered: registered,
            requiresApproval: requiresApproval,
            requestedOn: requestedOn
        )
        return next == self ? nil : next
    }
}
