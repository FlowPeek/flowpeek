import XCTest
@testable import FlowPeekCore

final class OnboardingPolicyTests: XCTestCase {
    func testMissingPermissionShowsOnboardingEvenWhenItWasPreviouslyCompleted() {
        XCTAssertTrue(
            OnboardingPolicy.shouldShow(
                accessibilityGranted: false,
                onboardingCompleted: true,
                permissionDeclined: false,
                forceOnboarding: false
            )
        )
    }

    func testGrantedPermissionSkipsCompletedOnboarding() {
        XCTAssertFalse(
            OnboardingPolicy.shouldShow(
                accessibilityGranted: true,
                onboardingCompleted: true,
                permissionDeclined: false,
                forceOnboarding: false
            )
        )
    }

    func testForcedOnboardingIsAlwaysShown() {
        XCTAssertTrue(
            OnboardingPolicy.shouldShow(
                accessibilityGranted: true,
                onboardingCompleted: true,
                permissionDeclined: false,
                forceOnboarding: true
            )
        )
    }

    /// The whole point of the decline button: it has to survive a relaunch, or it is cosmetic.
    func testDecliningThePermissionStopsTheWindowComingBack() {
        XCTAssertFalse(
            OnboardingPolicy.shouldShow(
                accessibilityGranted: false,
                onboardingCompleted: true,
                permissionDeclined: true,
                forceOnboarding: false
            )
        )
    }

    /// Declining mid-flow is not finishing: the launch and tutorial steps have not been answered.
    func testDecliningBeforeFinishingStillShowsOnboarding() {
        XCTAssertTrue(
            OnboardingPolicy.shouldShow(
                accessibilityGranted: false,
                onboardingCompleted: false,
                permissionDeclined: true,
                forceOnboarding: false
            )
        )
    }

    func testForcedOnboardingOverridesADecline() {
        XCTAssertTrue(
            OnboardingPolicy.shouldShow(
                accessibilityGranted: false,
                onboardingCompleted: true,
                permissionDeclined: true,
                forceOnboarding: true
            )
        )
        // The half that makes the assertion above mean something: these are answers that stay quiet
        // on their own, so the flag is what reopened the window.
        XCTAssertFalse(
            OnboardingPolicy.shouldShow(
                accessibilityGranted: false,
                onboardingCompleted: true,
                permissionDeclined: true,
                forceOnboarding: false
            )
        )
    }

    /// Quitting with the card open has to count, or the user who granted permission and closed the
    /// lid is met by the whole wizard again.
    func testEitherAnswerToThePermissionQuestionFinishesSetup() {
        XCTAssertTrue(
            OnboardingPolicy.completionAfterDismissal(
                wasCompleted: false,
                accessibilityGranted: true,
                permissionDeclined: false
            )
        )
        XCTAssertTrue(
            OnboardingPolicy.completionAfterDismissal(
                wasCompleted: false,
                accessibilityGranted: false,
                permissionDeclined: true
            )
        )
    }

    /// "I'll decide later" is not an answer, so the offer has to survive the window closing.
    func testLeavingThePermissionQuestionUnansweredDoesNotFinishSetup() {
        XCTAssertFalse(
            OnboardingPolicy.completionAfterDismissal(
                wasCompleted: false,
                accessibilityGranted: false,
                permissionDeclined: false
            )
        )
    }

    /// Reopening the wizard from the menu bar and closing it again must not cost a finished user
    /// their quiet launches: whoever writes the flag writes this answer, so it can only ever add.
    func testAnAlreadyFinishedSetupSurvivesADismissalWithNothingAnswered() {
        XCTAssertTrue(
            OnboardingPolicy.completionAfterDismissal(
                wasCompleted: true,
                accessibilityGranted: false,
                permissionDeclined: false
            )
        )
    }

