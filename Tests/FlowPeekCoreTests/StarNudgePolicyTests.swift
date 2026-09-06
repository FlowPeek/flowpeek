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

    /// A busy screen must not be able to answer the question by accident — `asked` is written by
    /// the notice appearing and by nothing else.
    func testDecidingDoesNotChangeTheLedger() {
        let ledger = earned()
        _ = StarNudgePolicy.decide(ledger: ledger, screen: .clear, now: wellAfterTenure)
        XCTAssertEqual(ledger, earned())
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

    func testTheRepositoryAddressIsAUsableURL() {
        let url = URL(string: StarNudgePolicy.repository)
        XCTAssertEqual(url?.scheme, "https")
        XCTAssertEqual(url?.host, "github.com")
    }
}
