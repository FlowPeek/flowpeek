import XCTest
@testable import FlowPeekCore

final class ModifierDoubleTapTests: XCTestCase {
    /// One clean press and release at `at`, lasting `held`.
    private func tap(_ recogniser: inout ModifierDoubleTap, at: TimeInterval, held: TimeInterval = 0.05) -> Bool {
        recogniser.press(alone: true, at: at)
        return recogniser.release(at: at + held)
    }

    func testTwoQuickTapsFire() {
        var recogniser = ModifierDoubleTap()
        XCTAssertFalse(tap(&recogniser, at: 0))
        XCTAssertTrue(tap(&recogniser, at: 0.25))
    }

    func testTwoSlowTapsDoNot() {
        var recogniser = ModifierDoubleTap()
        XCTAssertFalse(tap(&recogniser, at: 0))
        XCTAssertFalse(tap(&recogniser, at: 1.2))
    }

    func testExactlyTheIntervalStillCounts() {
        var recogniser = ModifierDoubleTap(interval: 0.5)
        _ = tap(&recogniser, at: 0, held: 0)
        XCTAssertTrue(tap(&recogniser, at: 0.5, held: 0))
    }

    /// Three taps are one gesture, not two. Without clearing the mark, taps two and three would
    /// fire a second time and the diagram would open twice.
    func testThreeTapsFireOnce() {
        var recogniser = ModifierDoubleTap()
        XCTAssertFalse(tap(&recogniser, at: 0))
        XCTAssertTrue(tap(&recogniser, at: 0.2))
        XCTAssertFalse(tap(&recogniser, at: 0.4))
    }

    func testFourTapsFireTwice() {
        var recogniser = ModifierDoubleTap()
        XCTAssertFalse(tap(&recogniser, at: 0))
        XCTAssertTrue(tap(&recogniser, at: 0.2))
        XCTAssertFalse(tap(&recogniser, at: 0.4))
        XCTAssertTrue(tap(&recogniser, at: 0.6))
    }

    /// A hold is the pointer gesture, and this app has one. It must not also be half a double tap.
    func testAHoldIsNotATap() {
        var recogniser = ModifierDoubleTap()
        XCTAssertFalse(tap(&recogniser, at: 0, held: 1.0))
        XCTAssertFalse(tap(&recogniser, at: 0.3))
    }

    func testTheHoldThresholdIsTheBoundary() {
        var recogniser = ModifierDoubleTap()
        _ = tap(&recogniser, at: 0, held: ModifierDoubleTap.maximumHold)
        XCTAssertTrue(tap(&recogniser, at: 0.4), "a press exactly at the threshold is still a tap")

        var other = ModifierDoubleTap()
        _ = tap(&other, at: 0, held: ModifierDoubleTap.maximumHold + 0.01)
        XCTAssertFalse(tap(&other, at: 0.4), "a press past the threshold is a hold")
    }

    /// Option with Command is a chord somebody is typing, not a tap.
    func testAnotherModifierMakesItAChord() {
        var recogniser = ModifierDoubleTap()
        recogniser.press(alone: false, at: 0)
        XCTAssertFalse(recogniser.release(at: 0.05))
        XCTAssertFalse(tap(&recogniser, at: 0.2))
    }

    /// Option and an arrow key: the arrow arrives while the modifier is down.
    func testAKeyWhileHeldMakesItAChord() {
        var recogniser = ModifierDoubleTap()
        recogniser.press(alone: true, at: 0)
        recogniser.interrupt()
        XCTAssertFalse(recogniser.release(at: 0.05))
        XCTAssertFalse(tap(&recogniser, at: 0.2))
    }

    /// Typing between two taps ends them, even though the modifier was not involved.
    func testSomethingBetweenTapsEndsTheGesture() {
        var recogniser = ModifierDoubleTap()
        XCTAssertFalse(tap(&recogniser, at: 0))
        recogniser.interrupt()
        XCTAssertFalse(tap(&recogniser, at: 0.2))
    }

    /// A word jump followed by a genuine double tap still works: the chord must not poison what
    /// comes after it.
    func testAChordDoesNotBlockTheNextGesture() {
        var recogniser = ModifierDoubleTap()
        recogniser.press(alone: true, at: 0)
        recogniser.interrupt()
        _ = recogniser.release(at: 0.05)
        XCTAssertFalse(tap(&recogniser, at: 0.5))
        XCTAssertTrue(tap(&recogniser, at: 0.7))
    }

    func testTheIntervalIsHeldInsideItsRange() {
        XCTAssertEqual(ModifierDoubleTap(interval: 0.05).interval, ModifierDoubleTap.intervalRange.lowerBound)
        XCTAssertEqual(ModifierDoubleTap(interval: 9).interval, ModifierDoubleTap.intervalRange.upperBound)
        XCTAssertEqual(ModifierDoubleTap.defaultInterval, 0.5)
    }

    /// Changing the number mid-gesture would measure half of it against the old one.
    func testChangingTheIntervalForgetsWhatWasInProgress() {
        var recogniser = ModifierDoubleTap()
        XCTAssertFalse(tap(&recogniser, at: 0))
        recogniser.setInterval(0.6)
        XCTAssertFalse(tap(&recogniser, at: 0.2))
    }

    func testForgettingClearsAHalfGesture() {
        var recogniser = ModifierDoubleTap()
        XCTAssertFalse(tap(&recogniser, at: 0))
        recogniser.forget()
        XCTAssertFalse(tap(&recogniser, at: 0.2))
    }

    /// A release with no press in front of it, which is what arriving mid-gesture looks like.
    func testAReleaseWithNoPressIsIgnored() {
        var recogniser = ModifierDoubleTap()
        XCTAssertFalse(recogniser.release(at: 1))
        XCTAssertFalse(tap(&recogniser, at: 1.1))
    }
}
