import XCTest
@testable import FlowPeekCore

final class OnboardingPolicyTests: XCTestCase {
    func testMissingPermissionShowsOnboardingEvenWhenItWasPreviouslyCompleted() {
        XCTAssertTrue(
            OnboardingPolicy.shouldShow(
                accessibilityGranted: false,
                onboardingCompleted: true,
                forceOnboarding: false
            )
        )
    }

    func testGrantedPermissionSkipsCompletedOnboarding() {
        XCTAssertFalse(
            OnboardingPolicy.shouldShow(
                accessibilityGranted: true,
                onboardingCompleted: true,
                forceOnboarding: false
            )
        )
    }

    func testForcedOnboardingIsAlwaysShown() {
        XCTAssertTrue(
            OnboardingPolicy.shouldShow(
                accessibilityGranted: true,
                onboardingCompleted: true,
                forceOnboarding: true
            )
        )
    }
}
