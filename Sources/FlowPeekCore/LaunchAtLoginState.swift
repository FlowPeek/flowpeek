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
        if requiresApproval { return .needsApproval }
        if registered { return .on }
        return requestedOn ? .failed : .off
    }

    /// `needsApproval` keeps the switch on: the item really is registered, and flipping it back would
    /// contradict what System Settings shows the user in the next breath.
    public var isOn: Bool {
        switch self {
        case .on, .needsApproval: true
        case .off, .failed: false
        }
    }

    public var noticeKey: String.LocalizationValue? {
        switch self {
        case .off, .on: nil
        case .needsApproval: "settings.launch-at-login.needs-approval"
        case .failed: "settings.launch-at-login.failed"
        }
    }

    /// Neither unhappy state can be fixed from inside the app, so both offer the door out to it.
    public var offersLoginItems: Bool { noticeKey != nil }
}
