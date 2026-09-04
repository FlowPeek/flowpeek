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
