import Foundation

public enum OnboardingPolicy {
    /// A missing grant re-offers onboarding, because an app whose overlay silently does nothing
    /// looks broken. A *declined* grant does not: the user answered, and re-asking every launch is
    /// a nag they cannot switch off. Granting later clears the decline, so an accidental revoke
    /// still gets the window back.
    public static func shouldShow(
        accessibilityGranted: Bool,
        onboardingCompleted: Bool,
        permissionDeclined: Bool,
        forceOnboarding: Bool
    ) -> Bool {
        forceOnboarding || (!accessibilityGranted && !permissionDeclined) || !onboardingCompleted
    }

    /// Whether the wizard going away should record setup as finished. Answering the permission
    /// question, either way, is the whole of it: the tutorial is practice, not a gate. It has to
    /// hold for *every* way the window can leave — Escape, the ✕, or quitting with it still open —
    /// because otherwise a user who granted permission and quit for the day is met by the whole
    /// flow again at the next launch, which is the nag their answer was supposed to end.
    public static func recordsCompletion(accessibilityGranted: Bool, permissionDeclined: Bool) -> Bool {
        accessibilityGranted || permissionDeclined
    }
}

/// The wizard's cards, in the order they are offered. Here rather than in the view because which
/// card comes next is a rule about the user's answers, not about SwiftUI.
public enum OnboardingStep: Int, CaseIterable, Comparable, Sendable {
    case welcome, permission, launch, tutorial

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public var symbol: String {
        switch self {
        case .welcome: "point.3.connected.trianglepath.dotted"
        case .permission: "hand.point.up.left.and.text"
        case .launch: "power"
        case .tutorial: "graduationcap"
        }
    }

    public var titleKey: String.LocalizationValue {
        switch self {
        case .welcome: "onboarding.welcome.title"
        case .permission: "onboarding.permission.title"
        case .launch: "onboarding.launch.title"
        case .tutorial: "tutorial.title"
        }
    }

    public var messageKey: String.LocalizationValue {
        switch self {
        case .welcome: "onboarding.welcome.message"
        case .permission: "onboarding.permission.message"
        case .launch: "onboarding.launch.message"
        case .tutorial: "tutorial.message"
        }
    }

    /// The tutorial's headline counts the ways in, and only one of the three survives without the
    /// Accessibility grant, so the card would otherwise promise "all three" directly above a single
    /// clipboard row. Every other card's copy is the same either way.
    public func titleKey(allLessonsAvailable: Bool) -> String.LocalizationValue {
        guard self == .tutorial, !allLessonsAvailable else { return titleKey }
        return "tutorial.title.one"
    }

    public func messageKey(allLessonsAvailable: Bool) -> String.LocalizationValue {
        guard self == .tutorial, !allLessonsAvailable else { return messageKey }
        return "tutorial.message.one"
    }

    /// Continue from the welcome card. A permission question that already has an answer is stepped
    /// over rather than walked into again: a user who has just refused it reads being shown it once
    /// more as not having been heard.
    public static func afterWelcome(permissionSettled: Bool) -> Self {
        permissionSettled ? .launch : .permission
    }

    /// Back. Only the login card has a decision to make. A decline has to stay reachable — it is the
    /// one answer a user can give by accident, and Back is the whole of the undo — while a grant has
    /// nothing left to revisit, and the permission card's own poll would push a granted user
    /// straight forward again.
    public func previous(accessibilityGranted: Bool) -> Self {
        switch self {
        case .tutorial: .launch
        case .launch: accessibilityGranted ? .welcome : .permission
        case .permission, .welcome: .welcome
        }
    }

    /// The dots in the header, which have to count the cards this run will actually visit: a
    /// settled permission question is stepped over going forward, and drawing its dot leaves the
    /// last card looking like there is still one to come. It reappears while the user is standing on
    /// it, which is the only way back into that question.
    public static func visible(permissionSettled: Bool, current: Self) -> [Self] {
        allCases.filter { $0 != .permission || !permissionSettled || current == .permission }
    }
}
