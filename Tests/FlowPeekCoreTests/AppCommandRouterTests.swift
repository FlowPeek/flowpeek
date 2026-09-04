import XCTest
@testable import FlowPeekCore

final class AppCommandRouterTests: XCTestCase {
    func testSettingsCommandUsesTheExplicitSettingsPresenter() {
        var presented = false
        let router = AppCommandRouter(showSettings: { presented = true })

        router.handle(.showSettings)

        XCTAssertTrue(presented)
    }
}
