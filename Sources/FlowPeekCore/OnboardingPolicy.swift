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
}
