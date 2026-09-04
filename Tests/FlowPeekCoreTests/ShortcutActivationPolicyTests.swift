import XCTest
@testable import FlowPeekCore

final class ShortcutActivationPolicyTests: XCTestCase {
    private func active(
        isEnabled: Bool = true,
        clipboard: Bool = true,
        ai: Bool = false
    ) -> Set<FlowPeekShortcutAction> {
        ShortcutActivationPolicy.activeActions(
            isEnabled: isEnabled,
            clipboardWatchEnabled: clipboard,
            aiEnabled: ai
        )
    }

    /// The shipped defaults: AI is off, so ⌥⌘M must stay with whatever app the user is in.
    func testTheAIShortcutIsDormantUntilTheExperimentIsOn() {
        XCTAssertEqual(active(), [.previewClipboard])
        XCTAssertEqual(active(ai: true), [.previewClipboard, .aiPrompt])
    }

    func testEachShortcutFollowsItsOwnFeature() {
        XCTAssertEqual(active(clipboard: false, ai: true), [.aiPrompt])
        XCTAssertTrue(active(clipboard: false).isEmpty)
    }

    /// Pausing detection from the menu bar gives every combination back.
    func testPausingTheAppReleasesEverything() {
        XCTAssertTrue(active(isEnabled: false, clipboard: true, ai: true).isEmpty)
    }
}
