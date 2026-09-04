import XCTest
@testable import FlowPeekCore

final class MenuBarStatusTests: XCTestCase {
    private func status(
        engineUsable: Bool = true,
        granted: Bool = true,
        declined: Bool = false,
        isEnabled: Bool = true,
        clipboardWatch: Bool = true
    ) -> MenuBarStatus {
        MenuBarStatus.resolve(
            engineUsable: engineUsable,
            accessibilityGranted: granted,
            permissionDeclined: declined,
            isEnabled: isEnabled,
            clipboardWatchEnabled: clipboardWatch
        )
    }

    func testAWorkingAppIsArmed() {
        XCTAssertEqual(status(), .armed)
    }

    /// The state the user put the app in themselves, from the toggle in this very menu.
    func testPausingDetectionShowsAsPaused() {
        XCTAssertEqual(status(isEnabled: false), .paused)
    }

    /// The revoked-mid-session case: two of the three routes are switched off and until now the
    /// icon looked exactly as it does when everything works.
    func testAMissingGrantIsCalledOut() {
        XCTAssertEqual(status(granted: false), .permissionMissing)
    }

    /// Someone who answered "continue without it" has the app they asked for, so the icon must not
    /// wear a permanent warning badge for a switch they deliberately left off.
    func testADeclinedGrantIsNotAWarning() {
        XCTAssertEqual(status(granted: false, declined: true), .armed)
        XCTAssertEqual(status(granted: false, declined: true, isEnabled: false), .paused)
    }

    /// Silence about the grant is not a licence to claim the app is watching. With no grant the
    /// selection button and the Option-hover outline are both impossible, so the clipboard watch is
    /// the only route left — and switched off, "Ready — watching for diagrams" describes nothing
    /// that is happening.
    func testADeclinerWithTheClipboardWatchOffIsNotCalledReady() {
        XCTAssertEqual(status(granted: false, declined: true, clipboardWatch: false), .nothingWatched)
    }

    /// The grant is what makes the other two routes possible, so it settles the question on its own.
    func testTheGrantAloneIsEnoughToBeWatching() {
        XCTAssertEqual(status(clipboardWatch: false), .armed)
    }

    /// An unanswered permission question is the more useful of the two things to say, and it is the
    /// one with a button beside it.
    func testAnUnansweredGrantOutranksTheEmptyWatch() {
        XCTAssertEqual(status(granted: false, clipboardWatch: false), .permissionMissing)
    }

    /// The pause is the user's own doing and undoing it is one row away; it says more than the
    /// bookkeeping about which routes would then be live.
    func testThePauseOutranksTheEmptyWatch() {
        XCTAssertEqual(status(granted: false, declined: true, isEnabled: false, clipboardWatch: false), .paused)
    }

    /// Nothing renders while the canary fails, so the engine outranks both the grant and the pause.
    func testABrokenEngineOutranksEverythingElse() {
        XCTAssertEqual(status(engineUsable: false), .engineBroken)
        XCTAssertEqual(status(engineUsable: false, granted: false), .engineBroken)
        XCTAssertEqual(status(engineUsable: false, declined: true, isEnabled: false), .engineBroken)
        XCTAssertEqual(status(engineUsable: false, declined: true, clipboardWatch: false), .engineBroken)
    }

    /// A grant that disappeared is news; the pause is not, and its remedy is one row away.
    func testAMissingGrantOutranksThePause() {
        XCTAssertEqual(status(granted: false, isEnabled: false), .permissionMissing)
    }

    /// The icon is one glyph wide, so two states sharing a symbol are indistinguishable to the only
    /// person who reads it.
    func testEveryStateDrawsItsOwnGlyph() {
        let symbols = MenuBarStatus.allCases.map(\.symbolName)
        XCTAssertEqual(Set(symbols).count, MenuBarStatus.allCases.count, "two statuses share a symbol")
        XCTAssertFalse(symbols.contains(where: \.isEmpty))
    }
}
