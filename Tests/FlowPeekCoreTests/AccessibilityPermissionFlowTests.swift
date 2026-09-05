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

/// The `AXManualAccessibility` switch is what makes an Electron app's tree exist at all, and both
/// routes into a preview send it before they read. What the memo decides is how often that message
/// is worth sending to an app that will not take it.
final class AccessibilityWarmUpMemoTests: XCTestCase {
    private let pid: pid_t = 4_242
    private let now = Date()

    func testAProcessThatHasNeverBeenAskedIsWorthAsking() {
        XCTAssertTrue(AccessibilityWarmUpMemo().shouldSend(pid: pid, now: now))
    }

    /// The switch is one boolean per process and it stays set, so a second message buys nothing.
    func testAProcessThatTookTheSwitchIsNeverAskedAgain() {
        var memo = AccessibilityWarmUpMemo()
        memo.note(pid: pid, succeeded: true, now: now)

        XCTAssertTrue(memo.isEnabled(pid: pid))
        XCTAssertFalse(memo.shouldSend(pid: pid, now: now))
        XCTAssertFalse(memo.shouldSend(pid: pid, now: now + AccessibilityWarmUpMemo.retryInterval * 10))
    }

    /// Every app that is not Chromium refuses this attribute every time it is asked, and a hold
    /// asks once per debounce. Without a window on the refusal each of those reads pays for one
    /// more synchronous message to another process that was never going to answer it.
    func testARefusalIsLeftAloneUntilTheRetryWindowHasPassed() {
        var memo = AccessibilityWarmUpMemo()
        memo.note(pid: pid, succeeded: false, now: now)

        XCTAssertFalse(memo.isEnabled(pid: pid))
        XCTAssertFalse(memo.shouldSend(pid: pid, now: now))
        XCTAssertFalse(memo.shouldSend(pid: pid, now: now + AccessibilityWarmUpMemo.retryInterval - 1))
        XCTAssertTrue(memo.shouldSend(pid: pid, now: now + AccessibilityWarmUpMemo.retryInterval))
    }

    /// A refusal is not a verdict on the app, only on the moment: an Electron app that was still
    /// starting its renderer takes the switch on the next window.
    func testASuccessAfterARefusalClearsIt() {
        var memo = AccessibilityWarmUpMemo()
        memo.note(pid: pid, succeeded: false, now: now)
        memo.note(pid: pid, succeeded: true, now: now + AccessibilityWarmUpMemo.retryInterval)

        XCTAssertTrue(memo.isEnabled(pid: pid))
        XCTAssertFalse(memo.shouldSend(pid: pid, now: now + AccessibilityWarmUpMemo.retryInterval * 10))
    }

    /// pids come back around. A new process wearing a dead one's number has its own tree, and both
    /// halves of the memo have to let go of it.
    func testForgettingAProcessLetsTheNextOneWithItsPidBeWarmed() {
        var memo = AccessibilityWarmUpMemo()
        memo.note(pid: pid, succeeded: true, now: now)
        memo.forget(pid: pid)
        XCTAssertTrue(memo.shouldSend(pid: pid, now: now))

        memo.note(pid: pid, succeeded: false, now: now)
        memo.forget(pid: pid)
        XCTAssertTrue(memo.shouldSend(pid: pid, now: now))
    }

    /// Draining hands back exactly the processes whose switch FlowPeek turned on, because those are
    /// the only ones it has any business turning off again.
    func testDrainingReturnsTheProcessesLeftSwitchedOn() {
        var memo = AccessibilityWarmUpMemo()
        memo.note(pid: 1, succeeded: true, now: now)
        memo.note(pid: 2, succeeded: false, now: now)
        memo.note(pid: 3, succeeded: true, now: now)

        XCTAssertEqual(memo.drain().sorted(), [1, 3])
        XCTAssertTrue(memo.drain().isEmpty)
        XCTAssertTrue(memo.shouldSend(pid: 2, now: now))
    }
}
