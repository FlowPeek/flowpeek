public enum OnboardingPolicy {
    public static func shouldShow(
        accessibilityGranted: Bool,
        onboardingCompleted: Bool,
        forceOnboarding: Bool
    ) -> Bool {
        forceOnboarding || !accessibilityGranted || !onboardingCompleted
    }
}
