import XCTest
@testable import FlowPeekCore

final class LaunchAtLoginStateTests: XCTestCase {
    func testAnUntouchedLoginItemIsSimplyOff() {
        let state = LaunchAtLoginState.resolve(registered: false, requiresApproval: false, requestedOn: false)
        XCTAssertEqual(state, .off)
        XCTAssertFalse(state.isOn)
        XCTAssertNil(state.noticeKey)
    }

    func testRegisteredMeansOnAndSaysNothingFurther() {
        let state = LaunchAtLoginState.resolve(registered: true, requiresApproval: false, requestedOn: true)
        XCTAssertEqual(state, .on)
        XCTAssertTrue(state.isOn)
        XCTAssertNil(state.noticeKey)
    }

    /// The case that shipped silently broken: `register()` does not throw here, so the switch stayed
    /// on and nothing ever launched at login.
    func testAskingForItAndBeingHeldForApprovalKeepsTheSwitchOnAndExplainsItself() {
        let state = LaunchAtLoginState.resolve(registered: false, requiresApproval: true, requestedOn: true)
        XCTAssertEqual(state, .needsApproval)
        XCTAssertTrue(state.isOn)
        XCTAssertEqual(state.noticeKey, "settings.launch-at-login.needs-approval")
    }

    /// The user who switched FlowPeek off under Login Items: macOS keeps reporting requires-approval
    /// for the disabled registration, and nobody asked for it in this run. Reading that as
    /// needs-approval would turn the switch back on and ask them to undo their own choice.
    func testALoginItemNobodyAskedForReadsAsOffRatherThanPendingApproval() {
        let state = LaunchAtLoginState.resolve(registered: false, requiresApproval: true, requestedOn: false)
        XCTAssertEqual(state, .off)
        XCTAssertFalse(state.isOn)
        XCTAssertNil(state.noticeKey)
    }

    /// Turning the switch on is what makes the pending approval worth mentioning, and it is the same
    /// status either side of that click.
    func testTheSameStatusIsPendingOnlyForTheRunThatAskedForIt() {
        XCTAssertEqual(
            LaunchAtLoginState.resolve(registered: false, requiresApproval: true, requestedOn: true),
            .needsApproval
        )
        XCTAssertEqual(
            LaunchAtLoginState.resolve(registered: false, requiresApproval: true, requestedOn: false),
            .off
        )
    }

    /// An item that is actually enabled is on, whatever else the status flags claim: approval is a
    /// question about something that is not running yet.
    func testAnEnabledItemOutranksAPendingApproval() {
        XCTAssertEqual(
            LaunchAtLoginState.resolve(registered: true, requiresApproval: true, requestedOn: false),
            .on
        )
    }

    func testAskingForItAndNotGettingItReadsAsFailedRatherThanOff() {
        let state = LaunchAtLoginState.resolve(registered: false, requiresApproval: false, requestedOn: true)
        XCTAssertEqual(state, .failed)
        XCTAssertFalse(state.isOn)
        XCTAssertEqual(state.noticeKey, "settings.launch-at-login.failed")
    }

    /// Switching it back off is not a failure, however the previous attempt went.
    func testTurningItOffLeavesNoWarningBehind() {
        XCTAssertEqual(
            LaunchAtLoginState.resolve(registered: false, requiresApproval: false, requestedOn: false),
            .off
        )
    }
}
