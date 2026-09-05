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

    /// The state with nothing to show for itself: `register()` does not throw here, so without the
    /// status to read the switch would sit on while nothing ever launched at login.
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

final class LaunchAtLoginAnswerTests: XCTestCase {
    /// What the app holds after working the switch, through the same call the switch itself makes:
    /// the request first, then whatever the system reports once it has been asked.
    private func afterFlipping(
        _ enabled: Bool,
        on answer: LaunchAtLoginAnswer,
        statusBecomes status: (registered: Bool, requiresApproval: Bool)
    ) -> LaunchAtLoginAnswer {
        answer.requesting(
            enabled,
            thenReading: status.registered,
            requiresApproval: status.requiresApproval
        )
    }

    /// The flow the whole feature exists for, end to end. macOS is already holding a registration
    /// at requires-approval from an earlier run, so it reads as off and says nothing; the user
    /// switches it on and `register()` hands the same status straight back. The answer still has to
    /// move, or the amber line and the Login Items door never appear and the switch sits on with no
    /// explanation. Anything that decides "nothing changed" from the status alone loses this.
    func testSwitchingOnAnItemAlreadyHeldForApprovalMovesTheAnswer() {
        let beforeTheClick = LaunchAtLoginAnswer(registered: false, requiresApproval: true)
        XCTAssertEqual(beforeTheClick.state, .off)
        XCTAssertNil(beforeTheClick.state.noticeKey)

        let afterTheClick = afterFlipping(
            true,
            on: beforeTheClick,
            statusBecomes: (registered: false, requiresApproval: true)
        )
        XCTAssertNotEqual(afterTheClick, beforeTheClick)
        XCTAssertEqual(afterTheClick.state, .needsApproval)
        XCTAssertTrue(afterTheClick.state.isOn)
        XCTAssertEqual(afterTheClick.state.noticeKey, "settings.launch-at-login.needs-approval")
    }

    /// The mirror: a registration that never took, switched back off. `unregister()` leaves the
    /// status where it was, so again only the request moved — and the failure notice has to go
    /// rather than sit over a switch that is now honestly off.
    func testSwitchingOffAFailedRegistrationClearsItsNotice() {
        let failed = LaunchAtLoginAnswer(registered: false, requiresApproval: false, requestedOn: true)
        XCTAssertEqual(failed.state, .failed)

        let afterTheClick = afterFlipping(
            false,
            on: failed,
            statusBecomes: (registered: false, requiresApproval: false)
        )
        XCTAssertNotEqual(afterTheClick, failed)
        XCTAssertEqual(afterTheClick.state, .off)
        XCTAssertNil(afterTheClick.state.noticeKey)
    }

    /// Both statuses that survive their own register call, in one place: whichever way the switch
    /// goes, the click alone is a different answer.
    func testTheClickIsAChangeForEveryStatusThatDoesNotMoveWithIt() {
        for status in [(registered: false, requiresApproval: true), (registered: false, requiresApproval: false)] {
            for enabled in [true, false] {
                let before = LaunchAtLoginAnswer(
                    registered: status.registered,
                    requiresApproval: status.requiresApproval,
                    requestedOn: !enabled
                )
                let after = afterFlipping(enabled, on: before, statusBecomes: status)
                XCTAssertNotEqual(after, before, "\(status) flipped to \(enabled)")
                XCTAssertNotEqual(after.state, before.state, "\(status) flipped to \(enabled)")
            }
        }
    }

    /// Returning from System Settings without approving: the activation re-read finds nothing new,
    /// and the notice the user was sent there by has to still be on screen.
    func testComingBackWithoutApprovingChangesNothing() {
        let pending = LaunchAtLoginAnswer(registered: false, requiresApproval: true, requestedOn: true)
        XCTAssertNil(pending.rereading(registered: false, requiresApproval: true))
        XCTAssertEqual(pending.state, .needsApproval)
    }

    /// And approving is a change, without the app having asked again.
    func testApprovalArrivesAsARereadOfTheSystemStatus() {
        let pending = LaunchAtLoginAnswer(registered: false, requiresApproval: true, requestedOn: true)
        let approved = pending.rereading(registered: true, requiresApproval: false)
        XCTAssertEqual(approved?.state, .on)
        XCTAssertNil(approved?.state.noticeKey)
        // The request is the app's to remember; re-reading the system must not forget it.
        XCTAssertEqual(approved?.requestedOn, true)
    }
}
