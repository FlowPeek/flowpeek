import XCTest
@testable import FlowPeekCore

final class AppCommandRouterTests: XCTestCase {
    private func router(
        settings: @escaping () -> Void = { XCTFail("the settings presenter was not asked for") },
        preview: @escaping () -> Void = { XCTFail("the preview presenter was not asked for") }
    ) -> AppCommandRouter {
        AppCommandRouter(showSettings: settings, revealPreview: preview)
    }

    func testSettingsCommandUsesTheExplicitSettingsPresenter() {
        var presented = false

        router(settings: { presented = true }).handle(.showSettings)

        XCTAssertTrue(presented)
    }

    /// The way back to a preview window that another app has covered. Its own presenter, so the
    /// menu-bar entry cannot end up opening Settings instead.
    func testRevealPreviewCommandUsesTheExplicitPreviewPresenter() {
        var revealed = false

        router(preview: { revealed = true }).handle(.revealPreview)

        XCTAssertTrue(revealed)
    }
}
