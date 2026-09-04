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
    public var shouldOfferRelaunch: Bool { phase == .waitingForUser && unconfirmedChecks >= 8 }

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
