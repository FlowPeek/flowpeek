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
            OnboardingPolicy.recordsCompletion(accessibilityGranted: true, permissionDeclined: false)
        )
        XCTAssertTrue(
            OnboardingPolicy.recordsCompletion(accessibilityGranted: false, permissionDeclined: true)
        )
    }

    func testLeavingThePermissionQuestionUnansweredDoesNotFinishSetup() {
        XCTAssertFalse(
            OnboardingPolicy.recordsCompletion(accessibilityGranted: false, permissionDeclined: false)
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
            OnboardingStep.visible(permissionSettled: false, current: .welcome),
            [.welcome, .permission, .launch, .tutorial]
        )
    }

    /// The dot for a step this run will not visit reads as one more card still to come.
    func testTheHeaderDropsTheStepItIsGoingToSkip() {
        XCTAssertEqual(
            OnboardingStep.visible(permissionSettled: true, current: .tutorial),
            [.welcome, .launch, .tutorial]
        )
    }

    func testTheSkippedStepGetsItsDotBackWhileTheUserStandsOnIt() {
        XCTAssertEqual(
            OnboardingStep.visible(permissionSettled: true, current: .permission),
            [.welcome, .permission, .launch, .tutorial]
        )
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
