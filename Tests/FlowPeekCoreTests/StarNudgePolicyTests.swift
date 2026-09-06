import XCTest
@testable import FlowPeekCore

final class StarNudgePolicyTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func earned(asked: Bool = false) -> StarNudgeLedger {
        StarNudgeLedger(
            diagramsOpened: StarNudgePolicy.diagramsBeforeAsking,
            firstDiagramAt: epoch,
            asked: asked
        )
    }

    private var wellAfterTenure: Date {
        epoch.addingTimeInterval(StarNudgePolicy.minimumTenure + 1)
    }

    func testTheQuestionIsAskedOnceTheCountAndTheTenureAreBothMet() {
        XCTAssertEqual(
            StarNudgePolicy.decide(ledger: earned(), screen: .clear, now: wellAfterTenure),
            .ask
        )
    }

    /// The whole point of the ledger. Once it has been put, no amount of further use, no quiet
    /// screen and no passage of time puts it again.
    func testItIsNeverAskedTwice() {
        let heavilyUsed = StarNudgeLedger(
            diagramsOpened: 10_000,
            firstDiagramAt: epoch,
            asked: true
        )
        XCTAssertEqual(
            StarNudgePolicy.decide(ledger: heavilyUsed, screen: .clear, now: wellAfterTenure),
            .alreadyAsked
        )
        XCTAssertEqual(
            StarNudgePolicy.decide(
                ledger: heavilyUsed,
                screen: .clear,
                now: epoch.addingTimeInterval(365 * 24 * 60 * 60)
            ),
            .alreadyAsked
        )
    }

    /// The two numbers the restraint is made of, written out. Every other test here says "the
    /// threshold", which keeps them honest about the shape of the rule and says nothing at all
    /// about its size — and the size is the decision: forty diagrams over three days is a user who
    /// kept FlowPeek, and three diagrams over a second is anybody who opened it once.
    func testTheThresholdsAreTheOnesThatWereChosen() {
        XCTAssertEqual(StarNudgePolicy.diagramsBeforeAsking, 40)
        XCTAssertEqual(StarNudgePolicy.minimumTenure, 3 * 24 * 60 * 60)
    }

    /// The tenure is a floor, not a fence to be past: the instant it is reached, it is met.
    func testTheTenureIsMetExactlyOnTheBoundary() {
        XCTAssertEqual(
            StarNudgePolicy.decide(
                ledger: earned(),
                screen: .clear,
                now: epoch.addingTimeInterval(StarNudgePolicy.minimumTenure)
            ),
            .ask
        )
    }

    /// A user still working out what FlowPeek is has not been asked anything, and one diagram short
    /// of the threshold is still that user.
    func testOneDiagramShortIsNotEnough() {
        var ledger = earned()
        ledger.diagramsOpened = StarNudgePolicy.diagramsBeforeAsking - 1
        XCTAssertEqual(
            StarNudgePolicy.decide(ledger: ledger, screen: .clear, now: wellAfterTenure),
            .notEarnedYet
        )
    }

    /// Forty diagrams in one sitting is somebody trying the app out, not somebody who has kept it.
    func testTheCountAloneDoesNotEarnIt() {
        XCTAssertEqual(
            StarNudgePolicy.decide(
                ledger: earned(),
                screen: .clear,
                now: epoch.addingTimeInterval(StarNudgePolicy.minimumTenure - 1)
            ),
            .notEarnedYet
        )
    }

    /// An app installed months ago and used twice has earned nothing either.
    func testTheTenureAloneDoesNotEarnIt() {
        let ledger = StarNudgeLedger(diagramsOpened: 2, firstDiagramAt: epoch, asked: false)
        XCTAssertEqual(
            StarNudgePolicy.decide(ledger: ledger, screen: .clear, now: wellAfterTenure),
            .notEarnedYet
        )
    }

    /// A count with no start date can only have come from a store written before the date was kept.
    /// Guessing "long enough" there would fire the notice at the first launch after an update.
    func testACountWithNoStartDateWaits() {
        var ledger = earned()
        ledger.firstDiagramAt = nil
        XCTAssertEqual(
            StarNudgePolicy.decide(ledger: ledger, screen: .clear, now: wellAfterTenure),
            .notEarnedYet
        )
    }

    /// Never over a diagram the user is reading, never over the setup card, never over another
    /// FlowPeek window. Each one on its own is enough to hold the question back.
    func testAnythingOnScreenHoldsTheQuestionBack() {
        let busy: [StarNudgeScreen] = [
            StarNudgeScreen(previewOnScreen: true),
            StarNudgeScreen(onboardingOnScreen: true),
            StarNudgeScreen(otherWindowOnScreen: true),
            StarNudgeScreen(previewOnScreen: true, onboardingOnScreen: true, otherWindowOnScreen: true),
        ]
        for screen in busy {
            XCTAssertEqual(
                StarNudgePolicy.decide(ledger: earned(), screen: screen, now: wellAfterTenure),
                .waitForAQuietMoment,
                "\(screen) should have held the notice back"
            )
        }
        XCTAssertFalse(StarNudgeScreen.clear.isBusy)
    }

    /// Deferring is not answering: the moment the screen clears the question is still owed.
    func testAHeldBackQuestionIsStillAskedLater() {
        let ledger = earned()
        XCTAssertEqual(
            StarNudgePolicy.decide(
                ledger: ledger,
                screen: StarNudgeScreen(previewOnScreen: true),
                now: wellAfterTenure
            ),
            .waitForAQuietMoment
        )
        XCTAssertEqual(StarNudgePolicy.decide(ledger: ledger, screen: .clear, now: wellAfterTenure), .ask)
    }

    // MARK: - Ledger

    func testTheFirstDiagramStartsTheClock() {
        let ledger = StarNudgeLedger().recordingDiagram(at: epoch)
        XCTAssertEqual(ledger.diagramsOpened, 1)
        XCTAssertEqual(ledger.firstDiagramAt, epoch)
    }

    func testLaterDiagramsCountButDoNotMoveTheClock() {
        var ledger = StarNudgeLedger().recordingDiagram(at: epoch)
        ledger = ledger.recordingDiagram(at: epoch.addingTimeInterval(60))
        ledger = ledger.recordingDiagram(at: epoch.addingTimeInterval(120))
        XCTAssertEqual(ledger.diagramsOpened, 3)
        XCTAssertEqual(ledger.firstDiagramAt, epoch)
    }

    /// A Mac whose clock ran fast and was then corrected would otherwise hold a start date in the
    /// future, and the tenure would read as zero for as long as the error lasted.
    func testAClockThatWentBackwardsMovesTheStartDateBack() {
        var ledger = StarNudgeLedger().recordingDiagram(at: epoch.addingTimeInterval(1_000))
        ledger = ledger.recordingDiagram(at: epoch)
        XCTAssertEqual(ledger.firstDiagramAt, epoch)
    }

    /// Nothing is left to ask, so nothing is left to write: the store is untouched from here on.
    func testCountingStopsOnceTheQuestionHasBeenPut() {
        let asked = earned(asked: true)
        XCTAssertEqual(asked.recordingDiagram(at: wellAfterTenure), asked)
    }

    func testAskingIsRecorded() {
        XCTAssertTrue(earned().asking().asked)
    }

    /// Saturating rather than wrapping: an overflow trap while opening a diagram would be a crash
    /// caused by a counter nothing reads any more.
    func testTheCounterDoesNotOverflow() {
        let ledger = StarNudgeLedger(diagramsOpened: .max, firstDiagramAt: epoch, asked: false)
        XCTAssertEqual(ledger.recordingDiagram(at: wellAfterTenure).diagramsOpened, .max)
    }

    /// The one address the one button opens. Pinned in full: a scheme and a host would be just as
    /// happy with somebody else's repository, and nobody would find out until the button was
    /// pressed — once, by a user who had already decided to be generous.
    func testTheRepositoryAddressIsTheRepository() {
        XCTAssertEqual(StarNudgePolicy.repository, "https://github.com/FlowPeek/flowpeek")
        let url = URL(string: StarNudgePolicy.repository)
        XCTAssertEqual(url?.scheme, "https")
        XCTAssertEqual(url?.host, "github.com")
    }

    // MARK: - The moment

    /// The failure notice and the diagram share a panel slot, so an emptied slot on its own does
    /// not say the app worked. Only a diagram going away does.
    func testOnlyADiagramLeavingTheScreenIsAMomentToAsk() {
        XCTAssertTrue(StarNudgePolicy.isAskableMoment(previous: .diagram, current: .none))

        // FlowPeek has just said it could not do the thing that was asked of it, and the user has
        // closed the notice saying so. Everything about that looks like a preview closing.
        XCTAssertFalse(StarNudgePolicy.isAskableMoment(previous: .message, current: .none))
        XCTAssertFalse(StarNudgePolicy.isAskableMoment(previous: .none, current: .none))
    }

    /// A diagram replaced by a failure, or promoted into a window, has not left the screen.
    func testADiagramGivingWayToSomethingElseIsNotAMoment() {
        XCTAssertFalse(StarNudgePolicy.isAskableMoment(previous: .diagram, current: .message))
        XCTAssertFalse(StarNudgePolicy.isAskableMoment(previous: .diagram, current: .diagram))
    }

    /// Nothing arriving is never the moment, whatever arrives.
    func testAnArrivalIsNeverAMoment() {
        for arriving in [PreviewSurface.diagram, .message] {
            XCTAssertFalse(
                StarNudgePolicy.isAskableMoment(previous: .none, current: arriving),
                "\(arriving) appearing should not be a moment to ask"
            )
            XCTAssertFalse(
                StarNudgePolicy.isAskableMoment(previous: .message, current: arriving),
                "\(arriving) replacing a failure notice should not be a moment to ask"
            )
        }
    }
}
