import XCTest
@testable import FlowPeekCore

/// The gesture that brings a hidden menu bar icon back. Tested harder than its size suggests,
/// because it is the only way back: every case where it refuses to reveal is a user locked out of
/// their own app.
final class ModifierHoldTests: XCTestCase {
    private func hold() -> ModifierHold {
        ModifierHold(holdDuration: 5, grace: 8)
    }

    func testNothingIsRevealedBeforeTheHoldIsUp() {
        var subject = hold()
        for time in stride(from: 0.0, to: 5.0, by: 0.25) {
            XCTAssertFalse(subject.observe(alone: true, at: time), "revealed at \(time)")
        }
    }

    func testTheHoldRevealsExactlyAtItsDuration() {
        var subject = hold()
        _ = subject.observe(alone: true, at: 0)
        XCTAssertFalse(subject.observe(alone: true, at: 4.75))
        XCTAssertTrue(subject.observe(alone: true, at: 5.0))
    }

    func testLettingGoEarlyStartsTheHoldOver() {
        var subject = hold()
        _ = subject.observe(alone: true, at: 0)
        _ = subject.observe(alone: true, at: 4.5)
        _ = subject.observe(alone: false, at: 4.75)
        // Four and a half seconds of credit must not carry across the release: the hold starts
        // again from the press at 5.0 and is only up five seconds after that.
        XCTAssertFalse(subject.observe(alone: true, at: 5.0))
        XCTAssertFalse(subject.observe(alone: true, at: 9.75))
        XCTAssertTrue(subject.observe(alone: true, at: 10.0))
    }

    func testAChordIsNotAHold() {
        var subject = hold()
        for time in stride(from: 0.0, through: 12.0, by: 0.25) {
            XCTAssertFalse(subject.observe(alone: false, at: time))
        }
    }

    /// The case that makes the feature usable at all: the icon has to outlive the key, or the hand
    /// that let go of it can never reach the menu bar to click it.
    func testItStaysForTheGraceAfterTheKeyComesUp() {
        var subject = hold()
        _ = subject.observe(alone: true, at: 0)
        XCTAssertTrue(subject.observe(alone: true, at: 5))
        XCTAssertTrue(subject.observe(alone: false, at: 6))
        XCTAssertTrue(subject.observe(alone: false, at: 12.9))
        XCTAssertFalse(subject.observe(alone: false, at: 13.1))
    }

    func testHoldingOnKeepsItAliveWithoutRestartingTheGrace() {
        var subject = hold()
        _ = subject.observe(alone: true, at: 0)
        XCTAssertTrue(subject.observe(alone: true, at: 5))
        XCTAssertTrue(subject.observe(alone: true, at: 30))
        XCTAssertTrue(subject.observe(alone: false, at: 37))
        XCTAssertFalse(subject.observe(alone: false, at: 38.1))
    }

    func testAnOpenMenuIsNeverTakenAway() {
        var subject = hold()
        _ = subject.observe(alone: true, at: 0)
        XCTAssertTrue(subject.observe(alone: true, at: 5))
        subject.setPinned(true, at: 5)
        _ = subject.observe(alone: false, at: 6)
        XCTAssertTrue(subject.observe(alone: false, at: 600))
        // And once it is let go of, the grace runs from then rather than from the key.
        subject.setPinned(false, at: 600)
        XCTAssertTrue(subject.observe(alone: false, at: 604))
        XCTAssertFalse(subject.observe(alone: false, at: 609))
    }

    func testPrimingShowsItForTheGraceWithNoGesture() {
        var subject = hold()
        subject.prime(at: 0)
        XCTAssertTrue(subject.isRevealed)
        XCTAssertTrue(subject.observe(alone: false, at: 7.9))
        XCTAssertFalse(subject.observe(alone: false, at: 8.1))
    }

    func testForgettingDropsAGestureInProgress() {
        var subject = hold()
        _ = subject.observe(alone: true, at: 0)
        subject.forget()
        XCTAssertFalse(subject.observe(alone: true, at: 5))
        XCTAssertTrue(subject.observe(alone: true, at: 10))
    }

    /// A Mac that slept with Option down comes back with a clock far ahead of the press. Without
    /// this the first look after waking completes a hold nobody performed.
    func testAClockThatJumpsBackwardsDoesNotCompleteAHold() {
        var subject = hold()
        _ = subject.observe(alone: true, at: 1_000)
        XCTAssertFalse(subject.observe(alone: true, at: 10))
        XCTAssertFalse(subject.observe(alone: true, at: 14.9))
        XCTAssertTrue(subject.observe(alone: true, at: 15))
    }

    func testProgressRunsFromNothingToOneAndStaysThere() {
        var subject = hold()
        XCTAssertEqual(subject.progress(at: 0), 0)
        _ = subject.observe(alone: true, at: 0)
        XCTAssertEqual(subject.progress(at: 2.5), 0.5, accuracy: 0.0001)
        _ = subject.observe(alone: true, at: 5)
        XCTAssertEqual(subject.progress(at: 5), 1)
        _ = subject.observe(alone: false, at: 6)
        XCTAssertEqual(subject.progress(at: 6), 1)
    }

    func testProgressIsNothingWhenTheKeyIsUp() {
        var subject = hold()
        _ = subject.observe(alone: true, at: 0)
        _ = subject.observe(alone: false, at: 1)
        XCTAssertEqual(subject.progress(at: 1), 0)
    }
}