    /// The pair that makes the rest of this suite mean something: the flag the dismissal writes is
    /// exactly the one that decides whether the next launch is quiet.
    func testFinishingWithAnAnswerIsWhatStopsTheNextLaunchOfferingTheWizard() {
        for granted in [true, false] {
            let completed = OnboardingPolicy.completionAfterDismissal(
                wasCompleted: false,
                accessibilityGranted: granted,
                permissionDeclined: !granted
            )
            XCTAssertTrue(completed)
            XCTAssertFalse(
                OnboardingPolicy.shouldShow(
                    accessibilityGranted: granted,
                    onboardingCompleted: completed,
                    permissionDeclined: !granted,
                    forceOnboarding: false
                )
            )
        }
        // And unanswered stays offered, whether or not the window was dismissed.
        let unanswered = OnboardingPolicy.completionAfterDismissal(
            wasCompleted: false,
            accessibilityGranted: false,
            permissionDeclined: false
        )
        XCTAssertTrue(
            OnboardingPolicy.shouldShow(
                accessibilityGranted: false,
                onboardingCompleted: unanswered,
                permissionDeclined: false,
                forceOnboarding: false
            )
        )
    }
}

final class OnboardingStepTests: XCTestCase {
    func testTheUnansweredPermissionQuestionIsTheFirstStopAfterWelcome() {
        XCTAssertEqual(OnboardingStep.afterWelcome(permissionSettled: false), .permission)
    }

    func testAnAnsweredPermissionQuestionIsSteppedOverGoingForward() {
        XCTAssertEqual(OnboardingStep.afterWelcome(permissionSettled: true), .launch)
    }

    /// The undo for "Continue Without It", which is the one answer a user can give by accident.
    /// Sending Back to the welcome card instead left the decline unreachable from the wizard.
    func testBackFromTheLoginStepReturnsToADeclinedPermissionQuestion() {
        XCTAssertEqual(OnboardingStep.launch.previous(accessibilityGranted: false), .permission)
    }

    /// A grant has nothing to revisit, and the permission step's own poll would push a granted user
    /// straight forward again, so Back would do nothing visible.
    func testBackFromTheLoginStepSkipsAGrantedPermissionQuestion() {
        XCTAssertEqual(OnboardingStep.launch.previous(accessibilityGranted: true), .welcome)
    }

    func testBackWalksTheRestOfTheFlowInOrder() {
        XCTAssertEqual(OnboardingStep.tutorial.previous(accessibilityGranted: true), .launch)
        XCTAssertEqual(OnboardingStep.permission.previous(accessibilityGranted: false), .welcome)
        XCTAssertEqual(OnboardingStep.welcome.previous(accessibilityGranted: false), .welcome)
    }

    func testTheHeaderCountsEveryStepWhilePermissionIsStillOpen() {
        XCTAssertEqual(
            OnboardingStep.visible(accessibilityGranted: false, current: .welcome),
            [.welcome, .permission, .launch, .tutorial]
        )
    }

    /// The dot for a step this run will not visit reads as one more card still to come.
    func testTheHeaderDropsTheStepItIsGoingToSkip() {
        XCTAssertEqual(
            OnboardingStep.visible(accessibilityGranted: true, current: .tutorial),
            [.welcome, .launch, .tutorial]
        )
    }

    func testTheSkippedStepGetsItsDotBackWhileTheUserStandsOnIt() {
        XCTAssertEqual(
            OnboardingStep.visible(accessibilityGranted: true, current: .permission),
            [.welcome, .permission, .launch, .tutorial]
        )
    }

    /// A refused permission question keeps its dot even though the flow steps over it going
    /// forward, because Back still walks into it: dropping the dot would grow a capsule under the
    /// user's hand as they press Back, and jump the count from three to four.
    func testTheRefusedPermissionQuestionKeepsItsDotBecauseBackStillReachesIt() {
        XCTAssertEqual(
            OnboardingStep.visible(accessibilityGranted: false, current: .launch),
            [.welcome, .permission, .launch, .tutorial]
        )
    }

    /// The invariant behind both rules: the header cannot leave out a card the user is standing on
    /// or is one Back away from, whatever they answered.
    func testTheHeaderAlwaysHasADotForWhereTheUserIsAndWhereBackGoes() {
        for granted in [true, false] {
            for step in OnboardingStep.allCases {
                let dots = OnboardingStep.visible(accessibilityGranted: granted, current: step)
                XCTAssertTrue(dots.contains(step), "\(step) with granted=\(granted)")
                XCTAssertTrue(
                    dots.contains(step.previous(accessibilityGranted: granted)),
                    "back from \(step) with granted=\(granted)"
                )
            }
        }
    }

