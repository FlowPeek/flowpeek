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
}
