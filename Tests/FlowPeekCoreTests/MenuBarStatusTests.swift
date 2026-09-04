import XCTest
@testable import FlowPeekCore

final class MenuBarStatusTests: XCTestCase {
    private func status(
        engineUsable: Bool = true,
        granted: Bool = true,
        declined: Bool = false,
        isEnabled: Bool = true
    ) -> MenuBarStatus {
        MenuBarStatus.resolve(
            engineUsable: engineUsable,
            accessibilityGranted: granted,
            permissionDeclined: declined,
            isEnabled: isEnabled
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

    /// Nothing renders while the canary fails, so the engine outranks both the grant and the pause.
    func testABrokenEngineOutranksEverythingElse() {
        XCTAssertEqual(status(engineUsable: false), .engineBroken)
        XCTAssertEqual(status(engineUsable: false, granted: false), .engineBroken)
        XCTAssertEqual(status(engineUsable: false, declined: true, isEnabled: false), .engineBroken)
    }

    /// A grant that disappeared is news; the pause is not, and its remedy is one row away.
    func testAMissingGrantOutranksThePause() {
        XCTAssertEqual(status(granted: false, isEnabled: false), .permissionMissing)
    }

    /// The defect this type exists for was one glyph for every state, so two states sharing a
    /// symbol would put it straight back.
    func testEveryStateDrawsItsOwnGlyph() {
        let symbols = MenuBarStatus.allCases.map(\.symbolName)
        XCTAssertEqual(Set(symbols).count, MenuBarStatus.allCases.count, "two statuses share a symbol")
        XCTAssertFalse(symbols.contains(where: \.isEmpty))
    }
}
