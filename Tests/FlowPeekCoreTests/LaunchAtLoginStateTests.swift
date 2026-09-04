import XCTest
@testable import FlowPeekCore

final class LaunchAtLoginStateTests: XCTestCase {
    func testAnUntouchedLoginItemIsSimplyOff() {
        let state = LaunchAtLoginState.resolve(registered: false, requiresApproval: false, requestedOn: false)
        XCTAssertEqual(state, .off)
        XCTAssertFalse(state.isOn)
        XCTAssertNil(state.noticeKey)
        XCTAssertFalse(state.offersLoginItems)
    }

    func testRegisteredMeansOnAndSaysNothingFurther() {
        let state = LaunchAtLoginState.resolve(registered: true, requiresApproval: false, requestedOn: true)
        XCTAssertEqual(state, .on)
        XCTAssertTrue(state.isOn)
        XCTAssertNil(state.noticeKey)
    }

    /// The case that shipped silently broken: `register()` does not throw here, so the switch stayed
    /// on and nothing ever launched at login.
    func testRequiresApprovalKeepsTheSwitchOnAndExplainsItself() {
        let state = LaunchAtLoginState.resolve(registered: false, requiresApproval: true, requestedOn: true)
        XCTAssertEqual(state, .needsApproval)
        XCTAssertTrue(state.isOn)
        XCTAssertEqual(state.noticeKey, "settings.launch-at-login.needs-approval")
        XCTAssertTrue(state.offersLoginItems)
    }

    /// macOS reports approval-pending the same way whether or not this launch asked for it.
    func testApprovalOutranksWhatTheUserAskedFor() {
        XCTAssertEqual(
            LaunchAtLoginState.resolve(registered: false, requiresApproval: true, requestedOn: false),
            .needsApproval
        )
        XCTAssertEqual(
            LaunchAtLoginState.resolve(registered: true, requiresApproval: true, requestedOn: false),
            .needsApproval
        )
    }

    func testAskingForItAndNotGettingItReadsAsFailedRatherThanOff() {
        let state = LaunchAtLoginState.resolve(registered: false, requiresApproval: false, requestedOn: true)
        XCTAssertEqual(state, .failed)
        XCTAssertFalse(state.isOn)
        XCTAssertEqual(state.noticeKey, "settings.launch-at-login.failed")
        XCTAssertTrue(state.offersLoginItems)
    }

    /// Switching it back off is not a failure, however the previous attempt went.
    func testTurningItOffLeavesNoWarningBehind() {
        XCTAssertEqual(
            LaunchAtLoginState.resolve(registered: false, requiresApproval: false, requestedOn: false),
            .off
        )
    }
}
