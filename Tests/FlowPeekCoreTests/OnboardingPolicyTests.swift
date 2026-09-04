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
    }
}