    /// "Try All Three" above a single clipboard row is copy the card itself contradicts.
    func testTheTutorialHeadlineCountsOnlyTheLessonsOnOffer() {
        XCTAssertEqual(OnboardingStep.tutorial.titleKey(allLessonsAvailable: true), "tutorial.title")
        XCTAssertEqual(OnboardingStep.tutorial.titleKey(allLessonsAvailable: false), "tutorial.title.one")
        XCTAssertEqual(OnboardingStep.tutorial.messageKey(allLessonsAvailable: true), "tutorial.message")
        XCTAssertEqual(OnboardingStep.tutorial.messageKey(allLessonsAvailable: false), "tutorial.message.one")
    }

    func testEveryOtherStepReadsTheSameHoweverManyLessonsThereAre() {
        for step in OnboardingStep.allCases where step != .tutorial {
            XCTAssertEqual(step.titleKey(allLessonsAvailable: false), step.titleKey)
            XCTAssertEqual(step.messageKey(allLessonsAvailable: false), step.messageKey)
        }
    }
}

/// The wizard's answer is written when it goes away, and quitting with it still on screen is one of
/// the ways it goes away. Driven through a notification centre of this test's own, so the real
/// application's termination notice is never involved.
@MainActor
final class OnboardingQuitGuardTests: XCTestCase {
    private let quit = Notification.Name("OnboardingQuitGuardTests.quit")

    private func makeGuard(_ center: NotificationCenter, recording: @escaping () -> Void) -> OnboardingQuitGuard {
        OnboardingQuitGuard(center: center, quitNotification: quit, record: recording)
    }

    /// The whole reason the hook exists: granting permission, ticking a lesson and quitting for the
    /// day used to record nothing, so the entire flow was waiting again at the next launch.
    func testQuittingWithTheCardStillOpenRecordsWhatTheUserGotThrough() {
        let center = NotificationCenter()
        var records = 0
        let hook = makeGuard(center) { records += 1 }

        hook.windowOpened()
        XCTAssertTrue(hook.isWatchingForQuit)
        center.post(name: quit, object: nil)

        XCTAssertEqual(records, 1)
    }

    /// Nothing listens before the window is up: a quit during an ordinary session must not answer a
    /// question the user was never shown.
    func testQuittingWithNoCardOnScreenWritesNothing() {
        let center = NotificationCenter()
        var records = 0
        let hook = makeGuard(center) { records += 1 }

        XCTAssertFalse(hook.isWatchingForQuit)
        center.post(name: quit, object: nil)

        XCTAssertEqual(records, 0)
    }

    /// Closing is the ordinary exit and records on its own; the quit notice covers the other one,
    /// and is not this one's backstop.
    func testClosingTheCardRecordsTheAnswerItself() {
        let center = NotificationCenter()
        var records = 0
        let hook = makeGuard(center) { records += 1 }

        hook.windowOpened()
        hook.windowClosed()

        XCTAssertEqual(records, 1)
        XCTAssertFalse(hook.isWatchingForQuit)
    }

    /// And having recorded it, it stops listening: a wizard dismissed hours ago must not answer for
    /// the user a second time whenever they eventually quit.
    func testAQuitLongAfterTheCardIsGoneWritesNothingMore() {
        let center = NotificationCenter()
        var records = 0
        let hook = makeGuard(center) { records += 1 }

        hook.windowOpened()
        hook.windowClosed()
        center.post(name: quit, object: nil)

        XCTAssertEqual(records, 1)
    }

    /// Asking for the tutorial while the setup card is up rebuilds the window rather than
    /// re-pointing it, so the same guard is opened twice. One listener, or the quit records twice
    /// and the second registration is one nothing holds a token for.
    func testReopeningTheWindowLeavesOnlyOneListenerBehind() {
        let center = NotificationCenter()
        var records = 0
        let hook = makeGuard(center) { records += 1 }

        hook.windowOpened()
        hook.windowOpened()
        center.post(name: quit, object: nil)

        XCTAssertEqual(records, 1)
    }
}
