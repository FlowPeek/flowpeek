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

/// What the menu bar panel decides to show.
///
/// Kept here as a pure rule rather than read off a view, because the fault it guards against is one
/// nobody sees until they press the button: a check whose whole answer is "nothing to get" showed
/// no row at all, so the press looked exactly like a press that did nothing.
final class UpdateNoteworthinessTests: XCTestCase {
    /// The rule the panel uses: something waiting, something happening, or something just answered.
    private func noteworthy(_ state: UpdateState, confirmed: Bool) -> Bool {
        state.wantsAttention || state.isBusy || confirmed
    }

    func testAnswerlessChecksStillShowSomething() {
        // The case that was wrong: the check came back, found nothing, and left no trace.
        XCTAssertTrue(noteworthy(.idle, confirmed: true))
        XCTAssertFalse(noteworthy(.idle, confirmed: false), "and it does not linger forever")
    }

    func testWorkInFlightIsAlwaysShown() {
        XCTAssertTrue(noteworthy(.checking, confirmed: false))
        XCTAssertTrue(noteworthy(.downloading(fraction: nil), confirmed: false))
        XCTAssertTrue(noteworthy(.installing, confirmed: false))
    }

    func testThingsWaitingOnTheReaderAreAlwaysShown() {
        XCTAssertTrue(noteworthy(.available(version: "1"), confirmed: false))
        XCTAssertTrue(noteworthy(.readyToInstall(version: "1"), confirmed: false))
        XCTAssertTrue(noteworthy(.failed("x"), confirmed: false))
    }

    /// Every state the panel can be in has something to say, so a row is never drawn empty.
    func testEveryShownStateHasAReasonToBeShown() {
        let all: [UpdateState] = [
            .idle, .checking, .available(version: "1"), .downloading(fraction: 0.3),
            .readyToInstall(version: "1"), .installing, .failed("x"),
        ]
        for state in all where noteworthy(state, confirmed: false) {
            XCTAssertTrue(state.wantsAttention || state.isBusy, "\(state) is shown for no reason")
        }
    }
}
