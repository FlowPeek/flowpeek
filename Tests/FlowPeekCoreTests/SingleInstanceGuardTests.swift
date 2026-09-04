import XCTest
@testable import FlowPeekCore

final class SingleInstanceGuardTests: XCTestCase {
    private let identifier = "com.flowpeek.FlowPeek"
    private let epoch = Date(timeIntervalSince1970: 1_757_000_000)

    private func instance(_ pid: pid_t, _ offset: TimeInterval, bundle: String? = nil) -> SingleInstanceGuard.Instance {
        SingleInstanceGuard.Instance(
            bundleIdentifier: bundle ?? identifier,
            processIdentifier: pid,
            launchDate: epoch.addingTimeInterval(offset)
        )
    }

    private func decide(
        own: SingleInstanceGuard.Instance,
        running: [SingleInstanceGuard.Instance],
        isReplacingAnInstance: Bool = false
    ) -> SingleInstanceGuard.Decision {
        SingleInstanceGuard.decide(own: own, running: running, isReplacingAnInstance: isReplacingAnInstance)
    }

    /// The ordinary launch: nothing else of ours is running, so this copy is the app.
    func testTheOnlyCopyRuns() {
        let own = instance(900, 0)
        XCTAssertEqual(decide(own: own, running: [own]), .run)
    }

    /// The double-click on an app that is already in the menu bar. The copy that is already there
    /// keeps it; the new one hands the user over to it and leaves.
    func testASecondLaunchStandsAsideForTheCopyAlreadyRunning() {
        let incumbent = instance(340, 0)
        let own = instance(900, 120)
        XCTAssertEqual(decide(own: own, running: [incumbent, own]), .deferTo(340))
    }

    /// The same list read from the incumbent's point of view: it started first, so it carries on.
    func testTheCopyThatStartedFirstCarriesOn() {
        let incumbent = instance(340, 0)
        let latecomer = instance(900, 120)
        XCTAssertEqual(decide(own: incumbent, running: [incumbent, latecomer]), .run)
    }

    /// Exactly one copy may survive a pair of launches that share an instant. A rule of "any other
    /// copy wins" leaves both standing aside and the user with no FlowPeek at all.
    func testTwoCopiesLaunchedAtTheSameInstantLeaveExactlyOneRunning() {
        let first = instance(340, 0)
        let second = instance(900, 0)
        let running = [first, second]
        let decisions = [decide(own: first, running: running), decide(own: second, running: running)]
        XCTAssertEqual(decisions.filter { $0 == .run }.count, 1)
        XCTAssertEqual(decisions, [.run, .deferTo(340)])
    }

    /// macOS reports some processes without a launch date; the pid still has to produce one winner.
    func testCopiesWithNoLaunchDateAreStillOrdered() {
        let first = SingleInstanceGuard.Instance(bundleIdentifier: identifier, processIdentifier: 340)
        let second = SingleInstanceGuard.Instance(bundleIdentifier: identifier, processIdentifier: 900)
        XCTAssertEqual(decide(own: second, running: [first, second]), .deferTo(340))
        XCTAssertEqual(decide(own: first, running: [first, second]), .run)
    }

    func testOtherApplicationsAreNotOurOwnCopies() {
        let own = instance(900, 120)
        let others = [
            instance(120, 0, bundle: "com.apple.Safari"),
            instance(200, 0, bundle: "com.apple.dt.Xcode"),
            instance(300, 0, bundle: "com.flowpeek.FlowPeekHelper"),
        ]
        XCTAssertEqual(decide(own: own, running: others + [own]), .run)
    }

    /// A binary with no bundle identifier -- a test host, or the product run out of the build
    /// directory -- cannot compare itself to anything, and must not refuse to start.
    func testACopyWithNoBundleIdentifierAlwaysRuns() {
        let own = SingleInstanceGuard.Instance(bundleIdentifier: nil, processIdentifier: 900, launchDate: epoch)
        XCTAssertEqual(decide(own: own, running: [instance(340, 0), own]), .run)
    }

    /// The permission relaunch starts a second copy on purpose and terminates the first one a moment
    /// later. Standing aside for a copy that is already on its way out would leave nothing running.
    func testTheCopyStartedByTheRelaunchDoesNotStandAside() {
        let outgoing = instance(340, 0)
        let own = instance(900, 120)
        XCTAssertEqual(decide(own: own, running: [outgoing, own], isReplacingAnInstance: true), .run)
        XCTAssertEqual(decide(own: own, running: [outgoing, own]), .deferTo(340), "only the relaunch is exempt")
    }

    /// The oldest copy is the one to hand the user over to, not merely the first one in the list.
    func testTheOldestCopyIsTheOneBroughtForward() {
        let own = instance(900, 300)
        let running = [instance(700, 120), instance(340, 10), instance(500, 60), own]
        XCTAssertEqual(decide(own: own, running: running), .deferTo(340))
    }
}
