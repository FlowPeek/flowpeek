import FlowPeekCore
import XCTest

@testable import FlowPeek

/// What the status item is actually drawn from. `MenuBarStatus.resolve` is pure and covered in the
/// core tests; what only the app can answer is whether the published value moves when the user
/// changes one of its inputs — `isEnabled` and `permissionDeclined` are both `@AppStorage`, which
/// publishes nothing from inside a class, so nothing but an explicit refresh keeps the icon honest.
@MainActor
final class MenuBarStatusRoutingTests: XCTestCase {
    /// The switches live in the app's own defaults domain and the grant belongs to the machine, so a
    /// case puts both back. It starts from an app that is watching: detection on, clipboard watch
    /// on, the permission question answered. Written as a wrapper rather than as `setUp`, which
    /// XCTest declares outside the main actor.
    private func watching(_ body: () throws -> Void) throws {
        let app = AppState.shared
        // A broken engine outranks everything else, and the engine belongs to the test host rather
        // than to the case: with the canary failing there is nothing here left to observe.
        try XCTSkipIf(app.engineHealth?.isUsable == false, "the host's diagram engine cannot draw")
        let enabled = app.isEnabled
        let declined = app.permissionDeclined
        let watch = app.clipboardWatchEnabled
        defer {
            app.isEnabled = enabled
            app.permissionDeclined = declined
            app.clipboardWatchEnabled = watch
            // Back to what the machine actually reports, monitors and poll cadence included.
            app.refreshPermission()
            app.permissionAnswerDidChange()
            app.applyEnabledState()
        }
        app.permissionDeclined = true
        app.clipboardWatchEnabled = true
        app.isEnabled = true
        app.applyEnabledState()
        try body()
    }

    /// The menu's own toggle does exactly this. Without the refresh on this path the icon would go
    /// on drawing "watching for diagrams" over an app that has stopped watching.
    func testPausingDetectionMovesTheStatusTheIconIsDrawnFrom() throws {
        try watching {
            let app = AppState.shared
            XCTAssertEqual(app.menuBarStatus, .armed)

            app.isEnabled = false
            app.applyEnabledState()

            XCTAssertEqual(app.menuBarStatus, .paused)
            XCTAssertEqual(app.menuBarStatus.symbolName, "pause.circle")
        }
    }

    /// What the menu's switch now calls, and all it calls. The rows of a `.menu`-style MenuBarExtra
    /// are NSMenu items, so the view modifier that used to carry the second half of the click runs
    /// only while SwiftUI re-renders the row: everything the pause has to do lives on one call the
    /// setter makes itself.
    func testThePauseSwitchStopsTheWatchAndMovesTheIconInOneCall() throws {
        try watching {
            let app = AppState.shared
            XCTAssertTrue(app.clipboard.isRunning)

            app.setDetectionEnabled(false)

            XCTAssertEqual(app.menuBarStatus, .paused)
            XCTAssertFalse(app.clipboard.isRunning, "a paused app was still polling the pasteboard")

            app.setDetectionEnabled(true)

            XCTAssertEqual(app.menuBarStatus, .armed)
            XCTAssertTrue(app.clipboard.isRunning)
        }
    }

    /// Switching the last live route off is the case the "Ready" line used to survive: with no grant
    /// the selection button and the Option-hover outline are both impossible, so the clipboard watch
    /// is all that is left, and off it leaves nothing at all being watched.
    func testTurningOffTheLastRouteIsNotStillCalledReady() throws {
        try watching {
            let app = AppState.shared
            app.updateAccessibilityState(false)
            XCTAssertEqual(app.menuBarStatus, .armed, "the decline is what keeps the icon calm here")

            app.clipboardWatchEnabled = false
            app.applyEnabledState()

            XCTAssertEqual(app.menuBarStatus, .nothingWatched)
        }
    }

    /// The answer to the permission question is a click, and the poll that would otherwise notice it
    /// runs every three seconds — which is also three seconds of the wrong glyph. A decline is an
    /// answer too, so it settles the cadence as well: no tccd round-trip on the main actor every
    /// three seconds for someone who is not waiting for a switch to take effect.
    func testAnsweringThePermissionQuestionIsNoticedWithoutWaitingForThePoll() throws {
        try watching {
            let app = AppState.shared
            app.updateAccessibilityState(false)

            app.permissionDeclined = false
            app.permissionAnswerDidChange()
            XCTAssertEqual(app.menuBarStatus, .permissionMissing)
            XCTAssertEqual(app.permissionPollInterval, 3)

            app.permissionDeclined = true
            app.permissionAnswerDidChange()
            XCTAssertEqual(app.menuBarStatus, .armed)
            XCTAssertEqual(app.permissionPollInterval, 10)
        }
    }

    /// A grant that goes away while the app runs, and one that comes back: macOS posts nothing an
    /// app may rely on for either, and both used to be invisible until the next launch.
    func testAGrantThatGoesAwayAndComesBackIsNoticedBothWays() throws {
        try watching {
            let app = AppState.shared
            app.permissionDeclined = false

            app.updateAccessibilityState(true)
            XCTAssertEqual(app.menuBarStatus, .armed)
            XCTAssertEqual(app.permissionPollInterval, 10)

            app.updateAccessibilityState(false)
            XCTAssertEqual(app.menuBarStatus, .permissionMissing)
            XCTAssertEqual(app.menuBarStatus.symbolName, "exclamationmark.triangle.fill")
            XCTAssertEqual(app.permissionPollInterval, 3, "someone in System Settings is waiting for the switch")

            app.updateAccessibilityState(true)
            XCTAssertEqual(app.menuBarStatus, .armed)
        }
    }
}
