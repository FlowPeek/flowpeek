import XCTest
@testable import FlowPeekCore

final class ShortcutActivationPolicyTests: XCTestCase {
    private func active(
        isEnabled: Bool = true,
        clipboard: Bool = true,
        ai: Bool = false,
        ambient: Bool = false,
        accessibility: Bool = true,
        history: Bool = true
    ) -> Set<FlowPeekShortcutAction> {
        ShortcutActivationPolicy.activeActions(
            isEnabled: isEnabled,
            clipboardWatchEnabled: clipboard,
            aiEnabled: ai,
            ambientPeekEnabled: ambient,
            accessibilityGranted: accessibility,
            historyEnabled: history
        )
    }

    /// The shipped defaults: AI is off, so ⌥⌘M must stay with whatever app the user is in.
    func testTheAIShortcutIsDormantUntilTheExperimentIsOn() {
        XCTAssertEqual(active(), [.previewClipboard, .history])
        XCTAssertEqual(active(ai: true), [.previewClipboard, .aiPrompt, .history])
    }

    func testEachShortcutFollowsItsOwnFeature() {
        XCTAssertEqual(active(clipboard: false, ai: true), [.aiPrompt, .history])
        // The shelf follows the history rather than a detection route, so with every route off it
        // is the one combination still worth holding.
        XCTAssertEqual(active(clipboard: false), [.history])
    }

    /// Nothing to open: with the remembering switched off there is no shelf, so the chord goes back
    /// to whatever app the user is in.
    func testTheShelfChordIsDormantWhenNothingIsRemembered() {
        XCTAssertFalse(active(clipboard: false, history: false).contains(.history))
    }

    /// Pausing detection from the menu bar gives every combination back.
    func testPausingTheAppReleasesEverything() {
        XCTAssertTrue(active(isEnabled: false, clipboard: true, ai: true, ambient: true).isEmpty)
    }

    /// ⌥Space is a character people type, and a registered hot key is consumed system-wide, so it
    /// is only claimed while the hold-to-peek experiment is switched on.
    func testThePeekChordIsDormantUntilHoldToPeekIsOn() {
        XCTAssertFalse(active().contains(.ambientPeek))
        XCTAssertTrue(active(ambient: true).contains(.ambientPeek))
    }

    /// Pointing reads the accessibility tree. Without the grant no outline can appear, so holding
    /// the chord would take ⌥Space away from every other app and do nothing with it.
    func testThePeekChordIsDormantWithoutTheAccessibilityGrant() {
        XCTAssertFalse(active(ambient: true, accessibility: false).contains(.ambientPeek))
        XCTAssertEqual(active(clipboard: false, ambient: true, accessibility: false), [.history])
    }
}
