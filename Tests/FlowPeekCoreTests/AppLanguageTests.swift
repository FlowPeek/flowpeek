import XCTest
@testable import FlowPeekCore

final class AppLanguageTests: XCTestCase {
    func testSystemMeansNoStoredOverride() {
        XCTAssertNil(AppLanguage.system.localeIdentifier)
        XCTAssertNil(AppLanguage.system.storedValue)
    }

    func testEachLanguageStoresASingleIdentifier() {
        XCTAssertEqual(AppLanguage.english.storedValue, ["en"])
        XCTAssertEqual(AppLanguage.korean.storedValue, ["ko"])
    }

    func testStoredReadsBackWhatWeWrote() {
        for language in AppLanguage.allCases {
            XCTAssertEqual(AppLanguage.stored(in: language.storedValue), language)
        }
    }

    /// macOS writes this key itself, with a region suffix and often several entries.
    func testARegionQualifiedValueStillResolvesToItsBaseLanguage() {
        XCTAssertEqual(AppLanguage.stored(in: ["ko-KR"]), .korean)
        XCTAssertEqual(AppLanguage.stored(in: ["en-US", "ko-KR"]), .english)
    }

    func testAnUnsupportedOrEmptyValueIsReportedAsSystemRatherThanGuessed() {
        XCTAssertEqual(AppLanguage.stored(in: ["ja"]), .system)
        XCTAssertEqual(AppLanguage.stored(in: []), .system)
        XCTAssertEqual(AppLanguage.stored(in: nil), .system)
    }

    // MARK: - The app's own override

    private func scratchDefaults(_ name: String) throws -> (UserDefaults, String) {
        let domain = "com.flowpeek.tests.\(name)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: domain) }
        return (defaults, domain)
    }

    func testNoOverrideInTheAppsOwnDomainMeansSystem() throws {
        let (defaults, domain) = try scratchDefaults("empty")
        XCTAssertEqual(AppLanguage.storedOverride(in: defaults, bundleIdentifier: domain), .system)
    }

    func testAnOverrideInTheAppsOwnDomainIsReadBack() throws {
        let (defaults, domain) = try scratchDefaults("override")
        defaults.set(AppLanguage.korean.storedValue, forKey: AppLanguage.defaultsKey)
        XCTAssertEqual(AppLanguage.storedOverride(in: defaults, bundleIdentifier: domain), .korean)

        defaults.removeObject(forKey: AppLanguage.defaultsKey)
        XCTAssertEqual(AppLanguage.storedOverride(in: defaults, bundleIdentifier: domain), .system)
    }

    /// The regression that made the picker lie: `AppleLanguages` reaches a plain read from a domain
    /// the app never wrote, so a search-list read cannot tell "no override" from "override = the OS
    /// language". Registration is the one such domain a test can write; the global domain, which
    /// already defines this key on a configured Mac and may win over this one, behaves identically —
    /// reachable through the app's defaults, absent from its own persistent domain.
    func testALanguageReachableOnlyThroughTheSearchListIsNotAnOverride() throws {
        let (defaults, domain) = try scratchDefaults("search-list")
        defaults.register(defaults: [AppLanguage.defaultsKey: ["en-US"]])

        XCTAssertNotNil(defaults.stringArray(forKey: AppLanguage.defaultsKey))
        XCTAssertEqual(AppLanguage.storedOverride(in: defaults, bundleIdentifier: domain), .system)
    }

    func testAMissingBundleIdentifierIsReportedAsSystem() {
        XCTAssertEqual(AppLanguage.storedOverride(bundleIdentifier: nil), .system)
    }
}
