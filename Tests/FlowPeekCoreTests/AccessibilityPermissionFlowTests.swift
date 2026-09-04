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

        for _ in 0..<8 { flow.recordUnconfirmedCheck() }

        XCTAssertTrue(flow.shouldOfferRelaunch)
    }
}
