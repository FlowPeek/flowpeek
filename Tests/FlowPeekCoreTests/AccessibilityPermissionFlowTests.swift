import XCTest
@testable import FlowPeekCore

final class AccessibilityPermissionFlowTests: XCTestCase {
    func testGrantingPermissionWhileWaitingCompletesTheFlow() {
        var flow = AccessibilityPermissionFlow(isGranted: false)
        flow.beginWaitingForSystemSettings()

        XCTAssertEqual(flow.phase, .waitingForUser)
        XCTAssertFalse(flow.shouldComplete)

        flow.update(isGranted: true)

        XCTAssertEqual(flow.phase, .granted)
        XCTAssertTrue(flow.shouldComplete)
    }

    func testOffersRelaunchWhenMacOSDoesNotRefreshPermission() {
        var flow = AccessibilityPermissionFlow(isGranted: false)
        flow.beginWaitingForSystemSettings()

        for _ in 0..<45 { flow.recordUnconfirmedCheck() }

        XCTAssertTrue(flow.shouldOfferRelaunch)
    }

    /// Hunting for the FlowPeek row is not a failure, so the recovery offer must not appear while
    /// the user is still plausibly doing it.
    func testStaysQuietWhileTheUserIsStillLookingForTheSwitch() {
        var flow = AccessibilityPermissionFlow(isGranted: false)
        flow.beginWaitingForSystemSettings()

        for _ in 0..<44 { flow.recordUnconfirmedCheck() }

        XCTAssertFalse(flow.shouldOfferRelaunch)
    }

    /// Opening System Settings a second time restarts the clock, so a fresh attempt does not
    /// inherit the previous one's exhausted patience.
    func testReopeningSettingsRestartsThePatience() {
        var flow = AccessibilityPermissionFlow(isGranted: false)
        flow.beginWaitingForSystemSettings()
        for _ in 0..<45 { flow.recordUnconfirmedCheck() }

        flow.beginWaitingForSystemSettings()

        XCTAssertFalse(flow.shouldOfferRelaunch)
    }
}
