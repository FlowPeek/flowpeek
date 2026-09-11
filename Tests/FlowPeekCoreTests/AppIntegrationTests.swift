import XCTest

@testable import FlowPeekCore

/// The rules about when FlowPeek may put an editor in front of somebody, and when it must not.
final class AppIntegrationTests: XCTestCase {
    private func statuses(_ pairs: (String, AppIntegrationStatus)...) -> [(id: String, status: AppIntegrationStatus)] {
        pairs.map { (id: $0.0, status: $0.1) }
    }

    // MARK: - What the wizard shows

    /// The card does not exist on a Mac with none of these editors on it, which is most Macs. A
    /// setup step about software the reader does not have is the kind people learn to click past.
    func testTheWizardSkipsTheCardWhenNothingIsInstalled() {
        XCTAssertFalse(AppIntegrationPolicy.showsOnboardingStep(statuses(("sublime-text", .absent))))
        XCTAssertEqual(AppIntegrationPolicy.onboardingOffers(statuses(("sublime-text", .absent))), [])
    }

    func testTheWizardOffersAnEditorThatIsHereAndNotSetUp() {
        XCTAssertTrue(AppIntegrationPolicy.showsOnboardingStep(statuses(("sublime-text", .offered))))
        XCTAssertEqual(
            AppIntegrationPolicy.onboardingOffers(statuses(("sublime-text", .offered))),
            ["sublime-text"]
        )
    }

    /// Somebody who already said yes is not asked again. An integration carrying the current payload
    /// has nothing for them to do.
    func testAnEditorAlreadySetUpIsNotAnOffer() {
        XCTAssertFalse(AppIntegrationPolicy.showsOnboardingStep(statuses(("sublime-text", .active))))
    }

    /// A payload that has moved on is an offer again: the file in place is ours and is behind.
    func testAnOutdatedPayloadIsOfferedAgain() {
        XCTAssertTrue(
            AppIntegrationPolicy.showsOnboardingStep(statuses(("sublime-text", .outdated(installed: 1))))
        )
    }

    /// A failure is the one state that most needs saying out loud, so it counts as wanting
    /// attention rather than being quietly treated as done.
    func testAFailureAsksToBeSeen() {
        XCTAssertTrue(AppIntegrationPolicy.showsOnboardingStep(statuses(("sublime-text", .failed("disk full")))))
    }

    /// With several editors, one already set up and one not, only the one with something to do is
    /// offered — but the card still appears.
    func testOnlyTheEditorsWithSomethingToDoAreOffered() {
        let mixed = statuses(
            ("one", .active), ("two", .offered), ("three", .absent), ("four", .outdated(installed: 2))
        )
        XCTAssertTrue(AppIntegrationPolicy.showsOnboardingStep(mixed))
        XCTAssertEqual(AppIntegrationPolicy.onboardingOffers(mixed), ["two", "four"])
    }

    // MARK: - What the settings tab lists

    /// The tab is where a decision is undone as well as made, so it lists what is set up too.
    func testTheTabListsEveryEditorFoundHereWhateverItsState() {
        let mixed = statuses(("one", .active), ("two", .offered), ("three", .absent))
        XCTAssertEqual(AppIntegrationPolicy.settingsRows(mixed), ["one", "two"])
        XCTAssertTrue(AppIntegrationPolicy.settingsHasRows(mixed))
    }

    /// An editor that is not on this Mac stays out of the tab as well: the tab says what FlowPeek
    /// can do here, not what it could do somewhere else.
    func testTheTabSaysSoWhenThereIsNothingToList() {
        XCTAssertEqual(AppIntegrationPolicy.settingsRows(statuses(("one", .absent))), [])
        XCTAssertFalse(AppIntegrationPolicy.settingsHasRows(statuses(("one", .absent))))
    }

    // MARK: - The states themselves

    func testTheStatesAgreeOnWhatIsInstalledAndWhatIsPresent() {
        XCTAssertFalse(AppIntegrationStatus.absent.isPresent)
        for status in [AppIntegrationStatus.offered, .active, .outdated(installed: 1), .failed("x")] {
            XCTAssertTrue(status.isPresent, "\(status) means the application is here")
        }
        XCTAssertTrue(AppIntegrationStatus.active.isInstalled)
        XCTAssertTrue(AppIntegrationStatus.outdated(installed: 1).isInstalled)
        XCTAssertFalse(AppIntegrationStatus.offered.isInstalled)
        // A failed write left nothing behind, so the switch must not read as on.
        XCTAssertFalse(AppIntegrationStatus.failed("x").isInstalled)
    }

    // MARK: - The catalogue

    /// The one integration that exists has to be described well enough to be written and found
    /// again, and its identifier is what its state is filed under, so it may never be reworded.
    func testTheSublimeIntegrationNamesEverythingNeededToWriteAndFindIt() {
        let sublime = AppIntegration.sublimeText
        XCTAssertEqual(sublime.id, "sublime-text")
        XCTAssertEqual(sublime.displayName, "Sublime Text")
        XCTAssertTrue(sublime.bundleIDs.contains("com.sublimetext.4"))
        XCTAssertEqual(
            sublime.installDirectory,
            ["Application Support", "Sublime Text", "Packages", "User"],
            "this is where Sublime looks for plugins; it is not a guess"
        )
        XCTAssertEqual(sublime.payloadName, "FlowPeek.py")
        XCTAssertGreaterThan(sublime.payloadVersion, 0)
        XCTAssertTrue(AppIntegration.known.contains(sublime))
    }

    /// Identifiers are the filing system. Two integrations sharing one would overwrite each other's
    /// state, and a renamed one would lose track of a file it had already written.
    func testEveryKnownIntegrationHasItsOwnIdentifier() {
        let ids = AppIntegration.known.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count)
        XCTAssertFalse(ids.contains(where: \.isEmpty))
    }
}
