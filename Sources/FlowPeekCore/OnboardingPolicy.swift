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

    /// What the completion flag reads after the wizard goes away, whichever way it went: Escape,
    /// the ✕, or quitting with the card still open. Answering the permission question, either way,
    /// is the whole of finishing — the tutorial is practice, not a gate — because otherwise a user
    /// who granted permission and quit for the day is met by the whole flow again at the next
    /// launch, which is the nag their answer was supposed to end. Leaving it unanswered is what
    /// earns the second offer, so "I'll decide later" still works and only "I decided" sticks.
    /// A run that was already recorded stays recorded: a dismissal can add a completion and never
    /// take one back, or an already-finished user who reopens the wizard from the menu and closes
    /// it again would have their quiet launches taken away.
    public static func completionAfterDismissal(
        wasCompleted: Bool,
        accessibilityGranted: Bool,
        permissionDeclined: Bool
    ) -> Bool {
        wasCompleted || accessibilityGranted || permissionDeclined
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

    /// The dots in the header, which have to count the cards this run can actually visit: a granted
    /// permission question is stepped over going forward and has nothing to come back to, so drawing
    /// its dot leaves the last card looking like there is still one to come. A refused one keeps its
    /// dot, because `previous` still walks back into it — a row that grows a capsule under the
    /// user's hand as they press Back is worse than a card they were never going to see.
    public static func visible(accessibilityGranted: Bool, current: Self) -> [Self] {
        allCases.filter { $0 != .permission || !accessibilityGranted || current == .permission }
    }
}

/// Keeps `completionAfterDismissal` honest for the one exit AppKit does not announce: the user
/// quits with the card still on screen. The wizard's window is borderless, so its close path is
/// never taken and the process is torn down with the answer unwritten — a user who granted
/// permission, ticked a lesson or two and quit for the day was then met by the whole flow again at
/// the next launch. So the window arms a listener for the quit while it is up and hands it back the
/// moment it goes away, and everything about that bookkeeping lives here rather than beside the
/// AppKit window it belongs to, where nothing can reach it.
@MainActor
public final class OnboardingQuitGuard {
    private let center: NotificationCenter
    private let quitNotification: Notification.Name
    private let record: () -> Void
    private var observer: (any NSObjectProtocol)?

    /// True exactly while a quit would still be recorded.
    public var isWatchingForQuit: Bool { observer != nil }

    public init(
        center: NotificationCenter = .default,
        quitNotification: Notification.Name,
        record: @escaping () -> Void
    ) {
        self.center = center
        self.quitNotification = quitNotification
        self.record = record
    }

    /// Idempotent, because the window is rebuilt rather than re-pointed whenever the menu opens it
    /// by the other door: a second listener would write the same answer twice on the way out and,
    /// worse, outlive the token the first one was remembered by.
    public func windowOpened() {
        guard observer == nil else { return }
        observer = center.addObserver(forName: quitNotification, object: nil, queue: nil) { [weak self] _ in
            // Synchronous rather than a `Task`: the app is already on its way out and a hop to the
            // next main-actor turn would never run. `queue: nil` is the delivery that promises that
            // — the block runs on the thread that posted the notification, which for a termination
            // notice is the main one, so the isolation assumption holds too. Handing it a queue
            // instead would be free to enqueue the block for a turn that never comes.
            MainActor.assumeIsolated { self?.record() }
        }
    }

    /// Records, then stops listening: a wizard that is already gone must not write anything again
    /// at the next quit, whenever that happens to be.
    public func windowClosed() {
        record()
        guard let observer else { return }
        center.removeObserver(observer)
        self.observer = nil
    }
}
