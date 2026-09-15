import XCTest
@testable import FlowPeekCore

/// What an update state is allowed to claim about itself.
///
/// Small, and worth having because two of these answers drive things a reader sees in the menu bar:
/// whether the icon grows a dot, and whether a second press can start a second check on top of one
/// already running.
final class UpdateStateTests: XCTestCase {
    /// Only the states waiting on a decision. A dot for "checking" would blink on every background
    /// check and mean nothing; a dot for "downloading" announces work already accepted.
    func testOnlyTheStatesWaitingOnSomebodyAskForAttention() {
        XCTAssertTrue(UpdateState.available(version: "1.2").wantsAttention)
        XCTAssertTrue(UpdateState.readyToInstall(version: "1.2").wantsAttention)
        XCTAssertTrue(UpdateState.failed("no").wantsAttention)
        XCTAssertFalse(UpdateState.idle.wantsAttention)
        XCTAssertFalse(UpdateState.checking.wantsAttention)
        XCTAssertFalse(UpdateState.downloading(fraction: 0.5).wantsAttention)
        XCTAssertFalse(UpdateState.installing.wantsAttention)
    }

    /// Busy is what stops a second check starting. An offer that nobody has answered is NOT busy:
    /// a reader who ignored it must still be able to look again later.
    func testBusyIsWorkInFlightAndNotAnUnansweredOffer() {
        XCTAssertTrue(UpdateState.checking.isBusy)
        XCTAssertTrue(UpdateState.downloading(fraction: nil).isBusy)
        XCTAssertTrue(UpdateState.installing.isBusy)
        XCTAssertFalse(UpdateState.idle.isBusy)
        XCTAssertFalse(UpdateState.available(version: "1.2").isBusy)
        XCTAssertFalse(UpdateState.readyToInstall(version: "1.2").isBusy)
        XCTAssertFalse(UpdateState.failed("no").isBusy)
    }

    func testTheVersionIsCarriedThroughTheStatesThatOfferOne() {
        XCTAssertEqual(UpdateState.available(version: "0.26.0").version, "0.26.0")
        XCTAssertEqual(UpdateState.readyToInstall(version: "0.26.0").version, "0.26.0")
        XCTAssertNil(UpdateState.idle.version)
        XCTAssertNil(UpdateState.downloading(fraction: 1).version)
    }

    /// Every state is either worth showing or worth waiting through, never both, so the panel row
    /// and the spinner in Settings can never disagree about which one is on screen.
    func testNoStateBothAsksForAttentionAndIsBusy() {
        let all: [UpdateState] = [
            .idle, .checking, .available(version: "1"), .downloading(fraction: nil),
            .downloading(fraction: 0.4), .readyToInstall(version: "1"), .installing, .failed("x"),
        ]
        for state in all {
            XCTAssertFalse(state.wantsAttention && state.isBusy, "\(state) claims both")
        }
    }
}
